import XCTest
@testable import NearChatCore

final class ContactTests: XCTestCase {
    typealias Network = PersistentMeshTests.Network
    private func pair(_ net: Network) throws -> (MeshEngine, MeshEngine) {
        let a = try net.node(0, consent: true), b = try net.node(1, consent: true)
        net.connect(0, 1); try net.drain(); try net.announce()
        return (a, b)
    }
    private func decide(_ receiver: MeshEngine, from sender: MeshEngine, accept: Bool) throws {
        let request = try XCTUnwrap(receiver.contact(for: sender.identity.card.id)?.incomingRequestID)
        try receiver.respondToContact(from: sender.identity.card.id, requestID: request, accept: accept)
    }
    private func open(_ a: MeshEngine, _ b: MeshEngine, _ net: Network) throws {
        try a.requestContact(to: b.identity.card.id); try net.drain()
        try decide(b, from: a, accept: true); try net.drain()
    }
    func testPrivateSendRequiresConsentAndPublicStillWorks() throws {
        let net = Network(); let (a,b) = try pair(net)
        XCTAssertThrowsError(try a.send(text: "no consent", to: b.identity.card.id))
        let id = try a.broadcast(text: "common"); try net.drain()
        XCTAssertEqual(b.messages.first?.id, id)
        XCTAssertFalse(a.canSendDirect(to: b.identity.card.id))
        XCTAssertTrue(a.contact(for: b.identity.card.id)?.canRequest == true)
    }
    func testAcceptanceAcrossRelayOpensBothAndDeliversText() throws {
        let net = Network()
        let a = try net.node(0, consent: true), r = try net.node(1, consent: true), b = try net.node(2, consent: true)
        net.connect(0,1); net.connect(1,2); try net.drain(); try net.announce()
        try open(a,b,net)
        XCTAssertTrue(a.canSendDirect(to: b.identity.card.id)); XCTAssertTrue(b.canSendDirect(to: a.identity.card.id))
        let id = try a.send(text: "agreed", to: b.identity.card.id); try net.drain()
        XCTAssertEqual(b.messages.first?.id, id); XCTAssertTrue(r.messages.isEmpty)
        XCTAssertEqual(a.messages.first?.state, .delivered)
    }
    func testDuplicateRequestAndDecisionDoNotUseAnotherAttempt() throws {
        let net = Network(); let (a,b) = try pair(net)
        try a.requestContact(to: b.identity.card.id); try net.drain()
        let original = b.contact(for: a.identity.card.id)?.incomingRequestID
        try a.requestContact(to: b.identity.card.id); try net.drain()
        XCTAssertEqual(b.contact(for: a.identity.card.id)?.incomingRequestID, original)
        try decide(b, from: a, accept: false); try net.drain()
        for (_,_,data) in net.captured.filter({ $0.0 == 0 && $0.1 == 1 }) {
            if let packet = try? MeshPacket.decode(data, now: net.time), packet.body.kind == .contact {
                b.receive(data, from: "0")
            }
        }
        try net.drain()
        XCTAssertNil(b.contact(for: a.identity.card.id)?.incomingRequestID)
        XCTAssertEqual(a.contact(for: b.identity.card.id)?.phase, .declined)
    }
    func testTwoRejectionsPauseThenPermitTwoAgain() throws {
        let net = Network(); let (a,b) = try pair(net)
        for _ in 0..<2 {
            try a.requestContact(to: b.identity.card.id); try net.drain()
            try decide(b, from: a, accept: false); try net.drain()
        }
        XCTAssertEqual(a.contact(for: b.identity.card.id)?.phase, .paused)
        XCTAssertThrowsError(try a.requestContact(to: b.identity.card.id))
        try net.advance(86_400); try net.announce()
        try a.requestContact(to: b.identity.card.id); try net.drain()
        try decide(b, from: a, accept: false); try net.drain()
        XCTAssertEqual(a.contact(for: b.identity.card.id)?.phase, .declined)
        XCTAssertTrue(a.contact(for: b.identity.card.id)?.canRequest == true)
    }
    func testReverseRequestRestartsTwoAttemptsWithoutOpeningDialog() throws {
        let net = Network(); let (a,b) = try pair(net)
        for _ in 0..<2 {
            try a.requestContact(to: b.identity.card.id); try net.drain()
            try decide(b, from: a, accept: false); try net.drain()
        }
        try b.requestContact(to: a.identity.card.id); try net.drain()
        XCTAssertEqual(a.contact(for: b.identity.card.id)?.phase, .incoming)
        XCTAssertFalse(a.canSendDirect(to: b.identity.card.id))
        try decide(a, from: b, accept: false); try net.drain()
        try a.requestContact(to: b.identity.card.id); try net.drain()
        try decide(b, from: a, accept: false); try net.drain()
        XCTAssertEqual(a.contact(for: b.identity.card.id)?.phase, .declined)
        try a.requestContact(to: b.identity.card.id); try net.drain()
        try decide(b, from: a, accept: false); try net.drain()
        XCTAssertEqual(a.contact(for: b.identity.card.id)?.phase, .paused)
    }
    func testManualBlockSurvivesReverseRequestAndDayButAllowsCommonChat() throws {
        let net = Network(); let (a,b) = try pair(net)
        try a.setContactBlocked(b.identity.card.id, blocked: true)
        try b.requestContact(to: a.identity.card.id); try net.drain()
        XCTAssertEqual(a.contact(for: b.identity.card.id)?.phase, .blocked)
        XCTAssertNil(a.contact(for: b.identity.card.id)?.incomingRequestID)
        try net.advance(86_401); try net.announce()
        XCTAssertEqual(a.contact(for: b.identity.card.id)?.phase, .blocked)
        let id = try b.broadcast(text: "visible in common"); try net.drain()
        XCTAssertEqual(a.messages.first?.id, id)
    }
    func testBlockDropsIncomingPrivateAndPausesOwnQueuedUntilUnblocked() throws {
        let net = Network(); let (a,b) = try pair(net); try open(a,b,net)
        net.disconnect(0,1)
        let waiting = try a.send(text: "queued", to: b.identity.card.id)
        try a.setContactBlocked(b.identity.card.id, blocked: true)
        net.connect(0,1); try net.drain(); try net.announce(); try net.advance(6)
        XCTAssertTrue(b.messages.isEmpty)
        _ = try b.send(text: "blocked incoming", to: a.identity.card.id); try net.drain()
        XCTAssertEqual(a.messages.count, 1)
        try a.setContactBlocked(b.identity.card.id, blocked: false)
        try net.advance(6)
        XCTAssertTrue(b.messages.contains { $0.id == waiting && !$0.outgoing })
    }
    func testUnsignedConsentAndForgedGrantCannotCreateHistory() throws {
        let net = Network(); let (a,b) = try pair(net)
        let unauthorized = try MeshPacket.make(identity: a.identity, kind: .message, recipient: b.identity.card,
            cleartext: JSONEncoder().encode(ChatPayload(text: "no proof", isPublic: false)), now: net.time)
        b.receive(try unauthorized.encoded(), from: "0")
        XCTAssertTrue(b.messages.isEmpty)
        let proof = try ContactRequestProof.make(identity: a.identity, recipient: b.identity.card, sequence: 1, now: net.time)
        let forged = ContactGrant(body: ContactGrantBody(request: proof, approvedAt: Int64(net.time.timeIntervalSince1970)), signature: Data(repeating: 0, count: 64))
        var payload = ChatPayload(text: "forged", isPublic: false); payload.consent = forged
        let packet = try MeshPacket.make(identity: a.identity, kind: .message, recipient: b.identity.card,
            cleartext: JSONEncoder().encode(payload), now: net.time)
        b.receive(try packet.encoded(), from: "0")
        XCTAssertTrue(b.messages.isEmpty); XCTAssertEqual(b.unreadCount, 0)
        XCTAssertFalse(b.canSendDirect(to: a.identity.card.id))
    }
    func testMessageMayArriveBeforeAcceptanceResponse() throws {
        let net = Network(); let (a,b) = try pair(net)
        try a.requestContact(to: b.identity.card.id); try net.drain()
        net.drop = { _,_,packet in packet.body.kind == .contact }
        try decide(b, from: a, accept: true); try net.drain()
        XCTAssertFalse(a.canSendDirect(to: b.identity.card.id))
        let id = try b.send(text: "approval proof travels with text", to: a.identity.card.id); try net.drain()
        XCTAssertEqual(a.messages.first?.id, id); XCTAssertTrue(a.canSendDirect(to: b.identity.card.id))
    }
    func testPauseSurvivesRestartAndNicknameChange() throws {
        let net = Network(); let (a,b) = try pair(net)
        for _ in 0..<2 {
            try a.requestContact(to: b.identity.card.id); try net.drain()
            try decide(b, from: a, accept: false); try net.drain()
        }
        let restored = try net.node(0, consent: true); restored.rename("new nickname")
        net.connect(0,1); try net.drain(); try net.announce()
        XCTAssertEqual(restored.contact(for: b.identity.card.id)?.phase, .paused)
        XCTAssertThrowsError(try restored.requestContact(to: b.identity.card.id))
        let recipient = try net.node(1, consent: true)
        net.connect(0,1); try net.drain(); try net.announce()
        // Receiver enforces its own saved pause even if the sender disregards local checks.
        let proof = try ContactRequestProof.make(identity: a.identity, recipient: recipient.identity.card, sequence: 3, now: net.time)
        let packet = try MeshPacket.make(identity: a.identity, kind: .contact, recipient: recipient.identity.card,
            cleartext: JSONEncoder().encode(ContactSignal.request(proof)), now: net.time)
        recipient.receive(try packet.encoded(), from: "0")
        XCTAssertNil(recipient.contact(for: restored.identity.card.id)?.incomingRequestID)
    }
    func testAcceptedAndBlockedStateSurviveRestartAndHistoryDeletion() throws {
        let net = Network(); let (a,b) = try pair(net); try open(a,b,net)
        _ = try a.send(text: "history", to: b.identity.card.id); try net.drain()
        try b.setContactBlocked(a.identity.card.id, blocked: true)
        let store = try MeshStore(directory: net.root.appendingPathComponent("1"), identity: b.identity)
        try store.own.transaction { for row in try store.own.all(space: "history") { try store.own.remove(space: "history", id: row.id) } }
        let restored = try net.node(1, consent: true)
        XCTAssertEqual(restored.contact(for: a.identity.card.id)?.phase, .blocked)
        XCTAssertTrue(restored.messages.isEmpty)
        try restored.setContactBlocked(a.identity.card.id, blocked: false)
        XCTAssertTrue(restored.canSendDirect(to: a.identity.card.id))
    }
    func testPendingRequestSurvivesRestartAndStaleDecisionIsRejected() throws {
        let net = Network(); let (a,b) = try pair(net)
        try a.requestContact(to: b.identity.card.id); try net.drain()
        let id = try XCTUnwrap(b.contact(for: a.identity.card.id)?.incomingRequestID)
        let restored = try net.node(1, consent: true)
        XCTAssertEqual(restored.contact(for: a.identity.card.id)?.incomingRequestID, id)
        XCTAssertThrowsError(try restored.respondToContact(from: a.identity.card.id, requestID: UUID(), accept: true))
        try restored.respondToContact(from: a.identity.card.id, requestID: id, accept: true)
        XCTAssertTrue(restored.canSendDirect(to: a.identity.card.id))
    }
    func testNoStorageCannotCreateRequestOrAcknowledgeDecision() throws {
        let net = Network(); let a = try net.node(0, persistent: false, consent: true), b = try net.node(1, consent: true)
        net.connect(0,1); try net.drain(); try net.announce()
        XCTAssertThrowsError(try a.requestContact(to: b.identity.card.id))
        try b.requestContact(to: a.identity.card.id); try net.drain()
        XCTAssertNil(a.contact(for: b.identity.card.id)?.incomingRequestID)
        XCTAssertFalse(a.canSendDirect(to: b.identity.card.id))
    }
    func testOldPeerCannotReceiveNewDirectRequest() throws {
        let net = Network(); let (a,b) = try pair(net)
        // New engine with no saved contacts sees an old v2 presence without capabilities.
        let fresh = try net.node(0, consent: true); net.connect(0,1); try net.drain()
        let old = try MeshPacket.make(identity: b.identity, kind: .presence,
            cleartext: JSONEncoder().encode(PresenceInfo(sessionID: UUID())), now: net.time)
        fresh.receive(try old.encoded(), from: "1")
        XCTAssertFalse(fresh.contact(for: b.identity.card.id)?.supportsContacts ?? true)
        XCTAssertThrowsError(try fresh.requestContact(to: b.identity.card.id))
        XCTAssertTrue(a.messages.isEmpty)
    }
    func testFailedDurableDecisionLeavesRequestPendingAndSendsNoAcceptance() throws {
        let net = Network(); let (a,b) = try pair(net)
        try a.requestContact(to: b.identity.card.id); try net.drain()
        let directory = net.root.appendingPathComponent("1")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        guard !FileManager.default.isWritableFile(atPath: directory.path) else { throw XCTSkip("Permissions bypassed") }
        XCTAssertThrowsError(try decide(b, from: a, accept: true))
        try net.drain()
        XCTAssertEqual(b.contact(for: a.identity.card.id)?.phase, .incoming)
        XCTAssertFalse(a.canSendDirect(to: b.identity.card.id)); XCTAssertFalse(b.canSendDirect(to: a.identity.card.id))
    }
    func testReplayedOldSequenceCannotReplaceNewPrompt() throws {
        let net = Network(); let (a,b) = try pair(net)
        try a.requestContact(to: b.identity.card.id); try net.drain()
        let old = net.captured.compactMap { item -> Data? in
            guard item.0 == 0, let packet = try? MeshPacket.decode(item.2, now: net.time), packet.body.kind == .contact else { return nil }
            return item.2
        }
        try decide(b, from: a, accept: false); try net.drain()
        try a.requestContact(to: b.identity.card.id); try net.drain()
        let newID = b.contact(for: a.identity.card.id)?.incomingRequestID
        for data in old { b.receive(data, from: "0") }; try net.drain()
        XCTAssertEqual(b.contact(for: a.identity.card.id)?.incomingRequestID, newID)
        XCTAssertEqual(a.contact(for: b.identity.card.id)?.phase, .outgoing)
    }
    func testConsentMetadataSurvivesQuotaResize() throws {
        let net = Network(); let (a,b) = try pair(net); try open(a,b,net)
        let plan = try b.prepareStorageResize(.history, to: 1_000_000)
        try b.applyStorageResize(plan, confirmed: true)
        let restored = try net.node(1, consent: true)
        XCTAssertTrue(restored.canSendDirect(to: a.identity.card.id))
        XCTAssertEqual(restored.storageLimits?.historyBytes, 1_000_000)
    }
    func testUpgradeKeepsOldPrivateTextButStopsUnapprovedPendingJob() throws {
        let net = Network(); let a = try net.node(0), b = try net.node(1)
        net.connect(0,1); try net.drain(); try net.announce(); net.disconnect(0,1)
        let id = try a.send(text: "old queued private", to: b.identity.card.id)
        let restored = try net.node(0, consent: true)
        XCTAssertEqual(restored.messages.first?.id, id)
        XCTAssertEqual(restored.messages.first?.state, .failed)
        XCTAssertEqual(restored.storageUsage?.outgoingTasks, 0)
        net.connect(0,1); try net.drain(); try net.announce()
        XCTAssertTrue(b.messages.isEmpty)
        XCTAssertThrowsError(try restored.retry(id))
    }
}
