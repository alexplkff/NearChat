import XCTest
@testable import NearChatCore

final class ConversationTests: XCTestCase {
    private let net = PersistentMeshTests.Network()
    private func entry(owner: MeshIdentity, sender: MeshIdentity, text: String, outgoing: Bool = false, publicChat: Bool = false) -> ChatEntry {
        ChatEntry(id: UUID(), sender: outgoing ? owner.card : sender.card,
            recipient: outgoing ? sender.card.id : owner.card.id, recipientName: outgoing ? sender.name : owner.name,
            text: text, isPublic: publicChat, outgoing: outgoing, state: outgoing ? .queued : .received,
            date: net.time, hops: 1, packetDigest: Data(repeating: 3, count: 32))
    }
    func testOldConversationOutsideGlobalPageOpensAtItsOwnLatestPage() throws {
        let owner = try MeshIdentity(name: "owner"), old = try MeshIdentity(name: "same"), recent = try MeshIdentity(name: "same")
        let store = try MeshStore(directory: net.root, identity: owner)
        var older: [ChatEntry] = []
        try store.own.transaction {
            for index in 0..<205 {
                let value = entry(owner: owner, sender: old, text: "old \(index)")
                older.append(value); try store.own.put(space: "history", id: value.id.uuidString, value: value)
            }
            for index in 0..<205 {
                let value = entry(owner: owner, sender: recent, text: "recent \(index)")
                try store.own.put(space: "history", id: value.id.uuidString, value: value)
            }
        }
        let restored = try MeshStore(directory: net.root, identity: owner)
        let engine = try MeshEngine(identity: owner, store: restored, enforceContactConsent: false, clock: { self.net.time })
        XCTAssertTrue(engine.messages.allSatisfy { $0.sender.id == recent.card.id })
        XCTAssertEqual(engine.conversations.count, 2)
        XCTAssertEqual(engine.conversations.first { $0.id == old.card.id }?.unreadCount, 205)
        engine.openConversation(old.card.id)
        XCTAssertEqual(engine.messages.map(\.id), Array(older.suffix(200)).map(\.id))
        engine.loadEarlierMessages()
        XCTAssertEqual(engine.messages.map(\.id), older.map(\.id))
        engine.openConversation(recent.card.id)
        XCTAssertEqual(engine.messages.count, 200)
        XCTAssertTrue(engine.messages.allSatisfy { $0.sender.id == recent.card.id })
    }
    func testReadingChangesUnreadWithoutReorderingChats() throws {
        let a = try net.node(0), b = try net.node(1)
        net.connect(0, 1); try net.drain()
        let first = try a.send(text: "private", to: b.identity.card.id); try net.drain()
        _ = try a.broadcast(text: "common"); try net.drain()
        let order = b.conversations.map(\.id)
        XCTAssertEqual(b.conversations.map(\.unreadCount).reduce(0, +), 2)
        b.openConversation(a.identity.card.id); b.markRead(first); try net.drain()
        XCTAssertEqual(b.conversations.map(\.id), order)
        XCTAssertEqual(b.conversations.first { $0.id == a.identity.card.id }?.unreadCount, 0)
        XCTAssertEqual(b.conversations.first { $0.id == "*" }?.unreadCount, 1)
        XCTAssertEqual(a.conversations.first { $0.id == b.identity.card.id }?.lastMessage.state, .read)
        XCTAssertEqual(try net.node(1).conversations.map(\.id), order)
    }
    func testRemovedLatestFallsBackAndEmptyChatDisappears() throws {
        let owner = try MeshIdentity(name: "owner"), peer = try MeshIdentity(name: "peer")
        let store = try MeshStore(directory: net.root, identity: owner)
        let first = entry(owner: owner, sender: peer, text: "first"), last = entry(owner: owner, sender: peer, text: "last")
        try store.importLegacy([first, last])
        XCTAssertEqual(try store.conversationSummaries().first?.lastMessage.id, last.id)
        try store.own.transaction { try store.own.remove(space: "history", id: last.id.uuidString) }
        XCTAssertEqual(try store.conversationSummaries().first?.lastMessage.id, first.id)
        XCTAssertEqual(try store.conversationSummaries().first?.messageCount, 1)
        try store.own.transaction { try store.own.remove(space: "history", id: first.id.uuidString) }
        XCTAssertTrue(try store.conversationSummaries().isEmpty)
    }
    func testAbortedWriteDoesNotCreateConversationOrLosePreviousOne() throws {
        let owner = try MeshIdentity(name: "owner"), peer = try MeshIdentity(name: "peer"), other = try MeshIdentity(name: "other")
        let store = try MeshStore(directory: net.root, identity: owner)
        let original = entry(owner: owner, sender: peer, text: "committed")
        try store.importLegacy([original]); _ = try store.conversationSummaries()
        enum Abort: Error { case requested }
        XCTAssertThrowsError(try store.own.transaction {
            try store.own.remove(space: "history", id: original.id.uuidString)
            let phantom = entry(owner: owner, sender: other, text: "rollback")
            try store.own.put(space: "history", id: phantom.id.uuidString, value: phantom)
            throw Abort.requested
        })
        XCTAssertEqual(try store.conversationSummaries().map(\.id), [peer.card.id])
        XCTAssertEqual(try store.history(conversationID: peer.card.id).map(\.id), [original.id])
    }
    func testRAMConversationSummarySurvivesReadAndRecovery() throws {
        let a = try net.node(0), b = try net.node(1, persistent: false)
        net.connect(0, 1); try net.drain()
        let id = try a.send(text: "RAM", to: b.identity.card.id); try net.drain()
        XCTAssertEqual(b.conversations.first?.unreadCount, 1)
        b.openConversation(a.identity.card.id); b.markRead(id)
        XCTAssertEqual(b.conversations.first?.unreadCount, 0)
        let store = try MeshStore(directory: net.root.appendingPathComponent("recovered"), identity: b.identity)
        b.onRecoverStorage = { store }; b.tick()
        XCTAssertEqual(b.conversations.first?.messageCount, 1)
        XCTAssertEqual(b.conversations.first?.unreadCount, 0)
        XCTAssertEqual(b.conversations.first?.lastMessage.id, id)
    }
    func testConfirmedCleanupRefreshesSummariesAndUnread() throws {
        let owner = try MeshIdentity(name: "owner"), peer = try MeshIdentity(name: "peer")
        let store = try MeshStore(directory: net.root, identity: owner)
        try store.importLegacy((0..<5).map { entry(owner: owner, sender: peer, text: "message \($0)") })
        XCTAssertEqual(try store.conversationSummaries().first?.messageCount, 5)
        let plan = try store.prepareHistoryCleanup()
        _ = try store.applyHistoryCleanup(plan, confirmed: true)
        XCTAssertTrue(try store.conversationSummaries().isEmpty)
    }
    func testResizeRefreshesIndexAfterArchiveReplacement() throws {
        let owner = try MeshIdentity(name: "owner"), peer = try MeshIdentity(name: "peer")
        let store = try MeshStore(directory: net.root, identity: owner, limits: MeshStorageLimits(historyBytes: 4_000_000, relayBytes: 5_000_000))
        for index in 0..<180 {
            let value = entry(owner: owner, sender: peer, text: String(repeating: "😀", count: 1000))
            _ = try store.accept(value, evidence: InboxEvidence(digest: value.packetDigest!, originalDeadline: net.time.addingTimeInterval(86400)))
            if index == 0 { XCTAssertEqual(try store.conversationSummaries().first?.messageCount, 1) }
        }
        XCTAssertEqual(try store.conversationSummaries().first?.messageCount, 180)
        let plan = try store.prepareResize(.history, to: 1_000_000, now: net.time)
        _ = try store.applyResize(plan, confirmed: true, now: net.time)
        let summary = try XCTUnwrap(store.conversationSummaries().first)
        XCTAssertEqual(summary.messageCount, 180 - plan.removedMessages)
        XCTAssertEqual(summary.unreadCount, summary.messageCount)
        XCTAssertEqual(try store.history(conversationID: peer.card.id, limit: 1000).count, summary.messageCount)
    }
}
