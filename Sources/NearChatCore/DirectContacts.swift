import Foundation
import CryptoKit

public enum ContactError: Error, LocalizedError {
    case consentRequired, blocked, paused(Date), unsupportedPeer, noRequest, storageUnavailable, invalidRequest
    public var errorDescription: String? {
        switch self {
        case .consentRequired: return "Сначала отправьте запрос и дождитесь согласия собеседника"
        case .blocked: return "Участник заблокирован. Сначала разблокируйте его"
        case .paused(let until): return "Новый запрос доступен после \(until.formatted(date: .abbreviated, time: .shortened))"
        case .unsupportedPeer: return "Для личного диалога собеседнику нужна обновлённая версия NearChat"
        case .noRequest: return "Запрос уже обработан или недоступен"
        case .storageUnavailable: return "Не удалось сохранить запрос или решение. Повторите после восстановления хранилища"
        case .invalidRequest: return "Не удалось проверить согласие на личную переписку"
        }
    }
}

public struct ContactRequestBody: Codable, Equatable, Sendable {
    public let id: UUID
    public let sequence: Int64
    public let requester: PeerCard
    public let recipient: PeerCard
    public let createdAt: Int64
}
public struct ContactRequestProof: Codable, Equatable, Sendable {
    public let body: ContactRequestBody
    public let signature: Data
    func validate() throws {
        try body.requester.validate(); try body.recipient.validate()
        guard body.requester.id != body.recipient.id, body.sequence > 0, signature.count == 64,
              try Curve25519.Signing.PublicKey(rawRepresentation: body.requester.signingKey)
                .isValidSignature(signature, for: MeshPacket.encoder.encode(body)) else { throw ContactError.invalidRequest }
    }
    static func make(identity: MeshIdentity, recipient: PeerCard, sequence: Int64, now: Date) throws -> Self {
        let body = ContactRequestBody(id: UUID(), sequence: sequence, requester: identity.card,
            recipient: recipient, createdAt: Int64(now.timeIntervalSince1970))
        return Self(body: body, signature: try identity.signing.signature(for: MeshPacket.encoder.encode(body)))
    }
    var deadline: Date { Date(timeIntervalSince1970: Double(body.createdAt) + MeshPacket.lifetime) }
}
public struct ContactGrantBody: Codable, Equatable, Sendable {
    public let request: ContactRequestProof
    public let approvedAt: Int64
}
public struct ContactGrant: Codable, Equatable, Sendable {
    public let body: ContactGrantBody
    public let signature: Data
    func validate(local: PeerCard, peer: PeerCard) throws {
        try body.request.validate()
        let request = body.request.body
        guard signature.count == 64,
              (request.requester.id == local.id && request.recipient.id == peer.id) ||
              (request.requester.id == peer.id && request.recipient.id == local.id) else { throw ContactError.invalidRequest }
        let localProof = request.requester.id == local.id ? request.requester : request.recipient
        let peerProof = request.requester.id == peer.id ? request.requester : request.recipient
        guard localProof.agreementKey == local.agreementKey, peerProof.agreementKey == peer.agreementKey,
              try Curve25519.Signing.PublicKey(rawRepresentation: request.recipient.signingKey)
                .isValidSignature(signature, for: MeshPacket.encoder.encode(body)) else { throw ContactError.invalidRequest }
    }
    static func approve(_ request: ContactRequestProof, by identity: MeshIdentity, now: Date) throws -> Self {
        try request.validate()
        guard request.body.recipient.id == identity.card.id else { throw ContactError.invalidRequest }
        let body = ContactGrantBody(request: request, approvedAt: Int64(now.timeIntervalSince1970))
        return Self(body: body, signature: try identity.signing.signature(for: MeshPacket.encoder.encode(body)))
    }
}
struct ContactRejection: Codable, Equatable, Sendable {
    let requestID: UUID
    let rejectedAt: Int64
    let rejectionCount: Int
    let retryAt: Int64?
}
enum ContactSignal: Codable, Equatable, Sendable {
    case request(ContactRequestProof)
    case accepted(ContactGrant)
    case rejected(ContactRejection)
    var deadline: Date {
        switch self {
        case .request(let value): return value.deadline
        case .accepted(let value): return Date(timeIntervalSince1970: Double(value.body.approvedAt) + MeshPacket.lifetime)
        case .rejected(let value): return Date(timeIntervalSince1970: Double(value.rejectedAt) + MeshPacket.lifetime)
        }
    }
}
struct ContactRecord: Codable, Equatable {
    var peer: PeerCard
    var supportsContacts = true
    var blocked = false
    var grant: ContactGrant?
    var outgoing: ContactRequestProof?
    var incoming: ContactRequestProof?
    var outgoingSequence: Int64 = 0
    var incomingSequence: Int64 = 0
    var incomingRequestID: UUID?
    var lastResponse: ContactSignal?
    var incomingRejections = 0
    var incomingRetryAt: Date?
    var outgoingRejections = 0
    var outgoingRetryAt: Date?
}
public enum DirectContactPhase: String, Sendable {
    case available, outgoing, incoming, accepted, declined, paused, blocked
}
public struct DirectContact: Identifiable, Sendable {
    public var id: String { peer.id }
    public let peer: PeerCard
    public let phase: DirectContactPhase
    public let incomingRequestID: UUID?
    public let outgoingRequestID: UUID?
    public let retryAt: Date?
    public let canSend: Bool
    public let supportsContacts: Bool
    public let canRequest: Bool
    public var status: String {
        switch phase {
        case .available: return "Для переписки нужен запрос"
        case .outgoing: return "Запрос отправлен, ответа пока нет"
        case .incoming: return "Запрос на общение"
        case .accepted: return "Личный диалог открыт"
        case .declined: return "Запрос отклонён. Можно попробовать ещё раз"
        case .paused: return "Два отказа — пауза до \(retryAt?.formatted(date: .abbreviated, time: .shortened) ?? "")"
        case .blocked: return "Участник заблокирован"
        }
    }
}

/// Local authority for rejection limits and blocks. New decisions require a durable commit.
final class ContactBook {
    private(set) var records: [String: ContactRecord] = [:]
    private let persist: (ContactRecord) throws -> Void
    init(persist: @escaping (ContactRecord) throws -> Void) { self.persist = persist }
    func load(_ values: [ContactRecord], identity: MeshIdentity) throws {
        var result: [String: ContactRecord] = [:]
        for value in values {
            try value.peer.validate()
            guard value.peer.id != identity.card.id, (0...2).contains(value.incomingRejections),
                  (0...2).contains(value.outgoingRejections), value.incomingSequence >= 0,
                  value.outgoingSequence >= 0 else { throw MeshStorageError.corrupt }
            if let grant = value.grant { try grant.validate(local: identity.card, peer: value.peer) }
            if let proof = value.incoming {
                try proof.validate()
                guard proof.body.requester.id == value.peer.id, proof.body.recipient.id == identity.card.id else { throw MeshStorageError.corrupt }
            }
            if let proof = value.outgoing {
                try proof.validate()
                guard proof.body.requester.id == identity.card.id, proof.body.recipient.id == value.peer.id else { throw MeshStorageError.corrupt }
            }
            result[value.peer.id] = value
        }
        records = result
    }
    private func commit(_ record: ContactRecord) throws {
        guard records[record.peer.id] != record else { return }
        try persist(record)
        records[record.peer.id] = record
    }
    func observe(_ peer: PeerCard) throws {
        var record = records[peer.id] ?? ContactRecord(peer: peer)
        record.peer = peer; record.supportsContacts = true
        try commit(record)
    }
    func summary(_ peer: PeerCard, now: Date, supported: Bool = false) -> DirectContact {
        let record = records[peer.id] ?? ContactRecord(peer: peer, supportsContacts: false)
        let paused = record.outgoingRetryAt.map { $0 > now } ?? false
        let phase: DirectContactPhase
        if record.blocked { phase = .blocked }
        else if record.grant != nil { phase = .accepted }
        else if record.incoming != nil { phase = .incoming }
        else if paused { phase = .paused }
        else if record.outgoing != nil { phase = .outgoing }
        else if record.outgoingRejections == 1 { phase = .declined }
        else { phase = .available }
        let pendingCanRepeat = record.outgoing.map { $0.deadline <= now } ?? true
        return DirectContact(peer: peer, phase: phase, incomingRequestID: record.blocked ? nil : record.incoming?.body.id,
            outgoingRequestID: record.outgoing?.body.id, retryAt: paused ? record.outgoingRetryAt : nil,
            canSend: record.grant != nil && !record.blocked, supportsContacts: record.supportsContacts || supported,
            canRequest: (record.supportsContacts || supported) && !record.blocked && record.grant == nil && !paused && pendingCanRepeat)
    }
    func request(_ peer: PeerCard, identity: MeshIdentity, now: Date) throws -> ContactSignal {
        var record = records[peer.id] ?? ContactRecord(peer: peer, supportsContacts: false)
        guard !record.blocked else { throw ContactError.blocked }
        guard record.grant == nil else { throw ContactError.noRequest }
        guard record.supportsContacts else { throw ContactError.unsupportedPeer }
        if let until = record.outgoingRetryAt, until > now { throw ContactError.paused(until) }
        if let previous = record.outgoing, previous.deadline > now { return .request(previous) }
        guard record.outgoingSequence < Int64.max else { throw ContactError.invalidRequest }
        if record.outgoingRetryAt != nil { record.outgoingRejections = 0; record.outgoingRetryAt = nil }
        record.outgoingSequence += 1
        let proof = try ContactRequestProof.make(identity: identity, recipient: peer, sequence: record.outgoingSequence, now: now)
        record.peer = peer; record.outgoing = proof
        // The recipient's voluntary reverse request starts a fresh two-attempt cycle.
        record.incomingRejections = 0; record.incomingRetryAt = nil
        try commit(record)
        return .request(proof)
    }
    func decide(peerID: String, requestID: UUID, accept: Bool, identity: MeshIdentity, now: Date) throws -> ContactSignal {
        guard var record = records[peerID], !record.blocked,
              let request = record.incoming, request.body.id == requestID else { throw ContactError.noRequest }
        let response: ContactSignal
        if accept {
            let grant = try ContactGrant.approve(request, by: identity, now: now)
            record.grant = grant; record.outgoing = nil
            record.incomingRejections = 0; record.incomingRetryAt = nil
            record.outgoingRejections = 0; record.outgoingRetryAt = nil
            response = .accepted(grant)
        } else {
            if let until = record.incomingRetryAt, until <= now { record.incomingRejections = 0; record.incomingRetryAt = nil }
            record.incomingRejections = min(2, record.incomingRejections + 1)
            let rejectedAt = Int64(now.timeIntervalSince1970)
            record.incomingRetryAt = record.incomingRejections == 2 ? Date(timeIntervalSince1970: Double(rejectedAt) + MeshPacket.lifetime) : nil
            response = .rejected(ContactRejection(requestID: requestID, rejectedAt: rejectedAt,
                rejectionCount: record.incomingRejections,
                retryAt: record.incomingRetryAt.map { Int64($0.timeIntervalSince1970) }))
        }
        record.incoming = nil; record.lastResponse = response
        try commit(record)
        return response
    }
    func receive(_ signal: ContactSignal, from peer: PeerCard, identity: MeshIdentity, now: Date) throws -> ContactSignal? {
        var record = records[peer.id] ?? ContactRecord(peer: peer)
        record.peer = peer; record.supportsContacts = true
        switch signal {
        case .request(let proof):
            try proof.validate()
            guard proof.body.requester.id == peer.id, proof.body.recipient.id == identity.card.id,
                  proof.body.requester.agreementKey == peer.agreementKey,
                  proof.body.recipient.agreementKey == identity.card.agreementKey else { throw ContactError.invalidRequest }
            if proof.body.sequence == record.incomingSequence && proof.body.id == record.incomingRequestID {
                return record.blocked ? nil : record.lastResponse
            }
            guard proof.body.sequence > record.incomingSequence,
                  proof.deadline > now, Double(proof.body.createdAt) <= now.timeIntervalSince1970 + 5 else { return nil }
            // Receiving a reverse request lifts only the automatic outgoing pause.
            record.outgoingRejections = 0; record.outgoingRetryAt = nil
            if record.blocked { try commit(record); return nil }
            if let until = record.incomingRetryAt {
                if until > now { try commit(record); return nil }
                record.incomingRetryAt = nil; record.incomingRejections = 0
            }
            record.incomingSequence = proof.body.sequence; record.incomingRequestID = proof.body.id
            if record.grant != nil {
                let grant = try ContactGrant.approve(proof, by: identity, now: now)
                record.grant = grant; record.lastResponse = .accepted(grant)
                try commit(record); return record.lastResponse
            }
            record.incoming = proof; record.lastResponse = nil
            try commit(record)
        case .accepted(let grant):
            try grant.validate(local: identity.card, peer: peer)
            // Both signatures establish bilateral consent, including a crossed/late response.
            if record.grant == nil { record.grant = grant }
            record.outgoing = nil; record.incoming = nil
            record.outgoingRejections = 0; record.outgoingRetryAt = nil
            record.incomingRejections = 0; record.incomingRetryAt = nil
            try commit(record)
        case .rejected(let rejection):
            guard (1...2).contains(rejection.rejectionCount),
                  Double(rejection.rejectedAt) <= now.timeIntervalSince1970 + 5,
                  (rejection.rejectionCount == 1 && rejection.retryAt == nil) ||
                    (rejection.rejectionCount == 2 && rejection.retryAt.map { Double($0) - Double(rejection.rejectedAt) == MeshPacket.lifetime } == true)
                else { throw ContactError.invalidRequest }
            guard record.grant == nil, record.outgoing?.body.id == rejection.requestID else { return nil }
            record.outgoing = nil; record.outgoingRejections = rejection.rejectionCount
            record.outgoingRetryAt = rejection.retryAt.map { Date(timeIntervalSince1970: Double($0)) }
            try commit(record)
        }
        return nil
    }
    func authorize(_ grant: ContactGrant?, from peer: PeerCard, identity: MeshIdentity) throws {
        guard records[peer.id]?.blocked != true else { throw ContactError.blocked }
        guard let grant else { throw ContactError.consentRequired }
        try grant.validate(local: identity.card, peer: peer)
        if records[peer.id]?.grant == nil {
            var record = records[peer.id] ?? ContactRecord(peer: peer)
            record.grant = grant; record.incoming = nil; record.outgoing = nil
            record.outgoingRejections = 0; record.outgoingRetryAt = nil
            record.incomingRejections = 0; record.incomingRetryAt = nil
            try commit(record)
        }
    }
    func replaceKey(_ peer: PeerCard) throws {
        guard var record = records[peer.id] else { return }
        record.peer = peer; record.grant = nil; record.incoming = nil; record.outgoing = nil
        record.incomingRequestID = nil; record.lastResponse = nil
        try commit(record)
    }
    func block(_ peer: PeerCard, blocked: Bool) throws {
        var record = records[peer.id] ?? ContactRecord(peer: peer, supportsContacts: false)
        record.blocked = blocked
        if blocked { record.incoming = nil }
        try commit(record)
    }
}

extension MeshStore {
    /// Pre-consent versions could queue private text. Preserve the text but stop old unsigned-consent jobs.
    func invalidateUnconsentedPrivateTasks(authorized: Set<String>, forced: Set<String> = []) throws {
        let pending = try own.all(space: "outbox") + own.all(space: "awaiting")
        let tasks = try pending.map { try JSONDecoder().decode(TransferTask.self, from: $0.data) }.filter { task in
            guard let entry = try self.entry(task.packet.body.id) else { throw MeshStorageError.corrupt }
            return !entry.isPublic && entry.group == nil && (!authorized.contains(entry.recipient) || forced.contains(task.packet.storageKey))
        }
        guard !tasks.isEmpty else { return }
        try own.transaction {
            for task in tasks {
                let key = task.packet.storageKey
                try own.remove(space: "outbox", id: key); try own.remove(space: "awaiting", id: key)
                if var evidence = try own.decode(DeliveryEvidence.self, space: "delivery", id: key) {
                    if evidence.state != .read && evidence.state != .delivered { evidence.state = .failed }
                    try own.put(space: "delivery", id: key, value: evidence)
                }
                if var entry = try self.entry(task.packet.body.id), entry.state != .read && entry.state != .delivered {
                    entry.state = .failed
                    try own.put(space: "history", id: entry.id.uuidString, value: entry)
                }
            }
        }
    }
    func loadContacts() throws -> [ContactRecord] {
        try own.all(space: "contact").map {
            let value = try JSONDecoder().decode(ContactRecord.self, from: $0.data)
            guard value.peer.id == $0.id else { throw MeshStorageError.corrupt }
            return value
        }
    }
    func saveContact(_ value: ContactRecord) throws {
        try own.transaction { try own.put(space: "contact", id: value.peer.id, value: value) }
    }
}
