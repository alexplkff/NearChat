import XCTest
@testable import NearChatCore

final class StorageResizeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var roots: [URL] = []
    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }
    private func root() -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(value); return value
    }
    private func populate(_ store: MeshStore, owner: MeshIdentity, recipient: MeshIdentity, count: Int) throws -> [UUID] {
        var ids: [UUID] = []
        for _ in 0..<count {
            let text = String(repeating: "😀", count: 1000)
            let packet = try MeshPacket.make(identity: owner, kind: .message, recipient: recipient.card,
                cleartext: JSONEncoder().encode(ChatPayload(text: text, isPublic: false)), now: now)
            let entry = ChatEntry(id: packet.body.id, sender: owner.card, recipient: recipient.card.id,
                recipientName: recipient.name, text: text, isPublic: false, outgoing: true,
                state: .queued, date: now, hops: 0)
            try store.enqueue(entry, packets: [(packet,recipient.card)])
            ids.append(entry.id)
        }
        return ids
    }
    func testGrowingPersistsIndependentlyOfStartupDefaultsWithoutDeletingMessages() throws {
        let directory = root(), owner = try MeshIdentity(name: "owner"), recipient = try MeshIdentity(name: "recipient")
        var store = try MeshStore(directory: directory, identity: owner,
            limits: MeshStorageLimits(historyBytes: 3_000_000, relayBytes: 5_000_000))
        let ids = try populate(store, owner: owner, recipient: recipient, count: 3)
        let engine = try MeshEngine(identity: owner, store: store, enforceContactConsent: false, clock: { self.now })
        let plan = try engine.prepareStorageResize(.history, to: 4_000_000)
        XCTAssertFalse(plan.requiresConfirmation)
        XCTAssertEqual(plan.removedMessages, 0)
        try engine.applyStorageResize(plan)
        XCTAssertNil(engine.sessionID, "Storage changes must not enable networking")
        XCTAssertEqual(store.limits.historyBytes, 4_000_000)
        store = try MeshStore(directory: directory, identity: owner)
        XCTAssertEqual(store.limits.historyBytes, 4_000_000)
        XCTAssertEqual(store.limits.relayBytes, 5_000_000)
        XCTAssertEqual(try store.history().map(\.id), ids)
        XCTAssertEqual(try store.outgoing().count, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("resize.sqlite").path))
    }
    func testPreviewAndCancelPreserveBytesAndUnconfirmedShrinkIsRejected() throws {
        let directory = root(), owner = try MeshIdentity(name: "owner"), recipient = try MeshIdentity(name: "recipient")
        let store = try MeshStore(directory: directory, identity: owner,
            limits: MeshStorageLimits(historyBytes: 4_000_000, relayBytes: 5_000_000))
        let ids = try populate(store, owner: owner, recipient: recipient, count: 100)
        let file = directory.appendingPathComponent("archive.sqlite")
        let before = try Data(contentsOf: file)
        let plan = try store.prepareResize(.history, to: 1_000_000, now: now)
        XCTAssertTrue(plan.requiresConfirmation)
        XCTAssertGreaterThan(plan.removedMessages, 0)
        XCTAssertGreaterThan(plan.bytesToFree, 0)
        XCTAssertEqual(plan.removedMessages, plan.canceledTasks)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try store.history().map(\.id), ids)
        XCTAssertThrowsError(try store.applyResize(plan, confirmed: false, now: now))
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(store.limits.historyBytes, 4_000_000)
    }
    func testConfirmedShrinkRemovesOnlyOldestRowsAndTheirWaitingTasks() throws {
        let directory = root(), owner = try MeshIdentity(name: "owner"), recipient = try MeshIdentity(name: "recipient")
        let store = try MeshStore(directory: directory, identity: owner,
            limits: MeshStorageLimits(historyBytes: 4_000_000, relayBytes: 5_000_000))
        let ids = try populate(store, owner: owner, recipient: recipient, count: 100)
        let first = try XCTUnwrap(store.outgoing().first)
        try store.apply(TransferControl(recipientID: recipient.card.id, packetID: first.packet.body.id,
            digest: first.packet.digest(), offerID: XCTUnwrap(first.packet.offer).body.id, kind: .stored), signedBy: recipient.card)
        try store.own.transaction {
            try store.own.put(space: "inbox", id: UUID().uuidString,
                value: InboxEvidence(digest: Data(repeating: 1, count: 32), originalDeadline: now.addingTimeInterval(100)))
        }
        let plan = try store.prepareResize(.history, to: 1_000_000, now: now)
        let result = try store.applyResize(plan, confirmed: true, now: now)
        XCTAssertEqual(result.removedHistoryIDs, Set(ids.prefix(plan.removedMessages)))
        XCTAssertEqual(try store.history().map(\.id), Array(ids.dropFirst(plan.removedMessages)))
        XCTAssertNil(try store.ownTask(key: first.packet.storageKey))
        XCTAssertEqual(try store.own.count(space: "inbox"), 1)
        XCTAssertLessThanOrEqual(try store.usage().historyFiles, 1_000_000)
        let reopened = try MeshStore(directory: directory, identity: owner)
        XCTAssertEqual(reopened.limits.historyBytes, 1_000_000)
        XCTAssertEqual(try reopened.history().map(\.id), Array(ids.dropFirst(plan.removedMessages)))
    }
    func testChangedDeletionPreviewRequiresNewConfirmation() throws {
        let owner = try MeshIdentity(name: "owner"), recipient = try MeshIdentity(name: "recipient")
        let store = try MeshStore(directory: root(), identity: owner,
            limits: MeshStorageLimits(historyBytes: 4_000_000, relayBytes: 5_000_000))
        let ids = try populate(store, owner: owner, recipient: recipient, count: 100)
        let plan = try store.prepareResize(.history, to: 1_000_000, now: now)
        var first = try XCTUnwrap(store.entry(ids[0])); first.state = .sent
        try store.own.transaction { try store.own.put(space: "history", id: first.id.uuidString, value: first) }
        XCTAssertThrowsError(try store.applyResize(plan, confirmed: true, now: now)) { error in
            guard case MeshStorageError.resizeChanged = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(store.limits.historyBytes, 4_000_000)
        XCTAssertEqual(try store.history().count, ids.count)
        let refreshed = try store.prepareResize(.history, to: 1_000_000, now: now)
        _ = try store.applyResize(refreshed, confirmed: true, now: now)
        XCTAssertEqual(store.limits.historyBytes, 1_000_000)
    }
    func testInvalidLimitsAndWriteFailureNeverDeleteSourceData() throws {
        let owner = try MeshIdentity(name: "owner"), recipient = try MeshIdentity(name: "recipient")
        let store = try MeshStore(directory: root(), identity: owner)
        let ids = try populate(store, owner: owner, recipient: recipient, count: 1)
        XCTAssertThrowsError(try store.prepareResize(.relay, to: 4_000_000, now: now))
        XCTAssertThrowsError(try store.prepareResize(.history, to: 0, now: now))
        XCTAssertThrowsError(try store.prepareResize(.history, to: 1_000_001, now: now))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.own.directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.own.directory.path) }
        guard !FileManager.default.isWritableFile(atPath: store.own.directory.path) else { throw XCTSkip("Permissions bypassed") }
        XCTAssertThrowsError(try store.prepareResize(.history, to: 1_000_000, now: now))
        XCTAssertEqual(try store.history().map(\.id), ids)
        XCTAssertEqual(store.limits.historyBytes, 100_000_000)
    }
    func testAbandonedPreparationIsDiscardedOnRestart() throws {
        let directory = root(), owner = try MeshIdentity(name: "owner"), recipient = try MeshIdentity(name: "recipient")
        let store = try MeshStore(directory: directory, identity: owner)
        let ids = try populate(store, owner: owner, recipient: recipient, count: 1)
        try Data("incomplete preparation".utf8).write(to: directory.appendingPathComponent("resize.sqlite"))
        try Data([1]).write(to: directory.appendingPathComponent("resize.sqlite-journal"))
        let reopened = try MeshStore(directory: directory, identity: owner)
        XCTAssertEqual(try reopened.history().map(\.id), ids)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("resize.sqlite").path))
        XCTAssertEqual(reopened.limits.historyBytes, 100_000_000)
    }
    func testGrowingAnAlreadyPackedArchiveNeverDeletesHistory() throws {
        let owner = try MeshIdentity(name: "owner"), recipient = try MeshIdentity(name: "recipient")
        let store = try MeshStore(directory: root(), identity: owner,
            limits: MeshStorageLimits(historyBytes: 1_000_000, relayBytes: 5_000_000))
        _ = try populate(store, owner: owner, recipient: recipient, count: 100)
        let before = try store.history().map(\.id)
        let plan = try store.prepareResize(.history, to: 2_000_000, now: now)
        XCTAssertEqual(plan.removedMessages, 0)
        _ = try store.applyResize(plan, confirmed: false, now: now)
        XCTAssertEqual(try store.history().map(\.id), before)
        XCTAssertEqual(store.limits.historyBytes, 2_000_000)
    }
    func testRelayShrinkSendsReleaseAndSourceResumesWithOriginalDeadline() throws {
        let source = try MeshIdentity(name: "source"), relay = try MeshIdentity(name: "relay"), target = try MeshIdentity(name: "target")
        let senderStore = try MeshStore(directory: root(), identity: source)
        let relayDirectory = root()
        let relayStore = try MeshStore(directory: relayDirectory, identity: relay,
            limits: MeshStorageLimits(historyBytes: 100_000_000, relayBytes: 6_000_000))
        var first: MeshPacket?
        var full = false
        for _ in 0..<600 {
            let text = String(repeating: "😀", count: 1000)
            let packet = try MeshPacket.make(identity: source, kind: .message, recipient: target.card,
                cleartext: JSONEncoder().encode(ChatPayload(text: text, isPublic: false)), now: now)
            do {
                let admitted = try relayStore.admit(packet, from: source.card.id, now: now)
                XCTAssertTrue(admitted)
            } catch MeshStorageError.budgetFull { full = true; break }
            if first == nil {
                first = packet
                let entry = ChatEntry(id: packet.body.id, sender: source.card, recipient: target.card.id,
                    recipientName: target.name, text: text, isPublic: false, outgoing: true, state: .queued, date: now, hops: 0)
                try senderStore.enqueue(entry, packets: [(packet,target.card)])
                try senderStore.apply(TransferControl(recipientID: target.card.id, packetID: packet.body.id,
                    digest: packet.digest(), offerID: XCTUnwrap(packet.offer).body.id, kind: .stored), signedBy: relay.card)
            }
        }
        XCTAssertTrue(full)
        let packet = try XCTUnwrap(first)
        let before = try relayStore.relayTasks().map { $0.packet.body.id }
        let engine = try MeshEngine(identity: relay, store: relayStore, enforceContactConsent: false, clock: { self.now })
        var transmitted: [Data] = []
        engine.onTransmit = { _, data in transmitted.append(data) }
        engine.linkOpened(id: "source", transport: "test")
        let presence = try MeshPacket.make(identity: source, kind: .presence,
            cleartext: JSONEncoder().encode(PresenceInfo(sessionID: UUID())), now: now)
        engine.receive(try presence.encoded(), from: "source")
        let plan = try engine.prepareStorageResize(.relay, to: 5_000_000)
        XCTAssertTrue(plan.requiresConfirmation)
        XCTAssertGreaterThan(plan.canceledTasks, 0)
        XCTAssertEqual(try relayStore.relayTasks().map { $0.packet.body.id }, before)
        try engine.applyStorageResize(plan, confirmed: true)
        XCTAssertEqual(try relayStore.relayTasks().map { $0.packet.body.id }, Array(before.dropFirst(plan.canceledTasks)))
        XCTAssertEqual(engine.storageLimits?.relayBytes, 5_000_000)
        XCTAssertLessThanOrEqual(try relayStore.usage().relayFiles, 5_000_000)
        // With no reserved space, a full buffer may only send the notice immediately.
        let notices = try transmitted.map { try MeshPacket.decode($0, now: now) }.filter { $0.body.kind == .notice }
        let decoded = try notices.map { try JSONDecoder().decode(ReleaseNotice.self, from: $0.decrypted(using: source)) }
        let notice = try XCTUnwrap(decoded.first { $0.packetID == packet.body.id })
        _ = try senderStore.recover(notice, signedBy: relay.card, now: now)
        let resumed = try XCTUnwrap(senderStore.outgoing().first)
        XCTAssertEqual(resumed.packet.deadline, packet.deadline)
        XCTAssertNotEqual(resumed.packet.offer?.body.id, packet.offer?.body.id)
        XCTAssertEqual(try senderStore.entry(packet.body.id)?.state, .queued)
        XCTAssertFalse(try relayStore.admit(packet, from: source.card.id, now: now), "Canceled generation must not receive a ghost custody ACK")
        let reopened = try MeshStore(directory: relayDirectory, identity: relay)
        XCTAssertEqual(reopened.limits.relayBytes, 5_000_000)
        XCTAssertEqual(try reopened.relayTasks().map { $0.packet.body.id }, Array(before.dropFirst(plan.canceledTasks)))
    }

    func testCannotShrinkByErasingUnexpiredDedupMetadata() throws {
        let owner = try MeshIdentity(name: "owner")
        let store = try MeshStore(directory: root(), identity: owner,
            limits: MeshStorageLimits(historyBytes: 4_000_000, relayBytes: 5_000_000))
        try store.own.transaction {
            for _ in 0..<4000 {
                try store.own.put(space: "inbox", id: UUID().uuidString,
                    value: InboxEvidence(digest: Data(repeating: 1, count: 32), originalDeadline: now.addingTimeInterval(86400)),
                    expiry: now.addingTimeInterval(86400))
            }
        }
        XCTAssertThrowsError(try store.prepareResize(.history, to: 1_000_000, now: now)) { error in
            guard case MeshStorageError.budgetTooSmall = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try store.own.count(space: "inbox"), 4000)
        XCTAssertEqual(store.limits.historyBytes, 4_000_000)
    }
    func testReleaseRestartsRAMSenderWithoutExtendingDeadline() throws {
        let owner = try MeshIdentity(name: "owner"), relay = try MeshIdentity(name: "relay"), target = try MeshIdentity(name: "target")
        let engine = MeshEngine(identity: owner, enforceContactConsent: false, clock: { self.now })
        var sent: [Data] = []
        engine.onTransmit = { _, data in sent.append(data) }
        engine.linkOpened(id: "relay", transport: "test")
        func presence(_ identity: MeshIdentity) throws -> MeshPacket {
            try MeshPacket.make(identity: identity, kind: .presence,
                cleartext: JSONEncoder().encode(PresenceInfo(sessionID: UUID())), now: now)
        }
        engine.receive(try presence(relay).encoded(), from: "relay")
        var targetPresence = try presence(target); targetPresence.remainingHops -= 1
        engine.receive(try targetPresence.encoded(), from: "relay")
        let id = try engine.send(text: "recover in RAM", to: target.card.id)
        let original = try XCTUnwrap(sent.compactMap { try? MeshPacket.decode($0, now: now) }.first { $0.body.id == id })
        let control = TransferControl(recipientID: target.card.id, packetID: id,
            digest: try original.digest(), offerID: try XCTUnwrap(original.offer).body.id, kind: .stored)
        let ack = try MeshPacket.make(identity: relay, kind: .control, recipient: owner.card,
            cleartext: JSONEncoder().encode(control), now: now)
        engine.receive(try ack.encoded(), from: "relay")
        XCTAssertEqual(engine.messages.first?.state, .relayed)
        let notice = try MeshPacket.make(identity: relay, kind: .notice, recipient: owner.card,
            cleartext: JSONEncoder().encode(ReleaseNotice(recipientID: target.card.id, packetID: id,
                digest: original.digest(), offerID: XCTUnwrap(original.offer).body.id)), now: now, expiresAt: original.deadline)
        engine.receive(try notice.encoded(), from: "relay")
        let resumed = try XCTUnwrap(sent.compactMap { try? MeshPacket.decode($0, now: now) }.last { $0.body.id == id })
        XCTAssertNotEqual(resumed.offer?.body.id, original.offer?.body.id)
        XCTAssertEqual(resumed.deadline, original.deadline)
        XCTAssertEqual(engine.messages.first?.state, .sent)
        XCTAssertEqual(engine.messages.count, 1)
    }

    func testCustodyAndRecoveryKeepOriginalFIFOPosition() throws {
        let owner = try MeshIdentity(name: "owner"), recipient = try MeshIdentity(name: "recipient"), courier = try MeshIdentity(name: "courier")
        let store = try MeshStore(directory: root(), identity: owner)
        let receipt = try MeshPacket.make(identity: owner, kind: .receipt, recipient: recipient.card,
            cleartext: JSONEncoder().encode(FinalReceipt(messageID: UUID(), recipientID: owner.card.id,
                digest: Data(repeating: 1, count: 32), kind: .delivered)), now: now)
        try store.enqueueControl(receipt, now: now)
        let order = try XCTUnwrap(store.relay.row(space: "origin", id: receipt.storageKey)).order
        try store.apply(TransferControl(recipientID: recipient.card.id, packetID: receipt.body.id,
            digest: receipt.digest(), offerID: XCTUnwrap(receipt.offer).body.id, kind: .stored), signedBy: courier.card)
        XCTAssertEqual(try store.relay.row(space: "originAwaiting", id: receipt.storageKey)?.order, order)
        _ = try store.recover(ReleaseNotice(recipientID: recipient.card.id, packetID: receipt.body.id,
            digest: receipt.digest(), offerID: XCTUnwrap(receipt.offer).body.id), signedBy: courier.card, now: now)
        XCTAssertEqual(try store.relay.row(space: "origin", id: receipt.storageKey)?.order, order)
    }

}
