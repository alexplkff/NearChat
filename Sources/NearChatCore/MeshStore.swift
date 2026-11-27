import Foundation

public struct MeshStorageLimits: Sendable {
    public var historyBytes: Int64
    public var relayBytes: Int64
    public static let defaults = Self(historyBytes: 100_000_000, relayBytes: 5_000_000)
    public init(historyBytes: Int64, relayBytes: Int64) {
        self.historyBytes = historyBytes; self.relayBytes = relayBytes
    }
}
public struct MeshStorageUsage {
    public let historyFiles: Int64
    public let relayFiles: Int64
    public let outgoingTasks: Int
    public let relayTasks: Int
}
enum TransferPhase: String, Codable { case waiting, handedOff }
struct TransferTask: Codable, Equatable {
    var packet: MeshPacket
    var phase: TransferPhase = .waiting
    var custodian: PeerCard?
    var receivedFrom: String?
    var groupIntent: GroupIntent? = nil
}
struct DeliveryEvidence: Codable, Equatable {
    let messageID: UUID
    let recipient: PeerCard
    let digest: Data
    var state: DeliveryState
}
struct InboxEvidence: Codable, Equatable {
    let digest: Data
    var delivered: MeshPacket?
    var read: MeshPacket?
    var deliveredKey: String? = nil
    var readKey: String? = nil
    var originalDeadline: Date? = nil
    var proofDeadline: Date? = nil
    var deadline: Date {
        [originalDeadline, proofDeadline, delivered?.deadline, read?.deadline].compactMap { $0 }.max() ?? .distantPast
    }
    // Receipt ciphertext belongs to the relay budget; history keeps only references and dedup metadata.
    var metadata: Self {
        var value = self
        value.deliveredKey = delivered?.storageKey ?? deliveredKey
        value.readKey = read?.storageKey ?? readKey
        value.proofDeadline = deadline
        value.delivered = nil; value.read = nil
        return value
    }
}
struct AcceptedOffer: Codable {
    let incoming: CustodyOffer
    let ownOfferID: UUID
}
struct HandoffMarker: Codable {
    let packetID: UUID
    let recipientID: String
    let digest: Data
    let offerID: UUID
    let custodian: PeerCard
    let deadline: Date
}

/// Serialized transactional stores. Limits include live SQLite journals via the VFS.
/// The old sealed history file is in the history directory and counts during migration.
public final class MeshStore {
    let own: SQLiteArchive
    let relay: SQLiteArchive
    public var limits: MeshStorageLimits { MeshStorageLimits(historyBytes: own.budget, relayBytes: relay.budget) }
    let identity: MeshIdentity
    var conversationIndex = ConversationIndex()
    public private(set) var unreadMessageIDs: Set<UUID> = []

    public init(directory: URL, identity: MeshIdentity, limits: MeshStorageLimits = .defaults) throws {
        self.identity = identity
        own = try SQLiteArchive(directory: directory, category: "history", budget: limits.historyBytes, identity: identity)
        relay = try SQLiteArchive(directory: directory.appendingPathComponent("relay", isDirectory: true),
            category: "relay", budget: limits.relayBytes, identity: identity)
        // Derived in-memory index: the persisted readAt field remains authoritative.
        // Legacy v1 rows have no receipt digest and are not retroactively marked unread.
        for row in try own.recordInfo() where row.space == "history" {
            if let entry = try own.decode(ChatEntry.self, space: "history", id: row.id) {
                conversationIndex.update(entry.id, entry: entry, order: row.order)
                if entry.isUnread { unreadMessageIDs.insert(entry.id) }
            }
        }
    }
    public func history(limit: Int = MeshEngine.historyLimit) throws -> [ChatEntry] {
        try own.all(space: "history", limit: limit).map {
            try validatedHistoryEntry(JSONDecoder().decode(ChatEntry.self, from: $0.data))
        }
    }
    func validatedHistoryEntry(_ value: ChatEntry) throws -> ChatEntry {
        var entry = value
        try entry.sender.validate()
        try ChatPayload.validate(entry.text)
        guard (0...256).contains(entry.hops),
              entry.outgoing ? entry.sender.id == identity.card.id : entry.recipient == identity.card.id else {
            throw MeshStorageError.corrupt
        }
        entry.isSaved = true
        return entry
    }
    public func usage() throws -> MeshStorageUsage {
        MeshStorageUsage(historyFiles: own.bytesOnDisk, relayFiles: relay.bytesOnDisk,
            outgoingTasks: try own.count(space: "outbox") + own.count(space: "awaiting") + own.count(space: "secure-intent"),
            relayTasks: try relay.count(space: "relay"))
    }
    public func importLegacy(_ entries: [ChatEntry]) throws {
        guard try own.row(space: "meta", id: "legacy-imported") == nil else { return }
        var inserted: [ChatEntry] = []
        try own.transaction {
            for var entry in entries {
                guard try own.row(space: "history", id: entry.id.uuidString) == nil else { continue }
                if entry.outgoing && entry.state == .sent { entry.state = .failed }
                entry.isSaved = true
                try own.put(space: "history", id: entry.id.uuidString, value: entry)
                inserted.append(entry)
            }
            try own.put(space: "meta", id: "legacy-imported", data: Data([1]))
        }
        for entry in inserted { updateUnread(entry) }
    }
    func remember(_ card: PeerCard) throws {
        try card.validate()
        if try own.row(space: "peer", id: card.id) == nil, try own.all(space: "peer").count >= 64 { return }
        try own.transaction { try own.put(space: "peer", id: card.id, value: card) }
    }
    func knownPeers() throws -> [PeerCard] { try decode(PeerCard.self, archive: own, space: "peer") }
    func card(_ id: String) throws -> PeerCard? {
        guard id.count == 64, id.allSatisfy({ $0.isHexDigit }) else { return nil }
        if let card = try own.decode(PeerCard.self, space: "peer", id: id) { return card }
        guard let row = try own.last(space: "delivery", suffix: ":" + id) else { return nil }
        return try JSONDecoder().decode(DeliveryEvidence.self, from: row.data).recipient
    }
    func entry(_ id: UUID) throws -> ChatEntry? { try own.decode(ChatEntry.self, space: "history", id: id.uuidString) }
    func inbox(_ id: UUID) throws -> InboxEvidence? {
        guard var value = try own.decode(InboxEvidence.self, space: "inbox", id: id.uuidString) else { return nil }
        func packet(_ key: String?) throws -> MeshPacket? {
            guard let key else { return nil }
            return try (relay.decode(TransferTask.self, space: "origin", id: key) ??
                relay.decode(TransferTask.self, space: "originAwaiting", id: key))?.packet
        }
        value.delivered = try packet(value.deliveredKey)
        value.read = try packet(value.readKey)
        return value
    }
    func outgoing() throws -> [TransferTask] { try decode(TransferTask.self, archive: own, space: "outbox") }
    func relayTasks() throws -> [TransferTask] { try decode(TransferTask.self, archive: relay, space: "relay") }
    func originControls() throws -> [TransferTask] { try decode(TransferTask.self, archive: relay, space: "origin") }
    func ownTask(key: String) throws -> TransferTask? {
        try own.decode(TransferTask.self, space: "outbox", id: key) ?? own.decode(TransferTask.self, space: "awaiting", id: key)
    }

    func enqueue(_ entry: ChatEntry, packets: [(MeshPacket, PeerCard)], intents: [SecureSendIntent] = []) throws {
        try writeHistory(protecting: entry.id) {
            try self.own.put(space: "history", id: entry.id.uuidString, value: entry)
            for intent in intents { try self.own.put(space: "secure-intent", id: intent.key, value: intent) }
            for (packet, recipient) in packets {
                try self.own.put(space: "outbox", id: packet.storageKey, value: TransferTask(packet: packet),
                                 expiry: packet.deadline)
                try self.own.put(space: "delivery", id: packet.storageKey,
                    value: DeliveryEvidence(messageID: entry.id, recipient: recipient,
                                            digest: try packet.digest(), state: .queued))
            }
        }
    }
    func restore(_ entry: ChatEntry, tasks: [TransferTask], evidence: [DeliveryEvidence], inbox: InboxEvidence?, intents: [SecureSendIntent] = []) throws {
        try writeHistory(protecting: entry.id) {
            var saved = entry; saved.isSaved = true
            for intent in intents { try self.own.put(space: "secure-intent", id: intent.key, value: intent) }
            try self.own.put(space: "history", id: entry.id.uuidString, value: saved)
            for value in evidence {
                let key = "\(value.messageID.uuidString):\(value.recipient.id)"
                try self.own.put(space: "delivery", id: key, value: value)
            }
            for task in tasks {
                let state = evidence.first { $0.recipient.id == task.packet.body.recipient }?.state
                guard state != .delivered && state != .read && state != .failed else { continue }
                try self.own.put(space: task.phase == .waiting ? "outbox" : "awaiting",
                    id: task.packet.storageKey, value: task, expiry: task.packet.deadline)
            }
            if let inbox {
                try self.own.put(space: "inbox", id: entry.id.uuidString, value: inbox.metadata, expiry: inbox.deadline)
            }
        }
        updateUnread(entry)
    }
    @discardableResult
    func accept(_ entry: ChatEntry, evidence: InboxEvidence) throws -> Bool {
        if let known = try inbox(entry.id) {
            guard known.digest == evidence.digest else { throw MeshError.invalidPacket }
            return false
        }
        guard try self.entry(entry.id) == nil else { throw MeshError.invalidPacket }
        try writeHistory(protecting: entry.id) {
            try self.own.put(space: "history", id: entry.id.uuidString, value: entry)
            try self.own.put(space: "inbox", id: entry.id.uuidString, value: evidence.metadata, expiry: evidence.deadline)
        }
        updateUnread(entry)
        return true
    }
    func saveRead(_ entry: ChatEntry, evidence: InboxEvidence) throws {
        guard try self.entry(entry.id) != nil else { unreadMessageIDs.remove(entry.id); return }
        // Updating the oldest row must not protect it from FIFO by deleting newer
        // conversations. On failure the engine keeps this read update in RAM.
        try own.transaction {
            try self.own.put(space: "history", id: entry.id.uuidString, value: entry)
            try self.own.put(space: "inbox", id: entry.id.uuidString, value: evidence.metadata, expiry: evidence.deadline)
        }
        updateUnread(entry)
    }
    private func updateUnread(_ entry: ChatEntry) {
        if !entry.outgoing && entry.readAt == nil && entry.packetDigest != nil { unreadMessageIDs.insert(entry.id) }
        else { unreadMessageIDs.remove(entry.id) }
    }
    func removeUnread(_ ids: Set<UUID>) { unreadMessageIDs.subtract(ids) }
    func noteAttempt(_ packet: MeshPacket) throws {
        guard var evidence = try own.decode(DeliveryEvidence.self, space: "delivery", id: packet.storageKey),
              evidence.state == .queued else { return }
        evidence.state = .sent
        try own.transaction {
            try own.put(space: "delivery", id: packet.storageKey, value: evidence)
            try aggregate(packet.body.id)
        }
    }
    func apply(_ receipt: FinalReceipt, signedBy sender: PeerCard) throws {
        let key = "\(receipt.messageID.uuidString):\(receipt.recipientID)"
        guard receipt.recipientID == sender.id, receipt.digest.count == 32 else { throw MeshError.invalidPacket }
        guard var evidence = try own.decode(DeliveryEvidence.self, space: "delivery", id: key) else {
            if let task = try relay.decode(TransferTask.self, space: "origin", id: key) ?? relay.decode(TransferTask.self, space: "originAwaiting", id: key),
               task.packet.body.kind == .group {
                guard task.packet.body.recipient == sender.id, try task.packet.digest() == receipt.digest else { throw MeshError.invalidPacket }
                try relay.transaction {
                    try relay.remove(space: "origin", id: key); try relay.remove(space: "originAwaiting", id: key)
                }
                return
            }
            if try entry(receipt.messageID) != nil { throw MeshError.invalidPacket }
            return
        }
        guard evidence.recipient.id == sender.id, evidence.digest == receipt.digest else { throw MeshError.invalidPacket }
        if evidence.state == .read { return }
        evidence.state = receipt.kind == .read ? .read : .delivered
        try own.transaction {
            try own.put(space: "delivery", id: key, value: evidence)
            try own.remove(space: "outbox", id: key)
            try own.remove(space: "awaiting", id: key)
            try aggregate(receipt.messageID)
        }
    }
    func enqueueControl(_ packet: MeshPacket, now: Date, groupIntent: GroupIntent? = nil) throws {
        guard now < packet.deadline else { return }
        guard try relay.row(space: "origin", id: packet.storageKey) == nil,
              try relay.row(space: "originAwaiting", id: packet.storageKey) == nil else { return }
        try relay.transaction {
            try relay.removeExpired(now: now)
            try relay.put(space: "origin", id: packet.storageKey, value: TransferTask(packet: packet, groupIntent: groupIntent), expiry: packet.deadline)
        }
    }
    /// True only after packet+dedup offer have committed; only then may the caller ACK.
    func admit(_ incoming: MeshPacket, from neighbor: String, now: Date) throws -> Bool {
        guard incoming.remainingHops > 1, let upstream = incoming.offer else { return false }
        let key = incoming.storageKey
        let active = try relay.decode(TransferTask.self, space: "relay", id: key)
        if let accepted = try relay.decode(AcceptedOffer.self, space: "accepted", id: upstream.body.id.uuidString) {
            guard accepted.incoming.body.digest == (try incoming.digest()) else { throw MeshError.invalidPacket }
            return active?.packet.offer?.body.id == accepted.ownOfferID
        }
        var task: TransferTask
        if let active {
            guard try active.packet.digest() == incoming.digest() else { throw MeshError.invalidPacket }
            task = active
        } else {
            var outgoing = incoming
            outgoing.remainingHops -= 1
            try outgoing.offerCustody(by: identity)
            task = TransferTask(packet: outgoing, receivedFrom: neighbor)
        }
        guard let ownOffer = task.packet.offer else { throw MeshError.invalidPacket }
        try relay.transaction {
            try relay.removeExpired(now: now)
            try relay.put(space: "relay", id: key, value: task, expiry: incoming.deadline)
            try relay.put(space: "accepted", id: upstream.body.id.uuidString,
                value: AcceptedOffer(incoming: upstream, ownOfferID: ownOffer.body.id), expiry: incoming.deadline)
        }
        return true
    }
    func apply(_ control: TransferControl, signedBy sender: PeerCard) throws {
        let key = "\(control.packetID.uuidString):\(control.recipientID)"
        if var task = try ownTask(key: key),
           task.packet.offer?.body.id == control.offerID, try task.packet.digest() == control.digest {
            if control.kind == .applied {
                guard sender.id == task.packet.body.recipient else { throw MeshError.invalidPacket }
                try apply(FinalReceipt(messageID: control.packetID, recipientID: sender.id,
                    digest: control.digest, kind: .delivered), signedBy: sender)
            } else if task.phase == .waiting {
                task.phase = .handedOff; task.custodian = sender
                try own.transaction {
                    try own.move(from: "outbox", to: "awaiting", id: key, value: task, expiry: task.packet.deadline)
                    if var evidence = try own.decode(DeliveryEvidence.self, space: "delivery", id: key) {
                        evidence.state = .relayed
                        try own.put(space: "delivery", id: key, value: evidence)
                        try aggregate(control.packetID)
                    }
                }
            }
            return
        }
        if var task = try relay.decode(TransferTask.self, space: "origin", id: key) ?? relay.decode(TransferTask.self, space: "originAwaiting", id: key),
           task.packet.offer?.body.id == control.offerID, try task.packet.digest() == control.digest {
            if control.kind == .applied {
                guard sender.id == task.packet.body.recipient else { throw MeshError.invalidPacket }
                try relay.transaction {
                    try relay.remove(space: "origin", id: key)
                    try relay.remove(space: "originAwaiting", id: key)
                }
            } else if task.phase == .waiting {
                task.phase = .handedOff; task.custodian = sender
                try relay.transaction {
                    try relay.move(from: "origin", to: "originAwaiting", id: key, value: task, expiry: task.packet.deadline)
                }
            }
            return
        }
        guard let task = try relay.decode(TransferTask.self, space: "relay", id: key),
              task.packet.offer?.body.id == control.offerID, try task.packet.digest() == control.digest else { return }
        if control.kind == .applied, sender.id != task.packet.body.recipient { throw MeshError.invalidPacket }
        try relay.transaction {
            if control.kind == .stored {
                try relay.put(space: "handoff", id: control.offerID.uuidString,
                    value: HandoffMarker(packetID: control.packetID, recipientID: control.recipientID,
                        digest: control.digest, offerID: control.offerID, custodian: sender,
                        deadline: task.packet.deadline), expiry: task.packet.deadline)
            }
            try relay.remove(space: "relay", id: key)
        }
    }
    /// Persist source recovery with a fresh offer generation; stale ACKs cannot discharge it.
    func recover(_ notice: ReleaseNotice, signedBy sender: PeerCard, now: Date) throws -> [CustodyOffer] {
        let key = "\(notice.packetID.uuidString):\(notice.recipientID)"
        for space in ["awaiting", "originAwaiting"] {
            let archive = space == "awaiting" ? own : relay
            guard var task = try archive.decode(TransferTask.self, space: space, id: key),
                  task.packet.deadline > now,
                  task.packet.body.id == notice.packetID, try task.packet.digest() == notice.digest,
                  task.packet.offer?.body.id == notice.offerID, task.custodian?.id == sender.id else { continue }
            task.phase = .waiting; task.custodian = nil
            try task.packet.offerCustody(by: identity)
            try archive.transaction {
                try archive.move(from: space, to: space == "awaiting" ? "outbox" : "origin", id: key,
                                 value: task, expiry: task.packet.deadline)
                if space == "awaiting",
                   var evidence = try own.decode(DeliveryEvidence.self, space: "delivery", id: key) {
                    evidence.state = .queued
                    try own.put(space: "delivery", id: key, value: evidence)
                    try aggregate(task.packet.body.id)
                }
            }
            return []
        }
        guard let marker = try relay.decode(HandoffMarker.self, space: "handoff", id: notice.offerID.uuidString),
              marker.deadline > now, marker.packetID == notice.packetID, marker.digest == notice.digest,
              marker.custodian.id == sender.id else { return [] }
        return try decode(AcceptedOffer.self, archive: relay, space: "accepted")
            .filter { $0.ownOfferID == marker.offerID }.map(\.incoming)
    }
    func cleanup(now: Date) throws {
        try expireSecureIntents(now: now)
        let expired = try (own.expired(space: "outbox", now: now) + own.expired(space: "awaiting", now: now))
            .map { try JSONDecoder().decode(TransferTask.self, from: $0.data) }
        try own.transaction {
            for task in expired {
                if var evidence = try own.decode(DeliveryEvidence.self, space: "delivery", id: task.packet.storageKey),
                   evidence.state != .read && evidence.state != .delivered {
                    evidence.state = .failed
                    try own.put(space: "delivery", id: task.packet.storageKey, value: evidence)
                    try aggregate(task.packet.body.id)
                }
            }
            try own.removeExpired(now: now)
        }
        try relay.transaction { try relay.removeExpired(now: now) }
    }
    func retryEntry(_ id: UUID) throws -> (ChatEntry, [PeerCard])? {
        guard let entry = try entry(id), entry.outgoing, entry.state == .failed else { return nil }
        let evidence = try own.all(space: "delivery", prefix: id.uuidString + ":").map {
            try JSONDecoder().decode(DeliveryEvidence.self, from: $0.data)
        }
        return (entry, evidence.map(\.recipient))
    }
    func aggregate(_ id: UUID) throws {
        guard var entry = try entry(id) else { return }
        let states = try own.all(space: "delivery", prefix: id.uuidString + ":").map {
            try JSONDecoder().decode(DeliveryEvidence.self, from: $0.data).state
        }
        if states.contains(.read) { entry.state = .read }
        else if states.contains(.delivered) { entry.state = .delivered }
        else if states.contains(.relayed) { entry.state = .relayed }
        else if states.contains(.sent) { entry.state = .sent }
        else if states.contains(.queued) { entry.state = .queued }
        else if try !own.all(space: "secure-intent", prefix: id.uuidString + ":").isEmpty { entry.state = .securing }
        else { entry.state = .failed }
        try own.put(space: "history", id: id.uuidString, value: entry)
    }
    func writeHistory(protecting id: UUID, _ work: () throws -> Void) throws {
        var victims: [String] = []
        var offset = 0
        while true {
            do {
                try own.transaction {
                    for victim in victims {
                        try own.remove(space: "history", id: victim)
                        try own.removePrefix(space: "outbox", prefix: victim + ":")
                        try own.removePrefix(space: "awaiting", prefix: victim + ":")
                        try own.removePrefix(space: "delivery", prefix: victim + ":")
                        try own.removePrefix(space: "secure-intent", prefix: victim + ":")
                    }
                    try work()
                }
                removeUnread(Set(victims.compactMap(UUID.init(uuidString:))))
                return
            } catch MeshStorageError.budgetFull {
                var next: SQLiteArchive.Row?
                repeat {
                    next = try own.oldest(space: "history", offset: offset); offset += 1
                } while next?.id == id.uuidString
                guard let next else { throw MeshStorageError.budgetFull }
                victims.append(next.id)
            }
        }
    }
    private func decode<T: Decodable>(_ type: T.Type, archive: SQLiteArchive, space: String) throws -> [T] {
        try archive.all(space: space).map { try JSONDecoder().decode(type, from: $0.data) }
    }
}
