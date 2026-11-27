import XCTest
import CryptoKit
import Noise
@testable import NearChatCore

final class ForwardSecrecyTests: XCTestCase {
    final class Network {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        var nodes: [Int: MeshEngine] = [:]
        var identities: [Int: MeshIdentity] = [:]
        var queue: [(Int, Int, Data)] = []
        var captured: [(Int, Int, Data)] = []
        var drop: ((MeshPacket) -> Bool)?
        func node(_ index: Int) throws -> MeshEngine {
            let identity = try identities[index] ?? MeshIdentity(name: "Peer \(index)")
            identities[index] = identity
            let store = try MeshStore(directory: root.appendingPathComponent("\(index)"), identity: identity)
            let node = try MeshEngine(identity: identity, store: store, clock: { [unowned self] in self.time })
            node.receiveUptime = { [unowned self] in self.time.timeIntervalSince1970 }
            node.onTransmit = { [unowned self] link, bytes in
                if let destination = Int(link) { self.queue.append((index, destination, bytes)); self.captured.append((index,destination,bytes)) }
            }
            nodes[index] = node; return node
        }
        func connect(_ first: Int, _ second: Int) {
            nodes[first]!.linkOpened(id: "\(second)", transport: "test")
            nodes[second]!.linkOpened(id: "\(first)", transport: "test")
        }
        func drain() throws {
            var count = 0
            while !queue.isEmpty {
                count += 1; guard count < 10000 else { return XCTFail("unbounded packet loop") }
                let (from,to,bytes) = queue.removeFirst()
                if let packet = try? MeshPacket.decode(bytes, now: time), drop?(packet) == true { continue }
                nodes[to]?.receive(bytes, from: "\(from)")
            }
        }
        func pair() throws -> (MeshEngine, MeshEngine) {
            let a = try node(0), b = try node(1); connect(0,1); try drain()
            XCTAssertTrue(a.channelReady(to: b.identity.card.id), a.events.suffix(8).joined(separator: "\n"))
            XCTAssertTrue(b.channelReady(to: a.identity.card.id), b.events.suffix(8).joined(separator: "\n"))
            try a.requestContact(to: b.identity.card.id); try drain()
            let id = try XCTUnwrap(b.contact(for: a.identity.card.id)?.incomingRequestID, b.events.suffix(8).joined(separator: "\n"))
            try b.respondToContact(from: a.identity.card.id, requestID: id, accept: true); try drain()
            return (a,b)
        }
        func store(_ index: Int) throws -> MeshStore {
            try MeshStore(directory: root.appendingPathComponent("\(index)"), identity: identities[index]!)
        }
        func message(_ id: UUID, to destination: Int) throws -> MeshPacket {
            try XCTUnwrap(captured.filter { $0.1 == destination }.compactMap { try? MeshPacket.decode($0.2, now: time) }.first { $0.body.kind == .message && $0.body.id == id })
        }
        deinit { nodes.removeAll(); try? FileManager.default.removeItem(at: root) }
    }
    func testPublicAPIUsesForwardSecureTextAndDeliveryReceipts() throws {
        let net = Network(); let (a,b) = try net.pair()
        let id = try a.send(text: "forward secret", to: b.identity.card.id); try net.drain()
        let packet = try net.message(id, to: 1)
        XCTAssertEqual(packet.body.version, 3); XCTAssertNotNil(packet.body.secure)
        XCTAssertEqual(b.messages.last?.text, "forward secret")
        XCTAssertEqual(a.messages.last?.state, .delivered)
        b.markRead(id); try net.drain(); XCTAssertEqual(a.messages.last?.state, .read)
        XCTAssertThrowsError(try packet.decrypted(using: b.identity))
    }
    func testCurrentRatchetKeysAndLongTermKeysCannotDecryptCompletedPacket() throws {
        let net = Network(); let (a,b) = try net.pair()
        let id = try a.send(text: "past secret", to: b.identity.card.id); try net.drain()
        let packet = try net.message(id, to: 1), header = try XCTUnwrap(packet.body.secure)
        let store = try net.store(1)
        let epoch = try XCTUnwrap(store.own.decode(NoiseEpoch.self, space: "noise-epoch", id: header.session.uuidString))
        XCTAssertFalse(epoch.skipped.contains { $0.sequence == header.sequence })
        XCTAssertTrue(epoch.completed.contains { $0.sequence == header.sequence && $0.cleartext == nil })
        let cipher = try Noise.CipherState.restoring(key: epoch.receiveKey)
        try cipher.setNonce(UInt64(header.sequence))
        XCTAssertThrowsError(try cipher.open(ad: packet.body.associatedData, ciphertext: packet.body.payload))
        let staticKey = try b.identity.sharedKey(with: a.identity.card)
        let payload = packet.body.payload
        let nonceBytes = [UInt8](repeating: 0, count: 4) + (0..<8).map { UInt8(truncatingIfNeeded: UInt64(header.sequence) >> ($0 * 8)) }
        let sealed = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: Data(nonceBytes)),
            ciphertext: payload.dropLast(16), tag: payload.suffix(16))
        XCTAssertThrowsError(try ChaChaPoly.open(sealed, using: staticKey, authenticating: packet.body.associatedData))
        XCTAssertNil(try net.store(0).own.row(space: "noise-pending", id: b.identity.card.id), "Handshake ephemeral private key is retired")
    }
    func testOutOfOrderDeliveryAndReplayDoNotNeedErasedKeys() throws {
        let net = Network(); let (a,b) = try net.pair()
        let first = try a.send(text: "first", to: b.identity.card.id)
        let second = try a.send(text: "second", to: b.identity.card.id)
        let one = try net.message(first, to: 1), two = try net.message(second, to: 1)
        net.queue.removeAll()
        b.receive(try two.encoded(), from: "0")
        b.receive(try one.encoded(), from: "0"); try net.drain()
        XCTAssertEqual(b.messages.map(\.text), ["second", "first"])
        b.receive(try one.encoded(), from: "0"); try net.drain()
        XCTAssertEqual(b.messages.count, 2)
        XCTAssertTrue(a.messages.allSatisfy { $0.state == .delivered })
    }
    func testPersistentSessionsDeliverPreviouslySealedQueueAfterReceiverRestart() throws {
        let net = Network(); let (a,b) = try net.pair()
        let id = try a.send(text: "queued before restart", to: b.identity.card.id)
        net.queue.removeAll(); a.linkClosed(id: "1"); _ = try net.node(1)
        net.connect(0,1); try net.drain()
        net.time.addTimeInterval(6); a.tick(); try net.drain()
        XCTAssertEqual(net.nodes[1]?.messages.last?.id, id)
        XCTAssertEqual(a.messages.last?.state, .delivered)
    }
    func testSecureMessagesAndHandshakeCrossRelay() throws {
        let net = Network()
        let a = try net.node(0), r = try net.node(1), b = try net.node(2)
        net.connect(0,1); net.connect(1,2); try net.drain()
        a.announce(); r.announce(); b.announce(); try net.drain()
        XCTAssertTrue(a.channelReady(to: b.identity.card.id), a.events.suffix(10).joined(separator: "\n"))
        try a.requestContact(to: b.identity.card.id); try net.drain()
        let request = try XCTUnwrap(b.contact(for: a.identity.card.id)?.incomingRequestID)
        try b.respondToContact(from: a.identity.card.id, requestID: request, accept: true); try net.drain()
        let id = try a.send(text: "via relay", to: b.identity.card.id); try net.drain()
        XCTAssertEqual(b.messages.last?.id, id); XCTAssertTrue(r.messages.isEmpty)
        XCTAssertEqual(a.messages.last?.state, .delivered)
    }
    func testLegacyMessageCannotDowngradeSecureEndpoint() throws {
        let net = Network(); let (a,b) = try net.pair()
        let legacy = try MeshPacket.make(identity: a.identity, kind: .message, recipient: b.identity.card,
            cleartext: JSONEncoder().encode(ChatPayload(text: "downgrade", isPublic: false)), now: net.time)
        b.receive(try legacy.encoded(), from: "0"); try net.drain()
        XCTAssertTrue(b.messages.isEmpty); XCTAssertGreaterThan(b.counters.rejected, 0)
    }
    func testCommonAndGroupTextUseSecureTransport() throws {
        let net = Network(); let (a,b) = try net.pair()
        let common = try a.broadcast(text: "common"); try net.drain()
        XCTAssertEqual(try net.message(common, to: 1).body.version, 3)
        let group = try a.createClosedGroup(name: "private group")
        try a.inviteToGroup(group, peerID: b.identity.card.id); try net.drain()
        let invite = try XCTUnwrap(b.groupInvitations.first { !$0.outgoing && $0.invitation.body.groupID == group })
        XCTAssertEqual(invite.phase, .offered, b.events.suffix(8).joined(separator: "\n"))
        try b.acceptGroupInvitation(invite.id); try net.drain()
        let message = try a.sendToGroup(text: "group text", groupID: group); try net.drain()
        XCTAssertEqual(try net.message(message, to: 1).body.version, 3)
        XCTAssertEqual(b.messages.last?.text, "group text")
        XCTAssertEqual(a.messages.last?.state, .delivered)
    }
    func testSenderWriteFailureCannotReuseOrPublishAllocatedKey() throws {
        let net = Network(); let (a,b) = try net.pair()
        let root = net.root.appendingPathComponent("0")
        let store = try net.store(0)
        let before = try store.own.all(space: "noise-epoch").map(\.data)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        guard !FileManager.default.isWritableFile(atPath: root.path) else { throw XCTSkip("Permissions bypassed") }
        let sent = net.captured.count
        let waiting = try a.send(text: "cannot publish", to: b.identity.card.id)
        XCTAssertEqual(a.messages.last?.state, .securing)
        XCTAssertEqual(a.messages.last?.isSaved, false)
        XCTAssertEqual(net.captured.count, sent)
        XCTAssertEqual(try store.own.all(space: "noise-epoch").map(\.data), before)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        net.time.addTimeInterval(6); a.tick(); try net.drain()
        XCTAssertEqual(b.messages.last?.id, waiting)
    }
    func testForgedCiphertextDoesNotAdvanceReceiveChain() throws {
        let net = Network(); let (a,b) = try net.pair()
        let id = try a.send(text: "valid", to: b.identity.card.id)
        let original = try net.message(id, to: 1), header = try XCTUnwrap(original.body.secure)
        net.queue.removeAll()
        let store = try net.store(1)
        let before = try store.own.row(space: "noise-epoch", id: header.session.uuidString)?.data
        var payload = original.body.payload; payload[payload.count - 1] ^= 1
        let body = PacketBody(version: 3, id: original.body.id, kind: .message, sender: a.identity.card,
            recipient: b.identity.card.id, createdAt: original.body.createdAt, expiresAt: original.body.expiresAt,
            hopLimit: 256, payload: payload, secure: header)
        var bad = MeshPacket(body: body, signature: try a.identity.signing.signature(for: MeshPacket.encoder.encode(body)), remainingHops: 256)
        try bad.offerCustody(by: a.identity)
        b.receive(try bad.encoded(), from: "0")
        XCTAssertEqual(try store.own.row(space: "noise-epoch", id: header.session.uuidString)?.data, before)
        XCTAssertTrue(b.messages.isEmpty)
        b.receive(try original.encoded(), from: "0"); try net.drain()
        XCTAssertEqual(b.messages.last?.id, id)
    }

    func testOfflineSenderDoesNotPreventReceptionOfPreviouslySealedText() throws {
        let net = Network()
        let a = try net.node(0), relay = try net.node(1), b = try net.node(2)
        net.connect(0,1); net.connect(1,2); try net.drain()
        a.announce(); relay.announce(); b.announce(); try net.drain()
        try a.requestContact(to: b.identity.card.id); try net.drain()
        let request = try XCTUnwrap(b.contact(for: a.identity.card.id)?.incomingRequestID)
        try b.respondToContact(from: a.identity.card.id, requestID: request, accept: true); try net.drain()
        let id = try a.send(text: "sender has gone", to: b.identity.card.id)
        var packet = try XCTUnwrap(net.captured.compactMap { try? MeshPacket.decode($0.2, now: net.time) }.first { $0.body.id == id })
        packet.remainingHops -= 1
        net.queue.removeAll(); a.endNetworking()
        net.time.addTimeInterval(23 * 3600)
        b.receive(try packet.encoded(), from: "1"); try net.drain()
        XCTAssertEqual(b.messages.last?.id, id, b.events.suffix(8).joined(separator: "\n"))
        b.markRead(id)
        XCTAssertEqual(b.unreadCount, 0)
    }
    func testGroupsDoNotRequirePersonalConsentForForwardSecureText() throws {
        let net = Network(); let a = try net.node(0), b = try net.node(1)
        net.connect(0,1); try net.drain()
        let id = try a.createClosedGroup(name: "group without personal grant")
        try a.inviteToGroup(id, peerID: b.identity.card.id); try net.drain()
        let invite = try XCTUnwrap(b.groupInvitations.first { !$0.outgoing })
        try b.acceptGroupInvitation(invite.id); try net.drain()
        XCTAssertFalse(a.canSendDirect(to: b.identity.card.id))
        let message = try a.sendToGroup(text: "group only", groupID: id); try net.drain()
        XCTAssertEqual(b.messages.last?.id, message)
        XCTAssertNotNil(try net.message(message, to: 1).body.secure)
    }

    func testPendingReceiveKeyErasureRecoversFromCommittedInbox() throws {
        let net = Network(); let (a,b) = try net.pair()
        let id = try a.send(text: "commit before erasure", to: b.identity.card.id)
        let packet = try net.message(id, to: 1), header = try XCTUnwrap(packet.body.secure)
        net.queue.removeAll()
        let store = try net.store(1)
        let trust = PeerTrustBook(identity: b.identity, store: { store }); try trust.load()
        let sessions = SecureSessions(identity: b.identity, store: { store }, trust: trust); try sessions.load(now: net.time)
        let opened = try sessions.prepareOpen(packet, now: net.time)
        var entry = ChatEntry(id: id, sender: a.identity.card, recipient: b.identity.card.id, recipientName: "b",
            text: "commit before erasure", isPublic: false, outgoing: false, state: .received, date: net.time, hops: 1,
            packetDigest: try packet.digest())
        entry.secure = header
        _ = try store.accept(entry, evidence: InboxEvidence(digest: try packet.digest(), originalDeadline: packet.deadline))
        let root = store.own.directory
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        guard !FileManager.default.isWritableFile(atPath: root.path) else { throw XCTSkip("Permissions bypassed") }
        XCTAssertThrowsError(try sessions.finish(opened, kind: .message))
        XCTAssertFalse(sessions.mayAcknowledge(header))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let recovered = try sessions.completeCommittedMessages()
        XCTAssertEqual(recovered.map { $0.0.messageID }, [id])
        XCTAssertTrue(sessions.mayAcknowledge(header))
        XCTAssertTrue(try sessions.completeCommittedMessages().isEmpty)
    }
    func testEpochSendLimitDoesNotAllowKeyCounterToWrap() throws {
        let net = Network(); let (a,b) = try net.pair()
        let store = try net.store(0)
        let trust = PeerTrustBook(identity: a.identity, store: { store }); try trust.load()
        let sessions = SecureSessions(identity: a.identity, store: { store }, trust: trust); try sessions.load(now: net.time)
        var first: MeshPacket?
        for _ in 0..<256 {
            do {
                let packet = try sessions.seal(kind: .message, to: b.identity.card, cleartext: Data("test".utf8), now: net.time, id: UUID(), expiresAt: nil)
                if first == nil { first = packet }
            } catch ChannelSecurityError.pending { break }
        }
        XCTAssertThrowsError(try sessions.seal(kind: .message, to: b.identity.card, cleartext: Data(), now: net.time, id: UUID(), expiresAt: nil))
        XCTAssertNotNil(first)
        XCTAssertTrue(sessions.epochs.values.allSatisfy { $0.sendSequence <= 256 })
    }

    func testGroupSendWaitsOnlyForRecipientWithoutChannel() throws {
        let net = Network()
        let a = try net.node(0), creator = try net.node(1)
        net.connect(0,1); try net.drain()
        let group = try creator.createClosedGroup(name: "asynchronous group")
        try creator.inviteToGroup(group, peerID: a.identity.card.id); try net.drain()
        let invitation = try XCTUnwrap(a.groupInvitations.first { !$0.outgoing })
        try a.acceptGroupInvitation(invitation.id); try net.drain()
        a.endNetworking(); creator.linkClosed(id: "0")
        let c = try net.node(2); net.connect(1,2); try net.drain()
        try creator.inviteToGroup(group, peerID: c.identity.card.id); try net.drain()
        let inviteC = try XCTUnwrap(c.groupInvitations.first { !$0.outgoing })
        try c.acceptGroupInvitation(inviteC.id); try net.drain()
        XCTAssertFalse(c.channelReady(to: a.identity.card.id))
        // Human send occurs after the invitation burst, outside its admission window.
        net.time.addTimeInterval(1)
        let deadline = net.time.addingTimeInterval(MeshPacket.lifetime)
        let id = try c.sendToGroup(text: "one ready, one waiting", groupID: group); try net.drain()
        XCTAssertEqual(creator.messages.last?.id, id, creator.events.suffix(10).joined(separator: "\n"))
        XCTAssertTrue(a.messages.isEmpty)
        XCTAssertEqual(try net.store(2).secureIntents().map { $0.recipient.id }, [a.identity.card.id])
        net.connect(0,1); a.announce(); creator.announce(); c.announce(); try net.drain()
        for _ in 0..<3 {
            net.time.addTimeInterval(6)
            for node in net.nodes.values { node.tick() }
            try net.drain()
        }
        XCTAssertEqual(a.messages.last?.id, id, a.events.suffix(8).joined(separator: "\n"))
        XCTAssertTrue(try net.store(2).secureIntents().isEmpty)
        XCTAssertEqual(try net.message(id, to: 0).body.expiresAt, Int64(deadline.timeIntervalSince1970))
    }
    func testUnsealedIntentExpiresWithoutExtendingDeadline() throws {
        let net = Network(); let (a,b) = try net.pair()
        b.endNetworking(); a.linkClosed(id: "1")
        net.time.addTimeInterval(MeshPacket.lifetime + 1); a.tick()
        let id = try a.send(text: "wait for a fresh channel", to: b.identity.card.id)
        XCTAssertEqual(a.messages.last?.state, .securing)
        XCTAssertEqual(try net.store(0).secureIntents().count, 1)
        net.time.addTimeInterval(MeshPacket.lifetime + 1); a.tick()
        XCTAssertEqual(a.messages.first { $0.id == id }?.state, .failed)
        XCTAssertTrue(try net.store(0).secureIntents().isEmpty)
    }
    func testConfirmedCleanupCancelsUnsealedIntent() throws {
        let net = Network(); let (a,b) = try net.pair()
        b.endNetworking(); a.linkClosed(id: "1")
        net.time.addTimeInterval(MeshPacket.lifetime + 1); a.tick()
        _ = try a.send(text: "delete together with pending task", to: b.identity.card.id)
        let plan = try a.prepareHistoryCleanup()
        XCTAssertEqual(plan.canceledTasks, 1)
        _ = try a.applyHistoryCleanup(plan, confirmed: true)
        XCTAssertTrue(a.messages.isEmpty)
        XCTAssertTrue(try net.store(0).secureIntents().isEmpty)
    }

    func testOldCiphertextSurvivesChannelRotation() throws {
        let net = Network(); let (a,b) = try net.pair()
        let oldID = try a.send(text: "delayed old epoch", to: b.identity.card.id)
        let original = try net.message(oldID, to: 1), oldHeader = try XCTUnwrap(original.body.secure)
        net.queue.removeAll(); net.drop = { $0.body.id == oldID }
        net.time.addTimeInterval(3601)
        a.announce(); b.announce(); try net.drain()
        a.tick(); b.tick(); try net.drain()
        let freshID = try a.send(text: "fresh epoch", to: b.identity.card.id); try net.drain()
        let fresh = try net.message(freshID, to: 1)
        XCTAssertNotEqual(fresh.body.secure?.session, oldHeader.session)
        b.receive(try original.encoded(), from: "0"); try net.drain()
        XCTAssertTrue(b.messages.contains { $0.id == oldID })
        XCTAssertEqual(a.messages.first { $0.id == oldID }?.state, .delivered)
    }

    func testSessionsDoNotTransferToDifferentLocalAgreementKey() throws {
        let net = Network(); let (a,b) = try net.pair()
        let store = try net.store(0)
        let changed = try MeshIdentity(name: "changed local key", signingKey: a.identity.signingKeyData)
        let trust = PeerTrustBook(identity: changed, store: { store }); try trust.load()
        let sessions = SecureSessions(identity: changed, store: { store }, trust: trust)
        try sessions.load(now: net.time)
        XCTAssertNil(sessions.active(for: b.identity.card, now: net.time))
        XCTAssertTrue(sessions.epochs.isEmpty)
    }

}
