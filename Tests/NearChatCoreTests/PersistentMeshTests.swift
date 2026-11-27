import XCTest
import CryptoKit
@testable import NearChatCore

final class PersistentMeshTests: XCTestCase {
    final class Network {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        var nodes: [Int: MeshEngine] = [:]
        var identities: [Int: MeshIdentity] = [:]
        var queue: [(Int, Int, Data)] = []
        var captured: [(Int, Int, Data)] = []
        var drop: ((Int, Int, MeshPacket) -> Bool)?
        func node(_ id: Int, persistent: Bool = true, limits: MeshStorageLimits = .defaults, consent: Bool = false) throws -> MeshEngine {
            let identity = try identities[id] ?? MeshIdentity(name: "Node \(id)")
            identities[id] = identity
            let engine: MeshEngine
            if persistent {
                let store = try MeshStore(directory: root.appendingPathComponent(String(id)), identity: identity, limits: limits)
                engine = try MeshEngine(identity: identity, store: store, enforceContactConsent: consent, clock: { [unowned self] in self.time })
            } else {
                engine = MeshEngine(identity: identity, enforceContactConsent: consent, clock: { [unowned self] in self.time })
            }
            engine.receiveUptime = { [unowned self] in self.time.timeIntervalSince1970 }
            engine.onTransmit = { [unowned self] link, data in
                guard let target = Int(link) else { return }
                self.captured.append((id, target, data))
                self.queue.append((id, target, data))
            }
            nodes[id] = engine
            return engine
        }
        func connect(_ a: Int, _ b: Int) {
            nodes[a]!.linkOpened(id: String(b), transport: "test")
            nodes[b]!.linkOpened(id: String(a), transport: "test")
        }
        func disconnect(_ a: Int, _ b: Int) {
            nodes[a]!.linkClosed(id: String(b))
            nodes[b]!.linkClosed(id: String(a))
        }
        func drain() throws {
            var budget = 5000
            while !queue.isEmpty && budget > 0 {
                let (a,b,data) = queue.removeFirst(); budget -= 1
                if let packet = try? MeshPacket.decode(data, now: time), drop?(a,b,packet) == true { continue }
                nodes[b]?.receive(data, from: String(a))
            }
            XCTAssertGreaterThan(budget, 0, "Unbounded packet loop")
        }
        func advance(_ seconds: TimeInterval) throws {
            time.addTimeInterval(seconds)
            for engine in nodes.values { engine.tick() }
            try drain()
        }
        func announce() throws {
            for engine in nodes.values { engine.announce() }
            try drain()
        }
        deinit {
            nodes.removeAll()
            try? FileManager.default.removeItem(at: root)
        }
    }
    func testEncryptedTransactionsRollbackAndWrongOwner() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try MeshIdentity(name: "owner")
        let archive = try SQLiteArchive(directory: directory, category: "test", budget: 1_000_000, identity: owner)
        let text = Data("private message not present in SQLite".utf8)
        try archive.transaction { try archive.put(space: "history", id: "one", data: text) }
        enum Abort: Error { case requested }
        XCTAssertThrowsError(try archive.transaction {
            try archive.remove(space: "history", id: "one")
            try archive.put(space: "history", id: "two", data: text)
            throw Abort.requested
        })
        XCTAssertEqual(try archive.row(space: "history", id: "one")?.data, text)
        XCTAssertNil(try archive.row(space: "history", id: "two"))
        XCTAssertFalse(try Data(contentsOf: archive.directory.appendingPathComponent("archive.sqlite")).range(of: text) != nil)
        XCTAssertThrowsError(try SQLiteArchive(directory: directory, category: "test", budget: 1_000_000,
                                              identity: MeshIdentity(name: "wrong")))
        XCTAssertEqual(try archive.row(space: "history", id: "one")?.data, text)
    }
    func testQuotaIncludesLiveJournalAndFailedTransactionPreservesCommittedData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try MeshIdentity(name: "owner")
        let archive = try SQLiteArchive(directory: directory, category: "quota", budget: 131_072, identity: owner)
        try archive.transaction { try archive.put(space: "fixture", id: "committed", data: Data([1])) }
        XCTAssertThrowsError(try archive.transaction {
            for index in 0..<30 {
                try archive.put(space: "fixture", id: "new-\(index)", data: Data(repeating: 3, count: 8000))
                XCTAssertLessThanOrEqual(archive.bytesOnDisk, archive.budget)
            }
        })
        XCTAssertEqual(try archive.count(space: "fixture"), 1)
        XCTAssertEqual(try archive.row(space: "fixture", id: "committed")?.data, Data([1]))
        XCTAssertLessThanOrEqual(archive.bytesOnDisk, archive.budget)
        let reopened = try SQLiteArchive(directory: directory, category: "quota", budget: 131_072, identity: owner)
        XCTAssertEqual(try reopened.row(space: "fixture", id: "committed")?.data, Data([1]))
    }
    func testCustodyIsNotDeliveryAndQueuedRelaySurvivesRestart() throws {
        let net = Network()
        let a = try net.node(0), b = try net.node(1), c = try net.node(2)
        net.connect(0,1); net.connect(1,2); try net.drain(); try net.announce()
        net.disconnect(1,2); try net.advance(21)
        let id = try a.send(text: "courier secret", to: c.identity.card.id)
        try net.drain()
        XCTAssertEqual(a.messages.first { $0.id == id }?.state, .relayed)
        XCTAssertTrue(b.messages.isEmpty)
        XCTAssertEqual(b.storageUsage?.relayTasks, 1)
        net.disconnect(0,1)
        let restored = try net.node(1)
        XCTAssertNil(restored.sessionID)
        XCTAssertEqual(restored.storageUsage?.relayTasks, 1)
        net.connect(0,1); net.connect(1,2); try net.drain()
        XCTAssertEqual(c.messages.filter { $0.id == id }.count, 1)
        XCTAssertEqual(a.messages.first { $0.id == id }?.state, .delivered)
        XCTAssertEqual(restored.storageUsage?.relayTasks, 0)
    }
    func testLostCustodyAcknowledgementRetriesWithoutSecondRelayTask() throws {
        let net = Network()
        let a = try net.node(0), b = try net.node(1), c = try net.node(2)
        net.connect(0,1); net.connect(1,2); try net.drain(); try net.announce()
        net.disconnect(1,2)
        net.drop = { from, to, packet in from == 1 && to == 0 && packet.body.kind == .control }
        let id = try a.send(text: "retry stored packet", to: c.identity.card.id)
        try net.drain()
        XCTAssertEqual(a.messages.first { $0.id == id }?.state, .sent)
        XCTAssertEqual(b.storageUsage?.relayTasks, 1)
        net.drop = nil
        try net.advance(6)
        XCTAssertEqual(a.messages.first { $0.id == id }?.state, .relayed)
        XCTAssertEqual(b.storageUsage?.relayTasks, 1)
    }
    func testOriginalDeadlineExpiresAcrossRestart() throws {
        let net = Network()
        let a = try net.node(0), _ = try net.node(1), c = try net.node(2)
        net.connect(0,1); net.connect(1,2); try net.drain(); try net.announce()
        net.disconnect(1,2)
        let id = try a.send(text: "do not extend deadline", to: c.identity.card.id)
        try net.drain()
        net.disconnect(0,1)
        net.time.addTimeInterval(86_401)
        let restoredA = try net.node(0), restoredB = try net.node(1)
        XCTAssertEqual(restoredA.messages.first { $0.id == id }?.state, .failed)
        XCTAssertEqual(restoredB.storageUsage?.relayTasks, 0)
        net.connect(0,1); net.connect(1,2); try net.drain()
        XCTAssertTrue(c.messages.isEmpty)
    }
    func testPersistedOutgoingWaitsForExplicitNetworkingAndKnownPeerCanBeOffline() throws {
        let net = Network()
        let a = try net.node(0), b = try net.node(1)
        net.connect(0,1); try net.drain()
        net.disconnect(0,1); try net.advance(21)
        let id = try a.send(text: "saved before route appears", to: b.identity.card.id)
        XCTAssertEqual(a.messages.first { $0.id == id }?.state, .queued)
        let restored = try net.node(0)
        XCTAssertNil(restored.sessionID)
        let previousPackets = net.captured.count
        restored.tick()
        XCTAssertEqual(net.captured.count, previousPackets)
        XCTAssertEqual(restored.messages.first { $0.id == id }?.state, .queued)
        net.connect(0,1); try net.drain()
        XCTAssertEqual(b.messages.first { $0.id == id }?.text, "saved before route appears")
        XCTAssertEqual(restored.messages.first { $0.id == id }?.state, .delivered)
    }
    func testReadReceiptIsMonotonicAfterLateDeliveryReceipt() throws {
        let net = Network()
        let a = try net.node(0), b = try net.node(1)
        net.connect(0,1); try net.drain()
        let id = try a.send(text: "read when visible", to: b.identity.card.id)
        try net.drain()
        XCTAssertEqual(a.messages.first { $0.id == id }?.state, .delivered)
        let delivery = try XCTUnwrap(net.captured.first {
            guard $0.0 == 1, let p = try? MeshPacket.decode($0.2, now: net.time),
                  p.body.kind == .receipt,
                  let r = try? JSONDecoder().decode(FinalReceipt.self, from: p.decrypted(using: a.identity)) else { return false }
            return r.kind == .delivered
        })
        b.markRead(id); try net.drain()
        XCTAssertEqual(a.messages.first { $0.id == id }?.state, .read)
        a.receive(delivery.2, from: "1"); try net.drain()
        XCTAssertEqual(a.messages.first { $0.id == id }?.state, .read)
        XCTAssertEqual(a.messages.first { $0.id == id }?.state.title, "✓✓")
    }
    func testRelayCannotForgeEndpointReceipt() throws {
        let net = Network()
        let a = try net.node(0), b = try net.node(1), c = try net.node(2)
        net.connect(0,1); net.connect(1,2); try net.drain(); try net.announce()
        net.disconnect(1,2)
        let id = try a.send(text: "not delivered yet", to: c.identity.card.id)
        try net.drain()
        let original = try XCTUnwrap(net.captured.compactMap { try? MeshPacket.decode($0.2, now: net.time) }
            .first { $0.body.id == id })
        let forged = try MeshPacket.make(identity: b.identity, kind: .receipt, recipient: a.identity.card,
            cleartext: JSONEncoder().encode(FinalReceipt(messageID: id, recipientID: b.identity.card.id,
                                                         digest: original.digest(), kind: .delivered)), now: net.time)
        a.receive(try forged.encoded(), from: "1"); try net.drain()
        XCTAssertEqual(a.messages.first { $0.id == id }?.state, .relayed)
        XCTAssertGreaterThan(a.counters.rejected, 0)
    }
    func testRecoveryUsesNewOfferAndIgnoresOldCustodyAck() throws {
        let net = Network()
        let a = try net.node(0), b = try MeshIdentity(name: "B"), c = try MeshIdentity(name: "C")
        let store = try MeshStore(directory: net.root.appendingPathComponent("isolated"), identity: a.identity)
        let packet = try MeshPacket.make(identity: a.identity, kind: .message, recipient: c.card,
            cleartext: JSONEncoder().encode(ChatPayload(text: "recover", isPublic: false)), now: net.time)
        let entry = ChatEntry(id: packet.body.id, sender: a.identity.card, recipient: c.card.id, recipientName: "C",
            text: "recover", isPublic: false, outgoing: true, state: .queued, date: net.time, hops: 0)
        try store.enqueue(entry, packets: [(packet,c.card)])
        let nonce = try XCTUnwrap(packet.offer?.body.id)
        let control = TransferControl(recipientID: c.card.id, packetID: packet.body.id, digest: try packet.digest(),
                                      offerID: nonce, kind: .stored)
        try store.apply(control, signedBy: b.card)
        XCTAssertTrue(try store.outgoing().isEmpty)
        _ = try store.recover(ReleaseNotice(recipientID: c.card.id, packetID: packet.body.id,
                                           digest: packet.digest(), offerID: nonce), signedBy: b.card, now: net.time)
        let recovered = try XCTUnwrap(store.outgoing().first)
        XCTAssertNotEqual(recovered.packet.offer?.body.id, nonce)
        XCTAssertEqual(recovered.packet.deadline, packet.deadline)
        try store.apply(control, signedBy: b.card)
        XCTAssertEqual(try store.outgoing().count, 1)
    }
    func testPublicFanoutUsesOneEntryAndNewSessionRejectsOldPublicPackets() throws {
        let net = Network()
        let a = try net.node(0), b = try net.node(1), c = try net.node(2)
        net.connect(0,1); net.connect(1,2); try net.drain(); try net.announce()
        net.disconnect(1,2)
        let id = try a.broadcast(text: "only this session")
        try net.drain()
        XCTAssertEqual(a.messages.filter { $0.id == id }.count, 1)
        XCTAssertEqual(b.messages.filter { $0.id == id }.count, 1)
        c.endNetworking()
        net.connect(1,2); try net.drain(); try net.advance(6); try net.announce()
        XCTAssertFalse(c.messages.contains { $0.id == id })
        XCTAssertEqual(a.messages.first { $0.id == id }?.state, .delivered)
        let fresh = try a.broadcast(text: "new session message")
        try net.drain()
        XCTAssertEqual(c.messages.first { $0.id == fresh }?.text, "new session message")
    }
    func testLastAllowedHopDeliversAndZeroBudgetIsRejected() throws {
        let net = Network()
        let a = try net.node(0), b = try net.node(1)
        net.connect(0,1); try net.drain()
        var packet = try MeshPacket.make(identity: a.identity, kind: .message, recipient: b.identity.card,
            cleartext: JSONEncoder().encode(ChatPayload(text: "hop 256", isPublic: false)), now: net.time)
        packet.remainingHops = 1
        b.receive(try packet.encoded(), from: "0"); try net.drain()
        XCTAssertEqual(b.messages.first { $0.id == packet.body.id }?.hops, 256)
        packet.remainingHops = 0
        XCTAssertThrowsError(try packet.validate(now: net.time))
    }
    func testHistoryFIFOStopsSourceTasksAndLateReceiptDoesNotResurrect() throws {
        let net = Network()
        let identity = try MeshIdentity(name: "owner"), recipient = try MeshIdentity(name: "recipient")
        let store = try MeshStore(directory: net.root, identity: identity,
            limits: MeshStorageLimits(historyBytes: 131_072, relayBytes: 5_000_000))
        var first: MeshPacket?
        for index in 0..<20 {
            let packet = try MeshPacket.make(identity: identity, kind: .message, recipient: recipient.card,
                cleartext: JSONEncoder().encode(ChatPayload(text: String(repeating: "я", count: 1000), isPublic: false)),
                now: net.time)
            let entry = ChatEntry(id: packet.body.id, sender: identity.card, recipient: recipient.card.id,
                recipientName: recipient.name, text: String(repeating: "я", count: 1000), isPublic: false,
                outgoing: true, state: .queued, date: net.time, hops: 0)
            try store.enqueue(entry, packets: [(packet, recipient.card)])
            if index == 0 {
                first = packet
                try store.apply(TransferControl(recipientID: recipient.card.id, packetID: packet.body.id,
                    digest: packet.digest(), offerID: XCTUnwrap(packet.offer).body.id, kind: .stored), signedBy: recipient.card)
            }
        }
        let packet = try XCTUnwrap(first)
        XCTAssertNil(try store.entry(packet.body.id))
        XCTAssertNil(try store.ownTask(key: packet.storageKey))
        try store.apply(FinalReceipt(messageID: packet.body.id, recipientID: recipient.card.id,
            digest: packet.digest(), kind: .delivered), signedBy: recipient.card)
        XCTAssertNil(try store.entry(packet.body.id))
        XCTAssertLessThanOrEqual(try store.usage().historyFiles, 131_072)
    }
    func testInboxDedupSurvivesFIFOAndRestartAndReceiptsUseRelayBudget() throws {
        let net = Network()
        let identity = try MeshIdentity(name: "owner"), sender = try MeshIdentity(name: "sender")
        let limits = MeshStorageLimits(historyBytes: 131_072, relayBytes: 5_000_000)
        var store = try MeshStore(directory: net.root, identity: identity, limits: limits)
        var first: (ChatEntry, InboxEvidence)?
        for index in 0..<45 {
            let packet = try MeshPacket.make(identity: sender, kind: .message, recipient: identity.card,
                cleartext: JSONEncoder().encode(ChatPayload(text: "incoming", isPublic: false)), now: net.time)
            let receipt = try MeshPacket.make(identity: identity, kind: .receipt, recipient: sender.card,
                cleartext: JSONEncoder().encode(FinalReceipt(messageID: packet.body.id, recipientID: identity.card.id,
                    digest: packet.digest(), kind: .delivered)), now: net.time)
            let entry = ChatEntry(id: packet.body.id, sender: sender.card, recipient: identity.card.id,
                recipientName: identity.name, text: String(repeating: "я", count: 1000), isPublic: false,
                outgoing: false, state: .received, date: net.time, hops: 1)
            let evidence = InboxEvidence(digest: try packet.digest(), delivered: receipt, originalDeadline: packet.deadline)
            XCTAssertTrue(try store.accept(entry, evidence: evidence))
            try store.enqueueControl(receipt, now: net.time)
            if index == 0 { first = (entry, evidence) }
        }
        let (entry,evidence) = try XCTUnwrap(first)
        XCTAssertNil(try store.entry(entry.id))
        let raw = try XCTUnwrap(store.own.row(space: "inbox", id: entry.id.uuidString))
        let metadata = try JSONDecoder().decode(InboxEvidence.self, from: raw.data)
        XCTAssertNil(metadata.delivered, "History must not contain receipt ciphertext")
        XCTAssertNotNil(try store.inbox(entry.id)?.delivered)
        store = try MeshStore(directory: net.root, identity: identity, limits: limits)
        XCTAssertFalse(try store.accept(entry, evidence: evidence))
        XCTAssertNil(try store.entry(entry.id))
    }
    func testRelayRejectsNewWorkAtQuotaWithoutEvictingAcceptedMessage() throws {
        let net = Network()
        let relay = try MeshIdentity(name: "relay"), source = try MeshIdentity(name: "source"), target = try MeshIdentity(name: "target")
        let store = try MeshStore(directory: net.root, identity: relay,
            limits: MeshStorageLimits(historyBytes: 1_000_000, relayBytes: 131_072))
        var first: UUID?, rejected = false
        for _ in 0..<20 {
            let packet = try MeshPacket.make(identity: source, kind: .message, recipient: target.card,
                cleartext: JSONEncoder().encode(ChatPayload(text: String(repeating: "я", count: 1000), isPublic: false)), now: net.time)
            do {
                let admitted = try store.admit(packet, from: source.card.id, now: net.time)
                XCTAssertTrue(admitted)
                if first == nil { first = packet.body.id }
            } catch MeshStorageError.budgetFull {
                rejected = true
                XCTAssertNil(try store.relay.row(space: "accepted", id: XCTUnwrap(packet.offer).body.id.uuidString))
                break
            }
        }
        XCTAssertTrue(rejected)
        XCTAssertTrue(try store.relayTasks().contains { $0.packet.body.id == first })
        XCTAssertLessThanOrEqual(try store.usage().relayFiles, 131_072)
    }
    func testRAMDeliveryAutomaticallyPersistsInOrderAfterStorageRecovery() throws {
        let net = Network()
        let a = try net.node(0, persistent: false), b = try net.node(1)
        net.connect(0,1); try net.drain()
        let first = try a.send(text: "first", to: b.identity.card.id)
        let second = try a.send(text: "second", to: b.identity.card.id)
        try net.drain()
        XCTAssertTrue(a.messages.allSatisfy { $0.isSaved == false })
        XCTAssertTrue(a.messages.allSatisfy { $0.state == .delivered })
        b.markRead(first); try net.drain()
        let original = try XCTUnwrap(net.captured.compactMap { try? MeshPacket.decode($0.2, now: net.time) }
            .first { $0.body.id == first })
        let late = try MeshPacket.make(identity: b.identity, kind: .control, recipient: a.identity.card,
            cleartext: JSONEncoder().encode(TransferControl(recipientID: b.identity.card.id, packetID: first,
                digest: original.digest(), offerID: XCTUnwrap(original.offer).body.id, kind: .applied)), now: net.time)
        a.receive(try late.encoded(), from: "1")
        XCTAssertEqual(a.messages.first?.state, .read)
        let store = try MeshStore(directory: net.root.appendingPathComponent("recovered"), identity: a.identity)
        a.onRecoverStorage = { store }
        a.tick()
        XCTAssertEqual(a.messages.map(\.id), [first, second])
        XCTAssertTrue(a.messages.allSatisfy { $0.isSaved == true })
        XCTAssertNil(a.storageWarning)
        let restarted = try MeshEngine(identity: a.identity, store: store, enforceContactConsent: false, clock: { net.time })
        XCTAssertEqual(restarted.messages.map(\.id), [first, second])
        XCTAssertEqual(restarted.messages.map(\.state), [.read, .delivered])
        XCTAssertEqual(restarted.storageUsage?.outgoingTasks, 0)
    }

    func testRAMFullPausesNewMessagesWithoutEvicting() throws {
        let net = Network()
        let a = try net.node(0, persistent: false), b = try net.node(1, persistent: false)
        net.connect(0,1); try net.drain()
        a.onTransmit = nil
        let first = try a.send(text: String(repeating: "я", count: 1000), to: b.identity.card.id)
        var full = false
        for _ in 0..<1000 {
            do { try a.send(text: String(repeating: "я", count: 1000), to: b.identity.card.id) }
            catch MeshStorageError.capacity { full = true; break }
        }
        XCTAssertTrue(full)
        XCTAssertTrue(a.memoryBufferFull)
        XCTAssertEqual(a.messages.first?.id, first)
        XCTAssertNotNil(a.storageWarning)
        let count = a.messages.count
        XCTAssertThrowsError(try a.send(text: String(repeating: "я", count: 1000), to: b.identity.card.id))
        XCTAssertEqual(a.messages.count, count)
    }
    func testImportPreservesLocalOrderAndDoesNotInventOutgoingJobs() throws {
        let net = Network()
        let identity = try MeshIdentity(name: "owner"), sender = try MeshIdentity(name: "sender")
        let store = try MeshStore(directory: net.root, identity: identity)
        let first = ChatEntry(id: UUID(), sender: sender.card, recipient: identity.card.id,
            recipientName: identity.name, text: "first", isPublic: false, outgoing: false,
            state: .received, date: net.time, hops: 1)
        let second = ChatEntry(id: UUID(), sender: identity.card, recipient: sender.card.id,
            recipientName: sender.name, text: "second", isPublic: false, outgoing: true,
            state: .sent, date: net.time.addingTimeInterval(-10), hops: 0)
        try store.importLegacy([first,second])
        try store.importLegacy([first,second])
        XCTAssertEqual(try store.history().map(\.id), [first.id, second.id])
        XCTAssertEqual(try store.entry(second.id)?.state, .failed)
        XCTAssertTrue(try store.outgoing().isEmpty)
    }

    func testUnderlyingWriteFailurePreservesExistingHistory() throws {
        let net = Network()
        let owner = try MeshIdentity(name: "owner"), target = try MeshIdentity(name: "target")
        let store = try MeshStore(directory: net.root, identity: owner,
            limits: MeshStorageLimits(historyBytes: 131_072, relayBytes: 5_000_000))
        func enqueue(_ text: String) throws -> UUID {
            let packet = try MeshPacket.make(identity: owner, kind: .message, recipient: target.card,
                cleartext: JSONEncoder().encode(ChatPayload(text: text, isPublic: false)), now: net.time)
            let entry = ChatEntry(id: packet.body.id, sender: owner.card, recipient: target.card.id,
                recipientName: target.name, text: text, isPublic: false, outgoing: true,
                state: .queued, date: net.time, hops: 0)
            try store.enqueue(entry, packets: [(packet,target.card)])
            return entry.id
        }
        let id = try enqueue("preserve me")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.own.directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.own.directory.path) }
        guard !FileManager.default.isWritableFile(atPath: store.own.directory.path) else {
            throw XCTSkip("Environment bypasses file permissions")
        }
        XCTAssertThrowsError(try enqueue("cannot write journal"))
        XCTAssertEqual(try store.history().map(\.id), [id])
        XCTAssertEqual(try store.outgoing().count, 1)
    }

    func testDurableRelayCanUseNewRouteBackThroughFormerCustodian() throws {
        let net = Network(); let target = try net.node(0), previous = try net.node(1), custodian = try net.node(2), source = try net.node(3)
        net.connect(0,1); net.connect(1,2); net.connect(1,3); try net.drain(); try net.announce()
        net.disconnect(0,1); try net.advance(21)
        let id = try source.send(text:"route changed",to:target.identity.card.id); try net.drain()
        XCTAssertTrue(target.messages.isEmpty)
        XCTAssertGreaterThan(custodian.storageUsage?.relayTasks ?? 0,0)
        net.connect(0,1); try net.drain(); try net.announce()
        for _ in 0..<4 { try net.advance(6); if target.messages.contains(where: { $0.id == id }) { break } }
        XCTAssertTrue(target.messages.contains { $0.id == id })
        XCTAssertEqual(source.messages.first?.state,.delivered)
        XCTAssertTrue(previous.messages.isEmpty)
    }
}
