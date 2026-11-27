import XCTest
@testable import NearChatCore

final class UnreadTests: XCTestCase {
    func testIncomingCountPersistsAndReadDoesNotAffectOutgoingMessages() throws {
        let net = PersistentMeshTests.Network()
        let a = try net.node(0), b = try net.node(1)
        net.connect(0, 1); try net.drain()
        let id = try a.send(text: "unread", to: b.identity.card.id); try net.drain()
        XCTAssertEqual(a.unreadCount, 0)
        XCTAssertEqual(b.unreadCount, 1)
        let restored = try net.node(1)
        XCTAssertEqual(restored.unreadCount, 1)
        restored.markRead(id)
        XCTAssertEqual(restored.unreadCount, 0)
        XCTAssertEqual(try net.node(1).unreadCount, 0)
    }
    func testDuplicatePacketDoesNotIncreaseUnreadCountAndOnlyViewedMessageIsCleared() throws {
        let net = PersistentMeshTests.Network()
        let a = try net.node(0), b = try net.node(1)
        net.connect(0, 1); try net.drain()
        let first = try a.send(text: "first", to: b.identity.card.id)
        _ = try a.send(text: "second", to: b.identity.card.id); try net.drain()
        let packet = try XCTUnwrap(net.captured.first { (try? MeshPacket.decode($0.2, now: net.time).body.id) == first })
        b.receive(packet.2, from: "0"); try net.drain()
        XCTAssertEqual(b.unreadCount, 2)
        b.markRead(first)
        XCTAssertEqual(b.unreadCount, 1)
        XCTAssertEqual(try net.node(1).unreadCount, 1)
    }
    func testRAMUnreadIsKeptWhenStorageRecoversAndReadCanClearIt() throws {
        let net = PersistentMeshTests.Network()
        let a = try net.node(0), b = try net.node(1, persistent: false)
        net.connect(0, 1); try net.drain()
        let first = try a.send(text: "first", to: b.identity.card.id)
        let second = try a.send(text: "second", to: b.identity.card.id); try net.drain()
        XCTAssertEqual(b.unreadCount, 2)
        b.markRead(first)
        XCTAssertEqual(b.unreadCount, 1)
        let store = try MeshStore(directory: net.root.appendingPathComponent("recovered-unread"), identity: b.identity)
        b.onRecoverStorage = { store }; b.tick()
        XCTAssertEqual(b.unreadCount, 1)
        let reopened = try MeshEngine(identity: b.identity, store: store, enforceContactConsent: false, clock: { net.time })
        XCTAssertEqual(reopened.unreadCount, 1)
        reopened.markRead(second)
        XCTAssertEqual(reopened.unreadCount, 0)
    }
    func testUnreadOutsideFirstHistoryPageIsStillCounted() throws {
        let net = PersistentMeshTests.Network()
        let owner = try MeshIdentity(name: "owner"), sender = try MeshIdentity(name: "sender")
        let store = try MeshStore(directory: net.root, identity: owner)
        var entries: [ChatEntry] = []
        try store.own.transaction {
            for index in 0..<205 {
                let entry = ChatEntry(id: UUID(), sender: sender.card, recipient: owner.card.id, recipientName: owner.name,
                    text: "message \(index)", isPublic: false, outgoing: false, state: .received, date: net.time, hops: 1,
                    packetDigest: Data(repeating: UInt8(index % 255), count: 32), readAt: index == 0 ? nil : net.time)
                entries.append(entry)
                try store.own.put(space: "history", id: entry.id.uuidString, value: entry)
            }
        }
        let indexed = try MeshStore(directory: net.root, identity: owner)
        let engine = try MeshEngine(identity: owner, store: indexed, enforceContactConsent: false, clock: { net.time })
        XCTAssertEqual(engine.messages.count, 200)
        XCTAssertEqual(engine.unreadCount, 1)
        XCTAssertFalse(engine.messages.contains { $0.id == entries[0].id })
        engine.loadEarlierMessages()
        engine.markRead(entries[0].id)
        XCTAssertEqual(engine.unreadCount, 0)
    }
    func testFIFORemovesUnreadFromCounterWithoutRecreatingIt() throws {
        let net = PersistentMeshTests.Network()
        let owner = try MeshIdentity(name: "owner"), sender = try MeshIdentity(name: "sender")
        let store = try MeshStore(directory: net.root, identity: owner,
            limits: MeshStorageLimits(historyBytes: 131_072, relayBytes: 5_000_000))
        var ids: [UUID] = []
        for index in 0..<45 {
            let id = UUID(), digest = Data(repeating: UInt8(index), count: 32)
            let entry = ChatEntry(id: id, sender: sender.card, recipient: owner.card.id, recipientName: owner.name,
                text: String(repeating: "я", count: 1000), isPublic: false, outgoing: false, state: .received,
                date: net.time, hops: 1, packetDigest: digest)
            _ = try store.accept(entry, evidence: InboxEvidence(digest: digest, originalDeadline: net.time.addingTimeInterval(86400)))
            ids.append(id)
        }
        let remaining = try store.history().map(\.id)
        XCTAssertLessThan(remaining.count, ids.count)
        XCTAssertEqual(store.unreadMessageIDs, Set(remaining))
        let engine = try MeshEngine(identity: owner, store: store, enforceContactConsent: false, clock: { net.time })
        XCTAssertEqual(engine.unreadCount, remaining.count)
        let reopened = try MeshStore(directory: net.root, identity: owner,
            limits: MeshStorageLimits(historyBytes: 131_072, relayBytes: 5_000_000))
        XCTAssertEqual(reopened.unreadMessageIDs, Set(remaining))
    }
    func testConfirmedQuotaCleanupRemovesUnreadButPreviewDoesNot() throws {
        let net = PersistentMeshTests.Network()
        let owner = try MeshIdentity(name: "owner"), sender = try MeshIdentity(name: "sender")
        let store = try MeshStore(directory: net.root, identity: owner,
            limits: MeshStorageLimits(historyBytes: 4_000_000, relayBytes: 5_000_000))
        for index in 0..<180 {
            let digest = Data(repeating: UInt8(index), count: 32)
            let entry = ChatEntry(id: UUID(), sender: sender.card, recipient: owner.card.id, recipientName: owner.name,
                text: String(repeating: "😀", count: 1000), isPublic: false, outgoing: false, state: .received,
                date: net.time, hops: 1, packetDigest: digest)
            _ = try store.accept(entry, evidence: InboxEvidence(digest: digest, originalDeadline: net.time.addingTimeInterval(86400)))
        }
        XCTAssertEqual(store.unreadMessageIDs.count, 180)
        let plan = try store.prepareResize(.history, to: 1_000_000, now: net.time)
        XCTAssertGreaterThan(plan.removedMessages, 0)
        XCTAssertEqual(store.unreadMessageIDs.count, 180)
        _ = try store.applyResize(plan, confirmed: true, now: net.time)
        XCTAssertEqual(store.unreadMessageIDs.count, 180 - plan.removedMessages)
    }
    func testLegacyHistoryDoesNotBecomeUnreadRetroactively() throws {
        let net = PersistentMeshTests.Network()
        let owner = try MeshIdentity(name: "owner"), sender = try MeshIdentity(name: "sender")
        let store = try MeshStore(directory: net.root, identity: owner)
        let old = ChatEntry(id: UUID(), sender: sender.card, recipient: owner.card.id, recipientName: owner.name,
            text: "legacy", isPublic: false, outgoing: false, state: .received, date: net.time, hops: 1)
        try store.importLegacy([old])
        let reopened = try MeshStore(directory: net.root, identity: owner)
        let engine = try MeshEngine(identity: owner, store: reopened, enforceContactConsent: false, clock: { net.time })
        XCTAssertEqual(engine.messages.count, 1)
        XCTAssertEqual(engine.unreadCount, 0)
    }
    func testReadCounterClearsDuringDiskFailureAndPersistsAfterRecovery() throws {
        let net = PersistentMeshTests.Network()
        let a = try net.node(0), b = try net.node(1)
        net.connect(0, 1); try net.drain()
        let id = try a.send(text: "read during failure", to: b.identity.card.id); try net.drain()
        let directory = net.root.appendingPathComponent("1")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        guard !FileManager.default.isWritableFile(atPath: directory.path) else { throw XCTSkip("Permissions bypassed") }
        b.markRead(id)
        XCTAssertEqual(b.unreadCount, 0)
        XCTAssertNotNil(b.storageWarning)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        b.tick()
        XCTAssertEqual(b.unreadCount, 0)
        XCTAssertEqual(try net.node(1).unreadCount, 0)
    }

}
