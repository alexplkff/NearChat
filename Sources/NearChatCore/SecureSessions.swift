import Foundation
import CryptoKit
import Noise

struct NoiseHandshake: Codable {
    let epoch: UUID
    let startedAt: Int64
    let step: Int // 0 asks the deterministic initiator to start; 1/2 are Noise IK messages.
    let message: Data
}
struct PendingNoise: Codable {
    let peer: PeerCard
    let hello: NoiseHandshake
    let ephemeral: Data
    var localFingerprint: String? = nil
}
struct ReceiveKey: Codable {
    let sequence: Int
    let key: Data
    var packetID: UUID? = nil
    var digest: Data? = nil
    var kind: PacketKind? = nil
}
struct CompletedNoisePacket: Codable {
    let sequence: Int
    let digest: Data
    var cleartext: Data? // Service data only. Text is owned solely by chat history.
}
struct NoiseEpoch: Codable {
    let id: UUID
    let peer: PeerCard
    let startedAt: Int64
    var sendKey: Data
    var receiveKey: Data
    var localFingerprint: String? = nil
    var sendSequence = 0
    var receiveSequence = 0
    var skipped: [ReceiveKey] = []
    var completed: [CompletedNoisePacket] = []
    var response: NoiseHandshake?
    var helloDigest: Data?
    var expires: Date { Date(timeIntervalSince1970: Double(startedAt) + 2 * MeshPacket.lifetime + 5) }
    func canSend(_ now: Date) -> Bool { sendSequence < 256 && now.timeIntervalSince1970 < Double(startedAt) + MeshPacket.lifetime }
}
struct PreparedNoiseOpen {
    let epoch: UUID
    let sequence: Int
    let digest: Data
    let cleartext: Data?
    let duplicate: Bool
}
/// Noise IK + Noise REKEY after each transport packet. Serialized by MeshEngine.
/// Before consuming application data the current receive key is durably retained as a
/// skipped key. Only after application success is it punctured and the ACK released.
final class SecureSessions {
    let identity: MeshIdentity
    let store: () -> MeshStore?
    let trust: PeerTrustBook
    private(set) var epochs: [UUID: NoiseEpoch] = [:]
    private(set) var pending: [String: PendingNoise] = [:]
    private var lastHandshake: [String: Date] = [:]
    init(identity: MeshIdentity, store: @escaping () -> MeshStore?, trust: PeerTrustBook) {
        self.identity = identity; self.store = store; self.trust = trust
    }
    func load(now: Date) throws {
        guard let archive = store()?.own else { return }
        for row in try archive.all(space: "noise-epoch") {
            let value = try JSONDecoder().decode(NoiseEpoch.self, from: row.data)
            try value.peer.validate()
            guard row.id == value.id.uuidString, value.sendKey.count == 32, value.receiveKey.count == 32,
                  (0...256).contains(value.sendSequence), (0...256).contains(value.receiveSequence),
                  value.skipped.count <= 256, value.completed.count <= 256,
                  value.skipped.allSatisfy({ $0.key.count == 32 && (0..<value.receiveSequence).contains($0.sequence) && ($0.digest == nil || $0.digest?.count == 32) }),
                  Set(value.skipped.map(\.sequence)).count == value.skipped.count,
                  Set(value.completed.map(\.sequence)).count == value.completed.count,
                  value.completed.allSatisfy({ $0.digest.count == 32 && (0..<value.receiveSequence).contains($0.sequence) })
            else { throw MeshStorageError.corrupt }
            if value.expires > now, value.localFingerprint == identity.card.keyFingerprint { epochs[value.id] = value }
        }
        for row in try archive.all(space: "noise-pending") {
            let value = try JSONDecoder().decode(PendingNoise.self, from: row.data)
            try value.peer.validate()
            guard row.id == value.peer.id, value.ephemeral.count == 32, value.hello.step == 1 else { throw MeshStorageError.corrupt }
            if now.timeIntervalSince1970 < Double(value.hello.startedAt) + 30, value.localFingerprint == identity.card.keyFingerprint { pending[row.id] = value }
        }
    }
    private func archive() throws -> SQLiteArchive {
        guard let archive = store()?.own else { throw ChannelSecurityError.unavailable }; return archive
    }
    private func save(_ value: NoiseEpoch) throws {
        let archive = try archive()
        try archive.transaction { try archive.put(space: "noise-epoch", id: value.id.uuidString, value: value, expiry: value.expires) }
        epochs[value.id] = value
    }
    func cleanup(now: Date) throws {
        let archive = try archive()
        let expired = try archive.expired(space: "noise-epoch", now: now)
        let stale = try archive.expired(space: "noise-pending", now: now)
        if !expired.isEmpty || !stale.isEmpty {
            try archive.transaction {
                for row in expired + stale { try archive.remove(space: row.space, id: row.id) }
            }
        }
        epochs = epochs.filter { $0.value.expires > now }
        pending = pending.filter { now.timeIntervalSince1970 < Double($0.value.hello.startedAt) + 30 }
    }
    func active(for peer: PeerCard, now: Date) -> NoiseEpoch? {
        epochs.values.filter { $0.peer.id == peer.id && $0.peer.keyFingerprint == peer.keyFingerprint && $0.canSend(now) }
            .max { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }
    }
    private func state(peer: PeerCard, epoch: UUID, initiator: Bool, ephemeral: Data? = nil) throws -> Noise.HandshakeState {
        let prologue = "NearChat-v3-noise-ik-rekey-v1|\(epoch.uuidString)|" + [identity.card.keyFingerprint, peer.keyFingerprint].sorted().joined(separator: ":")
        return try Noise.HandshakeState(config: Noise.Config(
            cipherSuite: Noise.CipherSuite(keyCurve: .x25519, cipher: .ChaChaPoly1305, hashFunction: .sha256),
            handshake: initiator ? .IK_Initiator(remoteStatic: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer.agreementKey)) : .IK_Responder,
            prologue: Array(prologue.utf8),
            staticKeypair: identity.agreement,
            ephemeralKeypair: try ephemeral.map { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0) }))
    }
    func initiate(peer: PeerCard, now: Date) throws -> NoiseHandshake? {
        try trust.requireUnchanged(peer)
        if let active = active(for: peer, now: now), now.timeIntervalSince1970 < Double(active.startedAt) + 3600 { return nil }
        if let last = lastHandshake[peer.id], now.timeIntervalSince(last) < 5 { return nil }
        if identity.card.id > peer.id {
            lastHandshake[peer.id] = now
            return NoiseHandshake(epoch: UUID(), startedAt: Int64(now.timeIntervalSince1970), step: 0, message: Data())
        }
        if let existing = pending[peer.id], existing.peer.keyFingerprint == peer.keyFingerprint,
           now.timeIntervalSince1970 < Double(existing.hello.startedAt) + 30 {
            lastHandshake[peer.id] = now; return existing.hello
        }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey().rawRepresentation, epoch = UUID()
        let noise = try state(peer: peer, epoch: epoch, initiator: true, ephemeral: ephemeral)
        let first = try noise.writeMessage(payload: [])
        let hello = NoiseHandshake(epoch: epoch, startedAt: Int64(now.timeIntervalSince1970), step: 1, message: Data(first.buffer))
        let value = PendingNoise(peer: peer, hello: hello, ephemeral: ephemeral, localFingerprint: identity.card.keyFingerprint)
        let archive = try archive()
        try archive.transaction { try archive.put(space: "noise-pending", id: peer.id, value: value,
            expiry: Date(timeIntervalSince1970: Double(hello.startedAt) + 30)) }
        pending[peer.id] = value; lastHandshake[peer.id] = now
        return hello
    }
    func handle(_ hello: NoiseHandshake, from peer: PeerCard, now: Date) throws -> NoiseHandshake? {
        try trust.requireUnchanged(peer)
        guard Double(hello.startedAt) <= now.timeIntervalSince1970 + 5,
              now.timeIntervalSince1970 < Double(hello.startedAt) + 30,
              hello.message.count <= 256 else { throw ChannelSecurityError.invalidHandshake }
        switch hello.step {
        case 0:
            guard identity.card.id < peer.id, hello.message.isEmpty else { throw ChannelSecurityError.invalidHandshake }
            return try initiate(peer: peer, now: now)
        case 1:
            guard peer.id < identity.card.id else { throw ChannelSecurityError.invalidHandshake }
            let digest = Data(SHA256.hash(data: hello.message))
            if let existing = epochs[hello.epoch] {
                guard existing.peer.keyFingerprint == peer.keyFingerprint, existing.helloDigest == digest,
                      existing.startedAt == hello.startedAt else { throw ChannelSecurityError.invalidHandshake }
                return existing.response
            }
            guard epochs.count < 1024, epochs.values.filter({ $0.peer.id == peer.id }).count < 64 else { throw ChannelSecurityError.limit }
            let noise = try state(peer: peer, epoch: hello.epoch, initiator: false)
            let read = try noise.readMessage(Array(hello.message))
            guard read.payload.isEmpty, noise.remoteStaticKeyBytes == peer.agreementKey else { throw ChannelSecurityError.invalidHandshake }
            let result = try noise.writeMessage(payload: [])
            guard let send = result.c2?.keyBytes, let receive = result.c1?.keyBytes else { throw ChannelSecurityError.invalidHandshake }
            let reply = NoiseHandshake(epoch: hello.epoch, startedAt: hello.startedAt, step: 2, message: Data(result.buffer))
            try save(NoiseEpoch(id: hello.epoch, peer: peer, startedAt: hello.startedAt, sendKey: send, receiveKey: receive,
                localFingerprint: identity.card.keyFingerprint, response: reply, helloDigest: digest))
            return reply
        case 2:
            if let existing = epochs[hello.epoch], existing.peer.keyFingerprint == peer.keyFingerprint { return nil }
            guard let pending = pending[peer.id], pending.hello.epoch == hello.epoch,
                  pending.hello.startedAt == hello.startedAt, pending.peer.keyFingerprint == peer.keyFingerprint,
                  epochs.count < 1024, epochs.values.filter({ $0.peer.id == peer.id }).count < 64 else { throw ChannelSecurityError.invalidHandshake }
            let noise = try state(peer: peer, epoch: hello.epoch, initiator: true, ephemeral: pending.ephemeral)
            _ = try noise.writeMessage(payload: [])
            let result = try noise.readMessage(Array(hello.message))
            guard result.payload.isEmpty, let send = result.c1?.keyBytes, let receive = result.c2?.keyBytes else { throw ChannelSecurityError.invalidHandshake }
            let epoch = NoiseEpoch(id: hello.epoch, peer: peer, startedAt: hello.startedAt, sendKey: send, receiveKey: receive, localFingerprint: identity.card.keyFingerprint)
            let archive = try archive()
            try archive.transaction {
                try archive.put(space: "noise-epoch", id: epoch.id.uuidString, value: epoch, expiry: epoch.expires)
                try archive.remove(space: "noise-pending", id: peer.id)
            }
            epochs[epoch.id] = epoch; self.pending.removeValue(forKey: peer.id)
            return nil
        default: throw ChannelSecurityError.invalidHandshake
        }
    }
    func seal(kind: PacketKind, to peer: PeerCard, cleartext: Data, now: Date, id: UUID, expiresAt: Date?) throws -> MeshPacket {
        try trust.requireUnchanged(peer)
        guard var epoch = active(for: peer, now: now) else { throw ChannelSecurityError.pending }
        let created = Int64(now.timeIntervalSince1970)
        let expiry = Int64(min(expiresAt ?? now.addingTimeInterval(MeshPacket.lifetime), now.addingTimeInterval(MeshPacket.lifetime)).timeIntervalSince1970)
        guard expiry > created else { throw MeshError.expiredPacket }
        guard Double(created) >= Double(epoch.startedAt) - 5 else { throw MeshError.expiredPacket }
        let header = SecureHeader(session: epoch.id, sequence: epoch.sendSequence)
        var body = PacketBody(version: 3, id: id, kind: kind, sender: identity.card, recipient: peer.id,
            createdAt: created, expiresAt: expiry, hopLimit: 256, payload: Data(), secure: header)
        let cipher = try Noise.CipherState.restoring(key: epoch.sendKey)
        try cipher.setNonce(UInt64(epoch.sendSequence))
        let payload = try cipher.seal(ad: body.associatedData, plaintext: cleartext)
        try cipher.rekey()
        guard let next = cipher.keyBytes else { throw ChannelSecurityError.invalidHandshake }
        epoch.sendKey = next; epoch.sendSequence += 1
        // Commit allocation before ciphertext can escape. Failure never falls back to static DH.
        try save(epoch)
        body = PacketBody(version: 3, id: id, kind: kind, sender: identity.card, recipient: peer.id,
            createdAt: created, expiresAt: expiry, hopLimit: 256, payload: payload, secure: header)
        var packet = MeshPacket(body: body, signature: try identity.signing.signature(for: MeshPacket.encoder.encode(body)), remainingHops: 256)
        try packet.offerCustody(by: identity)
        return packet
    }
    func prepareOpen(_ packet: MeshPacket, now: Date) throws -> PreparedNoiseOpen {
        try trust.requireUnchanged(packet.body.sender)
        guard let header = packet.body.secure, var epoch = epochs[header.session], epoch.expires > now,
              epoch.peer.keyFingerprint == packet.body.sender.keyFingerprint,
              packet.body.recipient == identity.card.id,
              Double(packet.body.createdAt) >= Double(epoch.startedAt) - 5,
              Double(packet.body.createdAt) < Double(epoch.startedAt) + MeshPacket.lifetime else { throw ChannelSecurityError.invalidHandshake }
        let digest = try packet.digest()
        if let completed = epoch.completed.first(where: { $0.sequence == header.sequence }) {
            guard completed.digest == digest else { throw ChannelSecurityError.replay }
            return PreparedNoiseOpen(epoch: epoch.id, sequence: header.sequence, digest: digest, cleartext: completed.cleartext, duplicate: true)
        }
        var candidate = epoch
        if header.sequence >= candidate.receiveSequence {
            let cipher = try Noise.CipherState.restoring(key: candidate.receiveKey)
            for sequence in candidate.receiveSequence...header.sequence {
                guard let key = cipher.keyBytes else { throw ChannelSecurityError.invalidHandshake }
                candidate.skipped.append(ReceiveKey(sequence: sequence, key: key)); try cipher.rekey()
            }
            candidate.receiveSequence = header.sequence + 1
            guard let next = cipher.keyBytes else { throw ChannelSecurityError.invalidHandshake }
            candidate.receiveKey = next
        }
        guard let index = candidate.skipped.firstIndex(where: { $0.sequence == header.sequence }) else { throw ChannelSecurityError.replay }
        let retained = candidate.skipped[index]
        guard retained.digest == nil || retained.digest == digest else { throw ChannelSecurityError.replay }
        let key = retained.key
        let cipher = try Noise.CipherState.restoring(key: key)
        try cipher.setNonce(UInt64(header.sequence))
        let clear = try cipher.open(ad: packet.body.associatedData, ciphertext: packet.body.payload)
        candidate.skipped[index].packetID = packet.body.id
        candidate.skipped[index].digest = digest
        candidate.skipped[index].kind = packet.body.kind
        if candidate.receiveSequence != epoch.receiveSequence || retained.digest == nil {
            // Invalid AEAD must never advance a receive chain or fill skipped-key storage.
            try save(candidate); epoch = candidate
        }
        return PreparedNoiseOpen(epoch: epoch.id, sequence: header.sequence, digest: digest, cleartext: clear, duplicate: false)
    }
    func completeCommittedMessages() throws -> [(FinalReceipt, PeerCard)] {
        guard let store = store() else { return [] }
        var receipts: [(FinalReceipt, PeerCard)] = []
        for epoch in Array(epochs.values) {
            for key in epoch.skipped where key.kind == .message {
                guard let id = key.packetID, let digest = key.digest,
                      let inbox = try store.inbox(id), inbox.digest == digest else { continue }
                let prepared = PreparedNoiseOpen(epoch: epoch.id, sequence: key.sequence, digest: digest, cleartext: nil, duplicate: false)
                try finish(prepared, kind: .message)
                receipts.append((FinalReceipt(messageID: id, recipientID: identity.card.id, digest: digest, kind: .delivered), epoch.peer))
            }
        }
        return receipts
    }
    func mayAcknowledge(_ header: SecureHeader) -> Bool {
        epochs[header.session]?.skipped.contains(where: { $0.sequence == header.sequence }) != true
    }
    func finish(_ prepared: PreparedNoiseOpen, kind: PacketKind) throws {
        guard !prepared.duplicate, var epoch = epochs[prepared.epoch] else { return }
        epoch.skipped.removeAll { $0.sequence == prepared.sequence }
        epoch.completed.append(CompletedNoisePacket(sequence: prepared.sequence, digest: prepared.digest,
            cleartext: kind == .message ? nil : prepared.cleartext))
        var cachedBytes = epoch.completed.reduce(0) { $0 + ($1.cleartext?.count ?? 0) }
        for index in epoch.completed.indices where cachedBytes > 65_536 {
            cachedBytes -= epoch.completed[index].cleartext?.count ?? 0; epoch.completed[index].cleartext = nil
        }
        try save(epoch)
    }
}

extension MeshStore {
    func quarantineLegacyTextJobs(ownerID: String, localFingerprint: String) throws {
        let tasks = try outgoing() + own.all(space: "awaiting").map { try JSONDecoder().decode(TransferTask.self, from: $0.data) }
        let old = tasks.filter { $0.packet.body.sender.id == ownerID && $0.packet.body.kind == .message && ($0.packet.body.secure == nil || $0.packet.body.sender.keyFingerprint != localFingerprint) }
        if !old.isEmpty { try own.transaction {
            for task in old {
                let key = task.packet.storageKey
                try own.remove(space: "outbox", id: key); try own.remove(space: "awaiting", id: key)
                if var proof = try own.decode(DeliveryEvidence.self, space: "delivery", id: key) {
                    if proof.state != .read && proof.state != .delivered { proof.state = .failed }
                    try own.put(space: "delivery", id: key, value: proof)
                }
                try aggregate(task.packet.body.id)
            }
        } }
        let controls = try originControls() + relay.all(space: "originAwaiting").map { try JSONDecoder().decode(TransferTask.self, from: $0.data) }
        let legacy = controls.filter { $0.packet.body.sender.id == ownerID && [.contact, .group, .receipt].contains($0.packet.body.kind) && ($0.packet.body.secure == nil || $0.packet.body.sender.keyFingerprint != localFingerprint) }
        if !legacy.isEmpty { try relay.transaction {
            for task in legacy {
                try relay.remove(space: "origin", id: task.packet.storageKey)
                try relay.remove(space: "originAwaiting", id: task.packet.storageKey)
            }
        } }
    }
}
