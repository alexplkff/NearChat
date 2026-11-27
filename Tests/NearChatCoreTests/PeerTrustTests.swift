import XCTest
@testable import NearChatCore

final class PeerTrustTests: XCTestCase {
    func testSafetyCodesMatchOnBothEndsAndBindBothKeys() throws {
        let a = try MeshIdentity(name: "same"), b = try MeshIdentity(name: "same")
        XCTAssertEqual(a.card.safetyCode(with: b.card), b.card.safetyCode(with: a.card))
        XCTAssertEqual(a.card.safetyCode(with: b.card).count, 64)
        let changed = try MeshIdentity(name: "same", signingKey: b.signingKeyData)
        XCTAssertEqual(changed.card.id, b.card.id)
        XCTAssertNotEqual(a.card.safetyCode(with: b.card), a.card.safetyCode(with: changed.card))
        var renamed = b; renamed.name = "renamed"
        XCTAssertEqual(b.card.keyFingerprint, renamed.card.keyFingerprint)
    }
    func testVerificationPersistsAndChangedKeyBlocksUntilFreshComparison() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try MeshIdentity(name: "a"), b = try MeshIdentity(name: "b")
        let store = try MeshStore(directory: root, identity: a)
        let book = PeerTrustBook(identity: a, store: { store })
        try book.observe(b.card)
        XCTAssertEqual(book.info(b.card).status, .unverified)
        let code = a.card.safetyCode(with: b.card)
        XCTAssertThrowsError(try book.verify(b.card, code: "incorrect"))
        try book.verify(b.card, code: code)
        let reopened = PeerTrustBook(identity: a, store: { store }); try reopened.load()
        XCTAssertEqual(reopened.info(b.card).status, .verified)
        let replacement = try MeshIdentity(name: "b", signingKey: b.signingKeyData)
        try reopened.observe(replacement.card)
        XCTAssertEqual(reopened.info(replacement.card).status, .changed)
        XCTAssertThrowsError(try reopened.requireUnchanged(replacement.card))
        XCTAssertThrowsError(try reopened.verify(replacement.card, code: code), "Stale confirmation cannot approve a changed key")
        try reopened.verify(replacement.card, code: a.card.safetyCode(with: replacement.card))
        XCTAssertEqual(reopened.info(replacement.card).status, .verified)
    }
    func testKeyChangeWarningLatchesAndRetiredKeyCannotUndoVerification() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try MeshIdentity(name: "a"), b = try MeshIdentity(name: "b")
        let store = try MeshStore(directory: root, identity: a)
        let book = PeerTrustBook(identity: a, store: { store })
        try book.observe(b.card); try book.verify(b.card, code: a.card.safetyCode(with: b.card))
        let changed = try MeshIdentity(name: "b", signingKey: b.signingKeyData)
        try book.observe(changed.card); try book.observe(b.card)
        XCTAssertEqual(book.info(b.card).status, .changed, "Replaying the former card must not clear the warning")
        try book.observe(changed.card)
        try book.verify(changed.card, code: a.card.safetyCode(with: changed.card))
        XCTAssertThrowsError(try book.observe(b.card))
        XCTAssertEqual(book.info(changed.card).status, .verified)
    }

    func testVerificationDoesNotTransferToDifferentLocalAgreementKey() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try MeshIdentity(name: "a"), b = try MeshIdentity(name: "b")
        let store = try MeshStore(directory: root, identity: a)
        let original = PeerTrustBook(identity: a, store: { store })
        try original.observe(b.card); try original.verify(b.card, code: a.card.safetyCode(with: b.card))
        let changedLocal = try MeshIdentity(name: "a", signingKey: a.signingKeyData)
        let reopened = PeerTrustBook(identity: changedLocal, store: { store }); try reopened.load()
        XCTAssertEqual(reopened.info(b.card).status, .changed)
        XCTAssertThrowsError(try reopened.requireUnchanged(b.card))
        XCTAssertThrowsError(try reopened.verify(b.card, code: a.card.safetyCode(with: b.card)))
        try reopened.verify(b.card, code: changedLocal.card.safetyCode(with: b.card))
        XCTAssertEqual(reopened.info(b.card).status, .verified)
    }

}
