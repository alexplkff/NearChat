import Foundation
import CryptoKit

public enum GroupError: String, Error, Codable, LocalizedError {
    case unknownGroup, creatorOnly, notMember, closed, invalidName, invalidLimit, groupFull
    case invalidProof, missingEvents, conflictingEvent, invitationExpired, joinExpired
    case inviterLeft, returnPermissionRequired, alreadyMember, storageUnavailable, cancelled, unsupportedPeer
    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Вступление отменено"
        case .unsupportedPeer: return "Для групп собеседнику нужна обновлённая версия NearChat"
        case .unknownGroup: return "Группа не найдена"
        case .creatorOnly: return "Действие доступно только создателю группы"
        case .notMember: return "Вы не состоите в группе"
        case .closed: return "Группа завершена"
        case .invalidName: return "Название: от 1 до 64 символов, не более 256 байт UTF-8"
        case .invalidLimit: return "Лимит должен вмещать текущий состав и быть не больше 32"
        case .groupFull: return "Группа заполнена"
        case .invalidProof: return "Не удалось проверить событие группы"
        case .missingEvents: return "Сначала нужны предыдущие изменения состава"
        case .conflictingEvent: return "Получены противоречащие изменения группы"
        case .invitationExpired: return "Срок принятия приглашения истёк"
        case .joinExpired: return "Срок фиксации вступления истёк"
        case .inviterLeft: return "Пригласивший больше не состоит в группе"
        case .returnPermissionRequired: return "Для возвращения нужно разрешение создателя"
        case .alreadyMember: return "Участник уже состоит в группе"
        case .storageUnavailable: return "Не удалось сохранить изменение группы"
        }
    }
}

public struct GroupMember: Codable, Equatable, Sendable, Identifiable {
    public var id: String { peer.id }
    public let peer: PeerCard
    public let membershipID: UUID
    public let joinedRevision: Int64
}
public struct GroupRecipient: Codable, Equatable, Sendable {
    public let peerID: String
    public let membershipID: UUID
}
/// Captured once at send time. Future joins never expand an existing message's audience.
public struct GroupAudience: Codable, Equatable, Sendable {
    public let groupID: UUID
    public let revision: Int64
    public let senderMembershipID: UUID
    public let recipients: [GroupRecipient]
}
public struct ClosedGroup: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let creator: PeerCard
    public let memberLimit: Int
    public let members: [GroupMember]
    public let revision: Int64
    public let isClosed: Bool
    public func member(_ peerID: String) -> GroupMember? { members.first { $0.id == peerID } }
    public func canSend(as peerID: String) -> Bool { !isClosed && member(peerID) != nil }
    public func audience(for peerID: String) throws -> GroupAudience {
        guard !isClosed else { throw GroupError.closed }
        guard let sender = member(peerID) else { throw GroupError.notMember }
        return GroupAudience(groupID: id, revision: revision, senderMembershipID: sender.membershipID,
            recipients: members.filter { $0.id != peerID }.map { GroupRecipient(peerID: $0.id, membershipID: $0.membershipID) })
    }
    /// Membership admission policy used before adding incoming text to history.
    public func permitsMessage(from sender: PeerCard, audience: GroupAudience, to recipientID: String) -> Bool {
        guard (try? sender.validate()) != nil, !isClosed, audience.groupID == id, audience.revision <= revision,
              let author = member(sender.id), author.peer.agreementKey == sender.agreementKey,
              author.membershipID == audience.senderMembershipID, author.joinedRevision <= audience.revision,
              let recipient = member(recipientID), recipient.joinedRevision <= audience.revision,
              audience.recipients.contains(GroupRecipient(peerID: recipientID, membershipID: recipient.membershipID))
            else { return false }
        return true
    }
}

public struct GroupInvitationBody: Codable, Equatable, Sendable {
    public let id: UUID
    public let groupID: UUID
    public let name: String
    public let creator: PeerCard
    public let inviter: GroupMember
    public let invitee: PeerCard
    public let createdAt: Int64
    public let returnAuthorization: UUID?
}
public struct GroupInvitation: Codable, Equatable, Sendable {
    public let body: GroupInvitationBody
    public let signature: Data
    func validate() throws {
        try body.creator.validate(); try body.inviter.peer.validate(); try body.invitee.validate()
        try GroupProjection.validateName(body.name)
        guard body.inviter.id != body.invitee.id, body.inviter.joinedRevision >= 1 else { throw GroupError.invalidProof }
        try groupSignature(signature, body: body, signer: body.inviter.peer)
    }
}
public struct GroupJoinConsentBody: Codable, Equatable, Sendable {
    public let attemptID: UUID
    public let invitation: GroupInvitation
    public let acceptedAt: Int64
}
/// Construction represents an explicit Accept action; possession of an invitation is insufficient.
public struct GroupJoinConsent: Codable, Equatable, Sendable {
    public let body: GroupJoinConsentBody
    public let signature: Data
    public static func accept(_ invitation: GroupInvitation, by identity: MeshIdentity, now: Date = Date()) throws -> Self {
        try invitation.validate()
        guard invitation.body.invitee.id == identity.card.id,
              invitation.body.invitee.agreementKey == identity.card.agreementKey else { throw GroupError.invalidProof }
        let time = Int64(now.timeIntervalSince1970)
        guard Double(time) + 5 >= Double(invitation.body.createdAt), Double(time) < Double(invitation.body.createdAt) + MeshPacket.lifetime else {
            throw GroupError.invitationExpired
        }
        let body = GroupJoinConsentBody(attemptID: UUID(), invitation: invitation, acceptedAt: time)
        return Self(body: body, signature: try identity.signing.signature(for: MeshPacket.encoder.encode(body)))
    }
    func validate() throws {
        try body.invitation.validate()
        guard Double(body.acceptedAt) + 5 >= Double(body.invitation.body.createdAt),
              Double(body.acceptedAt) < Double(body.invitation.body.createdAt) + MeshPacket.lifetime else { throw GroupError.invalidProof }
        try groupSignature(signature, body: body, signer: body.invitation.body.invitee)
    }
}
public struct GroupDepartureBody: Codable, Equatable, Sendable {
    public let groupID: UUID
    public let member: GroupMember
    public let createdAt: Int64
}
/// Independent of the creator's revision: a participant can leave while the creator is offline.
public struct GroupDeparture: Codable, Equatable, Sendable {
    public let body: GroupDepartureBody
    public let signature: Data
    func validate() throws {
        try body.member.peer.validate()
        try groupSignature(signature, body: body, signer: body.member.peer)
    }
}
public enum GroupChange: Codable, Equatable, Sendable {
    case created(name: String, memberLimit: Int, creatorMembershipID: UUID)
    case limitChanged(Int)
    case joined(GroupJoinConsent)
    case left(GroupDeparture)
    case joinCancelled(GroupCancellation)
    case excluded(peerID: String, membershipID: UUID, restrictionID: UUID)
    case returnAllowed(peerID: String, restrictionID: UUID)
    case closed
}
public struct GroupEventBody: Codable, Equatable, Sendable {
    public let groupID: UUID
    public let revision: Int64
    public let previousDigest: Data?
    public let creator: PeerCard
    public let createdAt: Int64
    public let change: GroupChange
}
/// Canonical membership changes are serialized and signed by the original creator.
public struct GroupEvent: Codable, Equatable, Sendable {
    public let body: GroupEventBody
    public let signature: Data
    func validate() throws {
        try body.creator.validate()
        guard body.revision > 0 else { throw GroupError.invalidProof }
        try groupSignature(signature, body: body, signer: body.creator)
    }
    func digest() throws -> Data { Data(SHA256.hash(data: try MeshPacket.encoder.encode(self))) }
}
private func groupSignature<T: Encodable>(_ signature: Data, body: T, signer: PeerCard) throws {
    guard signature.count == 64,
          try Curve25519.Signing.PublicKey(rawRepresentation: signer.signingKey)
            .isValidSignature(signature, for: MeshPacket.encoder.encode(body)) else { throw GroupError.invalidProof }
}
private struct GroupRestriction: Equatable {
    let id: UUID
    var returnAllowed: Bool
}
struct GroupProjection {
    let id: UUID
    let creator: PeerCard
    var name: String
    var memberLimit: Int
    var members: [String: GroupMember]
    var revision: Int64
    var digest: Data
    var isClosed = false
    private var restrictions: [String: GroupRestriction] = [:]
    static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 64, name.utf8.count <= 256 else { throw GroupError.invalidName }
    }
    init(genesis: GroupEvent) throws {
        try genesis.validate()
        guard genesis.body.revision == 1, genesis.body.previousDigest == nil,
              case .created(let name, let limit, let period) = genesis.body.change else { throw GroupError.invalidProof }
        try Self.validateName(name)
        guard (1...32).contains(limit) else { throw GroupError.invalidLimit }
        id = genesis.body.groupID; creator = genesis.body.creator; self.name = name
        memberLimit = limit; revision = 1; digest = try genesis.digest()
        members = [creator.id: GroupMember(peer: creator, membershipID: period, joinedRevision: 1)]
    }
    func invitation(by identity: MeshIdentity, to invitee: PeerCard, now: Date) throws -> GroupInvitation {
        guard !isClosed else { throw GroupError.closed }
        guard let inviter = members[identity.card.id] else { throw GroupError.notMember }
        guard inviter.peer.agreementKey == identity.card.agreementKey else { throw GroupError.invalidProof }
        guard members[invitee.id] == nil else { throw GroupError.alreadyMember }
        try invitee.validate()
        if let restriction = restrictions[invitee.id], !restriction.returnAllowed { throw GroupError.returnPermissionRequired }
        let body = GroupInvitationBody(id: UUID(), groupID: id, name: name, creator: creator, inviter: inviter,
            invitee: invitee, createdAt: Int64(now.timeIntervalSince1970), returnAuthorization: restrictions[invitee.id]?.id)
        return GroupInvitation(body: body, signature: try identity.signing.signature(for: MeshPacket.encoder.encode(body)))
    }
    mutating func apply(_ event: GroupEvent) throws {
        try event.validate()
        guard event.body.groupID == id, event.body.creator.id == creator.id,
              event.body.creator.agreementKey == creator.agreementKey else { throw GroupError.invalidProof }
        guard !isClosed else { throw GroupError.closed }
        guard revision < Int64.max, event.body.revision == revision + 1 else { throw GroupError.missingEvents }
        guard event.body.previousDigest == digest else { throw GroupError.conflictingEvent }
        switch event.body.change {
        case .created: throw GroupError.invalidProof
        case .limitChanged(let limit):
            guard limit >= members.count, limit <= 32 else { throw GroupError.invalidLimit }
            memberLimit = limit
        case .joined(let consent):
            try consent.validate()
            let invitation = consent.body.invitation.body
            guard invitation.groupID == id, invitation.name == name, invitation.creator == creator,
                  members[invitation.inviter.id] == invitation.inviter else { throw GroupError.inviterLeft }
            guard Double(consent.body.acceptedAt) <= Double(event.body.createdAt) + 5,
                  Double(event.body.createdAt) < Double(consent.body.acceptedAt) + MeshPacket.lifetime else { throw GroupError.joinExpired }
            guard members[invitation.invitee.id] == nil else { throw GroupError.alreadyMember }
            if let restriction = restrictions[invitation.invitee.id] {
                guard restriction.returnAllowed, invitation.returnAuthorization == restriction.id else { throw GroupError.returnPermissionRequired }
            } else if invitation.returnAuthorization != nil { throw GroupError.invalidProof }
            guard members.count < memberLimit else { throw GroupError.groupFull }
            guard !members.values.contains(where: { $0.membershipID == consent.body.attemptID }) else { throw GroupError.invalidProof }
            members[invitation.invitee.id] = GroupMember(peer: invitation.invitee, membershipID: consent.body.attemptID, joinedRevision: event.body.revision)
        case .joinCancelled(let proof):
            try proof.validate()
            let consent = proof.body.consent
            guard consent.body.invitation.body.groupID == id else { throw GroupError.invalidProof }
            let peerID = consent.body.invitation.body.invitee.id
            if members[peerID]?.membershipID == consent.body.attemptID { members.removeValue(forKey: peerID) }
        case .left(let proof):
            try proof.validate()
            guard proof.body.groupID == id, proof.body.member.id != creator.id,
                  members[proof.body.member.id] == proof.body.member else { throw GroupError.invalidProof }
            members.removeValue(forKey: proof.body.member.id)
        case .excluded(let peerID, let period, let restriction):
            guard peerID != creator.id, members[peerID]?.membershipID == period else { throw GroupError.invalidProof }
            members.removeValue(forKey: peerID)
            restrictions[peerID] = GroupRestriction(id: restriction, returnAllowed: false)
        case .returnAllowed(let peerID, let restriction):
            guard restrictions[peerID]?.id == restriction else { throw GroupError.invalidProof }
            restrictions[peerID]?.returnAllowed = true
        case .closed: isClosed = true
        }
        revision = event.body.revision; digest = try event.digest()
    }
    func returnRequiresPermission(_ peerID: String) -> Bool { restrictions[peerID]?.returnAllowed == false }
    func restrictionID(_ peerID: String) -> UUID? { restrictions[peerID]?.id }
}

private struct GroupHead: Codable, Equatable {
    let groupID: UUID
    let revision: Int64
    let digest: Data
}
struct GroupJoinDecision: Codable, Equatable {
    let consentDigest: Data
    let revision: Int64?
    let error: GroupError?
}
struct GroupRecord {
    var events: [GroupEvent]
    var departures: [UUID: GroupDeparture] = [:]
    var decisions: [UUID: GroupJoinDecision] = [:]
    var cancellations: [UUID: GroupCancellation] = [:]
    var projection: GroupProjection
    init(genesis: GroupEvent) throws { projection = try GroupProjection(genesis: genesis); events = [genesis] }
    var view: ClosedGroup {
        let members = projection.members.values.filter { departures[$0.membershipID] == nil }.sorted { $0.id < $1.id }
        return ClosedGroup(id: projection.id, name: projection.name, creator: projection.creator,
            memberLimit: projection.memberLimit, members: members, revision: projection.revision, isClosed: projection.isClosed)
    }
    mutating func append(_ event: GroupEvent) throws {
        if case .joined(let consent) = event.body.change, decisions[consent.body.attemptID] != nil {
            throw GroupError.invalidProof
        }
        try projection.apply(event); events.append(event)
        if case .joined(let consent) = event.body.change {
            decisions[consent.body.attemptID] = GroupJoinDecision(consentDigest: try Self.consentDigest(consent), revision: event.body.revision, error: nil)
        }
    }
    func validateDeparture(_ proof: GroupDeparture) throws {
        try proof.validate()
        guard proof.body.groupID == projection.id, proof.body.member.id != projection.creator.id else { throw GroupError.invalidProof }
        // Old, authentic departures may arrive after rejoining. They cannot remove the new period.
        guard events.contains(where: { event in
            if case .joined(let consent) = event.body.change {
                return consent.body.attemptID == proof.body.member.membershipID &&
                    consent.body.invitation.body.invitee == proof.body.member.peer && event.body.revision == proof.body.member.joinedRevision
            }
            return false
        }) else { throw GroupError.invalidProof }
    }
    static func consentDigest(_ consent: GroupJoinConsent) throws -> Data { Data(SHA256.hash(data: try MeshPacket.encoder.encode(consent))) }
}

/// Used on the same serial executor as MeshEngine. No network or UI side effects.
final class GroupBook {
    private(set) var records: [UUID: GroupRecord] = [:]
    private let persist: (GroupRecord?, GroupRecord) throws -> Void
    init(persist: @escaping (GroupRecord?, GroupRecord) throws -> Void) { self.persist = persist }
    func load(_ values: [UUID: GroupRecord]) { records = values }
    var groups: [ClosedGroup] { records.values.map(\.view).sorted { $0.id.uuidString < $1.id.uuidString } }
    private func record(_ id: UUID) throws -> GroupRecord {
        guard let value = records[id] else { throw GroupError.unknownGroup }; return value
    }
    private func commit(_ value: GroupRecord) throws {
        try persist(records[value.projection.id], value)
        records[value.projection.id] = value
    }
    private func signed(_ change: GroupChange, record: GroupRecord?, id: UUID, identity: MeshIdentity, now: Date) throws -> GroupEvent {
        if let record {
            guard record.projection.creator.id == identity.card.id,
                  record.projection.creator.agreementKey == identity.card.agreementKey else { throw GroupError.creatorOnly }
            guard record.projection.revision < Int64.max else { throw GroupError.invalidProof }
        }
        let body = GroupEventBody(groupID: id, revision: (record?.projection.revision ?? 0) + 1,
            previousDigest: record?.projection.digest, creator: record?.projection.creator ?? identity.card,
            createdAt: Int64(now.timeIntervalSince1970), change: change)
        return GroupEvent(body: body, signature: try identity.signing.signature(for: MeshPacket.encoder.encode(body)))
    }
    func create(name: String, limit: Int, identity: MeshIdentity, now: Date) throws -> GroupEvent {
        let id = UUID()
        let event = try signed(.created(name: name, memberLimit: limit, creatorMembershipID: UUID()), record: nil, id: id, identity: identity, now: now)
        try commit(GroupRecord(genesis: event)); return event
    }
    @discardableResult func apply(_ event: GroupEvent) throws -> Bool {
        try event.validate()
        if var value = records[event.body.groupID] {
            if event.body.revision <= value.projection.revision {
                guard value.events.contains(event) else { throw GroupError.conflictingEvent }
                return false
            }
            try value.append(event); try commit(value)
        } else { try commit(GroupRecord(genesis: event)) }
        return true
    }
    private func change(_ change: GroupChange, id: UUID, identity: MeshIdentity, now: Date) throws -> GroupEvent {
        var value = try record(id)
        let event = try signed(change, record: value, id: id, identity: identity, now: now)
        try value.append(event); try commit(value); return event
    }
    func setLimit(_ limit: Int, id: UUID, identity: MeshIdentity, now: Date) throws -> GroupEvent {
        try change(.limitChanged(limit), id: id, identity: identity, now: now)
    }
    func invite(_ peer: PeerCard, id: UUID, identity: MeshIdentity, now: Date) throws -> GroupInvitation {
        let value = try record(id)
        guard value.view.canSend(as: identity.card.id) else { throw GroupError.notMember }
        return try value.projection.invitation(by: identity, to: peer, now: now)
    }
    func finalize(_ consent: GroupJoinConsent, identity: MeshIdentity, now: Date) throws -> GroupEvent {
        try consent.validate()
        let id = consent.body.invitation.body.groupID
        var value = try record(id)
        guard value.projection.creator.id == identity.card.id else { throw GroupError.creatorOnly }
        try value.validateInvitationAuthority(consent.body.invitation)
        let digest = try GroupRecord.consentDigest(consent)
        if value.cancellations[consent.body.attemptID] != nil { throw GroupError.cancelled }
        if let previous = value.decisions[consent.body.attemptID] {
            guard previous.consentDigest == digest else { throw GroupError.invalidProof }
            if let error = previous.error { throw error }
            guard let event = value.events.first(where: { $0.body.revision == previous.revision }) else { throw GroupError.invalidProof }
            return event
        }
        let event = try signed(.joined(consent), record: value, id: id, identity: identity, now: now)
        do { try value.append(event) }
        catch let error as GroupError {
            // Terminal refusal must survive retries/restart; a full attempt never becomes a wait list.
            value.decisions[consent.body.attemptID] = GroupJoinDecision(consentDigest: digest, revision: nil, error: error)
            try commit(value); throw error
        }
        try commit(value); return event
    }
    func cancel(_ proof: GroupCancellation, identity: MeshIdentity, now: Date) throws {
        try proof.validate()
        let consent = proof.body.consent, id = consent.body.invitation.body.groupID
        var value = try record(id)
        guard value.projection.creator.id == identity.card.id,
              consent.body.invitation.body.creator == value.projection.creator else { throw GroupError.creatorOnly }
        try value.validateInvitationAuthority(consent.body.invitation)
        if value.cancellations[consent.body.attemptID] != nil { return }
        value.cancellations[consent.body.attemptID] = proof
        if !value.projection.isClosed,
           value.projection.members[consent.body.invitation.body.invitee.id]?.membershipID == consent.body.attemptID {
            let event = try signed(.joinCancelled(proof), record: value, id: id, identity: identity, now: now)
            try value.append(event)
        }
        try commit(value)
    }
    func exclude(_ peerID: String, id: UUID, identity: MeshIdentity, now: Date) throws -> GroupEvent {
        let value = try record(id)
        guard let member = value.projection.members[peerID] else { throw GroupError.notMember }
        return try change(.excluded(peerID: peerID, membershipID: member.membershipID, restrictionID: UUID()), id: id, identity: identity, now: now)
    }
    func allowReturn(_ peerID: String, id: UUID, identity: MeshIdentity, now: Date) throws -> GroupEvent {
        let value = try record(id)
        guard let restriction = value.projection.restrictionID(peerID) else { throw GroupError.returnPermissionRequired }
        return try change(.returnAllowed(peerID: peerID, restrictionID: restriction), id: id, identity: identity, now: now)
    }
    func leave(_ id: UUID, identity: MeshIdentity, now: Date) throws -> GroupDeparture? {
        let value = try record(id)
        guard !value.projection.isClosed else { throw GroupError.closed }
        if value.projection.creator.id == identity.card.id {
            _ = try change(.closed, id: id, identity: identity, now: now); return nil
        }
        guard let member = value.projection.members[identity.card.id], member.peer.agreementKey == identity.card.agreementKey else { throw GroupError.notMember }
        if let existing = value.departures[member.membershipID] { return existing }
        let body = GroupDepartureBody(groupID: id, member: member, createdAt: Int64(now.timeIntervalSince1970))
        let proof = GroupDeparture(body: body, signature: try identity.signing.signature(for: MeshPacket.encoder.encode(body)))
        _ = try depart(proof, identity: identity, now: now); return proof
    }
    @discardableResult func depart(_ proof: GroupDeparture, identity: MeshIdentity, now: Date) throws -> GroupEvent? {
        var value = try record(proof.body.groupID)
        try value.validateDeparture(proof)
        let period = proof.body.member.membershipID
        if value.departures[period] != nil { return nil }
        value.departures[period] = proof
        var event: GroupEvent?
        if value.projection.creator.id == identity.card.id, !value.projection.isClosed,
           value.projection.members[proof.body.member.id]?.membershipID == period {
            let next = try signed(.left(proof), record: value, id: value.projection.id, identity: identity, now: now)
            try value.append(next); event = next
        }
        try commit(value); return event
    }
}

extension MeshStore {
    func saveGroup(previous: GroupRecord?, value: GroupRecord) throws {
        let prefix = value.projection.id.uuidString + ":"
        try own.transaction {
            if previous?.projection.revision != value.projection.revision {
                try own.put(space: "group-head", id: value.projection.id.uuidString,
                    value: GroupHead(groupID: value.projection.id, revision: value.projection.revision, digest: value.projection.digest))
            }
            for event in value.events.dropFirst(previous?.events.count ?? 0) {
                try own.put(space: "group-event", id: prefix + String(event.body.revision), value: event)
            }
            for (period, proof) in value.departures where previous?.departures[period] == nil {
                try own.put(space: "group-departure", id: prefix + period.uuidString, value: proof)
            }
            for (attempt, proof) in value.cancellations where previous?.cancellations[attempt] == nil {
                try own.put(space: "group-cancel", id: prefix + attempt.uuidString, value: proof)
            }
            for (attempt, decision) in value.decisions where previous?.decisions[attempt] != decision {
                try own.put(space: "group-decision", id: prefix + attempt.uuidString, value: decision)
            }
        }
    }
    func loadGroups() throws -> [UUID: GroupRecord] {
        var records: [UUID: GroupRecord] = [:]
        let events = try own.all(space: "group-event").map { row -> GroupEvent in
            let event = try JSONDecoder().decode(GroupEvent.self, from: row.data)
            guard row.id == event.body.groupID.uuidString + ":" + String(event.body.revision) else { throw MeshStorageError.corrupt }
            return event
        }.sorted { $0.body.revision < $1.body.revision }
        for event in events {
            let id = event.body.groupID
            if var value = records[id] { try value.append(event); records[id] = value }
            else { records[id] = try GroupRecord(genesis: event) }
        }
        let heads = try own.all(space: "group-head")
        guard heads.count == records.count else { throw MeshStorageError.corrupt }
        for row in heads {
            let head = try JSONDecoder().decode(GroupHead.self, from: row.data)
            guard row.id == head.groupID.uuidString, let value = records[head.groupID],
                  value.projection.revision == head.revision, value.projection.digest == head.digest else { throw MeshStorageError.corrupt }
        }
        for row in try own.all(space: "group-departure") {
            let proof = try JSONDecoder().decode(GroupDeparture.self, from: row.data)
            let id = proof.body.groupID, period = proof.body.member.membershipID
            guard var value = records[id], row.id == id.uuidString + ":" + period.uuidString else { throw MeshStorageError.corrupt }
            try value.validateDeparture(proof); value.departures[period] = proof; records[id] = value
        }
        for row in try own.all(space: "group-cancel") {
            let proof = try JSONDecoder().decode(GroupCancellation.self, from: row.data)
            try proof.validate()
            let consent = proof.body.consent, id = consent.body.invitation.body.groupID
            guard var value = records[id], consent.body.invitation.body.creator == value.projection.creator,
                  row.id == id.uuidString + ":" + consent.body.attemptID.uuidString else { throw MeshStorageError.corrupt }
            value.cancellations[consent.body.attemptID] = proof; records[id] = value
        }
        for row in try own.all(space: "group-decision") {
            let parts = row.id.split(separator: ":")
            guard parts.count == 2, let id = UUID(uuidString: String(parts[0])), let attempt = UUID(uuidString: String(parts[1])),
                  var value = records[id] else { throw MeshStorageError.corrupt }
            let decision = try JSONDecoder().decode(GroupJoinDecision.self, from: row.data)
            guard decision.consentDigest.count == 32, (decision.revision == nil) != (decision.error == nil) else { throw MeshStorageError.corrupt }
            if let revision = decision.revision {
                guard value.decisions[attempt] == decision, value.events.contains(where: { $0.body.revision == revision }) else { throw MeshStorageError.corrupt }
            } else { guard value.decisions[attempt] == nil else { throw MeshStorageError.corrupt } }
            value.decisions[attempt] = decision; records[id] = value
        }
        return records
    }
}
