import XCTest
import CryptoKit
@testable import NearChatCore

final class SecurityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func presence(_ identity: MeshIdentity, at date: Date, session: UUID = UUID()) throws -> MeshPacket {
        try MeshPacket.make(identity: identity, kind: .presence,
            cleartext: JSONEncoder().encode(PresenceInfo(sessionID: session)), now: date)
    }
    func testMalformedSignedPresenceCannotBindLinkOrCreateRoute() throws {
        let engine = MeshEngine(identity: try MeshIdentity(name: "receiver"), clock: { self.now })
        let sender = try MeshIdentity(name: "sender")
        engine.linkOpened(id: "link", transport: "test")
        let malformed = try MeshPacket.make(identity: sender, kind: .presence, cleartext: Data("{}".utf8), now: now)
        engine.receive(try malformed.encoded(), from: "link")
        XCTAssertNil(engine.links["link"]?.peerID)
        XCTAssertTrue(engine.peers.isEmpty)
        XCTAssertEqual(engine.counters.rejected, 1)
        engine.receive(try presence(sender, at: now).encoded(), from: "link")
        XCTAssertEqual(engine.links["link"]?.peerID, sender.card.id)
    }
    func testOlderSignedPresenceDoesNotReplaceNewerSession() throws {
        let engine = MeshEngine(identity: try MeshIdentity(name: "receiver"), clock: { self.now })
        let sender = try MeshIdentity(name: "sender"), session = UUID()
        engine.linkOpened(id: "link", transport: "test")
        engine.receive(try presence(sender, at: now, session: session).encoded(), from: "link")
        engine.receive(try presence(sender, at: now.addingTimeInterval(-5)).encoded(), from: "link")
        XCTAssertEqual(engine.peers[sender.card.id]?.sessionID, session)
        XCTAssertEqual(engine.peers[sender.card.id]?.lastSeen, now)
    }
    func testRelayAndUnrelatedRecipientCannotDecryptText() throws {
        let sender = try MeshIdentity(name: "sender"), receiver = try MeshIdentity(name: "receiver"), relay = try MeshIdentity(name: "relay")
        let text = Data("Private text \(UUID())".utf8)
        let packet = try MeshPacket.make(identity: sender, kind: .message, recipient: receiver.card, cleartext: text, now: now)
        XCTAssertEqual(try packet.decrypted(using: receiver), text)
        XCTAssertThrowsError(try packet.decrypted(using: relay))
        XCTAssertFalse(try packet.encoded().contains(text))
        let fakeRecipient = try MeshIdentity(name: "other keys", signingKey: receiver.signingKeyData)
        XCTAssertThrowsError(try packet.decrypted(using: fakeRecipient))
    }
    func testValidSenderSignatureDoesNotMakeCorruptCiphertextDecryptable() throws {
        let sender = try MeshIdentity(name: "sender"), receiver = try MeshIdentity(name: "receiver")
        let packet = try MeshPacket.make(identity: sender, kind: .message, recipient: receiver.card, cleartext: Data("secret".utf8), now: now)
        var payload = packet.body.payload; payload[payload.count - 1] ^= 1
        let body = PacketBody(version: 2, id: packet.body.id, kind: .message, sender: sender.card,
            recipient: receiver.card.id, createdAt: packet.body.createdAt, expiresAt: packet.body.expiresAt,
            hopLimit: 256, payload: payload)
        var corrupt = MeshPacket(body: body, signature: try sender.signing.signature(for: MeshPacket.encoder.encode(body)), remainingHops: 256)
        try corrupt.offerCustody(by: sender)
        XCTAssertNoThrow(try MeshPacket.decode(corrupt.encoded(), now: now))
        XCTAssertThrowsError(try corrupt.decrypted(using: receiver))
    }
    func testSignedPacketCannotSwapRecipientOrCustodyDigest() throws {
        let a = try MeshIdentity(name: "a"), b = try MeshIdentity(name: "b"), c = try MeshIdentity(name: "c")
        let packet = try MeshPacket.make(identity: a, kind: .message, recipient: b.card, cleartext: Data("text".utf8), now: now)
        let changed = PacketBody(version: 2, id: packet.body.id, kind: .message, sender: a.card,
            recipient: c.card.id, createdAt: packet.body.createdAt, expiresAt: packet.body.expiresAt, hopLimit: 256, payload: packet.body.payload)
        XCTAssertThrowsError(try MeshPacket(body: changed, signature: packet.signature, remainingHops: 256, offer: packet.offer).validate(now: now))
        var other = try MeshPacket.make(identity: a, kind: .message, recipient: b.card, cleartext: Data("other".utf8), now: now)
        other.offer = packet.offer
        XCTAssertThrowsError(try other.validate(now: now))
    }
    func testCiphertextTamperNeverBecomesDeliveredOrEntersHistory() throws {
        let net = PersistentMeshTests.Network()
        let sender = try net.node(0), receiver = try net.node(1)
        net.connect(0, 1); try net.drain()
        let before = receiver.counters.rejected
        let original = try MeshPacket.make(identity: sender.identity, kind: .message, recipient: receiver.identity.card,
            cleartext: JSONEncoder().encode(ChatPayload(text: "tamper", isPublic: false)), now: net.time)
        var bodyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: original.encoded()) as? [String: Any])
        var body = try XCTUnwrap(bodyJSON["body"] as? [String: Any])
        body["payload"] = Data(repeating: 1, count: 64).base64EncodedString(); bodyJSON["body"] = body
        receiver.receive(try JSONSerialization.data(withJSONObject: bodyJSON), from: "0")
        try net.drain()
        XCTAssertTrue(receiver.messages.isEmpty)
        XCTAssertGreaterThan(receiver.counters.rejected, before)
        XCTAssertTrue(try net.node(1).messages.isEmpty)
    }
    func testSignedMalformedHeadersAreRejected() throws {
        let sender = try MeshIdentity(name: "sender"), recipient = try MeshIdentity(name: "recipient")
        let invalid = PeerCard(id: String(repeating: "z", count: 64), name: recipient.name,
            signingKey: recipient.card.signingKey, agreementKey: recipient.card.agreementKey)
        let wrongID = try MeshPacket.make(identity: sender, kind: .message, recipient: invalid, cleartext: Data([1]), now: now)
        XCTAssertThrowsError(try wrongID.validate(now: now))
        func signed(_ kind: PacketKind, payload: Data, lifetime: Int64) throws -> MeshPacket {
            let time = Int64(now.timeIntervalSince1970)
            let body = PacketBody(version: 2, id: UUID(), kind: kind, sender: sender.card,
                recipient: recipient.card.id, createdAt: time, expiresAt: time + lifetime, hopLimit: 256, payload: payload)
            var packet = MeshPacket(body: body, signature: try sender.signing.signature(for: MeshPacket.encoder.encode(body)), remainingHops: 256)
            if kind != .control { try packet.offerCustody(by: sender) }
            return packet
        }
        XCTAssertThrowsError(try signed(.message, payload: Data([1]), lifetime: 86400).validate(now: now))
        XCTAssertThrowsError(try signed(.control, payload: Data(repeating: 0, count: 28), lifetime: 86400).validate(now: now))
        XCTAssertNoThrow(try signed(.control, payload: Data(repeating: 0, count: 28), lifetime: 30).validate(now: now))
    }
    func testPresenceCapabilityAndGroupListsAreBounded() throws {
        let identity = try MeshIdentity(name: "peer")
        func packet(capabilities: Int, groups: Int) throws -> MeshPacket {
            try MeshPacket.make(identity: identity, kind: .presence,
                cleartext: JSONEncoder().encode(PresenceInfo(sessionID: UUID(), capabilities: Array(repeating: "x", count: capabilities),
                    groups: (0..<groups).map { _ in UUID() })), now: now)
        }
        XCTAssertThrowsError(try packet(capabilities: 17, groups: 0).validate(now: now))
        XCTAssertThrowsError(try packet(capabilities: 0, groups: 17).validate(now: now))
        XCTAssertNoThrow(try packet(capabilities: 16, groups: 16).validate(now: now))
    }

}
