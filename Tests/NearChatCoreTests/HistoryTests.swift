import XCTest
@testable import NearChatCore

/// Added for the persistence change. Execution explicitly deferred by the user on 2026-11-25.
final class HistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func entry(owner: MeshIdentity, peer: MeshIdentity, outgoing: Bool = false,
                       state: DeliveryState = .received) -> ChatEntry {
        ChatEntry(id: UUID(), sender: outgoing ? owner.card : peer.card,
            recipient: outgoing ? peer.card.id : owner.card.id,
            recipientName: outgoing ? peer.card.name : owner.card.name,
            text: "История должна пережить перезапуск — секретный текст",
            isPublic: false, outgoing: outgoing, state: state, date: now, hops: outgoing ? 0 : 2)
    }
    func testEncryptedHistoryRoundTripWithPersistedIdentity() throws {
        let owner = try MeshIdentity(name: "А"), peer = try MeshIdentity(name: "Б")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sealed")
        let entries = [entry(owner: owner, peer: peer), entry(owner: owner, peer: peer, outgoing: true, state: .delivered)]
        try HistoryStore(fileURL: url, identity: owner).save(entries)
        let disk = try Data(contentsOf: url)
        XCTAssertNil(disk.range(of: Data(entries[0].text.utf8)))
        let restored = try MeshIdentity(name: "А", signingKey: owner.signingKeyData, agreementKey: owner.agreementKeyData)
        XCTAssertEqual(try HistoryStore(fileURL: url, identity: restored).load(), entries)
        XCTAssertEqual(try HistoryStore(fileURL: url, identity: restored).load().last?.recipientName, "Б")
        XCTAssertThrowsError(try HistoryStore(fileURL: url, identity: peer).load())
    }
    func testMissingAndCorruptArchivesDoNotEraseExistingFile() throws {
        let owner = try MeshIdentity(name: "А")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sealed")
        let store = HistoryStore(fileURL: url, identity: owner)
        XCTAssertTrue(try store.load().isEmpty)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corrupt = Data("incomplete archive".utf8)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }
    func testHistoryBoundAndUnconfirmedSendsAfterRestart() throws {
        let owner = try MeshIdentity(name: "А"), peer = try MeshIdentity(name: "Б")
        let entries = (0..<(MeshEngine.historyLimit + 1)).map { _ in
            entry(owner: owner, peer: peer, outgoing: true, state: .sent)
        }
        let restored = MeshEngine(identity: owner, history: entries, enforceContactConsent: false, clock: { self.now })
        XCTAssertEqual(restored.messages.count, MeshEngine.historyLimit)
        XCTAssertEqual(restored.messages.first?.id, entries[1].id)
        XCTAssertTrue(restored.messages.allSatisfy { $0.state == .failed })
        XCTAssertTrue(restored.peers.isEmpty)
        XCTAssertTrue(restored.links.isEmpty)
    }
    func testRecentlyReceivedPacketIsNotDuplicatedAfterRestart() throws {
        let owner = try MeshIdentity(name: "А"), peer = try MeshIdentity(name: "Б")
        let text = "received before restart"
        let packet = try MeshPacket.make(identity: peer, kind: .message, recipient: owner.card,
            cleartext: JSONEncoder().encode(ChatPayload(text: text, isPublic: false)), now: now)
        let message = ChatEntry(id: packet.body.id, sender: peer.card, recipient: owner.card.id,
            recipientName: owner.card.name, text: text, isPublic: false, outgoing: false,
            state: .received, date: now, hops: 1)
        let restored = MeshEngine(identity: owner, history: [message], enforceContactConsent: false, clock: { self.now })
        restored.linkOpened(id: "peer", transport: "test")
        let presence = try MeshPacket.make(identity: peer, kind: .presence, cleartext: JSONEncoder().encode(PresenceInfo(sessionID: UUID())), now: now)
        restored.receive(try presence.encoded(), from: "peer")
        restored.receive(try packet.encoded(), from: "peer")
        XCTAssertEqual(restored.messages.count, 1)
        XCTAssertEqual(restored.counters.duplicates, 1)
    }
}
