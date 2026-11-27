import XCTest
@testable import NearChatCore

final class InstallationIdentityTests: XCTestCase {
    final class Keys: IdentityKeyStorage {
        var values: [String: Data] = [:]
        var writes = 0
        var failure = false
        func readKey(account: String) throws -> Data? {
            if failure { throw InstallationIdentityError.missingKey }; return values[account]
        }
        func storeKey(_ data: Data, account: String) throws {
            if failure { throw InstallationIdentityError.missingKey }
            guard values[account] == nil else { throw InstallationIdentityError.invalidKey }
            values[account] = data; writes += 1
        }
    }
    private var roots: [URL] = []
    override func tearDown() { for url in roots { try? FileManager.default.removeItem(at: url) }; roots=[]; super.tearDown() }
    private func root() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NearChatInstall-" + UUID().uuidString)
        roots.append(url); return url
    }
    private func loader(_ keys: Keys, _ root: URL, legacy: Bool = false) -> InstallationIdentity {
        InstallationIdentity(keys:keys,directory:root.appendingPathComponent("identity"),
            historyDirectory:root.appendingPathComponent("history"),legacyPreferencesPresent:legacy)
    }
    private func data(_ identity: MeshIdentity) -> Data { identity.signingKeyData + identity.agreementKeyData }
    func testFreshInstallIgnoresRetainedLegacyKeyAndRestartKeepsNewKey() throws {
        let keys=Keys(), url=root(), old=try MeshIdentity(name:"old")
        keys.values["device"]=data(old)
        let first=try loader(keys,url).load(name:"new")
        XCTAssertNotEqual(first.card.id,old.card.id)
        XCTAssertEqual(try loader(keys,url).load(name:"renamed").card.id,first.card.id)
        XCTAssertEqual(keys.writes,1)
        XCTAssertEqual(keys.values["device"],data(old))
    }
    func testReinstallWithSameKeychainCreatesNewIdentity() throws {
        let keys=Keys(), firstRoot=root(), secondRoot=root()
        let first=try loader(keys,firstRoot).load(name:"first")
        let next=try loader(keys,secondRoot).load(name:"second")
        XCTAssertNotEqual(first.card.id,next.card.id)
        XCTAssertEqual(keys.writes,2)
    }
    func testLegacyUpdatePreservesKeyAndArchive() throws {
        let keys=Keys(), url=root(), old=try MeshIdentity(name:"old")
        keys.values["device"]=data(old)
        let store=try MeshStore(directory:url.appendingPathComponent("history"),identity:old)
        let entry=ChatEntry(id:UUID(),sender:old.card,recipient:"*",recipientName:"common",text:"preserve",
            isPublic:true,outgoing:true,state:.delivered,date:Date(),hops:0)
        try store.importLegacy([entry])
        let identity=try loader(keys,url).load(name:"renamed")
        XCTAssertEqual(identity.card.id,old.card.id); XCTAssertEqual(keys.writes,0)
        let reopened=try MeshStore(directory:url.appendingPathComponent("history"),identity:identity)
        XCTAssertEqual(try reopened.history().first?.text,"preserve")
        XCTAssertEqual(try loader(keys,url).load(name:"again").card.id,old.card.id)
    }
    func testLegacyEmptyInstallationWithPreferencesKeepsIdentity() throws {
        let keys=Keys(), url=root(), old=try MeshIdentity(name:"old")
        keys.values["device"]=data(old)
        XCTAssertEqual(try loader(keys,url,legacy:true).load(name:"name").card.id,old.card.id)
        XCTAssertEqual(keys.writes,0)
    }
    func testMissingKeyForExistingArchiveNeverGeneratesReplacement() throws {
        let keys=Keys(), url=root(), old=try MeshIdentity(name:"old")
        _ = try MeshStore(directory:url.appendingPathComponent("history"),identity:old)
        XCTAssertThrowsError(try loader(keys,url).load(name:"x"))
        XCTAssertEqual(keys.writes,0)
        XCTAssertTrue(FileManager.default.fileExists(atPath:url.appendingPathComponent("history/archive.sqlite").path))
    }
    func testWrongLegacyKeyDoesNotPinWrongMarkerOrEraseArchive() throws {
        let keys=Keys(), url=root(), old=try MeshIdentity(name:"old")
        _ = try MeshStore(directory:url.appendingPathComponent("history"),identity:old)
        keys.values["device"]=data(try MeshIdentity(name:"wrong"))
        XCTAssertThrowsError(try loader(keys,url).load(name:"x"))
        XCTAssertFalse(FileManager.default.fileExists(atPath:url.appendingPathComponent("identity/installation-v1.json").path))
        XCTAssertEqual(keys.writes,0)
    }
    func testPendingStateRecoversSameKeyAfterFinalMarkerWriteFails() throws {
        let keys=Keys(), url=root()
        var failing=loader(keys,url)
        var writes=0
        failing.commitState = { bytes,file in
            writes += 1
            if writes==2 { throw InstallationIdentityError.couldNotSynchronize }
            try bytes.write(to:file,options:.atomic)
        }
        XCTAssertThrowsError(try failing.load(name:"x"))
        let stored=try XCTUnwrap(keys.values.values.first)
        let recovered=try loader(keys,url).load(name:"recovered")
        XCTAssertEqual(data(recovered),stored); XCTAssertEqual(keys.writes,1)
    }
    func testFailureBeforePendingMarkerDoesNotCreateOrReplaceAnyKey() throws {
        let keys=Keys(), url=root()
        var failing=loader(keys,url)
        failing.commitState = { _,_ in throw InstallationIdentityError.couldNotSynchronize }
        XCTAssertThrowsError(try failing.load(name:"x")); XCTAssertEqual(keys.writes,0)
        XCTAssertEqual(keys.values.count,0)
    }
    func testCorruptMarkerAndMissingReferencedKeyFailClosed() throws {
        let keys=Keys(), url=root()
        _ = try loader(keys,url).load(name:"x")
        keys.values.removeAll()
        XCTAssertThrowsError(try loader(keys,url).load(name:"x")); XCTAssertEqual(keys.writes,1)
        try Data("broken".utf8).write(to:url.appendingPathComponent("identity/installation-v1.json"))
        XCTAssertThrowsError(try loader(keys,url).load(name:"x")); XCTAssertEqual(keys.writes,1)
    }
    func testKeychainUnavailableDoesNotRotateIdentity() throws {
        let keys=Keys(), url=root()
        let first=try loader(keys,url).load(name:"x")
        keys.failure=true; XCTAssertThrowsError(try loader(keys,url).load(name:"x"))
        keys.failure=false
        XCTAssertEqual(try loader(keys,url).load(name:"x").card.id,first.card.id)
    }
    func testDifferentKeyAtReferencedAccountDoesNotOverwritePinnedIdentity() throws {
        let keys=Keys(), url=root()
        _ = try loader(keys,url).load(name:"first")
        let account=try XCTUnwrap(keys.values.keys.first)
        keys.values[account]=data(try MeshIdentity(name:"replacement"))
        let marker=url.appendingPathComponent("identity/installation-v1.json"), before=try Data(contentsOf:marker)
        XCTAssertThrowsError(try loader(keys,url).load(name:"again"))
        XCTAssertEqual(try Data(contentsOf:marker),before); XCTAssertEqual(keys.writes,1)
    }
    func testFullDiskDuringLegacyMarkerMigrationKeepsExistingIdentityReadable() throws {
        let keys=Keys(), url=root(), old=try MeshIdentity(name:"old")
        keys.values["device"]=data(old)
        _ = try MeshStore(directory:url.appendingPathComponent("history"),identity:old)
        var migration=loader(keys,url)
        migration.commitState = { _,_ in throw InstallationIdentityError.couldNotSynchronize }
        XCTAssertEqual(try migration.load(name:"updated").card.id,old.card.id)
        XCTAssertEqual(keys.writes,0)
        XCTAssertEqual(try loader(keys,url).load(name:"retry").card.id,old.card.id)
    }
}
