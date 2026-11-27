import Foundation
import CryptoKit

public struct GroupCancellationBody: Codable, Equatable, Sendable {
    public let consent: GroupJoinConsent
    public let cancelledAt: Int64
}
public struct GroupCancellation: Codable, Equatable, Sendable {
    public let body: GroupCancellationBody
    public let signature: Data
    func validate() throws {
        try body.consent.validate()
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: body.consent.body.invitation.body.invitee.signingKey)
        guard signature.count == 64, key.isValidSignature(signature, for: try MeshPacket.encoder.encode(body)) else { throw GroupError.invalidProof }
    }
    static func make(_ consent: GroupJoinConsent, identity: MeshIdentity, now: Date) throws -> Self {
        guard consent.body.invitation.body.invitee.id == identity.card.id else { throw GroupError.invalidProof }
        let body = GroupCancellationBody(consent: consent, cancelledAt: Int64(now.timeIntervalSince1970))
        return Self(body: body, signature: try identity.signing.signature(for: MeshPacket.encoder.encode(body)))
    }
}
public enum GroupInvitationPhase: String, Codable, Sendable {
    case sent, verifying, offered, waiting, unconfirmed, joined, declined, expired, refused, cancelPending, cancelled, ended
    public var title: String {
        switch self {
        case .sent: return "Приглашение отправлено"
        case .verifying: return "Проверка приглашения"
        case .offered: return "Приглашение в группу"
        case .waiting: return "Ожидание подтверждения вступления"
        case .unconfirmed: return "Вступление не подтверждено"
        case .joined: return "В группе"
        case .ended: return "Участие прекращено · история сохранена"
        case .declined: return "Приглашение отклонено"
        case .expired: return "Приглашение устарело"
        case .refused: return "Вступление отклонено"
        case .cancelPending: return "Отмена ожидает подтверждения"
        case .cancelled: return "Вступление отменено"
        }
    }
}
public struct GroupInvitationState: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { invitation.body.id }
    public let invitation: GroupInvitation
    public let outgoing: Bool
    public internal(set) var phase: GroupInvitationPhase
    public internal(set) var error: GroupError?
    var consent: GroupJoinConsent?
    var cancellation: GroupCancellation?
    public var status: String { error?.localizedDescription ?? phase.title }
}
enum GroupIntent: Codable, Equatable { case join(UUID) }
struct GroupSync: Codable {
    let groupID: UUID
    let after: Int64
    let invitation: GroupInvitation?
    let consent: GroupJoinConsent?
}
struct GroupJoinReply: Codable {
    let groupID: UUID
    let attemptID: UUID
    let revision: Int64?
    let error: GroupError?
}
enum GroupSignal: Codable {
    case invitation(GroupInvitation)
    case declined(invitationID: UUID)
    case join(GroupJoinConsent)
    case query(GroupJoinConsent)
    case joinReply(GroupJoinReply)
    case cancel(GroupCancellation)
    case cancelled(groupID: UUID, attemptID: UUID)
    case sync(GroupSync)
    case event(GroupEvent, head: Int64)
    case hint(groupID: UUID, revision: Int64)
    case departure(GroupDeparture)
}

extension GroupRecord {
    func validateInvitationAuthority(_ invitation: GroupInvitation) throws {
        try invitation.validate()
        let body = invitation.body
        guard body.groupID == projection.id, body.creator == projection.creator, body.name == projection.name,
              events.contains(where: { event in
                  if case .created(_, _, let period) = event.body.change { return body.inviter.id == projection.creator.id && body.inviter.membershipID == period && body.inviter.peer == projection.creator && body.inviter.joinedRevision == 1 }
                  if case .joined(let proof) = event.body.change { return proof.body.attemptID == body.inviter.membershipID && proof.body.invitation.body.invitee == body.inviter.peer && event.body.revision == body.inviter.joinedRevision }
                  return false
              }) else { throw GroupError.invalidProof }
    }
    func syncCutoff(for peer: PeerCard, invitation: GroupInvitation?, consent: GroupJoinConsent?, now: Date) throws -> Int64 {
        if let member = view.member(peer.id), member.peer.agreementKey == peer.agreementKey { return projection.revision }
        if let invitation {
            try invitation.validate()
            let body = invitation.body
            guard body.groupID == projection.id, body.creator == projection.creator,
                  body.invitee.id == peer.id, body.invitee.agreementKey == peer.agreementKey else { throw GroupError.invalidProof }
            let inviterKnown = events.contains { event in
                if case .created(_, _, let period) = event.body.change { return body.inviter.id == projection.creator.id && body.inviter.membershipID == period && body.inviter.joinedRevision == 1 }
                if case .joined(let proof) = event.body.change { return proof.body.attemptID == body.inviter.membershipID && proof.body.invitation.body.invitee == body.inviter.peer && event.body.revision == body.inviter.joinedRevision }
                return false
            }
            guard inviterKnown else { throw GroupError.invalidProof }
            if let consent {
                try consent.validate()
                guard consent.body.invitation == invitation else { throw GroupError.invalidProof }
                // A persisted attempt may reconcile its already existing result after either window.
                if let decision = decisions[consent.body.attemptID] {
                    guard decision.error == nil else { throw GroupError.notMember }
                    for event in events {
                        switch event.body.change {
                        case .left(let proof) where proof.body.member.membershipID == consent.body.attemptID: return event.body.revision
                        case .excluded(_, let period, _) where period == consent.body.attemptID: return event.body.revision
                        case .joinCancelled(let proof) where proof.body.consent.body.attemptID == consent.body.attemptID: return event.body.revision
                        case .closed: return event.body.revision
                        default: break
                        }
                    }
                    return projection.revision
                }
                guard cancellations[consent.body.attemptID] == nil else { throw GroupError.cancelled }
                guard now.timeIntervalSince1970 < Double(consent.body.acceptedAt) + MeshPacket.lifetime else { throw GroupError.joinExpired }
            } else {
                guard now.timeIntervalSince1970 < Double(body.createdAt) + MeshPacket.lifetime else { throw GroupError.invitationExpired }
            }
            guard projection.members[body.inviter.id] == body.inviter else { throw GroupError.inviterLeft }
            if let restriction = projection.restrictionID(peer.id) {
                guard !projection.returnRequiresPermission(peer.id), body.returnAuthorization == restriction else { throw GroupError.returnPermissionRequired }
            }
            return projection.revision
        }
        // Former members may fetch through their own removal, not later private roster changes.
        var period: UUID?
        for event in events {
            if case .joined(let proof) = event.body.change, proof.body.invitation.body.invitee.id == peer.id,
               proof.body.invitation.body.invitee.agreementKey == peer.agreementKey { period = proof.body.attemptID }
            if let current = period {
                switch event.body.change {
                case .excluded(let id, let epoch, _) where id == peer.id && epoch == current: return event.body.revision
                case .left(let proof) where proof.body.member.membershipID == current: return event.body.revision
                case .joinCancelled(let proof) where proof.body.consent.body.attemptID == current: return event.body.revision
                case .closed: return event.body.revision
                default: break
                }
            }
        }
        throw GroupError.notMember
    }
}

extension MeshStore {
    func rememberGroupCapability(_ peer: PeerCard) throws {
        guard try own.count(space: "group-capable") < 256 else { return }
        try own.transaction { try own.put(space: "group-capable", id: peer.id, value: peer) }
    }
    func groupCapabilities() throws -> [PeerCard] {
        try own.all(space: "group-capable").map { row in
            let peer = try JSONDecoder().decode(PeerCard.self, from: row.data); try peer.validate()
            guard peer.id == row.id else { throw MeshStorageError.corrupt }; return peer
        }
    }
    func saveGroupFlow(_ flow: GroupInvitationState) throws {
        try own.transaction { try own.put(space: "group-flow", id: flow.id.uuidString, value: flow) }
    }
    func loadGroupFlows(identity: MeshIdentity) throws -> [UUID: GroupInvitationState] {
        var result: [UUID: GroupInvitationState] = [:]
        for row in try own.all(space: "group-flow") {
            let flow = try JSONDecoder().decode(GroupInvitationState.self, from: row.data)
            try flow.invitation.validate()
            guard row.id == flow.id.uuidString,
                  (flow.outgoing ? flow.invitation.body.inviter.id : flow.invitation.body.invitee.id) == identity.card.id else { throw MeshStorageError.corrupt }
            if let consent = flow.consent { try consent.validate(); guard consent.body.invitation == flow.invitation else { throw MeshStorageError.corrupt } }
            if let cancellation = flow.cancellation { try cancellation.validate(); guard cancellation.body.consent == flow.consent else { throw MeshStorageError.corrupt } }
            result[flow.id] = flow
        }
        return result
    }
}

extension MeshEngine {
    public func groupReturnCandidates(_ id: UUID) -> [PeerCard] {
        guard let record = groupBook.records[id] else { return [] }
        return knownParticipants.filter { record.projection.returnRequiresPermission($0.id) }
    }
    public var groupInvitations: [GroupInvitationState] { groupFlows.values.sorted { $0.invitation.body.createdAt > $1.invitation.body.createdAt } }
    public var nearbyClosedGroupIDs: [UUID] { discoveredGroups.filter { $0.value > clock() }.keys.sorted { $0.uuidString < $1.uuidString } }
    func saveGroupFlow(_ flow: GroupInvitationState) throws {
        guard let store else { throw GroupError.storageUnavailable }
        try store.saveGroupFlow(flow); groupFlows[flow.id] = flow
    }
    func effectiveGroup(_ group: ClosedGroup) -> ClosedGroup {
        let cancelled = Set(groupFlows.values.compactMap { $0.cancellation?.body.consent.body.attemptID })
        return ClosedGroup(id: group.id, name: group.name, creator: group.creator, memberLimit: group.memberLimit,
            members: group.members.filter { !cancelled.contains($0.membershipID) }, revision: group.revision, isClosed: group.isClosed)
    }
    func sendGroupSignal(_ signal: GroupSignal, to peer: PeerCard, deadline: Date? = nil) throws {
        let packet = try endpointPacket(kind: .group, recipient: peer,
            cleartext: JSONEncoder().encode(signal), now: clock(), expiresAt: deadline)
        guard try packet.encoded().count <= MeshPacket.maxWireBytes else { throw MeshError.invalidPacket }
        let intent: GroupIntent?
        switch signal { case .join(let proof), .query(let proof): intent = .join(proof.body.attemptID); default: intent = nil }
        queueControl(packet, groupIntent: intent)
    }
    public func inviteToGroup(_ id: UUID, peerID: String) throws {
        guard let peer = knownParticipants.first(where: { $0.id == peerID }) else { throw MeshError.unavailablePeer }
        guard peers[peerID]?.supportsGroups == true || groupCapablePeers.contains(peerID) || groupBook.records[id]?.projection.members[peerID] != nil else { throw GroupError.unsupportedPeer }
        let invitation = try makeGroupInvitation(to: peer, groupID: id)
        let flow = GroupInvitationState(invitation: invitation, outgoing: true, phase: .sent)
        try saveGroupFlow(flow)
        try sendGroupSignal(.invitation(invitation), to: peer, deadline: Date(timeIntervalSince1970: Double(invitation.body.createdAt) + MeshPacket.lifetime))
        changed()
    }
    public func acceptGroupInvitation(_ invitationID: UUID) throws {
        guard var flow = groupFlows[invitationID], !flow.outgoing, flow.phase == .offered else { throw GroupError.invalidProof }
        let consent = try GroupJoinConsent.accept(flow.invitation, by: identity, now: clock())
        flow.consent = consent; flow.phase = .waiting
        try saveGroupFlow(flow)
        try sendGroupSignal(.join(consent), to: flow.invitation.body.creator,
            deadline: Date(timeIntervalSince1970: Double(consent.body.acceptedAt) + MeshPacket.lifetime))
        changed()
    }
    public func declineGroupInvitation(_ invitationID: UUID) throws {
        guard var flow = groupFlows[invitationID], !flow.outgoing,
              flow.phase == .offered || flow.phase == .verifying else { throw GroupError.invalidProof }
        flow.phase = .declined; try saveGroupFlow(flow)
        try sendGroupSignal(.declined(invitationID: flow.id), to: flow.invitation.body.inviter.peer)
        changed()
    }
    public func cancelGroupJoin(_ invitationID: UUID) throws {
        guard var flow = groupFlows[invitationID], !flow.outgoing, let consent = flow.consent,
              [.waiting, .unconfirmed, .cancelPending].contains(flow.phase) else { throw GroupError.invalidProof }
        let proof = try flow.cancellation ?? GroupCancellation.make(consent, identity: identity, now: clock())
        flow.cancellation = proof; flow.phase = .cancelPending; flow.error = nil
        try saveGroupFlow(flow) // Before transmission/late confirmation: hides this period durably.
        try? store?.dropGroupJoinIntent(consent.body.attemptID)
        try sendGroupSignal(.cancel(proof), to: flow.invitation.body.creator)
        changed()
    }
    func notifyGroup(_ id: UUID, including extra: [PeerCard] = []) {
        guard let value = groupBook.records[id] else { return }
        var recipients = Dictionary(uniqueKeysWithValues: value.projection.members.values.map { ($0.id, $0.peer) })
        for peer in extra { recipients[peer.id] = peer }
        for peer in recipients.values where peer.id != identity.card.id {
            try? sendGroupSignal(.hint(groupID: id, revision: value.projection.revision), to: peer)
        }
    }
    func requestGroupSync(_ id: UUID, from peer: PeerCard, flow: GroupInvitationState? = nil) throws {
        let request = GroupSync(groupID: id, after: groupBook.records[id]?.projection.revision ?? 0,
            invitation: flow?.invitation, consent: flow?.consent)
        try sendGroupSignal(.sync(request), to: peer)
    }
    func consumeGroup(_ signal: GroupSignal, from peer: PeerCard) throws {
        switch signal {
        case .invitation(let invitation):
            try invitation.validate()
            guard invitation.body.invitee.id == identity.card.id,
                  invitation.body.invitee.agreementKey == identity.card.agreementKey,
                  invitation.body.inviter.id == peer.id,
                  invitation.body.inviter.peer.agreementKey == peer.agreementKey,
                  clock().timeIntervalSince1970 < Double(invitation.body.createdAt) + MeshPacket.lifetime,
                  Double(invitation.body.createdAt) <= clock().timeIntervalSince1970 + 5 else { throw GroupError.invalidProof }
            if groupFlows[invitation.body.id] == nil {
                try saveGroupFlow(GroupInvitationState(invitation: invitation, outgoing: false, phase: .verifying))
            } else { guard groupFlows[invitation.body.id]?.invitation == invitation else { throw GroupError.invalidProof } }
            if let value = groupBook.records[invitation.body.groupID], value.projection.creator != invitation.body.creator { throw GroupError.invalidProof }
            try refreshGroupFlows(invitation.body.groupID)
            try requestGroupSync(invitation.body.groupID, from: peer, flow: groupFlows[invitation.body.id])
        case .declined(let id):
            guard var flow = groupFlows[id], flow.outgoing, flow.invitation.body.invitee.id == peer.id else { throw GroupError.invalidProof }
            if flow.phase == .sent { flow.phase = .declined; try saveGroupFlow(flow) }
        case .join(let consent), .query(let consent):
            guard consent.body.invitation.body.invitee.id == peer.id,
                  consent.body.invitation.body.invitee.agreementKey == peer.agreementKey else { throw GroupError.invalidProof }
            let id = consent.body.invitation.body.groupID
            do {
                let event = try finalizeGroupJoin(consent)
                try sendGroupSignal(.joinReply(GroupJoinReply(groupID: id, attemptID: consent.body.attemptID, revision: event.body.revision, error: nil)), to: peer)
            } catch let error as GroupError {
                guard let record = groupBook.records[id], record.projection.creator.id == identity.card.id,
                      record.decisions[consent.body.attemptID]?.error == error || record.cancellations[consent.body.attemptID] != nil else { throw error }
                try sendGroupSignal(.joinReply(GroupJoinReply(groupID: id, attemptID: consent.body.attemptID, revision: nil, error: error)), to: peer)
            }
        case .joinReply(let reply):
            guard var flow = groupFlows.values.first(where: { $0.consent?.body.attemptID == reply.attemptID && !$0.outgoing }),
                  flow.invitation.body.groupID == reply.groupID, flow.invitation.body.creator.id == peer.id,
                  flow.invitation.body.creator.agreementKey == peer.agreementKey else { throw GroupError.invalidProof }
            if flow.cancellation != nil { break }
            if let error = reply.error { flow.phase = .refused; flow.error = error; try saveGroupFlow(flow) }
            else { try requestGroupSync(reply.groupID, from: peer, flow: flow) }
        case .cancel(let proof):
            try proof.validate()
            let consent = proof.body.consent, id = consent.body.invitation.body.groupID
            guard consent.body.invitation.body.invitee.id == peer.id,
                  consent.body.invitation.body.invitee.agreementKey == peer.agreementKey else { throw GroupError.invalidProof }
            try groupBook.cancel(proof, identity: identity, now: clock())
            notifyGroup(id, including: [peer])
            try sendGroupSignal(.cancelled(groupID: id, attemptID: consent.body.attemptID), to: peer)
        case .cancelled(let id, let attempt):
            guard var flow = groupFlows.values.first(where: { $0.cancellation?.body.consent.body.attemptID == attempt }),
                  flow.invitation.body.groupID == id, flow.invitation.body.creator.id == peer.id,
                  flow.invitation.body.creator.agreementKey == peer.agreementKey else { throw GroupError.invalidProof }
            flow.phase = .cancelled; try saveGroupFlow(flow)
            try? requestGroupSync(id, from: peer, flow: flow)
        case .sync(let request):
            guard let value = groupBook.records[request.groupID], request.after >= 0 else { throw GroupError.unknownGroup }
            let cutoff = try value.syncCutoff(for: peer, invitation: request.invitation, consent: request.consent, now: clock())
            if let next = value.events.first(where: { $0.body.revision > request.after && $0.body.revision <= cutoff }) {
                try sendGroupSignal(.event(next, head: cutoff), to: peer)
            } else {
                for departure in value.departures.values where value.projection.members[departure.body.member.id]?.membershipID == departure.body.member.membershipID {
                    try sendGroupSignal(.departure(departure), to: peer)
                }
            }
        case .event(let event, let head):
            let id = event.body.groupID
            let flow = groupFlows.values.first { !$0.outgoing && $0.invitation.body.groupID == id &&
                ($0.invitation.body.creator.id == peer.id || $0.invitation.body.inviter.id == peer.id) }
            if let record = groupBook.records[id] {
                guard record.projection.creator.id == event.body.creator.id,
                      record.projection.members[peer.id] != nil || flow != nil || record.events.contains(where: {
                          if case .joined(let proof) = $0.body.change { return proof.body.invitation.body.invitee.id == peer.id }; return false
                      }) else { throw GroupError.invalidProof }
            } else {
                guard let flow, flow.invitation.body.creator == event.body.creator else { throw GroupError.invalidProof }
            }
            do { _ = try groupBook.apply(event) }
            catch GroupError.missingEvents { try requestGroupSync(id, from: peer, flow: flow); throw GroupError.missingEvents }
            try refreshGroupFlows(id)
            if (groupBook.records[id]?.projection.revision ?? 0) < head { try requestGroupSync(id, from: peer, flow: flow) }
        case .hint(let id, let revision):
            let flow = groupFlows.values.first { !$0.outgoing && $0.invitation.body.groupID == id }
            guard let record = groupBook.records[id] else {
                if let flow { try requestGroupSync(id, from: peer, flow: flow) }; return
            }
            guard record.projection.members[peer.id] != nil || peer.id == record.projection.creator.id else { throw GroupError.notMember }
            if revision > record.projection.revision { try requestGroupSync(id, from: peer, flow: flow) }
        case .departure(let proof):
            // Proof authenticates the leaver even when forwarded by a different member.
            let event = try groupBook.depart(proof, identity: identity, now: clock())
            if event != nil { notifyGroup(proof.body.groupID) }
        }
    }
    func refreshGroupFlows(_ id: UUID) throws {
        guard let record = groupBook.records[id] else { return }
        for var flow in Array(groupFlows.values) where !flow.outgoing && flow.invitation.body.groupID == id {
            guard record.projection.creator == flow.invitation.body.creator else { throw GroupError.invalidProof }
            if flow.phase == .verifying, record.projection.members[flow.invitation.body.inviter.id] == flow.invitation.body.inviter {
                flow.phase = .offered; try saveGroupFlow(flow)
            }
            if let consent = flow.consent, flow.phase == .joined,
               record.projection.isClosed || record.view.member(identity.card.id)?.membershipID != consent.body.attemptID {
                flow.phase = .ended; try saveGroupFlow(flow)
            }
            if let consent = flow.consent, flow.cancellation == nil,
               record.view.member(identity.card.id)?.membershipID == consent.body.attemptID,
               [.waiting, .unconfirmed].contains(flow.phase) { flow.phase = .joined; flow.error = nil; try saveGroupFlow(flow) }
        }
    }
    func maintainGroups() {
        for var flow in Array(groupFlows.values) {
            let now = clock(), body = flow.invitation.body
            do {
                if [.sent, .offered, .verifying].contains(flow.phase), now.timeIntervalSince1970 >= Double(body.createdAt) + MeshPacket.lifetime {
                    flow.phase = .expired; try saveGroupFlow(flow)
                }
                if flow.phase == .waiting, let consent = flow.consent,
                   now.timeIntervalSince1970 >= Double(consent.body.acceptedAt) + MeshPacket.lifetime {
                    flow.phase = .unconfirmed; try saveGroupFlow(flow)
                }
                guard sessionID != nil else { continue }
                let destination = flow.phase == .verifying ? body.inviter.id : body.creator.id
                guard peers[destination] != nil || !links.isEmpty else { continue }
                guard now.timeIntervalSince(groupPolls[flow.id.uuidString] ?? .distantPast) >= 30 else { continue }
                groupPolls[flow.id.uuidString] = now
                switch flow.phase {
                case .verifying: try requestGroupSync(body.groupID, from: body.inviter.peer, flow: flow)
                case .waiting: if let consent = flow.consent { try sendGroupSignal(.join(consent), to: body.creator,
                    deadline: Date(timeIntervalSince1970: Double(consent.body.acceptedAt) + MeshPacket.lifetime)) }
                case .unconfirmed: if let consent = flow.consent { try sendGroupSignal(.query(consent), to: body.creator) }
                case .cancelPending: if let proof = flow.cancellation { try sendGroupSignal(.cancel(proof), to: body.creator) }
                default: break
                }
            } catch { /* Durable intent remains for the next reconciliation. */ }
        }
        guard sessionID != nil else { return }
        for group in closedGroups {
            for peer in peers.values where peer.supportsGroups && peer.id != identity.card.id {
                guard group.members.contains(where: { $0.id == peer.id }) || peer.id == group.creator.id else { continue }
                let key = group.id.uuidString + peer.id
                guard clock().timeIntervalSince(groupPolls[key] ?? .distantPast) >= 30 else { continue }
                groupPolls[key] = clock()
                try? requestGroupSync(group.id, from: peer.card,
                    flow: groupFlows.values.first { !$0.outgoing && $0.invitation.body.groupID == group.id })
            }
        }
    }
}

extension MeshStore {
    func stopGroupTasks(_ tasks: [TransferTask]) throws {
        guard !tasks.isEmpty else { return }
        try own.transaction {
            for task in tasks {
                let key = task.packet.storageKey
                try own.remove(space: "outbox", id: key); try own.remove(space: "awaiting", id: key)
                if var evidence = try own.decode(DeliveryEvidence.self, space: "delivery", id: key), evidence.state != .read && evidence.state != .delivered {
                    evidence.state = .failed; try own.put(space: "delivery", id: key, value: evidence)
                    try aggregate(task.packet.body.id)
                }
            }
        }
    }
}

extension MeshStore {
    func dropGroupJoinIntent(_ attempt: UUID) throws {
        let rows = try relay.all(space: "origin") + relay.all(space: "originAwaiting")
        let victims = try rows.filter { row in
            let task = try JSONDecoder().decode(TransferTask.self, from: row.data)
            return task.groupIntent == .join(attempt)
        }
        guard !victims.isEmpty else { return }
        try relay.transaction { for row in victims { try relay.remove(space: row.space, id: row.id) } }
    }
}
