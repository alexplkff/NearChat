import Foundation

/// Plaintext is stored only inside the local encrypted history budget, never at relays.
/// The recipient, audience and original deadline are fixed when the user presses Send.
struct SecureSendIntent: Codable, Equatable {
    let messageID: UUID
    let recipient: PeerCard
    let payload: Data
    let createdAt: Date
    let deadline: Date
    var key: String { messageID.uuidString + ":" + recipient.id }
}
extension MeshStore {
    func secureIntents() throws -> [SecureSendIntent] {
        try own.all(space: "secure-intent").map { row in
            let value = try JSONDecoder().decode(SecureSendIntent.self, from: row.data)
            try value.recipient.validate()
            let payload = try JSONDecoder().decode(ChatPayload.self, from: value.payload); try ChatPayload.validate(payload.text)
            guard value.key == row.id, value.deadline > value.createdAt,
                  value.deadline.timeIntervalSince(value.createdAt) <= MeshPacket.lifetime else { throw MeshStorageError.corrupt }
            return value
        }
    }
    func materialize(_ intent: SecureSendIntent, packet: MeshPacket) throws {
        guard try entry(intent.messageID) != nil else { try cancelSecureIntent(intent); return }
        try writeHistory(protecting: intent.messageID) {
            try self.own.put(space: "outbox", id: packet.storageKey, value: TransferTask(packet: packet), expiry: packet.deadline)
            try self.own.put(space: "delivery", id: packet.storageKey, value: DeliveryEvidence(messageID: intent.messageID,
                recipient: intent.recipient, digest: try packet.digest(), state: .queued))
            try self.own.remove(space: "secure-intent", id: intent.key)
            try self.aggregate(intent.messageID)
        }
    }
    func cancelSecureIntent(_ intent: SecureSendIntent) throws {
        try own.transaction { try own.remove(space: "secure-intent", id: intent.key); try aggregate(intent.messageID) }
    }
    func expireSecureIntents(now: Date) throws {
        let expired = try secureIntents().filter { $0.deadline <= now }
        guard !expired.isEmpty else { return }
        try own.transaction {
            for intent in expired { try own.remove(space: "secure-intent", id: intent.key) }
            for id in Set(expired.map(\.messageID)) { try aggregate(id) }
        }
    }
}
