import Foundation

public struct MeshPeer: Identifiable {
    public var id: String { card.id }
    public let card: PeerCard
    public var hops: Int
    public var lastSeen: Date
    public var sessionID: UUID?
    public var supportsContacts = false
    public var supportsGroups = false
    public var supportsForwardSecrecy = false
}
public struct MeshLink: Identifiable {
    public let id: String
    public let transport: String
    public var peerID: String?
}
public enum DeliveryState: String, Codable {
    // Preserve the old archive's raw values during migration.
    case sent = "Отправлено", delivered = "Доставлено", failed = "Нет подтверждения", received = "Получено"
    case local = "Сохранено на этом устройстве"
    case securing = "Ожидает защищённого сеанса"
    case queued = "Ожидает маршрута", relayed = "Передано ретранслятору", read = "Прочитано"
    public var title: String {
        switch self {
        case .sent: return "Ожидает подтверждения"
        case .failed: return "Доставка не подтверждена"
        case .delivered: return "✓"
        case .read: return "✓✓"
        default: return rawValue
        }
    }
}
public struct ChatEntry: Identifiable, Codable, Equatable {
    public let id: UUID
    public let sender: PeerCard
    public let recipient: String
    public let recipientName: String?
    public let text: String
    public let isPublic: Bool
    public let outgoing: Bool
    public var state: DeliveryState
    public let date: Date
    public let hops: Int
    public var isSaved: Bool? = nil
    public var packetDigest: Data? = nil
    public var readAt: Date? = nil
    public var group: GroupAudience? = nil
    public var secure: SecureHeader? = nil
}
public struct MeshCounters {
    public var received = 0, forwarded = 0, duplicates = 0, rejected = 0, sent = 0
}
private struct PendingRead: Codable, Equatable {
    let entry: ChatEntry
    let evidence: InboxEvidence
}
private struct ReceivedReceipt: Codable, Equatable {
    let packet: MeshPacket
    let value: FinalReceipt
}
private struct VolatileHistory: Codable {
    var entries: [ChatEntry] = []
    var tasks: [String: TransferTask] = [:]
    var evidence: [String: DeliveryEvidence] = [:]
    var intents: [String: SecureSendIntent] = [:]
    var inbox: [String: InboxEvidence] = [:]
    var receipts: [String: ReceivedReceipt] = [:]
    var reads: [String: PendingRead] = [:]
}

/// One serial executor. Transport callbacks and the iOS app use the main queue.
public final class MeshEngine {
    public static let historyLimit = 200 // Initial UI page, not the storage retention limit.
    public static let volatileLimit = 5_000_000
    public private(set) var identity: MeshIdentity
    public private(set) var peers: [String: MeshPeer] = [:]
    public private(set) var links: [String: MeshLink] = [:]
    public private(set) var messages: [ChatEntry] = []
    public private(set) var counters = MeshCounters()
    public private(set) var events: [String] = []
    public private(set) var excludedDirectPeers: Set<String> = []
    public private(set) var storageWarning: String?
    public private(set) var relayWarning: String?
    public private(set) var memoryBufferFull = false
    public private(set) var storageUsage: MeshStorageUsage?
    public private(set) var sessionID: UUID?
    public var onTransmit: ((String, Data) -> Void)?
    public var onChange: (() -> Void)?
    public var onHistoryChange: (([ChatEntry]) -> Void)?
    public var onRecoverStorage: (() -> MeshStore?)?
    public private(set) var historyCleanupSuggested = false
    public private(set) var deviceFreeBytes: Int64?
    var availableDiskBytes: () -> Int64? = { DiskCapacity.available() }
    private var lastDiskCheck = Date.distantPast
    private var capacityWriteFailure = false
    private var legacyJobsAwaitingValidation: Set<String> = []
    public var storageLimits: MeshStorageLimits? { store?.limits }
    public var unreadCount: Int {
        var ids = store?.unreadMessageIDs ?? Set(legacy.filter {
            !$0.outgoing && $0.readAt == nil && $0.packetDigest != nil
        }.map(\.id))
        for entry in memory.entries {
            if !entry.outgoing && entry.readAt == nil && entry.packetDigest != nil { ids.insert(entry.id) }
            else { ids.remove(entry.id) }
        }
        for key in memory.reads.keys { if let id = UUID(uuidString: key) { ids.remove(id) } }
        return ids.count
    }

    var store: MeshStore?
    private let enforceContactConsent: Bool
    let forwardSecure: Bool
    private lazy var trustBook = PeerTrustBook(identity: identity, store: { [weak self] in self?.store })
    private lazy var secureSessions = SecureSessions(identity: identity, store: { [weak self] in self?.store }, trust: trustBook)
    private var holdingSecureReplies = false
    private var secureIntentCursor = 0
    private var heldControls: [(MeshPacket, GroupIntent?)] = []
    private var heldFrames: [(String, Data)] = []
    private lazy var contactBook = ContactBook { [weak self] record in
        guard let store = self?.store else { throw ContactError.storageUnavailable }
        try store.saveContact(record)
    }
    lazy var groupBook = GroupBook { [weak self] previous, value in
        guard let store = self?.store else { throw GroupError.storageUnavailable }
        try store.saveGroup(previous: previous, value: value)
    }
    let clock: () -> Date
    var groupCapablePeers: Set<String> = []
    var groupFlows: [UUID: GroupInvitationState] = [:]
    var groupPolls: [String: Date] = [:]
    var discoveredGroups: [UUID: Date] = [:]
    private var groupAdvertisementPage = 0
    private var memory = VolatileHistory()
    private var measuredMemory = VolatileHistory()
    private var measuredSizes: [String: Int] = [:]
    private var routes: [String: [String: (expiry: Date, hops: Int)]] = [:]
    private var known: [String: PeerCard] = [:]
    private var seen: [String: Date] = [:]
    private var lastAttempt: [UUID: Date] = [:]
    private var lastTransit: [UUID: Date] = [:]
    private var ingress = IngressBudget()
    var receiveUptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var visibleLimit = historyLimit
    private var historyConversationID: String?
    private var pumping = false
    private var legacy: [ChatEntry] = []
    private var lastRecovery = Date.distantPast

    public convenience init(identity: MeshIdentity, history: [ChatEntry] = [], clock: @escaping () -> Date = Date.init) {
        self.init(identity: identity, history: history, enforceContactConsent: true, forwardSecure: true, clock: clock)
    }
    // Test fixtures may isolate storage/transport behavior; the public API always requires consent.
    init(identity: MeshIdentity, history: [ChatEntry] = [], enforceContactConsent: Bool, forwardSecure: Bool = false, clock: @escaping () -> Date = Date.init) {
        self.identity = identity; self.clock = clock; self.enforceContactConsent = enforceContactConsent; self.forwardSecure = forwardSecure
        var ids: Set<UUID> = []
        legacy = history.suffix(Self.historyLimit).filter {
            ($0.outgoing ? $0.sender.id == identity.card.id : $0.recipient == identity.card.id) && ids.insert($0.id).inserted
        }.map {
            var entry = $0
            if entry.outgoing && entry.state == .sent { entry.state = .failed }
            return entry
        }
        messages = legacy
        storageWarning = "Новые сообщения пока только в памяти и будут потеряны после завершения приложения."
    }
    public convenience init(identity: MeshIdentity, store: MeshStore, clock: @escaping () -> Date = Date.init) throws {
        try self.init(identity: identity, store: store, enforceContactConsent: true, forwardSecure: true, clock: clock)
    }
    convenience init(identity: MeshIdentity, store: MeshStore, enforceContactConsent: Bool, forwardSecure: Bool = false, clock: @escaping () -> Date = Date.init) throws {
        self.init(identity: identity, enforceContactConsent: enforceContactConsent, forwardSecure: forwardSecure, clock: clock)
        self.store = store
        if forwardSecure {
            try trustBook.load(); try secureSessions.load(now: clock())
        }
        try contactBook.load(store.loadContacts(), identity: identity)
        groupBook.load(try store.loadGroups())
        groupFlows = try store.loadGroupFlows(identity: identity)
        for peer in try store.groupCapabilities() { groupCapablePeers.insert(peer.id); known[peer.id] = peer }
        messages = try store.history()
        for card in try store.knownPeers() { known[card.id] = card }
        // Reads of existing jobs fail closed; no silent recreation after a corrupt archive.
        for task in try store.outgoing() + store.own.all(space: "awaiting").map({ try JSONDecoder().decode(TransferTask.self, from: $0.data) }) + store.relayTasks() + store.originControls() {
            try task.packet.validate(now: clock(), checkingTime: false)
            if task.packet.body.sender.id == identity.card.id, task.packet.body.kind == .message,
               let audience = try store.entry(task.packet.body.id)?.group,
               groupBook.records[audience.groupID] == nil { throw MeshStorageError.corrupt }
            if enforceContactConsent, task.packet.body.sender.id == identity.card.id, task.packet.body.kind == .message,
               let entry = try store.entry(task.packet.body.id), !entry.isPublic, entry.group == nil,
               contactBook.records[entry.recipient]?.grant == nil { legacyJobsAwaitingValidation.insert(task.packet.storageKey) }
        }
        storageWarning = nil
        do {
            if forwardSecure {
                try secureSessions.cleanup(now: clock())
                try store.quarantineLegacyTextJobs(ownerID: identity.card.id, localFingerprint: identity.card.keyFingerprint)
                try cancelInvalidGroupIntents()
            }
            if enforceContactConsent {
                try store.invalidateUnconsentedPrivateTasks(authorized: Set(contactBook.records.values.filter { $0.grant != nil }.map { $0.peer.id }), forced: legacyJobsAwaitingValidation)
                legacyJobsAwaitingValidation.removeAll()
            }
            try store.cleanup(now: clock())
        }
        catch let error as MeshStorageError {
            switch error {
            case .capacity, .budgetFull: warnStorage(error)
            case .sqlite(let code) where [8, 10, 13, 14].contains(Int(code & 255)): warnStorage(error)
            default: throw error
            }
        }
        refreshHistory()
    }
    public func beginNetworking() {
        if sessionID == nil { sessionID = UUID() }
        changed()
    }
    public func endNetworking() {
        sessionID = nil; links.removeAll(); routes.removeAll(); peers.removeAll(); ingress.removeLinks()
        changed()
    }
    public func rename(_ name: String) { identity.name = String(name.prefix(32)); announce(); changed() }
    public func canAddress(_ id: String) -> Bool { card(id) != nil }
    private func card(_ id: String) -> PeerCard? {
        peers[id]?.card ?? trustBook.records[id]?.peer ?? contactBook.records[id]?.peer ?? known[id] ?? messages.last(where: { !$0.outgoing && $0.sender.id == id })?.sender ??
            (try? store?.card(id))
    }
    public var knownParticipants: [PeerCard] {
        var result = known
        for record in contactBook.records.values { result[record.peer.id] = record.peer }
        for record in groupBook.records.values {
            for member in record.projection.members.values { result[member.id] = member.peer }
            for event in record.events {
                if case .joined(let proof) = event.body.change { let peer = proof.body.invitation.body.invitee; result[peer.id] = peer }
            }
        }
        for entry in messages where !entry.outgoing { result[entry.sender.id] = entry.sender }
        for peer in peers.values { result[peer.id] = peer.card }
        return result.values.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }
    public var directContacts: [DirectContact] {
        contactBook.records.values.filter {
            $0.blocked || $0.grant != nil || $0.incoming != nil || $0.outgoing != nil || $0.outgoingRejections > 0
        }.map { contactBook.summary($0.peer, now: clock()) }.sorted { $0.id < $1.id }
    }
    public func contact(for peerID: String) -> DirectContact? {
        guard let peer = card(peerID) else { return nil }
        return contactBook.summary(peer, now: clock(), supported: peers[peerID]?.supportsContacts == true)
    }
    public func canSendDirect(to peerID: String) -> Bool {
        enforceContactConsent ? contact(for: peerID)?.canSend == true : canAddress(peerID)
    }
    public func requestContact(to peerID: String) throws {
        guard sessionID != nil, let peer = card(peerID) else { throw MeshError.unavailablePeer }
        guard peers[peerID]?.supportsContacts == true || contactBook.records[peerID]?.supportsContacts == true else {
            throw ContactError.unsupportedPeer
        }
        try contactBook.observe(peer)
        let signal = try contactBook.request(peer, identity: identity, now: clock())
        try sendContact(signal, to: peer); changed()
    }
    public func respondToContact(from peerID: String, requestID: UUID, accept: Bool) throws {
        guard let peer = card(peerID) else { throw MeshError.unavailablePeer }
        let signal = try contactBook.decide(peerID: peerID, requestID: requestID, accept: accept, identity: identity, now: clock())
        try sendContact(signal, to: peer); changed()
    }
    public func setContactBlocked(_ peerID: String, blocked: Bool) throws {
        guard let peer = card(peerID) else { throw MeshError.unavailablePeer }
        try contactBook.block(peer, blocked: blocked); changed()
    }
    private func sendContact(_ signal: ContactSignal, to peer: PeerCard) throws {
        guard signal.deadline > clock() else { return }
        let packet = try endpointPacket(kind: .contact, recipient: peer,
            cleartext: JSONEncoder().encode(signal), now: clock(), expiresAt: signal.deadline)
        queueControl(packet)
    }
    // Group domain API; mutations notify peers and persist before transmission.
    public var closedGroups: [ClosedGroup] { groupBook.groups.map(effectiveGroup) }
    public func groupEvents(_ id: UUID) -> [GroupEvent] { groupBook.records[id]?.events ?? [] }
    @discardableResult public func createClosedGroup(name: String, memberLimit: Int = 32) throws -> UUID {
        defer { groupChanged() }
        return try groupBook.create(name: name, limit: memberLimit, identity: identity, now: clock()).body.groupID
    }
    @discardableResult public func setGroupMemberLimit(_ limit: Int, groupID: UUID) throws -> GroupEvent {
        defer { groupChanged() }
        let event = try groupBook.setLimit(limit, id: groupID, identity: identity, now: clock())
        notifyGroup(groupID); return event
    }
    public func makeGroupInvitation(to peer: PeerCard, groupID: UUID) throws -> GroupInvitation {
        try groupBook.invite(peer, id: groupID, identity: identity, now: clock())
    }
    @discardableResult public func finalizeGroupJoin(_ consent: GroupJoinConsent) throws -> GroupEvent {
        defer { groupChanged() }
        let event = try groupBook.finalize(consent, identity: identity, now: clock())
        notifyGroup(event.body.groupID); return event
    }
    @discardableResult public func excludeGroupMember(_ peerID: String, groupID: UUID) throws -> GroupEvent {
        defer { groupChanged() }
        let peer = groupBook.records[groupID]?.projection.members[peerID]?.peer
        let event = try groupBook.exclude(peerID, id: groupID, identity: identity, now: clock())
        notifyGroup(groupID, including: peer.map { [$0] } ?? []); return event
    }
    @discardableResult public func permitGroupReturn(_ peerID: String, groupID: UUID) throws -> GroupEvent {
        defer { groupChanged() }
        let event = try groupBook.allowReturn(peerID, id: groupID, identity: identity, now: clock())
        notifyGroup(groupID); return event
    }
    /// nil means the creator's exit was committed as a canonical closed event.
    @discardableResult public func leaveClosedGroup(_ id: UUID) throws -> GroupDeparture? {
        defer { groupChanged() }
        let recipients = groupBook.records[id]?.projection.members.values.map(\.peer) ?? []
        let proof = try groupBook.leave(id, identity: identity, now: clock())
        if let proof {
            for peer in recipients where peer.id != identity.card.id { try? sendGroupSignal(.departure(proof), to: peer) }
        } else { notifyGroup(id, including: recipients) }
        return proof
    }
    @discardableResult public func applyGroupEvent(_ event: GroupEvent) throws -> Bool {
        defer { groupChanged() }
        return try groupBook.apply(event)
    }
    @discardableResult public func applyGroupDeparture(_ proof: GroupDeparture) throws -> GroupEvent? {
        defer { groupChanged() }
        let event = try groupBook.depart(proof, identity: identity, now: clock())
        if event != nil { notifyGroup(proof.body.groupID) }; return event
    }
    private func groupChanged() {
        do { try cancelInvalidGroupIntents() } catch { warnStorage(error) }
        for id in groupBook.records.keys { try? refreshGroupFlows(id) }
        stopObsoleteGroupWork(); refreshHistory(); storageUsage = try? store?.usage(); changed()
    }
    public func linkOpened(id: String, transport: String) {
        guard links.count < 32, links[id] == nil else { return }
        beginNetworking()
        links[id] = MeshLink(id: id, transport: transport)
        log("Связь открыта: \(transport)")
        if let packet = try? presence() { _ = emit(packet, only: id) }
        pump(); changed()
    }
    public func linkClosed(id: String) {
        guard let link = links.removeValue(forKey: id) else { return }
        ingress.removeLink(id)
        for peer in Array(routes.keys) { routes[peer]?.removeValue(forKey: id) }
        refreshPeers(); log("Связь закрыта: \(link.transport)"); changed()
    }
    public func excludeDirectPeer(_ peerID: String, excluded: Bool) {
        if excluded { excludedDirectPeers.insert(peerID) } else { excludedDirectPeers.remove(peerID) }
        if excluded {
            for peer in Array(routes.keys) {
                routes[peer] = routes[peer]?.filter { !links.values.filter { $0.peerID == peerID }.map(\.id).contains($0.key) }
            }
        }
        refreshPeers(); announce(); changed()
    }
    public func announce() {
        guard sessionID != nil, let packet = try? presence() else { return }
        _ = emit(packet)
    }
    private func presence() throws -> MeshPacket {
        guard let sessionID else { throw MeshError.unavailablePeer }
        let ids = closedGroups.filter { $0.canSend(as: identity.card.id) }.map(\.id)
        let page = ids.isEmpty ? [] : (0..<min(16, ids.count)).map { ids[(groupAdvertisementPage + $0) % ids.count] }
        if !ids.isEmpty { groupAdvertisementPage = (groupAdvertisementPage + 16) % ids.count }
        let packet = try MeshPacket.make(identity: identity, kind: .presence,
            cleartext: JSONEncoder().encode(PresenceInfo(sessionID: sessionID, capabilities: ["contacts-v1", "groups-v1"] + (forwardSecure ? ["noise-fs-v1"] : []), groups: page)), now: clock())
        return packet
    }
    @discardableResult public func send(text: String, to peerID: String, isPublic: Bool = false) throws -> UUID {
        guard let card = card(peerID) else { throw MeshError.unavailablePeer }
        return try send(text: text, recipients: [card], isPublic: isPublic)
    }
    @discardableResult public func broadcast(text: String) throws -> UUID {
        try send(text: text, recipients: peers.values.filter { $0.sessionID != nil }.map(\.card), isPublic: true)
    }
    @discardableResult public func sendToGroup(text: String, groupID: UUID) throws -> UUID {
        guard let group = closedGroups.first(where: { $0.id == groupID }) else { throw GroupError.unknownGroup }
        let audience = try group.audience(for: identity.card.id)
        return try send(text: text, recipients: group.members.filter { $0.id != identity.card.id }.map(\.peer),
            isPublic: false, group: audience, groupName: group.name)
    }
    private func send(text: String, recipients: [PeerCard], isPublic: Bool, group: GroupAudience? = nil, groupName: String? = nil) throws -> UUID {
        guard sessionID != nil, !recipients.isEmpty || group != nil else { throw MeshError.unavailablePeer }
        try ChatPayload.validate(text)
        flushMemory()
        let now = clock(), id = UUID()
        var intents: [SecureSendIntent] = []
        var packets: [(MeshPacket, PeerCard)] = []
        for card in recipients {
            var payload = ChatPayload(text: text, isPublic: isPublic)
            payload.group = group
            if !isPublic && group == nil && enforceContactConsent {
                guard contactBook.summary(card, now: now).phase != .blocked else { throw ContactError.blocked }
                guard contactBook.summary(card, now: now).canSend else { throw ContactError.consentRequired }
                payload.consent = contactBook.records[card.id]?.grant
            }
            if isPublic {
                guard let session = peers[card.id]?.sessionID else { throw MeshError.unavailablePeer }
                payload.sessionID = session
            }
            let cleartext = try JSONEncoder().encode(payload)
            do {
                let packet = try endpointPacket(kind: .message, recipient: card, cleartext: cleartext, now: now, id: id)
                packets.append((packet, card))
            } catch let error as ChannelSecurityError where forwardSecure && [.pending, .unavailable].contains(error) {
                intents.append(SecureSendIntent(messageID: id, recipient: card, payload: cleartext,
                    createdAt: now, deadline: now.addingTimeInterval(MeshPacket.lifetime)))
            }
        }
        var entry = ChatEntry(id: id, sender: identity.card, recipient: group.map { "g:" + $0.groupID.uuidString } ?? (isPublic ? "*" : recipients[0].id),
            recipientName: groupName ?? (isPublic ? "Общий чат" : recipients[0].name), text: text, isPublic: isPublic,
            outgoing: true, state: recipients.isEmpty ? .local : (packets.isEmpty && !intents.isEmpty ? .securing : .queued), date: now, hops: 0, isSaved: true)
        entry.group = group
        do {
            guard let store, memory.entries.isEmpty else { throw MeshStorageError.capacity }
            try store.enqueue(entry, packets: packets, intents: intents)
        } catch {
            entry.isSaved = false
            var candidate = memory
            candidate.entries.append(entry)
            for intent in intents { candidate.intents[intent.key] = intent }
            for (packet, recipient) in packets {
                candidate.tasks[packet.storageKey] = TransferTask(packet: packet)
                candidate.evidence[packet.storageKey] = DeliveryEvidence(messageID: id, recipient: recipient,
                    digest: try packet.digest(), state: .queued)
            }
            try adopt(candidate)
            warnStorage(error)
        }
        counters.sent += 1; refreshHistory(); pump(); changed()
        return id
    }
    @discardableResult public func retry(_ id: UUID) throws -> UUID {
        guard let entry = messages.first(where: { $0.id == id && $0.outgoing && $0.state == .failed }) else {
            throw MeshError.invalidPacket
        }
        if let group = entry.group { return try sendToGroup(text: entry.text, groupID: group.groupID) }
        return try entry.isPublic ? broadcast(text: entry.text) : send(text: entry.text, to: entry.recipient)
    }
    public func openConversation(_ id: String?) {
        historyConversationID = id; visibleLimit = Self.historyLimit
        refreshHistory(); changed()
    }
    public var conversations: [ConversationSummary] {
        var result: [String: ConversationSummary]
        do { result = Dictionary(uniqueKeysWithValues: try store?.conversationSummaries().map { ($0.id, $0) } ?? []) }
        catch { warnStorage(error); result = store?.conversationIndex.summaries ?? [:] }
        let persisted = store?.conversationIndex.items ?? [:]
        let baseOrder = result.values.map(\.activityOrder).max() ?? 0
        for (index, entry) in (store == nil ? legacy + memory.entries : memory.entries).enumerated() {
            let chat = entry.conversationID
            let order = persisted[entry.id]?.order ?? (baseOrder + Int64(index) + 1)
            if var summary = result[chat] {
                if persisted[entry.id] == nil { summary.messageCount += 1; summary.unreadCount += entry.isUnread ? 1 : 0 }
                else if persisted[entry.id]?.unread == true && !entry.isUnread { summary.unreadCount = max(0, summary.unreadCount - 1) }
                if order >= summary.activityOrder { summary.lastMessage = entry; summary.activityOrder = order }
                result[chat] = summary
            } else {
                result[chat] = ConversationSummary(id: chat, lastMessage: entry, unreadCount: entry.isUnread ? 1 : 0, messageCount: 1, activityOrder: order)
            }
        }
        for pending in memory.reads.values where persisted[pending.entry.id]?.unread == true {
            let chat = pending.entry.conversationID
            if var summary = result[chat] {
                summary.unreadCount = max(0, summary.unreadCount - 1)
                if summary.lastMessage.id == pending.entry.id { summary.lastMessage.readAt = pending.entry.readAt }
                result[chat] = summary
            }
        }
        for received in memory.receipts.values {
            let value = received.value
            for key in result.keys where result[key]?.lastMessage.id == value.messageID {
                if result[key]?.lastMessage.state != .read { result[key]?.lastMessage.state = value.kind == .read ? .read : .delivered }
            }
        }
        return result.values.sorted { $0.activityOrder > $1.activityOrder }
    }
    public func loadEarlierMessages() { visibleLimit += Self.historyLimit; refreshHistory(); changed() }

    public func prepareHistoryCleanup() throws -> HistoryCleanupPlan {
        guard let store else { throw MeshStorageError.unavailable }
        return try store.prepareHistoryCleanup(availableDeviceBytes: deviceFreeBytes)
    }
    public func applyHistoryCleanup(_ plan: HistoryCleanupPlan, confirmed: Bool = false) throws -> HistoryCleanupResult {
        guard let store else { throw MeshStorageError.unavailable }
        let result = try store.applyHistoryCleanup(plan, confirmed: confirmed)
        messages.removeAll { plan.victims.contains($0.id) }
        refreshHistory(); capacityWriteFailure = false
        refreshDiskPressure(); flushMemory(); pump(); changed()
        return result
    }
    private func refreshDiskPressure() {
        deviceFreeBytes = availableDiskBytes()
        historyCleanupSuggested = capacityWriteFailure || deviceFreeBytes.map { $0 < 10_000_000 } == true
    }
    public func prepareStorageResize(_ area: MeshStorageArea, to bytes: Int64) throws -> StorageResizePlan {
        guard let store else { throw MeshStorageError.unavailable }
        return try store.prepareResize(area, to: bytes, now: clock())
    }
    public func applyStorageResize(_ plan: StorageResizePlan, confirmed: Bool = false) throws {
        guard let store else { throw MeshStorageError.unavailable }
        let result = try store.applyResize(plan, confirmed: confirmed, now: clock())
        messages.removeAll { result.removedHistoryIDs.contains($0.id) }
        for packet in result.notices { queueControl(packet) }
        flushMemory(); refreshHistory()
        if let warning = result.warning { storageWarning = warning }
        pump(); changed()
    }

    public func receive(_ data: Data, from linkID: String) {
        guard sessionID != nil, links[linkID] != nil else { return }
        let now = clock()
        guard ingress.admit(bytes: data.count, link: linkID, uptime: receiveUptime()) else {
            counters.rejected += 1; return
        }
        do {
            let packet = try MeshPacket.decode(data, now: now)
            if links[linkID]?.peerID == nil {
                guard packet.body.kind == .presence, packet.remainingHops == packet.body.hopLimit else {
                    throw MeshError.invalidPacket
                }
                links[linkID]?.peerID = packet.body.sender.id
            }
            guard let neighbor = links[linkID]?.peerID, !excludedDirectPeers.contains(neighbor),
                  packet.body.sender.id != identity.card.id else { return }
            counters.received += 1
            if packet.body.kind == .presence || packet.body.kind == .control {
                let key = packet.storageKey
                if seen[key] != nil { counters.duplicates += 1; return }
                seen = seen.filter { now.timeIntervalSince($0.value) <= MeshPacket.presenceLifetime }
                guard seen.count < 4096 else { throw MeshError.invalidPacket }
                seen[key] = now
            }
            if packet.body.kind == .presence {
                observe(packet, via: linkID)
                transit(packet, excluding: neighbor)
            } else if packet.body.recipient == identity.card.id {
                if forwardSecure { try trustBook.requireUnchanged(packet.body.sender) }
                if packet.body.kind == .handshake {
                    try acceptHandshake(packet)
                } else if forwardSecure && [.message, .contact, .group].contains(packet.body.kind) {
                    guard packet.body.version == 3, packet.body.secure != nil else { throw ChannelSecurityError.invalidHandshake }
                    try consumeSecure(packet)
                } else { try consume(packet) }
            } else if packet.body.kind == .control || packet.body.kind == .handshake {
                transit(packet, excluding: neighbor)
            } else if packet.remainingHops > 1 {
                var stored = false
                if let store {
                    do { stored = try store.admit(packet, from: neighbor, now: now) }
                    catch let error as MeshError { throw error }
                    catch { relayWarning = "Приём на хранение недоступен; возможен немедленный транзит." }
                }
                if stored {
                    relayWarning = nil
                    try acknowledge(packet, kind: .stored)
                } else {
                    transit(packet, excluding: neighbor)
                }
            }
            refreshHistory(); pump(); changed()
        } catch {
            counters.rejected += 1; log("Пакет отклонён: \(error.localizedDescription)"); changed()
        }
    }
    private func consume(_ packet: MeshPacket, cleartext: Data? = nil) throws {
        let data = try cleartext ?? packet.decrypted(using: identity)
        switch packet.body.kind {
        case .presence, .handshake: break
        case .group:
            try consumeGroup(JSONDecoder().decode(GroupSignal.self, from: data), from: packet.body.sender)
            try acknowledge(packet, kind: .applied)
            if packet.offer?.body.owner.id != packet.body.sender.id {
                // Release the original service job after custody has crossed relays.
                // This proof is opportunistic; durable group intent/reconciliation
                // survives its loss, without generating receipt-of-receipt queues.
                let value = FinalReceipt(messageID: packet.body.id, recipientID: identity.card.id,
                    digest: try packet.digest(), kind: .delivered)
                _ = emit(try makeReceipt(value, to: packet.body.sender))
            }
        case .contact:
            let signal = try JSONDecoder().decode(ContactSignal.self, from: data)
            guard signal.deadline > clock() else { throw MeshError.expiredPacket }
            if let response = try contactBook.receive(signal, from: packet.body.sender, identity: identity, now: clock()) {
                try sendContact(response, to: packet.body.sender)
            }
            try acknowledge(packet, kind: .applied)
        case .message:
            let payload = try JSONDecoder().decode(ChatPayload.self, from: data)
            try ChatPayload.validate(payload.text)
            if let audience = payload.group {
                guard !payload.isPublic else { throw MeshError.invalidPacket }
                if let group = closedGroups.first(where: { $0.id == audience.groupID }), group.revision < audience.revision {
                    try? requestGroupSync(audience.groupID, from: packet.body.sender,
                        flow: groupFlows.values.first { !$0.outgoing && $0.invitation.body.groupID == audience.groupID })
                    throw GroupError.missingEvents
                }
                guard closedGroups.first(where: { $0.id == audience.groupID })?.permitsMessage(
                    from: packet.body.sender, audience: audience, to: identity.card.id) == true else { throw GroupError.notMember }
            } else if !payload.isPublic && enforceContactConsent {
                try contactBook.authorize(payload.consent, from: packet.body.sender, identity: identity)
            }
            if payload.isPublic && payload.sessionID != sessionID { throw MeshError.expiredPacket }
            let digest = try packet.digest(), key = packet.body.id.uuidString
            let previous = try memory.inbox[key] ?? store?.inbox(packet.body.id)
            if let previous {
                guard previous.digest == digest else { throw MeshError.invalidPacket }
                counters.duplicates += 1
                try acknowledge(packet, kind: .applied)
                if let receipt = previous.delivered { queueControl(receipt) }
                if let receipt = previous.read { queueControl(receipt) }
                return
            }
            // A migrated legacy entry is never silently overwritten by another packet.
            guard !messages.contains(where: { $0.id == packet.body.id }) else {
                counters.duplicates += 1; return
            }
            let final = FinalReceipt(messageID: packet.body.id, recipientID: identity.card.id, digest: digest, kind: .delivered)
            let receipt = try makeReceipt(final, to: packet.body.sender)
            let evidence = InboxEvidence(digest: digest, delivered: receipt, originalDeadline: packet.deadline)
            var entry = ChatEntry(id: packet.body.id, sender: packet.body.sender, recipient: identity.card.id,
                recipientName: identity.card.name, text: payload.text, isPublic: payload.isPublic,
                outgoing: false, state: .received, date: clock(),
                hops: packet.body.hopLimit - packet.remainingHops + 1, isSaved: true, packetDigest: digest)
            entry.group = payload.group
            entry.secure = packet.body.secure
            flushMemory()
            do {
                guard let store, memory.entries.isEmpty else { throw MeshStorageError.capacity }
                _ = try store.accept(entry, evidence: evidence)
            } catch let error as MeshError { throw error }
            catch {
                entry.isSaved = false
                var candidate = memory; candidate.entries.append(entry); candidate.inbox[key] = evidence
                try adopt(candidate); warnStorage(error)
            }
            // This is endpoint reception, including explicitly warned RAM reception, not relay custody.
            try acknowledge(packet, kind: .applied)
            queueControl(receipt)
        case .receipt:
            let receipt = try JSONDecoder().decode(FinalReceipt.self, from: data)
            guard receipt.recipientID == packet.body.sender.id, receipt.digest.count == 32 else { throw MeshError.invalidPacket }
            try applyReceipt(packet, value: receipt)
            try acknowledge(packet, kind: .applied)
        case .control:
            let control = try JSONDecoder().decode(TransferControl.self, from: data)
            try store?.apply(control, signedBy: packet.body.sender)
            let key = "\(control.packetID.uuidString):\(control.recipientID)"
            if var task = memory.tasks[key], task.packet.offer?.body.id == control.offerID,
               try task.packet.digest() == control.digest {
                var candidate = memory
                if control.kind == .applied {
                    guard packet.body.sender.id == task.packet.body.recipient else { throw MeshError.invalidPacket }
                    if candidate.evidence[key]?.state != .read { candidate.evidence[key]?.state = .delivered }
                    candidate.tasks.removeValue(forKey: key)
                } else if task.phase == .waiting {
                    task.phase = .handedOff; task.custodian = packet.body.sender
                    candidate.evidence[key]?.state = .relayed; candidate.tasks[key] = task
                }
                aggregateMemory(control.packetID, in: &candidate)
                try adopt(candidate)
            }
        case .notice:
            let notice = try JSONDecoder().decode(ReleaseNotice.self, from: data)
            try recoverMemory(notice, signedBy: packet.body.sender)
            if let store {
                let parents = try store.recover(notice, signedBy: packet.body.sender, now: clock())
                for offer in parents {
                    let value = ReleaseNotice(recipientID: notice.recipientID, packetID: notice.packetID,
                                              digest: notice.digest, offerID: offer.body.id)
                    let next = try MeshPacket.make(identity: identity, kind: .notice, recipient: offer.body.owner,
                        cleartext: JSONEncoder().encode(value), now: clock(),
                        expiresAt: Date(timeIntervalSince1970: Double(offer.body.expiresAt)))
                    queueControl(next)
                }
            }
            try acknowledge(packet, kind: .applied)
        }
    }
    private func makeReceipt(_ value: FinalReceipt, to card: PeerCard) throws -> MeshPacket {
        try MeshPacket.make(identity: identity, kind: .receipt, recipient: card,
                            cleartext: JSONEncoder().encode(value), now: clock())
    }
    private func recoverMemory(_ notice: ReleaseNotice, signedBy sender: PeerCard) throws {
        let key = "\(notice.packetID.uuidString):\(notice.recipientID)"
        guard var task = memory.tasks[key], task.phase == .handedOff,
              task.packet.deadline > clock(), task.custodian?.id == sender.id,
              task.packet.offer?.body.id == notice.offerID,
              try task.packet.digest() == notice.digest else { return }
        task.phase = .waiting; task.custodian = nil
        try task.packet.offerCustody(by: identity)
        var candidate = memory
        candidate.tasks[key] = task; candidate.evidence[key]?.state = .queued
        aggregateMemory(notice.packetID, in: &candidate)
        try adopt(candidate)
    }
    private func acknowledge(_ packet: MeshPacket, kind: ControlKind) throws {
        guard let offer = packet.offer else { return }
        let value = TransferControl(recipientID: packet.body.recipient ?? "", packetID: packet.body.id,
                                    digest: try packet.digest(), offerID: offer.body.id, kind: kind)
        let reply = try MeshPacket.make(identity: identity, kind: .control, recipient: offer.body.owner,
            cleartext: JSONEncoder().encode(value), now: clock(), expiresAt: packet.deadline)
        _ = emit(reply)
    }
    private func applyReceipt(_ packet: MeshPacket, value: FinalReceipt) throws {
        let key = "\(value.messageID.uuidString):\(value.recipientID)"
        if let evidence = memory.evidence[key] {
            guard evidence.recipient.id == packet.body.sender.id, evidence.digest == value.digest else { throw MeshError.invalidPacket }
            var candidate = memory
            if evidence.state != .read { candidate.evidence[key]?.state = value.kind == .read ? .read : .delivered }
            candidate.tasks.removeValue(forKey: key)
            aggregateMemory(value.messageID, in: &candidate)
            try adopt(candidate)
        } else if let store {
            do { try store.apply(value, signedBy: packet.body.sender) }
            catch let error as MeshError { throw error }
            catch {
                // Verify against committed data before displaying a volatile receipt.
                let expected = try store.own.decode(DeliveryEvidence.self, space: "delivery", id: key)
                guard let expected else { return }
                guard expected.digest == value.digest, expected.recipient.id == packet.body.sender.id else { throw MeshError.invalidPacket }
                var candidate = memory; candidate.receipts[packet.body.id.uuidString] = ReceivedReceipt(packet: packet, value: value)
                try adopt(candidate); warnStorage(error)
            }
        }
    }
    public func markRead(_ id: UUID) {
        guard var entry = messages.first(where: { $0.id == id && !$0.outgoing }),
              entry.readAt == nil, let digest = entry.packetDigest else { return }
        if forwardSecure, let header = entry.secure, !secureSessions.mayAcknowledge(header) { return }
        do {
            let receipt = try makeReceipt(FinalReceipt(messageID: id, recipientID: identity.card.id,
                digest: digest, kind: .read), to: entry.sender)
            var evidence = try memory.inbox[id.uuidString] ?? store?.inbox(id) ?? InboxEvidence(digest: digest)
            evidence.read = receipt; entry.readAt = clock()
            if let index = memory.entries.firstIndex(where: { $0.id == id }) {
                var candidate = memory; candidate.entries[index] = entry; candidate.inbox[id.uuidString] = evidence
                try adopt(candidate)
            } else {
                do {
                    guard let store else { throw MeshStorageError.capacity }
                    try store.saveRead(entry, evidence: evidence)
                } catch {
                    var candidate = memory; candidate.reads[id.uuidString] = PendingRead(entry: entry, evidence: evidence)
                    try adopt(candidate); warnStorage(error)
                }
            }
            queueControl(receipt); refreshHistory(); changed()
        } catch { warnStorage(error); changed() }
    }
    func queueControl(_ packet: MeshPacket, groupIntent: GroupIntent? = nil) {
        if holdingSecureReplies { heldControls.append((packet, groupIntent)); return }
        guard packet.deadline > clock() else { return }
        do { try store?.enqueueControl(packet, now: clock(), groupIntent: groupIntent) }
        catch { relayWarning = "Буфер служебных пакетов заполнен. Доступна немедленная передача." }
        // Persistence/queue admission does not prevent immediate transmission.
        _ = emit(packet)
    }
    private func transit(_ packet: MeshPacket, excluding peer: String) {
        guard packet.remainingHops > 1 else { return }
        let token = packet.offer?.body.id ?? packet.body.id
        guard clock().timeIntervalSince(lastTransit[token] ?? .distantPast) >= 5 else {
            counters.duplicates += 1; return
        }
        guard lastTransit.count < 4096 || lastTransit[token] != nil else { return }
        lastTransit[token] = clock()
        var next = packet; next.remainingHops -= 1
        _ = emit(next, excludingPeer: peer, relay: true)
    }
    private func isSharedTask(_ task: TransferTask) -> Bool {
        let id = task.packet.body.id
        if let entry = memory.entries.first(where: { $0.id == id }) ?? messages.first(where: { $0.id == id }) {
            return entry.isPublic || entry.group != nil
        }
        guard let entry = try? store?.entry(id) else { return false }
        return entry.isPublic || entry.group != nil
    }
    private func groupTaskAllowed(_ task: TransferTask) -> Bool {
        if task.packet.body.sender.id == identity.card.id, case .join(let attempt) = task.groupIntent {
            return !groupFlows.values.contains { $0.cancellation?.body.consent.body.attemptID == attempt }
        }
        guard !groupBook.records.isEmpty else { return true }
        guard task.packet.body.sender.id == identity.card.id, task.packet.body.kind == .message else { return true }
        let entry = memory.entries.first { $0.id == task.packet.body.id } ?? (try? store?.entry(task.packet.body.id))
        guard let audience = entry?.group else { return true }
        guard let group = closedGroups.first(where: { $0.id == audience.groupID }), group.canSend(as: identity.card.id),
              group.member(identity.card.id)?.membershipID == audience.senderMembershipID,
              let peer = task.packet.body.recipient, let member = group.member(peer),
              audience.recipients.contains(GroupRecipient(peerID: peer, membershipID: member.membershipID)) else { return false }
        return true
    }
    private func stopObsoleteGroupWork() {
        guard !groupBook.records.isEmpty else { return }
        do {
            let tasks = try (store?.outgoing() ?? []) + (store?.own.all(space: "awaiting").map { try JSONDecoder().decode(TransferTask.self, from: $0.data) } ?? [])
            let invalid = tasks.filter { !groupTaskAllowed($0) }
            try store?.stopGroupTasks(invalid)
            var candidate = memory
            for (key, task) in candidate.tasks where !groupTaskAllowed(task) {
                candidate.tasks.removeValue(forKey: key)
                if candidate.evidence[key]?.state != .read && candidate.evidence[key]?.state != .delivered { candidate.evidence[key]?.state = .failed }
                aggregateMemory(task.packet.body.id, in: &candidate)
            }
            if candidate.tasks != memory.tasks { try adopt(candidate) }
        } catch { warnStorage(error) }
    }
    private func upstreamExclusion(_ task: TransferTask) -> String? {
        guard let upstream = task.receivedFrom, upstream != task.packet.body.sender.id, let recipient = task.packet.body.recipient,
              let paths = routes[recipient] else { return task.receivedFrom }
        let reachable = paths.keys.compactMap { links[$0]?.peerID }.filter { !excludedDirectPeers.contains($0) }
        // A newly discovered route may lead back through the former custodian.
        // Only use that return path when it is the sole advertised route; custody
        // gets a new offer and consumes another hop, with no lifetime extension.
        return reachable.contains(upstream) && !reachable.contains(where: { $0 != upstream }) ? nil : upstream
    }
    private func pump() {
        guard sessionID != nil, !pumping else { return }
        pumping = true; defer { pumping = false }
        stopObsoleteGroupWork()
        do {
            let persisted = try (store?.outgoing() ?? []) + (store?.relayTasks() ?? []) + (store?.originControls() ?? [])
            let tasks = (persisted + Array(memory.tasks.values)).filter { task in
                guard task.phase == .waiting, task.packet.deadline > clock() else { return false }
                if forwardSecure, task.packet.body.sender.id == identity.card.id,
                   [.message, .contact, .group].contains(task.packet.body.kind),
                   task.packet.body.secure == nil || task.packet.body.sender.keyFingerprint != identity.card.keyFingerprint { return false }
                if task.packet.body.sender.id == identity.card.id, legacyJobsAwaitingValidation.contains(task.packet.storageKey) { return false }
                if enforceContactConsent, task.packet.body.kind == .message,
                   task.packet.body.sender.id == identity.card.id,
                   let recipient = task.packet.body.recipient, !canSendDirect(to: recipient),
                   !isSharedTask(task) { return false }
                if task.packet.body.kind == .contact, task.packet.body.sender.id == identity.card.id,
                   let recipient = task.packet.body.recipient, contactBook.records[recipient]?.blocked == true { return false }
                if !groupTaskAllowed(task) { return false }
                let key = task.packet.storageKey
                if let state = memory.evidence[key]?.state, state == .read || state == .delivered || state == .failed { return false }
                return !memory.receipts.values.contains {
                    let value = $0.value
                    return value.messageID == task.packet.body.id && value.recipientID == task.packet.body.recipient
                }
            }.sorted { (lastAttempt[$0.packet.offer?.body.id ?? $0.packet.body.id] ?? .distantPast) <
                       (lastAttempt[$1.packet.offer?.body.id ?? $1.packet.body.id] ?? .distantPast) }
            let tokens = Set(tasks.map { $0.packet.offer?.body.id ?? $0.packet.body.id })
            lastAttempt = lastAttempt.filter { tokens.contains($0.key) }
            var sent = 0
            for task in tasks {
                guard sent < 16 else { break }
                let packet = task.packet, token = packet.offer?.body.id ?? packet.body.id
                let excludedUpstream = upstreamExclusion(task)
                guard clock().timeIntervalSince(lastAttempt[token] ?? .distantPast) >= 5,
                      !destinations(packet, excludingPeer: excludedUpstream).isEmpty else { continue }
                lastAttempt[token] = clock()
                if packet.body.kind == .message && packet.body.sender.id == identity.card.id {
                    if memory.evidence[packet.storageKey] != nil {
                        var candidate = memory
                        candidate.evidence[packet.storageKey]?.state = .sent
                        aggregateMemory(packet.body.id, in: &candidate)
                        try adopt(candidate)
                    } else { try store?.noteAttempt(packet) }
                }
                _ = emit(packet, excludingPeer: excludedUpstream, relay: packet.body.sender.id != identity.card.id)
                sent += 1
            }
        } catch { warnStorage(error) }
        refreshHistory()
    }
    public func tick() {
        let now = clock()
        if forwardSecure {
            do { try secureSessions.cleanup(now: now) } catch { warnStorage(error) }
            for peer in peers.values where peer.supportsForwardSecrecy { try? ensureSecureSession(peer.card) }
        }
        if now.timeIntervalSince(lastDiskCheck) >= 5 {
            lastDiskCheck = now; refreshDiskPressure()
            if !legacyJobsAwaitingValidation.isEmpty, let store {
                do {
                    try store.invalidateUnconsentedPrivateTasks(authorized: Set(contactBook.records.values.filter { $0.grant != nil }.map { $0.peer.id }), forced: legacyJobsAwaitingValidation)
                    legacyJobsAwaitingValidation.removeAll()
                } catch { warnStorage(error) }
            }
        }
        seen = seen.filter { now.timeIntervalSince($0.value) <= MeshPacket.presenceLifetime }
        lastTransit = lastTransit.filter { now.timeIntervalSince($0.value) <= MeshPacket.presenceLifetime }
        refreshPeers()
        if store == nil, now.timeIntervalSince(lastRecovery) >= 5 {
            lastRecovery = now
            if let recovered = onRecoverStorage?() {
                do {
                    let groups = try recovered.loadGroups()
                    try contactBook.load(recovered.loadContacts(), identity: identity)
                    groupBook.load(groups)
                    groupFlows = try recovered.loadGroupFlows(identity: identity)
                    for peer in try recovered.groupCapabilities() { groupCapablePeers.insert(peer.id); known[peer.id] = peer }
                    if enforceContactConsent {
                        try recovered.invalidateUnconsentedPrivateTasks(authorized: Set(contactBook.records.values.filter { $0.grant != nil }.map { $0.peer.id }))
                    }
                    store = recovered
                    if forwardSecure { try trustBook.load(); try secureSessions.load(now: now) }
                } catch { warnStorage(error) }
            }
        }
        do { try store?.cleanup(now: now) } catch { warnStorage(error) }
        for (key, task) in memory.tasks where task.packet.deadline <= now {
            var candidate = memory
            let state = candidate.evidence[key]?.state
            if state != .read && state != .delivered { candidate.evidence[key]?.state = .failed }
            candidate.tasks.removeValue(forKey: key)
            aggregateMemory(task.packet.body.id, in: &candidate)
            do { try adopt(candidate) } catch { warnStorage(error) }
        }
        var pendingMemory = memory
        for (key, intent) in pendingMemory.intents where intent.deadline <= now {
            pendingMemory.intents.removeValue(forKey: key)
            if !pendingMemory.intents.values.contains(where: { $0.messageID == intent.messageID }),
               let index = pendingMemory.entries.firstIndex(where: { $0.id == intent.messageID && $0.state == .securing }) {
                pendingMemory.entries[index].state = .failed
            }
        }
        if pendingMemory.intents != memory.intents { try? adopt(pendingMemory) }
        maintainGroups(); flushMemory()
        if forwardSecure {
            do {
                for (receipt, peer) in try secureSessions.completeCommittedMessages() {
                    queueControl(try makeReceipt(receipt, to: peer))
                }
            } catch { warnStorage(error) }
        }
        materializeSecureIntents()
        pump(); refreshHistory(); changed()
    }
    private func flushMemory() {
        guard let store else { return }
        do {
            while let entry = memory.entries.first {
                if let inbox = memory.inbox[entry.id.uuidString] {
                    for receipt in [inbox.delivered, inbox.read].compactMap({ $0 }) { queueControl(receipt) }
                }
                try store.restore(entry,
                    tasks: memory.tasks.values.filter { $0.packet.body.id == entry.id },
                    evidence: memory.evidence.values.filter { $0.messageID == entry.id },
                    inbox: memory.inbox[entry.id.uuidString], intents: memory.intents.values.filter { $0.messageID == entry.id })
                memory.entries.removeFirst()
                memory.tasks = memory.tasks.filter { $0.value.packet.body.id != entry.id }
                memory.evidence = memory.evidence.filter { $0.value.messageID != entry.id }
                memory.inbox.removeValue(forKey: entry.id.uuidString)
                memory.intents = memory.intents.filter { $0.value.messageID != entry.id }
            }
            for (key, value) in memory.reads {
                try store.saveRead(value.entry, evidence: value.evidence); memory.reads.removeValue(forKey: key)
            }
            for (key, received) in memory.receipts {
                try store.apply(received.value, signedBy: received.packet.body.sender); memory.receipts.removeValue(forKey: key)
            }
            if memory.entries.isEmpty && memory.reads.isEmpty && memory.receipts.isEmpty {
                storageWarning = nil; memoryBufferFull = false
                capacityWriteFailure = false
                measuredMemory = VolatileHistory(); measuredSizes.removeAll()
            }
        } catch { warnStorage(error) }
    }
    private func adopt(_ candidate: VolatileHistory) throws {
        // Cache each unchanged record's encoded size. Re-encoding the entire 5 MB
        // buffer on every append makes foreground exchange progressively stall.
        var sizes: [String: Int] = [:]
        func measure<T: Encodable & Equatable>(_ values: [String: T], previous: [String: T], prefix: String) throws -> Int {
            var total = 0
            for (key, value) in values {
                let token = prefix + key
                let count: Int
                if previous[key] == value, let old = measuredSizes[token] { count = old }
                else {
                    // UUID/hash keys are ASCII. Conservatively include JSON keys,
                    // punctuation and per-record framing, also for array entries.
                    count = try JSONEncoder().encode(value).count + key.utf8.count + 8
                }
                sizes[token] = count; total += count
            }
            return total
        }
        let entries = Dictionary(uniqueKeysWithValues: candidate.entries.map { ($0.id.uuidString, $0) })
        let previousEntries = Dictionary(uniqueKeysWithValues: measuredMemory.entries.map { ($0.id.uuidString, $0) })
        let count = try 256 + measure(entries, previous: previousEntries, prefix: "e") +
            measure(candidate.tasks, previous: measuredMemory.tasks, prefix: "t") +
            measure(candidate.evidence, previous: measuredMemory.evidence, prefix: "d") +
            measure(candidate.inbox, previous: measuredMemory.inbox, prefix: "i") +
            measure(candidate.receipts, previous: measuredMemory.receipts, prefix: "p") +
            measure(candidate.intents, previous: measuredMemory.intents, prefix: "s") +
            measure(candidate.reads, previous: measuredMemory.reads, prefix: "r")
        guard count <= Self.volatileLimit else {
            memoryBufferFull = true
            storageWarning = "Временная память заполнена. Новые сообщения приостановлены до восстановления сохранения."
            throw MeshStorageError.capacity
        }
        memory = candidate; measuredMemory = candidate; measuredSizes = sizes
    }
    private func aggregateMemory(_ id: UUID, in candidate: inout VolatileHistory) {
        guard let index = candidate.entries.firstIndex(where: { $0.id == id }) else { return }
        let states = candidate.evidence.values.filter { $0.messageID == id }.map(\.state)
        for state in [DeliveryState.read, .delivered, .relayed, .sent, .queued, .failed] where states.contains(state) {
            candidate.entries[index].state = state; break
        }
    }
    private func refreshHistory() {
        var base: [ChatEntry]
        do {
            if let chat = historyConversationID, let store { base = try store.history(conversationID: chat, limit: visibleLimit) }
            else { base = try store?.history(limit: visibleLimit) ?? legacy }
        }
        catch { warnStorage(error); base = messages.filter { $0.isSaved != false } }
        for entry in memory.entries {
            if let index = base.firstIndex(where: { $0.id == entry.id }) { base[index] = entry }
            else { base.append(entry) }
        }
        for pending in memory.reads.values {
            if let index = base.firstIndex(where: { $0.id == pending.entry.id }) { base[index].readAt = pending.entry.readAt }
        }
        for received in memory.receipts.values {
            let value = received.value
            guard let index = base.firstIndex(where: { $0.id == value.messageID }) else { continue }
            if base[index].state != .read { base[index].state = value.kind == .read ? .read : .delivered }
        }
        messages = historyConversationID.map { chat in base.filter { $0.conversationID == chat } } ?? base
        storageUsage = try? store?.usage()
        onHistoryChange?(messages)
    }
    private func observe(_ packet: MeshPacket, via linkID: String) {
        guard peers.count < 64 || peers[packet.body.sender.id] != nil else { return }
        guard let info = try? PresenceInfo.decode(packet.body.payload) else { return }
        let card = packet.body.sender
        let created = Date(timeIntervalSince1970: Double(packet.body.createdAt))
        // A delayed/replayed announcement must not restore an older public-chat session.
        guard peers[card.id].map({ $0.lastSeen <= created }) ?? true else { return }
        let expiry = Date(timeIntervalSince1970: Double(packet.body.createdAt) + 20)
        routes[card.id, default: [:]][linkID] = (expiry, packet.body.hopLimit - packet.remainingHops + 1)
        peers[card.id] = MeshPeer(card: card, hops: packet.body.hopLimit - packet.remainingHops + 1,
            lastSeen: Date(timeIntervalSince1970: Double(packet.body.createdAt)),
            sessionID: info.sessionID,
            supportsContacts: info.capabilities?.contains("contacts-v1") == true,
            supportsGroups: info.capabilities?.contains("groups-v1") == true,
            supportsForwardSecrecy: info.capabilities?.contains("noise-fs-v1") == true)
        do {
            if info.capabilities?.contains("groups-v1") == true, !groupCapablePeers.contains(card.id), groupCapablePeers.count < 256 {
                try? store?.rememberGroupCapability(card); groupCapablePeers.insert(card.id)
            }
            discoveredGroups = discoveredGroups.filter { $0.value > clock() }
            for id in (info.groups ?? []).prefix(16) where discoveredGroups.count < 256 || discoveredGroups[id] != nil {
                discoveredGroups[id] = clock().addingTimeInterval(20)
            }
        }
        if known.count < 256 || known[card.id] != nil { known[card.id] = card }
        try? store?.remember(card)
        if forwardSecure {
            try? trustBook.observe(card)
            if info.capabilities?.contains("noise-fs-v1") == true { try? ensureSecureSession(card) }
        }
        refreshPeers()
    }
    private func refreshPeers() {
        for peer in Array(routes.keys) {
            routes[peer] = routes[peer]?.filter { key, path in
                path.expiry > clock() && links[key] != nil &&
                    !excludedDirectPeers.contains(links[key]?.peerID ?? "")
            }
            if let values = routes[peer]?.values, !values.isEmpty {
                peers[peer]?.hops = values.map(\.hops).min() ?? 1
            } else { routes.removeValue(forKey: peer); peers.removeValue(forKey: peer) }
        }
    }
    private func destinations(_ packet: MeshPacket, excludingPeer: String? = nil, only: String? = nil) -> [String] {
        let allowed = links.values.filter {
            ($0.peerID != nil || packet.body.kind == .presence) &&
            (only == nil || $0.id == only) && (excludingPeer == nil || $0.peerID != excludingPeer) &&
                !excludedDirectPeers.contains($0.peerID ?? "")
        }
        if only != nil { return allowed.map(\.id) }
        if let recipient = packet.body.recipient, let routes = routes[recipient] {
            let preferred = allowed.filter { routes[$0.id] != nil }
            if !preferred.isEmpty { return preferred.map(\.id) }
        }
        return allowed.map(\.id)
    }
    @discardableResult
    private func emit(_ packet: MeshPacket, excludingPeer: String? = nil, only: String? = nil, relay: Bool = false) -> Int {
        guard sessionID != nil, packet.deadline > clock(),
              let data = try? packet.encoded(), data.count <= MeshPacket.maxWireBytes else { return 0 }
        let ids = destinations(packet, excludingPeer: excludingPeer, only: only)
        for id in ids {
            if relay { counters.forwarded += 1 }
            if holdingSecureReplies { heldFrames.append((id, data)) }
            else { onTransmit?(id, data) }
        }
        return ids.count
    }
    public func note(_ text: String) { log(text); changed() }
    private func warnStorage(_ error: Error) {
        if case MeshStorageError.capacity = error { capacityWriteFailure = true; historyCleanupSuggested = true }
        if !memoryBufferFull {
            storageWarning = "Сохранение недоступно. Новые несохранённые данные могут быть потеряны после завершения приложения."
        }
    }
    private func log(_ text: String) {
        events.append(text)
        if events.count > 100 { events.removeFirst(events.count - 100) }
    }
    func changed() { onChange?() }
    public func securityInfo(for peerID: String) -> PeerSecurityInfo? {
        guard let peer = trustBook.records[peerID]?.peer ?? card(peerID) ?? knownParticipants.first(where: { $0.id == peerID }) else { return nil }
        return trustBook.info(peer)
    }
    public func verifyPeer(_ peerID: String, safetyCode: String) throws {
        guard let peer = trustBook.records[peerID]?.peer ?? card(peerID) ?? knownParticipants.first(where: { $0.id == peerID }) else { throw MeshError.unavailablePeer }
        try trustBook.observe(peer)
        try trustBook.verify(peer, code: safetyCode)
        if contactBook.records[peerID]?.peer.agreementKey != peer.agreementKey {
            try contactBook.replaceKey(peer)
        }
        try? ensureSecureSession(peer); changed()
    }
    public func channelReady(to peerID: String) -> Bool {
        guard forwardSecure else { return true }
        guard let peer = card(peerID), trustBook.info(peer).status != .changed else { return false }
        return secureSessions.active(for: peer, now: clock()) != nil
    }
    func endpointPacket(kind: PacketKind, recipient: PeerCard, cleartext: Data, now: Date,
                        id: UUID = UUID(), expiresAt: Date? = nil) throws -> MeshPacket {
        guard forwardSecure else {
            return try MeshPacket.make(identity: identity, kind: kind, recipient: recipient, cleartext: cleartext, now: now, id: id, expiresAt: expiresAt)
        }
        do { return try secureSessions.seal(kind: kind, to: recipient, cleartext: cleartext, now: now, id: id, expiresAt: expiresAt) }
        catch ChannelSecurityError.pending { try? ensureSecureSession(recipient); throw ChannelSecurityError.pending }
        catch let error as MeshStorageError { warnStorage(error); throw ChannelSecurityError.unavailable }
    }
    private func ensureSecureSession(_ peer: PeerCard) throws {
        if let hello = try secureSessions.initiate(peer: peer, now: clock()) { try sendHandshake(hello, to: peer) }
    }
    private func sendHandshake(_ hello: NoiseHandshake, to peer: PeerCard) throws {
        let now = clock(), time = Int64(now.timeIntervalSince1970)
        let body = PacketBody(version: 3, id: UUID(), kind: .handshake, sender: identity.card, recipient: peer.id,
            createdAt: time, expiresAt: time + 30, hopLimit: 256, payload: try JSONEncoder().encode(hello))
        _ = emit(MeshPacket(body: body, signature: try identity.signing.signature(for: MeshPacket.encoder.encode(body)), remainingHops: 256))
    }
    private func acceptHandshake(_ packet: MeshPacket) throws {
        guard forwardSecure else { throw ChannelSecurityError.invalidHandshake }
        let peer = packet.body.sender
        let hello = try JSONDecoder().decode(NoiseHandshake.self, from: packet.body.payload)
        if let reply = try secureSessions.handle(hello, from: peer, now: clock()) { try sendHandshake(reply, to: peer) }
        if secureSessions.active(for: peer, now: clock()) != nil {
            materializeSecureIntents()
            if let record = contactBook.records[peer.id] {
                if let outgoing = record.outgoing { try? sendContact(.request(outgoing), to: peer) }
                if let response = record.lastResponse { try? sendContact(response, to: peer) }
            }
            for flow in groupFlows.values where flow.outgoing && flow.phase == .sent && flow.invitation.body.invitee.id == peer.id {
                try? sendGroupSignal(.invitation(flow.invitation), to: peer,
                    deadline: Date(timeIntervalSince1970: Double(flow.invitation.body.createdAt) + MeshPacket.lifetime))
            }
        }
    }
    private func groupIntentAllowed(_ intent: SecureSendIntent) throws -> Bool {
        let payload = try JSONDecoder().decode(ChatPayload.self, from: intent.payload)
        guard let audience = payload.group else { return true }
        guard let group = closedGroups.first(where: { $0.id == audience.groupID }),
              group.canSend(as: identity.card.id),
              group.member(identity.card.id)?.membershipID == audience.senderMembershipID,
              let member = group.member(intent.recipient.id),
              audience.recipients.contains(GroupRecipient(peerID: member.id, membershipID: member.membershipID)) else { return false }
        return true
    }
    private func cancelInvalidGroupIntents() throws {
        guard forwardSecure else { return }
        for intent in try store?.secureIntents() ?? [] where try !groupIntentAllowed(intent) { try store?.cancelSecureIntent(intent) }
        var candidate = memory
        for (key, intent) in candidate.intents where try !groupIntentAllowed(intent) {
            candidate.intents.removeValue(forKey: key)
            if let index = candidate.entries.firstIndex(where: { $0.id == intent.messageID && $0.state == .securing }) {
                candidate.entries[index].state = .failed
            }
        }
        if candidate.intents != memory.intents { try adopt(candidate) }
    }
    private func materializeSecureIntents() {
        guard forwardSecure, sessionID != nil, let store else { return }
        do {
            let intents = try store.secureIntents()
            guard !intents.isEmpty else { return }
            let batch = (0..<min(16, intents.count)).map { intents[(secureIntentCursor + $0) % intents.count] }
            secureIntentCursor = (secureIntentCursor + batch.count) % intents.count
            for intent in batch {
                let payload = try JSONDecoder().decode(ChatPayload.self, from: intent.payload)
                if intent.deadline <= clock() { try store.cancelSecureIntent(intent); continue }
                if let audience = payload.group {
                    guard let group = closedGroups.first(where: { $0.id == audience.groupID }),
                          group.canSend(as: identity.card.id),
                          group.member(identity.card.id)?.membershipID == audience.senderMembershipID,
                          let member = group.member(intent.recipient.id),
                          audience.recipients.contains(GroupRecipient(peerID: member.id, membershipID: member.membershipID)) else {
                        try store.cancelSecureIntent(intent); continue
                    }
                } else if !payload.isPublic && !canSendDirect(to: intent.recipient.id) { continue }
                if payload.isPublic, let current = peers[intent.recipient.id]?.sessionID, current != payload.sessionID {
                    try store.cancelSecureIntent(intent); continue
                }
                do {
                    let packet = try endpointPacket(kind: .message, recipient: intent.recipient, cleartext: intent.payload,
                        now: clock(), id: intent.messageID, expiresAt: intent.deadline)
                    try store.materialize(intent, packet: packet)
                } catch is ChannelSecurityError { continue }
            }
        } catch { warnStorage(error) }
    }
    private func consumeSecure(_ packet: MeshPacket) throws {
        let opened = try secureSessions.prepareOpen(packet, now: clock())
        holdingSecureReplies = true; heldControls = []; heldFrames = []
        defer { holdingSecureReplies = false; heldControls = []; heldFrames = [] }
        if opened.duplicate && opened.cleartext == nil {
            counters.duplicates += 1
            try acknowledge(packet, kind: .applied)
            if packet.body.kind == .message {
                let previous = try memory.inbox[packet.body.id.uuidString] ?? store?.inbox(packet.body.id)
                if let previous {
                    guard previous.digest == opened.digest else { throw ChannelSecurityError.replay }
                    if let delivered = previous.delivered { queueControl(delivered) }
                    if let read = previous.read { queueControl(read) }
                }
            }
        } else {
            guard let data = opened.cleartext else { throw ChannelSecurityError.replay }
            try consume(packet, cleartext: data)
        }
        try secureSessions.finish(opened, kind: packet.body.kind)
        // No delivery acknowledgment escapes while a consumed receive key is retained.
        holdingSecureReplies = false
        let jobs = heldControls, frames = heldFrames
        heldControls = []; heldFrames = []
        for (packet, intent) in jobs { queueControl(packet, groupIntent: intent) }
        for (link, data) in frames where links[link] != nil { onTransmit?(link, data) }
    }

}
