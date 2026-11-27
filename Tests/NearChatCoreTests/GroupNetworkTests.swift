import XCTest
@testable import NearChatCore

final class GroupNetworkTests: XCTestCase {
    typealias Network = PersistentMeshTests.Network
    private func pair(_ net: Network) throws -> (MeshEngine, MeshEngine) {
        let a = try net.node(0, consent: true), b = try net.node(1, consent: true)
        net.connect(0,1); try net.drain(); try net.announce(); return (a,b)
    }
    private func incoming(_ b: MeshEngine, group: UUID) throws -> GroupInvitationState {
        try XCTUnwrap(b.groupInvitations.first { !$0.outgoing && $0.invitation.body.groupID == group })
    }
    private func join(_ a: MeshEngine, _ b: MeshEngine, _ id: UUID, _ net: Network) throws {
        try a.inviteToGroup(id, peerID: b.identity.card.id); try net.drain()
        let flow = try incoming(b, group: id)
        XCTAssertEqual(flow.phase, .offered, b.events.suffix(5).joined(separator: "\n"))
        try b.acceptGroupInvitation(flow.id); try net.drain(); try net.advance(1)
        XCTAssertEqual(try incoming(b, group: id).phase, .joined, b.events.suffix(5).joined(separator: "\n"))
    }
    private func signal(_ packet: MeshPacket, at node: MeshEngine) -> GroupSignal? {
        guard packet.body.kind == .group, let data = try? packet.decrypted(using: node.identity) else { return nil }
        return try? JSONDecoder().decode(GroupSignal.self, from: data)
    }
    func testInvitationConsentAndGroupTextOverRelayWithoutPersonalConsent() throws {
        let net = Network()
        let a = try net.node(0, consent: true), relay = try net.node(1, consent: true), b = try net.node(2, consent: true)
        net.connect(0,1); net.connect(1,2); try net.drain(); try net.announce()
        let id = try a.createClosedGroup(name: "private title")
        try join(a,b,id,net)
        XCTAssertFalse(a.canSendDirect(to: b.identity.card.id))
        let message = try a.sendToGroup(text: "group secret", groupID: id); try net.drain()
        XCTAssertEqual(b.messages.first?.id, message)
        XCTAssertEqual(b.messages.first?.group?.groupID, id)
        XCTAssertTrue(relay.messages.isEmpty)
        XCTAssertEqual(a.messages.first?.state, .delivered)
        b.markRead(message); try net.drain()
        XCTAssertEqual(a.messages.first?.state, .read)
    }
    func testMemberInvitesThirdAndAllReceiveOneLogicalMessage() throws {
        let net = Network(); let (a,b) = try pair(net); let c = try net.node(2, consent: true)
        net.connect(1,2); try net.drain(); try net.announce()
        let id = try a.createClosedGroup(name: "company")
        try join(a,b,id,net); try net.advance(1)
        try join(b,c,id,net); try net.advance(1)
        let message = try b.sendToGroup(text: "everyone", groupID: id); try net.drain()
        XCTAssertEqual(a.messages.filter { $0.id == message }.count, 1)
        XCTAssertEqual(c.messages.filter { $0.id == message }.count, 1)
        XCTAssertEqual(b.messages.filter { $0.id == message }.count, 1)
        XCTAssertEqual(b.messages.first?.group?.recipients.count, 2)
    }
    func testCancellationBeforeCreatorSeesJoinSurvivesRestart() throws {
        let net = Network(); let (a,b) = try pair(net)
        let id = try a.createClosedGroup(name: "group")
        try a.inviteToGroup(id, peerID: b.identity.card.id); try net.drain()
        let flow = try incoming(b, group: id)
        net.drop = { [self] _,_,packet in if case .join? = signal(packet, at: a) { return true }; return false }
        try b.acceptGroupInvitation(flow.id); try net.drain()
        try b.cancelGroupJoin(flow.id); try net.drain()
        let stored = try MeshStore(directory:net.root.appendingPathComponent("1"),identity:b.identity)
        let jobs = try stored.originControls() + stored.relay.all(space:"originAwaiting").map { try JSONDecoder().decode(TransferTask.self,from:$0.data) }
        XCTAssertFalse(jobs.contains { $0.groupIntent == .join(b.groupInvitations.first(where: { $0.id == flow.id })!.consent!.body.attemptID) })
        XCTAssertEqual(try incoming(b,group:id).phase, .cancelled)
        net.drop = nil; try net.advance(6)
        XCTAssertNil(a.closedGroups.first?.member(b.identity.card.id))
        let restored = try net.node(1, consent: true)
        XCTAssertEqual(try incoming(restored,group:id).phase, .cancelled)
        XCTAssertFalse(restored.closedGroups.first?.canSend(as: restored.identity.card.id) ?? true)
    }
    func testCancellationAfterFixationDoesNotActivateOnLateConfirmation() throws {
        let net = Network(); let (a,b) = try pair(net)
        let id = try a.createClosedGroup(name: "group")
        try a.inviteToGroup(id, peerID: b.identity.card.id); try net.drain()
        let flow = try incoming(b, group: id)
        net.drop = { [self] _,_,packet in
            switch signal(packet, at:b) {
            case .event?, .hint?, .joinReply?: return true
            default: return false
            }
        }
        try b.acceptGroupInvitation(flow.id); try net.drain()
        XCTAssertNotNil(a.closedGroups.first?.member(b.identity.card.id))
        XCTAssertEqual(try incoming(b,group:id).phase, .waiting)
        try b.cancelGroupJoin(flow.id); try net.drain()
        XCTAssertEqual(try incoming(b,group:id).phase, .cancelled)
        XCTAssertNil(a.closedGroups.first?.member(b.identity.card.id))
        net.drop = nil; try net.advance(6); try net.announce(); try net.advance(31)
        XCTAssertFalse(b.closedGroups.first?.canSend(as: b.identity.card.id) ?? true)
        XCTAssertEqual(try incoming(b,group:id).phase, .cancelled)
    }
    func testDeclineAndFullResultDoNotAutoJoinAfterLimitIncrease() throws {
        let net = Network(); let (a,b) = try pair(net)
        let id = try a.createClosedGroup(name: "group", memberLimit: 1)
        try a.inviteToGroup(id, peerID: b.identity.card.id); try net.drain()
        var flow = try incoming(b,group:id)
        try b.declineGroupInvitation(flow.id); try net.drain()
        XCTAssertEqual(a.groupInvitations.first?.phase, .declined)
        try a.inviteToGroup(id, peerID: b.identity.card.id); try net.drain()
        flow = try XCTUnwrap(b.groupInvitations.first { $0.phase == .offered })
        try b.acceptGroupInvitation(flow.id); try net.drain()
        XCTAssertEqual(b.groupInvitations.first(where: { $0.id == flow.id })?.error, .groupFull)
        try a.setGroupMemberLimit(2, groupID: id); try net.drain(); try net.advance(31)
        XCTAssertNil(a.closedGroups.first?.member(b.identity.card.id))
    }
    func testLateProofAutomaticallyResolvesUnconfirmedJoin() throws {
        let net = Network(); let (a,b) = try pair(net)
        let id = try a.createClosedGroup(name: "group")
        try a.inviteToGroup(id, peerID: b.identity.card.id); try net.drain()
        let flow = try incoming(b,group:id)
        net.drop = { [self] _,_,packet in
            switch signal(packet,at:b) { case .event?, .hint?, .joinReply?: return true; default: return false }
        }
        try b.acceptGroupInvitation(flow.id); try net.drain()
        try net.advance(86_401)
        XCTAssertEqual(try incoming(b,group:id).phase, .unconfirmed)
        net.drop = nil; try net.announce(); try net.advance(31)
        XCTAssertEqual(try incoming(b,group:id).phase, .joined)
        XCTAssertEqual(a.closedGroups.first?.members.count, 2)
    }
    func testKnownExclusionStopsQueuedTasksAndGroupIsReadOnlyAtTarget() throws {
        let net = Network(); let (a,b) = try pair(net)
        let id = try a.createClosedGroup(name: "group"); try join(a,b,id,net)
        net.disconnect(0,1)
        let message = try a.sendToGroup(text: "queued before exclusion", groupID: id)
        try a.excludeGroupMember(b.identity.card.id, groupID: id)
        a.tick()
        XCTAssertEqual(a.messages.first(where: { $0.id == message })?.state, .failed)
        net.connect(0,1); try net.drain(); try net.announce(); try net.advance(31)
        XCTAssertFalse(b.closedGroups.first?.canSend(as:b.identity.card.id) ?? true)
        XCTAssertFalse(b.messages.contains { $0.id == message })
        XCTAssertThrowsError(try b.sendToGroup(text:"after removal",groupID:id))
    }
    func testSharedMessagesRemainVisibleAfterPersonalBlockAndHistorySurvivesRestart() throws {
        let net = Network(); let (a,b) = try pair(net)
        let id = try a.createClosedGroup(name: "group"); try join(a,b,id,net)
        try b.setContactBlocked(a.identity.card.id, blocked:true)
        let message = try a.sendToGroup(text:"shared",groupID:id); try net.drain()
        XCTAssertTrue(b.messages.contains { $0.id == message })
        let restored = try net.node(1,consent:true)
        XCTAssertEqual(restored.messages.first?.group?.groupID,id)
        XCTAssertEqual(restored.unreadCount,1)
    }
    func testNearbyAdvertisementDoesNotContainPrivateTitle() throws {
        let net = Network(); let (a,b) = try pair(net)
        let title = "secret title " + UUID().uuidString
        let id = try a.createClosedGroup(name:title)
        try net.announce()
        XCTAssertTrue(b.nearbyClosedGroupIDs.contains(id))
        XCTAssertTrue(b.closedGroups.isEmpty)
        for (_,_,data) in net.captured {
            if let packet = try? MeshPacket.decode(data,now:net.time), packet.body.kind == .presence {
                XCTAssertNil(packet.body.payload.range(of:Data(title.utf8)))
            }
        }
    }
    func testSingleMemberGroupStoresTextWithoutClaimingDelivery() throws {
        let net = Network(); let a = try net.node(0,consent:true); a.beginNetworking()
        let id = try a.createClosedGroup(name:"notes",memberLimit:1)
        let message = try a.sendToGroup(text:"local",groupID:id)
        XCTAssertEqual(a.messages.first?.id,message)
        XCTAssertEqual(a.messages.first?.state,.local)
    }
    func testOldTextCannotEnterNewMembershipPeriod() throws {
        let net = Network(); let (a,b) = try pair(net)
        let id = try a.createClosedGroup(name:"group"); try join(a,b,id,net)
        net.drop = { _,_,packet in packet.body.kind == .message }
        let oldID = try a.sendToGroup(text:"old period",groupID:id); try net.drain()
        let old = try XCTUnwrap(net.captured.compactMap { try? MeshPacket.decode($0.2,now:net.time) }.first { $0.body.id == oldID })
        net.drop = nil
        try b.leaveClosedGroup(id); try net.drain(); try net.advance(1)
        try join(a,b,id,net)
        b.receive(try old.encoded(),from:"0"); try net.drain()
        XCTAssertFalse(b.messages.contains { $0.id == oldID })
        let fresh = try a.sendToGroup(text:"new period",groupID:id); try net.drain()
        XCTAssertTrue(b.messages.contains { $0.id == fresh })
    }
    func testNewMemberIsNotAddedToOldQueuedAudience() throws {
        let net = Network(); let (a,b) = try pair(net); let c = try net.node(2,consent:true)
        net.connect(0,2); try net.drain(); try net.announce()
        let id = try a.createClosedGroup(name:"group"); try join(a,b,id,net)
        net.disconnect(0,1)
        let oldID = try a.sendToGroup(text:"before newcomer",groupID:id); try net.drain()
        try join(a,c,id,net)
        XCTAssertFalse(c.messages.contains { $0.id == oldID })
        XCTAssertEqual(a.messages.first(where: { $0.id == oldID })?.group?.recipients.map(\.peerID),[b.identity.card.id])
    }
    func testMembersChatWhileCreatorOfflineButNewJoinWaits() throws {
        let net = Network(); let (a,b) = try pair(net); let c = try net.node(2,consent:true), d = try net.node(3,consent:true)
        net.connect(0,2); net.connect(1,2); net.connect(1,3); try net.drain(); try net.announce()
        let id = try a.createClosedGroup(name:"company"); try join(a,b,id,net); try net.advance(1); try join(a,c,id,net)
        net.disconnect(0,1); net.disconnect(0,2); try net.advance(21); try net.announce()
        let message = try b.sendToGroup(text:"creator offline",groupID:id); try net.drain()
        XCTAssertTrue(c.messages.contains { $0.id == message })
        try b.inviteToGroup(id,peerID:d.identity.card.id); try net.drain()
        let flow = try incoming(d,group:id); XCTAssertEqual(flow.phase,.offered)
        try d.acceptGroupInvitation(flow.id); try net.drain()
        XCTAssertEqual(try incoming(d,group:id).phase,.waiting)
        XCTAssertFalse(d.closedGroups.first?.canSend(as:d.identity.card.id) ?? true)
        net.connect(0,1); try net.drain()
        for _ in 0..<12 {
            try net.announce(); try net.advance(6)
            if try incoming(d,group:id).phase == .joined { break }
        }
        let report = net.nodes.sorted { $0.key < $1.key }.map { key, node in
            "Node \(key): rejected=\(node.counters.rejected) peers=\(node.peers.count) events=" + node.events.suffix(5).joined(separator:"; ")
        }.joined(separator:"\n")
        XCTAssertEqual(try incoming(d,group:id).phase,.joined,report)
    }
    func testOutsiderCannotDownloadRosterOrForgeGroupMessage() throws {
        let net = Network(); let (a,b) = try pair(net); let outsider = try net.node(2,consent:true)
        net.connect(0,2); try net.drain(); try net.announce()
        let id = try a.createClosedGroup(name:"private"); try join(a,b,id,net)
        let before = net.captured.count
        let request = GroupSignal.sync(GroupSync(groupID:id,after:0,invitation:nil,consent:nil))
        let packet = try MeshPacket.make(identity:outsider.identity,kind:.group,recipient:a.identity.card,
            cleartext:JSONEncoder().encode(request),now:net.time)
        a.receive(try packet.encoded(),from:"2"); try net.drain()
        XCTAssertFalse(net.captured.dropFirst(before).contains { _,_,data in
            guard let packet = try? MeshPacket.decode(data,now:net.time) else { return false }
            if case .event? = signal(packet,at:outsider) { return true }; return false
        })
        var payload = ChatPayload(text:"intrusion",isPublic:false)
        payload.group = try a.closedGroups[0].audience(for:a.identity.card.id)
        let message = try MeshPacket.make(identity:outsider.identity,kind:.message,recipient:b.identity.card,
            cleartext:JSONEncoder().encode(payload),now:net.time)
        // Present the valid signed packet through B's already established link to A.
        b.receive(try message.encoded(),from:"0")
        XCTAssertTrue(b.messages.isEmpty)
    }
    func testPendingInvitationExpiresEvenWhenNetworkingStopped() throws {
        let net = Network(); let (a,b) = try pair(net)
        let id = try a.createClosedGroup(name:"group")
        try a.inviteToGroup(id,peerID:b.identity.card.id); try net.drain()
        b.endNetworking(); net.time.addTimeInterval(86_400); b.tick()
        XCTAssertEqual(try incoming(b,group:id).phase,.expired)
        XCTAssertThrowsError(try b.acceptGroupInvitation(incoming(b,group:id).id))
    }
    func testKnownUpdatedPeerCanBeInvitedOfflineAfterRestart() throws {
        let net = Network(); let (a,b) = try pair(net)
        let id = try a.createClosedGroup(name:"group")
        a.endNetworking(); b.endNetworking()
        let restored = try net.node(0,consent:true)
        try restored.inviteToGroup(id,peerID:b.identity.card.id)
        XCTAssertEqual(restored.groupInvitations.first?.phase,.sent)
        XCTAssertNil(restored.sessionID)
        net.connect(0,1); try net.drain()
        XCTAssertEqual(try incoming(b,group:id).phase,.offered)
    }
    func testFailedPersistenceCannotSendAcceptance() throws {
        let net = Network(); let (a,b) = try pair(net)
        let id = try a.createClosedGroup(name:"group")
        try a.inviteToGroup(id,peerID:b.identity.card.id); try net.drain()
        let flow = try incoming(b,group:id), root = net.root.appendingPathComponent("1")
        try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:root.path) }
        guard !FileManager.default.isWritableFile(atPath:root.path) else { throw XCTSkip("Permissions bypassed") }
        XCTAssertThrowsError(try b.acceptGroupInvitation(flow.id)); try net.drain()
        XCTAssertEqual(try incoming(b,group:id).phase,.offered)
        XCTAssertEqual(a.closedGroups.first?.members.count,1)
    }
    func testMaximumAudienceAndTextFitExistingWireLimit() throws {
        let net = Network(); let a = try net.node(0,consent:true)
        let id = try a.createClosedGroup(name:"maximum group")
        for _ in 0..<31 {
            let peer = try MeshIdentity(name:String(repeating:"🙂",count:32))
            let invitation = try a.makeGroupInvitation(to:peer.card,groupID:id)
            try a.finalizeGroupJoin(GroupJoinConsent.accept(invitation,by:peer,now:net.time))
        }
        a.beginNetworking()
        let message = try a.sendToGroup(text:String(repeating:"🙂",count:1000),groupID:id)
        let store = try MeshStore(directory:net.root.appendingPathComponent("0"),identity:a.identity)
        let tasks = try store.outgoing().filter { $0.packet.body.id == message }
        XCTAssertEqual(tasks.count,31)
        for task in tasks { XCTAssertLessThanOrEqual(try task.packet.encoded().count,MeshPacket.maxWireBytes) }
        let restored = try net.node(0,consent:true)
        XCTAssertEqual(restored.storageUsage?.outgoingTasks,31)
    }
    func testEndpointServiceProofReleasesOriginalRelayQueue() throws {
        let net = Network(); let a = try net.node(0,consent:true), relay = try net.node(1,consent:true), b = try net.node(2,consent:true)
        net.connect(0,1); net.connect(1,2); try net.drain(); try net.announce()
        let id = try a.createClosedGroup(name:"service receipts"); try join(a,b,id,net)
        for (index,node) in [(0,a),(2,b)] {
            let store = try MeshStore(directory:net.root.appendingPathComponent(String(index)),identity:node.identity)
            let tasks = try store.originControls() + store.relay.all(space:"originAwaiting").map { try JSONDecoder().decode(TransferTask.self,from:$0.data) }
            XCTAssertFalse(tasks.contains { $0.packet.body.kind == .group })
        }
        XCTAssertTrue(relay.messages.isEmpty)
    }
    func testRelayCannotForgeServiceAppliedProof() throws {
        let net = Network(); let a = try net.node(0,consent:true), relay = try net.node(1,consent:true), b = try net.node(2,consent:true)
        net.connect(0,1); net.connect(1,2); try net.drain(); try net.announce()
        let id = try a.createClosedGroup(name:"group")
        net.drop = { _,_,packet in packet.body.recipient == b.identity.card.id && packet.body.kind == .group }
        try a.inviteToGroup(id,peerID:b.identity.card.id); try net.drain()
        let store = try MeshStore(directory:net.root.appendingPathComponent("0"),identity:a.identity)
        let task = try XCTUnwrap((try store.originControls()).first)
        let proof = FinalReceipt(messageID:task.packet.body.id,recipientID:b.identity.card.id,digest:try task.packet.digest(),kind:.delivered)
        XCTAssertThrowsError(try store.apply(proof,signedBy:relay.identity.card))
        XCTAssertNotNil(try store.relay.row(space:"origin",id:task.packet.storageKey))
    }
}
