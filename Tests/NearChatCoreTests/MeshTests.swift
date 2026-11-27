import XCTest
import CryptoKit
@testable import NearChatCore

final class MeshTests: XCTestCase {
    final class Network {
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        var nodes: [MeshEngine] = []
        var queue: [(Int, Int, String, Data)] = []
        var captured: [Data] = []
        func node(_ name: String) throws -> MeshEngine {
            let engine = MeshEngine(identity: try MeshIdentity(name: name), enforceContactConsent: false, clock: { [unowned self] in self.time })
            engine.receiveUptime = { [unowned self] in self.time.timeIntervalSince1970 }
            nodes.append(engine); return engine
        }
        func connect(_ a: Int, _ b: Int) {
            for i in [a, b] {
                nodes[i].onTransmit = { [unowned self] link, data in
                    guard let target = Int(link) else { return }
                    self.captured.append(data)
                    self.queue.append((i, target, String(i), data))
                }
            }
            nodes[a].linkOpened(id: String(b), transport: "test")
            nodes[b].linkOpened(id: String(a), transport: "test")
        }
        func drain() {
            var budget = 10_000
            while !queue.isEmpty && budget > 0 {
                let item = queue.removeFirst(); budget -= 1
                nodes[item.1].receive(item.3, from: item.2)
            }
            XCTAssertGreaterThan(budget, 0, "Forwarding loop")
        }
    }
    func testEncryptedMultiHopDiscoveryDeliveryAndReceipt() throws {
        let net = Network()
        let a = try net.node("А"), b = try net.node("Б"), c = try net.node("В")
        net.connect(0, 1); net.connect(1, 2); net.drain()
        a.announce(); b.announce(); c.announce(); net.drain()
        XCTAssertEqual(a.peers[c.identity.card.id]?.hops, 2)
        let id = try a.send(text: "секретный текст", to: c.identity.card.id)
        net.drain()
        XCTAssertEqual(c.messages.last?.text, "секретный текст")
        XCTAssertEqual(c.messages.last?.hops, 2)
        XCTAssertTrue(b.messages.isEmpty, "Relay must not deliver the private message to itself")
        XCTAssertEqual(a.messages.first(where: { $0.id == id })?.state, .delivered)
        let wire = try XCTUnwrap(net.captured.compactMap { try? MeshPacket.decode($0, now: net.time) }
            .first(where: { $0.body.id == id }))
        XCTAssertThrowsError(try wire.decrypted(using: b.identity))
        XCTAssertFalse(String(data: try wire.encoded(), encoding: .utf8)!.contains("секретный"))
    }
    func testDuplicateAndCycleDoNotDuplicateMessages() throws {
        let net = Network(); let a = try net.node("A"), _ = try net.node("B"), c = try net.node("C")
        net.connect(0, 1); net.connect(1, 2); net.connect(0, 2); net.drain()
        a.announce(); c.announce(); net.drain()
        let id = try a.send(text: "one", to: c.identity.card.id); net.drain()
        let data = try XCTUnwrap(net.captured.first { (try? MeshPacket.decode($0, now: net.time).body.id) == id })
        c.receive(data, from: "0"); net.drain()
        XCTAssertEqual(c.messages.filter { $0.id == id }.count, 1)
        XCTAssertGreaterThan(net.nodes.map(\.counters.duplicates).reduce(0, +), 0)
    }
    func testRouteExpiresAndPendingDeliveryTimesOut() throws {
        let net = Network(); let a = try net.node("A"), _ = try net.node("B"), c = try net.node("C")
        net.connect(0, 1); net.connect(1, 2); net.drain(); c.announce(); net.drain()
        net.nodes[1].onTransmit = nil
        let id = try a.send(text: "offline", to: c.identity.card.id); net.drain()
        net.time.addTimeInterval(21); a.tick()
        XCTAssertNil(a.peers[c.identity.card.id])
        XCTAssertEqual(a.messages.first { $0.id == id }?.state, .sent)
        XCTAssertNoThrow(try a.send(text: "again", to: c.identity.card.id))
        net.time.addTimeInterval(MeshPacket.lifetime); a.tick()
        XCTAssertEqual(a.messages.first { $0.id == id }?.state, .failed)
    }
    func testExcludedDirectEdgeStillAllowsRelayPath() throws {
        let net = Network(); let a = try net.node("A"), b = try net.node("B"), c = try net.node("C")
        net.connect(0, 1); net.connect(1, 2); net.connect(0, 2); net.drain()
        a.excludeDirectPeer(c.identity.card.id, excluded: true)
        c.excludeDirectPeer(a.identity.card.id, excluded: true)
        a.announce(); b.announce(); c.announce(); net.drain()
        XCTAssertEqual(a.peers[c.identity.card.id]?.hops, 2)
        try a.send(text: "via B", to: c.identity.card.id); net.drain()
        XCTAssertEqual(c.messages.last?.hops, 2)
        XCTAssertEqual(a.messages.last?.state, .delivered)
    }
    func testTamperedSignatureAndExpiredPacketsRejected() throws {
        let identity = try MeshIdentity(name: "A")
        let now = Date()
        let packet = try MeshPacket.make(identity: identity, kind: .presence, now: now)
        XCTAssertThrowsError(try MeshPacket.decode(packet.encoded(), now: now.addingTimeInterval(31)))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: packet.encoded()) as? [String: Any])
        var body = object["body"] as! [String: Any]
        body["hopLimit"] = 6; object["body"] = body
        XCTAssertThrowsError(try MeshPacket.decode(JSONSerialization.data(withJSONObject: object), now: now))
        let badHops = MeshPacket(body: packet.body, signature: packet.signature, remainingHops: 257)
        XCTAssertThrowsError(try badHops.validate(now: now))
    }
    func testHopBudgetStopsForwarding() throws {
        let net = Network(); let a = try net.node("A"), _ = try net.node("B"), c = try net.node("C")
        net.connect(0, 1); net.connect(1, 2); net.drain()
        let packet = try MeshPacket.make(identity: a.identity, kind: .message, recipient: c.identity.card,
            cleartext: JSONEncoder().encode(ChatPayload(text: "stop", isPublic: false)), now: net.time, hops: 1)
        net.nodes[1].receive(try packet.encoded(), from: "0"); net.drain()
        XCTAssertTrue(c.messages.isEmpty)
    }
    func testStreamingFramesAndInvalidLengths() throws {
        var decoder = FrameDecoder()
        let first = Data("hello".utf8), second = Data(repeating: 7, count: 500)
        let wire = FrameDecoder.frame(first) + FrameDecoder.frame(second)
        var result: [Data] = []
        for b in wire { result += try decoder.append(Data([b])) }
        XCTAssertEqual(result, [first, second])
        XCTAssertThrowsError(try decoder.append(Data([255, 255, 255, 255])))
    }
    func testRelayCannotForgeRecipientReceipt() throws {
        let net = Network(); let a = try net.node("A"), b = try net.node("B"), c = try net.node("C")
        net.connect(0, 1); net.connect(1, 2); net.drain(); c.announce(); net.drain()
        let id = try a.send(text: "private", to: c.identity.card.id)
        let forged = try MeshPacket.make(identity: b.identity, kind: .receipt, recipient: a.identity.card,
            cleartext: Data(id.uuidString.utf8), now: net.time)
        a.receive(try forged.encoded(), from: "1")
        XCTAssertEqual(a.messages.last?.state, .sent)
        XCTAssertGreaterThan(a.counters.rejected, 0)
        net.drain()
        XCTAssertEqual(a.messages.last?.state, .delivered)
    }
    func testLateReceiptUpdatesTimedOutMessage() throws {
        let net = Network(); let a = try net.node("A"), _ = try net.node("B"), c = try net.node("C")
        net.connect(0, 1); net.connect(1, 2); net.drain(); c.announce(); net.drain()
        let id = try a.send(text: "delayed", to: c.identity.card.id)
        let original = try XCTUnwrap(net.captured.compactMap { try? MeshPacket.decode($0, now: net.time) }
            .first { $0.body.id == id })
        net.queue.removeAll()
        net.time.addTimeInterval(MeshPacket.lifetime + 1); a.tick()
        XCTAssertEqual(a.messages.last?.state, .failed)
        let receipt = try MeshPacket.make(identity: c.identity, kind: .receipt, recipient: a.identity.card,
            cleartext: JSONEncoder().encode(FinalReceipt(messageID: id, recipientID: c.identity.card.id,
                digest: original.digest(), kind: .delivered)), now: net.time)
        a.receive(try receipt.encoded(), from: "1")
        XCTAssertEqual(a.messages.last?.state, .delivered)
    }
    func testUnicodeLimitsAndKeyPersistence() throws {
        try ChatPayload.validate(String(repeating: "я", count: 1000))
        XCTAssertThrowsError(try ChatPayload.validate(String(repeating: "x", count: 1001)))
        XCTAssertThrowsError(try ChatPayload.validate(String(repeating: "👨‍👩‍👧‍👦", count: 200)))
        let a = try MeshIdentity(name: "A")
        let restored = try MeshIdentity(name: "renamed", signingKey: a.signingKeyData, agreementKey: a.agreementKeyData)
        XCTAssertEqual(a.card.id, restored.card.id)
        XCTAssertEqual(a.card.agreementKey, restored.card.agreementKey)
    }
}
