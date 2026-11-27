import XCTest
@testable import NearChatCore

final class HistoryCleanupTests: XCTestCase {
    private var roots:[URL]=[]
    override func tearDown() { for url in roots { try? FileManager.default.removeItem(at:url) }; roots=[]; super.tearDown() }
    private func fixture(count:Int=120) throws -> (MeshIdentity,MeshStore,[UUID]) {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("NearChatCleanup-"+UUID().uuidString)
        roots.append(url)
        let owner=try MeshIdentity(name:"owner"), peer=try MeshIdentity(name:"peer")
        let store=try MeshStore(directory:url,identity:owner)
        var ids:[UUID]=[]
        for index in 0..<count {
            let packet=try MeshPacket.make(identity:owner,kind:.message,recipient:peer.card,
                cleartext:JSONEncoder().encode(ChatPayload(text:String(repeating:"x",count:1000),isPublic:false)),now:Date())
            let entry=ChatEntry(id:packet.body.id,sender:owner.card,recipient:peer.card.id,recipientName:"peer",
                text:String(repeating:"x",count:1000),isPublic:false,outgoing:true,state:.queued,date:Date().addingTimeInterval(Double(index)),hops:0)
            try store.enqueue(entry,packets:[(packet,peer.card)]); ids.append(entry.id)
        }
        return (owner,store,ids)
    }
    func testPreviewAndCancelDoNotModifyAnyBytesOrBudget() throws {
        let (_,store,_)=try fixture()
        let url=store.own.directory.appendingPathComponent("archive.sqlite"), before=try Data(contentsOf:url)
        let plan=try store.prepareHistoryCleanup(availableDeviceBytes:500)
        XCTAssertGreaterThan(plan.removedMessages,0)
        XCTAssertThrowsError(try store.applyHistoryCleanup(plan,confirmed:false))
        XCTAssertEqual(try Data(contentsOf:url),before)
        XCTAssertEqual(store.limits.historyBytes,100_000_000)
    }
    func testConfirmedCleanupRemovesExactOldestPrefixAndShrinksFile() throws {
        let (owner,store,ids)=try fixture()
        let before=try store.usage().historyFiles, plan=try store.prepareHistoryCleanup()
        let result=try store.applyHistoryCleanup(plan,confirmed:true)
        XCTAssertEqual(try store.history(limit:200).map(\.id),Array(ids.dropFirst(plan.removedMessages)))
        XCTAssertEqual(try store.outgoing().count,ids.count-plan.removedMessages)
        XCTAssertGreaterThan(result.freedFileBytes,0)
        XCTAssertLessThan(try store.usage().historyFiles,before)
        XCTAssertEqual(store.limits.historyBytes,100_000_000)
        let restored=try MeshStore(directory:store.own.directory,identity:owner)
        XCTAssertEqual(try restored.history(limit:200).map(\.id),Array(ids.dropFirst(plan.removedMessages)))
    }
    func testChangedPreviewRequiresFreshConfirmation() throws {
        let (_,store,ids)=try fixture(count:4)
        let plan=try store.prepareHistoryCleanup()
        try store.own.transaction { try store.own.remove(space:"history",id:ids[0].uuidString) }
        XCTAssertThrowsError(try store.applyHistoryCleanup(plan,confirmed:true)) { XCTAssertEqual($0 as? MeshStorageError,.resizeChanged) }
        XCTAssertEqual(try store.history().count,3)
    }
    func testWriteFailurePreservesCommittedHistory() throws {
        let (_,store,ids)=try fixture(count:4), plan=try store.prepareHistoryCleanup()
        let root=store.own.directory
        try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:root.path) }
        guard !FileManager.default.isWritableFile(atPath:root.path) else { throw XCTSkip("Permissions bypassed") }
        XCTAssertThrowsError(try store.applyHistoryCleanup(plan,confirmed:true))
        XCTAssertEqual(try store.history().map(\.id),ids)
        XCTAssertEqual(try store.outgoing().count,4)
    }
    func testCleanupRetainsContactGroupAndInboxDedupMetadata() throws {
        let (owner,store,ids)=try fixture(count:4)
        let engine=try MeshEngine(identity:owner,store:store)
        let group=try engine.createClosedGroup(name:"metadata")
        let peer=try MeshIdentity(name:"blocked")
        try store.saveContact(ContactRecord(peer:peer.card,blocked:true))
        let evidence=InboxEvidence(digest:Data(repeating:7,count:32),originalDeadline:Date().addingTimeInterval(86400))
        try store.own.transaction { try store.own.put(space:"inbox",id:ids[0].uuidString,value:evidence,expiry:evidence.deadline) }
        _ = try store.applyHistoryCleanup(store.prepareHistoryCleanup(),confirmed:true)
        XCTAssertNotNil(try store.inbox(ids[0]))
        XCTAssertTrue(try store.loadContacts().first?.blocked == true)
        XCTAssertNotNil(try store.loadGroups()[group])
    }
    func testLowCapacitySuggestsCleanupButNeverDeletesWithoutConsent() throws {
        let (owner,store,ids)=try fixture(count:4)
        let engine=try MeshEngine(identity:owner,store:store,enforceContactConsent:false)
        engine.availableDiskBytes={ 100 }
        engine.tick()
        XCTAssertTrue(engine.historyCleanupSuggested)
        XCTAssertEqual(try store.history().map(\.id),ids)
        let plan=try engine.prepareHistoryCleanup()
        XCTAssertThrowsError(try engine.applyHistoryCleanup(plan))
        XCTAssertEqual(try store.history().map(\.id),ids)
        _ = try engine.applyHistoryCleanup(plan,confirmed:true)
        XCTAssertTrue(engine.messages.isEmpty)
    }
    func testEmptyStoreExplainsThatOtherDeviceSpaceMustBeFreed() throws {
        let (_,store,_)=try fixture(count:0)
        XCTAssertThrowsError(try store.prepareHistoryCleanup()) { XCTAssertEqual($0 as? MeshStorageError,.nothingToCleanup) }
    }
    func testCompactionInsideAbortedTransactionRestoresHistoryAndFileLength() throws {
        let (_,store,ids)=try fixture(count:30), before=try store.usage().historyFiles
        enum Abort:Error { case requested }
        XCTAssertThrowsError(try store.own.transaction {
            for id in ids.prefix(20) {
                try store.own.remove(space:"history",id:id.uuidString)
                for space in ["outbox","awaiting","delivery"] { try store.own.removePrefix(space:space,prefix:id.uuidString+":") }
            }
            try store.own.reclaimFreePages(256)
            throw Abort.requested
        })
        XCTAssertEqual(try store.history().map(\.id),ids)
        XCTAssertEqual(try store.outgoing().count,ids.count)
        XCTAssertEqual(try store.usage().historyFiles,before)
    }
    func testIncomingCleanupClearsUnreadAndReplayCannotRestoreDeletedText() throws {
        let net=PersistentMeshTests.Network()
        let a=try net.node(0), b=try net.node(1)
        net.connect(0,1); try net.drain(); try net.announce()
        let id=try a.send(text:"received history",to:b.identity.card.id); try net.drain()
        XCTAssertEqual(b.unreadCount,1)
        let packet=try XCTUnwrap(net.captured.compactMap { try? MeshPacket.decode($0.2,now:net.time) }.first { $0.body.id==id })
        let plan=try b.prepareHistoryCleanup()
        _ = try b.applyHistoryCleanup(plan,confirmed:true)
        XCTAssertEqual(b.unreadCount,0); XCTAssertTrue(b.messages.isEmpty)
        b.receive(try packet.encoded(),from:"0"); try net.drain()
        XCTAssertTrue(b.messages.isEmpty); XCTAssertEqual(b.unreadCount,0)
    }
    func testStartupWriteFailureKeepsOldHistoryReadableAndCleanupAvailable() throws {
        let (owner,store,ids)=try fixture(count:4), root=store.own.directory
        try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:root.path) }
        guard !FileManager.default.isWritableFile(atPath:root.path) else { throw XCTSkip("Permissions bypassed") }
        let engine=try MeshEngine(identity:owner,store:store)
        XCTAssertEqual(engine.messages.map(\.id),ids)
        XCTAssertNotNil(engine.storageWarning)
        let plan=try engine.prepareHistoryCleanup()
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:root.path)
        _ = try engine.applyHistoryCleanup(plan,confirmed:true)
        XCTAssertTrue(engine.messages.isEmpty)
    }
}
