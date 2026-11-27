import XCTest
@testable import NearChatCore

final class GroupTests: XCTestCase {
    private var roots: [URL] = []
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []; super.tearDown()
    }
    private func node(_ name: String) throws -> MeshEngine {
        let identity = try MeshIdentity(name: name)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NearChatGroups-" + UUID().uuidString)
        roots.append(root)
        return try reopen(identity, at: root)
    }
    private func reopen(_ identity: MeshIdentity, at root: URL) throws -> MeshEngine {
        try MeshEngine(identity: identity, store: MeshStore(directory: root, identity: identity), clock: { self.now })
    }
    private func sync(_ source: MeshEngine, _ target: MeshEngine, _ id: UUID) throws {
        for event in source.groupEvents(id) { try target.applyGroupEvent(event) }
    }
    private func group(_ node: MeshEngine, _ id: UUID) throws -> ClosedGroup {
        try XCTUnwrap(node.closedGroups.first { $0.id == id })
    }
    @discardableResult private func join(_ member: MeshEngine, inviter: MeshEngine, creator: MeshEngine, id: UUID) throws -> GroupEvent {
        let invitation = try inviter.makeGroupInvitation(to: member.identity.card, groupID: id)
        let consent = try GroupJoinConsent.accept(invitation, by: member.identity, now: now)
        let event = try creator.finalizeGroupJoin(consent)
        try sync(creator, member, id)
        if inviter !== creator { try sync(creator, inviter, id) }
        return event
    }
    func testCreateDefaultsAndIndependentLimitsSurviveRestart() throws {
        let a = try node("creator")
        let first = try a.createClosedGroup(name: "Company")
        let second = try a.createClosedGroup(name: "Family", memberLimit: 3)
        XCTAssertEqual(try group(a, first).memberLimit, 32)
        XCTAssertEqual(try group(a, first).members.count, 1)
        XCTAssertEqual(try group(a, second).memberLimit, 3)
        let restored = try reopen(a.identity, at: roots[0])
        XCTAssertEqual(restored.closedGroups, a.closedGroups)
        XCTAssertNil(restored.sessionID)
    }
    func testInvalidNamesAndLimitsDoNotCreateGroups() throws {
        let a = try node("creator")
        for name in [" ", String(repeating: "a", count: 65), String(repeating: "🇦🇲", count: 40)] {
            XCTAssertThrowsError(try a.createClosedGroup(name: name))
        }
        for limit in [0, -1, 33] { XCTAssertThrowsError(try a.createClosedGroup(name: "group", memberLimit: limit)) }
        XCTAssertTrue(a.closedGroups.isEmpty)
    }
    func testOnlyCreatorChangesLimitAndNeverBelowCurrentOfflineMembers() throws {
        let a = try node("a"), b = try node("b")
        let id = try a.createClosedGroup(name: "group")
        try join(b, inviter: a, creator: a, id: id)
        XCTAssertNil(b.sessionID) // Offline members still occupy a place.
        XCTAssertThrowsError(try b.setGroupMemberLimit(4, groupID: id))
        XCTAssertThrowsError(try a.setGroupMemberLimit(1, groupID: id))
        XCTAssertThrowsError(try a.setGroupMemberLimit(33, groupID: id))
        try a.setGroupMemberLimit(2, groupID: id)
        XCTAssertEqual(try group(a, id).members.count, 2)
    }
    func testInvitationIsNotMembershipAndOnlyInviteeCanConsent() throws {
        let a = try node("a"), b = try node("b"), outsider = try node("outsider")
        let id = try a.createClosedGroup(name: "group")
        let invitation = try a.makeGroupInvitation(to: b.identity.card, groupID: id)
        XCTAssertEqual(try group(a, id).members.count, 1)
        XCTAssertThrowsError(try GroupJoinConsent.accept(invitation, by: outsider.identity, now: now))
        let forged = GroupJoinConsent(body: GroupJoinConsentBody(attemptID: UUID(), invitation: invitation,
            acceptedAt: Int64(now.timeIntervalSince1970)), signature: Data(repeating: 0, count: 64))
        XCTAssertThrowsError(try a.finalizeGroupJoin(forged))
        XCTAssertEqual(try group(a, id).members.count, 1)
    }
    func testAnyCurrentMemberCanInviteButCannotFinalizeOrExclude() throws {
        let a = try node("a"), b = try node("b"), c = try node("c")
        let id = try a.createClosedGroup(name: "group")
        try join(b, inviter: a, creator: a, id: id)
        let invitation = try b.makeGroupInvitation(to: c.identity.card, groupID: id)
        let consent = try GroupJoinConsent.accept(invitation, by: c.identity, now: now)
        XCTAssertThrowsError(try b.finalizeGroupJoin(consent))
        XCTAssertThrowsError(try b.excludeGroupMember(a.identity.card.id, groupID: id))
        try a.finalizeGroupJoin(consent)
        XCTAssertEqual(try group(a, id).members.count, 3)
        try sync(a,c,id)
        XCTAssertTrue(try group(c,id).canSend(as: c.identity.card.id))
    }
    func testFullAttemptRemainsTerminalAfterIncreasingLimitAndRestart() throws {
        let a = try node("a"), b = try node("b")
        let id = try a.createClosedGroup(name: "group", memberLimit: 1)
        let invite = try a.makeGroupInvitation(to: b.identity.card, groupID: id)
        let consent = try GroupJoinConsent.accept(invite, by: b.identity, now: now)
        XCTAssertThrowsError(try a.finalizeGroupJoin(consent)) { XCTAssertEqual($0 as? GroupError, .groupFull) }
        try a.setGroupMemberLimit(2, groupID: id)
        let restored = try reopen(a.identity, at: roots[0])
        XCTAssertThrowsError(try restored.finalizeGroupJoin(consent)) { XCTAssertEqual($0 as? GroupError, .groupFull) }
        let newConsent = try GroupJoinConsent.accept(invite, by: b.identity, now: now)
        try restored.finalizeGroupJoin(newConsent)
        XCTAssertEqual(try group(restored,id).members.count, 2)
    }
    func testConcurrentLastPlaceAndDuplicateAdmissionOccupyItOnce() throws {
        let a = try node("a"), b = try node("b"), c = try node("c")
        let id = try a.createClosedGroup(name: "group", memberLimit: 2)
        let bConsent = try GroupJoinConsent.accept(a.makeGroupInvitation(to: b.identity.card, groupID: id), by: b.identity, now: now)
        let cConsent = try GroupJoinConsent.accept(a.makeGroupInvitation(to: c.identity.card, groupID: id), by: c.identity, now: now)
        let first = try a.finalizeGroupJoin(bConsent)
        XCTAssertEqual(try a.finalizeGroupJoin(bConsent), first)
        XCTAssertThrowsError(try a.finalizeGroupJoin(cConsent)) { XCTAssertEqual($0 as? GroupError, .groupFull) }
        XCTAssertEqual(try group(a,id).members.count, 2)
        XCTAssertEqual(a.groupEvents(id).count, 2)
    }
    func testInvitationAndFixationHaveSeparateImmutableDeadlines() throws {
        let a = try node("a"), b = try node("b")
        let id = try a.createClosedGroup(name: "group")
        let invite = try a.makeGroupInvitation(to: b.identity.card, groupID: id)
        now.addTimeInterval(86_399)
        let consent = try GroupJoinConsent.accept(invite, by: b.identity, now: now)
        now.addTimeInterval(2)
        XCTAssertThrowsError(try GroupJoinConsent.accept(invite, by: b.identity, now: now))
        try a.finalizeGroupJoin(consent) // Invitation expired, but timely consent has its own window.
        now.addTimeInterval(86_400)
        let count = a.groupEvents(id).count
        try a.finalizeGroupJoin(consent) // Duplicate returns its original result after both deadlines.
        XCTAssertEqual(a.groupEvents(id).count, count)
    }
    func testFirstReceivedExpiredConsentCannotJoin() throws {
        let a = try node("a"), b = try node("b")
        let id = try a.createClosedGroup(name: "group")
        let consent = try GroupJoinConsent.accept(a.makeGroupInvitation(to: b.identity.card, groupID: id), by: b.identity, now: now)
        now.addTimeInterval(86_400)
        XCTAssertThrowsError(try a.finalizeGroupJoin(consent)) { XCTAssertEqual($0 as? GroupError, .joinExpired) }
        XCTAssertEqual(try group(a,id).members.count, 1)
    }
    func testKnownDepartedInviterCannotCompleteOldInvitation() throws {
        let a = try node("a"), b = try node("b"), c = try node("c")
        let id = try a.createClosedGroup(name: "group")
        try join(b, inviter: a, creator: a, id: id)
        let consent = try GroupJoinConsent.accept(b.makeGroupInvitation(to: c.identity.card, groupID: id), by: c.identity, now: now)
        let departure = try XCTUnwrap(b.leaveClosedGroup(id))
        try a.applyGroupDeparture(departure)
        XCTAssertThrowsError(try a.finalizeGroupJoin(consent)) { XCTAssertEqual($0 as? GroupError, .inviterLeft) }
        XCTAssertNil(try group(a,id).member(c.identity.card.id))
        XCTAssertThrowsError(try b.makeGroupInvitation(to: c.identity.card, groupID: id))
    }
    func testOrdinaryLeaveIsImmediateOfflineAndSurvivesRestart() throws {
        let a = try node("a"), b = try node("b")
        let id = try a.createClosedGroup(name: "group")
        try join(b, inviter: a, creator: a, id: id)
        let departure = try XCTUnwrap(b.leaveClosedGroup(id))
        XCTAssertFalse(try group(b,id).canSend(as: b.identity.card.id))
        XCTAssertFalse(try group(b,id).isClosed)
        let restored = try reopen(b.identity, at: roots[1])
        XCTAssertFalse(try group(restored,id).canSend(as: b.identity.card.id))
        XCTAssertEqual(try restored.leaveClosedGroup(id), departure)
        XCTAssertNotNil(try group(a,id).member(b.identity.card.id)) // Creator has not received the proof yet.
        try a.applyGroupDeparture(departure)
        XCTAssertNil(try group(a,id).member(b.identity.card.id))
    }
    func testCreatorOfflineDoesNotCloseButExplicitExitIsFinal() throws {
        let a = try node("a"), b = try node("b")
        let id = try a.createClosedGroup(name: "group")
        try join(b, inviter: a, creator: a, id: id)
        a.endNetworking(); now.addTimeInterval(100_000); a.tick(); b.tick()
        XCTAssertTrue(try group(b,id).canSend(as: b.identity.card.id))
        XCTAssertNil(try a.leaveClosedGroup(id))
        try sync(a,b,id)
        XCTAssertTrue(try group(b,id).isClosed)
        XCTAssertFalse(try group(b,id).canSend(as: b.identity.card.id))
        XCTAssertThrowsError(try a.setGroupMemberLimit(3, groupID: id))
        let restored = try reopen(b.identity, at: roots[1])
        XCTAssertTrue(try group(restored,id).isClosed)
        try sync(a,restored,id)
        XCTAssertTrue(try group(restored,id).isClosed)
    }
    func testExclusionRequiresCreatorPermissionAndFreshInvitationForReturn() throws {
        let a = try node("a"), b = try node("b")
        let id = try a.createClosedGroup(name: "group")
        let oldInvite = try a.makeGroupInvitation(to: b.identity.card, groupID: id)
        try a.finalizeGroupJoin(GroupJoinConsent.accept(oldInvite, by: b.identity, now: now))
        try a.excludeGroupMember(b.identity.card.id, groupID: id)
        XCTAssertThrowsError(try a.makeGroupInvitation(to: b.identity.card, groupID: id))
        try a.permitGroupReturn(b.identity.card.id, groupID: id)
        let oldConsent = try GroupJoinConsent.accept(oldInvite, by: b.identity, now: now)
        XCTAssertThrowsError(try a.finalizeGroupJoin(oldConsent)) { XCTAssertEqual($0 as? GroupError, .returnPermissionRequired) }
        try join(b, inviter: a, creator: a, id: id)
        XCTAssertNotEqual(try group(a,id).member(b.identity.card.id)?.membershipID, oldConsent.body.attemptID)
    }
    func testExcludedInviterCannotInviteAndOldAdmissionDoesNotUndoExclusion() throws {
        let a = try node("a"), b = try node("b"), c = try node("c")
        let id = try a.createClosedGroup(name: "group")
        let admission = try join(b, inviter: a, creator: a, id: id)
        try a.excludeGroupMember(b.identity.card.id, groupID: id); try sync(a,b,id)
        XCTAssertFalse(try b.applyGroupEvent(admission))
        XCTAssertFalse(try group(b,id).canSend(as: b.identity.card.id))
        XCTAssertThrowsError(try b.makeGroupInvitation(to: c.identity.card, groupID: id))
    }
    func testAudienceIsFixedAndRejoinedPeriodRejectsOldMessagesAndOldDeparture() throws {
        let a = try node("a"), b = try node("b"), c = try node("c")
        let id = try a.createClosedGroup(name: "group")
        try join(b, inviter: a, creator: a, id: id)
        let oldAudience = try group(a,id).audience(for: a.identity.card.id)
        XCTAssertTrue(try group(b,id).permitsMessage(from: a.identity.card, audience: oldAudience, to: b.identity.card.id))
        let departure = try XCTUnwrap(b.leaveClosedGroup(id)); try a.applyGroupDeparture(departure)
        try join(b, inviter: a, creator: a, id: id)
        try join(c, inviter: a, creator: a, id: id); try sync(a,b,id)
        XCTAssertFalse(try group(b,id).permitsMessage(from: a.identity.card, audience: oldAudience, to: b.identity.card.id))
        XCTAssertFalse(try group(c,id).permitsMessage(from: a.identity.card, audience: oldAudience, to: c.identity.card.id))
        try b.applyGroupDeparture(departure)
        XCTAssertTrue(try group(b,id).canSend(as: b.identity.card.id))
        let fresh = try group(a,id).audience(for: a.identity.card.id)
        XCTAssertTrue(try group(b,id).permitsMessage(from: a.identity.card, audience: fresh, to: b.identity.card.id))
        XCTAssertEqual(oldAudience.recipients.count, 1)
    }
    func testKnownExitExclusionAndClosureRejectLateAuthorMessages() throws {
        let a = try node("a"), b = try node("b"), c = try node("c")
        let id = try a.createClosedGroup(name: "group")
        try join(b, inviter: a, creator: a, id: id); try join(c, inviter: a, creator: a, id: id); try sync(a,b,id)
        let audience = try group(b,id).audience(for: b.identity.card.id)
        let departure = try XCTUnwrap(b.leaveClosedGroup(id))
        try c.applyGroupDeparture(departure)
        XCTAssertFalse(try group(c,id).permitsMessage(from: b.identity.card, audience: audience, to: c.identity.card.id))
        // A still knows the old composition until it receives a trusted event.
        XCTAssertTrue(try group(a,id).permitsMessage(from: b.identity.card, audience: audience, to: a.identity.card.id))
        try a.excludeGroupMember(b.identity.card.id, groupID: id); try sync(a,c,id)
        XCTAssertFalse(try group(c,id).permitsMessage(from: b.identity.card, audience: audience, to: c.identity.card.id))
        let current = try group(a,id).audience(for: a.identity.card.id)
        try a.leaveClosedGroup(id); try sync(a,c,id)
        XCTAssertFalse(try group(c,id).permitsMessage(from: a.identity.card, audience: current, to: c.identity.card.id))
    }
    func testInvalidSignerAndForkCannotAlterGroupAndGapNeedsReplay() throws {
        let a = try node("a"), b = try node("b"), attacker = try node("attacker")
        let id = try a.createClosedGroup(name: "group")
        let first = try XCTUnwrap(a.groupEvents(id).first)
        try a.setGroupMemberLimit(2, groupID: id)
        let second = try XCTUnwrap(a.groupEvents(id).last)
        XCTAssertThrowsError(try b.applyGroupEvent(second))
        try b.applyGroupEvent(first)
        let forged = GroupEvent(body: second.body, signature: try attacker.identity.signing.signature(for: MeshPacket.encoder.encode(second.body)))
        XCTAssertThrowsError(try b.applyGroupEvent(forged))
        try b.applyGroupEvent(second)
        let forkBody = GroupEventBody(groupID: id, revision: 2, previousDigest: try first.digest(), creator: a.identity.card,
            createdAt: Int64(now.timeIntervalSince1970), change: .limitChanged(3))
        let fork = GroupEvent(body: forkBody, signature: try a.identity.signing.signature(for: MeshPacket.encoder.encode(forkBody)))
        XCTAssertThrowsError(try b.applyGroupEvent(fork)) { XCTAssertEqual($0 as? GroupError, .conflictingEvent) }
        XCTAssertEqual(try group(b,id).memberLimit, 2)
    }
    func testWriteFailureDoesNotApplyOrAnnounceGroupMutation() throws {
        let a = try node("a")
        let id = try a.createClosedGroup(name: "group")
        let directory = roots[0]
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        guard !FileManager.default.isWritableFile(atPath: directory.path) else { throw XCTSkip("Permissions bypassed") }
        XCTAssertThrowsError(try a.setGroupMemberLimit(2, groupID: id))
        XCTAssertThrowsError(try a.leaveClosedGroup(id))
        XCTAssertEqual(try group(a,id).memberLimit, 32)
        XCTAssertFalse(try group(a,id).isClosed)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let restored = try reopen(a.identity, at: directory)
        XCTAssertEqual(restored.closedGroups, a.closedGroups)
    }
    func testGroupRecordsSurviveQuotaResizeAndAreEncrypted() throws {
        let a = try node("a")
        let name = "private group title " + UUID().uuidString.prefix(8)
        let id = try a.createClosedGroup(name: String(name))
        let plan = try a.prepareStorageResize(.history, to: 1_000_000)
        try a.applyStorageResize(plan, confirmed: true)
        let restored = try reopen(a.identity, at: roots[0])
        XCTAssertEqual(try group(restored,id), try group(a,id))
        let bytes = try Data(contentsOf: roots[0].appendingPathComponent("archive.sqlite"))
        XCTAssertNil(bytes.range(of: Data(name.utf8)))
    }
    func testWithoutStorageGroupCannotBeCreated() throws {
        let a = MeshEngine(identity: try MeshIdentity(name: "a"))
        XCTAssertThrowsError(try a.createClosedGroup(name: "group"))
        XCTAssertTrue(a.closedGroups.isEmpty)
    }
    func testSmallClockSkewDoesNotTurnTimelyConsentIntoExpiry() throws {
        let a = try node("a"), b = try node("b")
        let id = try a.createClosedGroup(name: "group")
        let invite = try a.makeGroupInvitation(to: b.identity.card, groupID: id)
        let slightlyBehind = try GroupJoinConsent.accept(invite, by: b.identity, now: now.addingTimeInterval(-3))
        try a.finalizeGroupJoin(slightlyBehind)
        XCTAssertEqual(try group(a,id).members.count, 2)
    }
    func testSameHistoricalPeriodCannotBeReintroducedByNewEvent() throws {
        let a = try node("a"), b = try node("b")
        let id = try a.createClosedGroup(name: "group")
        let admission = try join(b, inviter: a, creator: a, id: id)
        let departure = try XCTUnwrap(b.leaveClosedGroup(id)); try a.applyGroupDeparture(departure)
        let tail = try XCTUnwrap(a.groupEvents(id).last)
        let body = GroupEventBody(groupID: id, revision: tail.body.revision + 1, previousDigest: try tail.digest(),
            creator: a.identity.card, createdAt: Int64(now.timeIntervalSince1970), change: admission.body.change)
        let replay = GroupEvent(body: body, signature: try a.identity.signing.signature(for: MeshPacket.encoder.encode(body)))
        XCTAssertThrowsError(try a.applyGroupEvent(replay))
        XCTAssertNil(try group(a,id).member(b.identity.card.id))
    }
    func testHistoryFIFODoesNotEraseGroupAuthorityOrClosure() throws {
        let identity = try MeshIdentity(name: "a")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NearChatGroups-" + UUID().uuidString)
        roots.append(root)
        let store = try MeshStore(directory: root, identity: identity,
            limits: MeshStorageLimits(historyBytes: 262_144, relayBytes: 5_000_000))
        let a = try MeshEngine(identity: identity, store: store, clock: { self.now })
        let id = try a.createClosedGroup(name: "retained group")
        try a.leaveClosedGroup(id)
        let entries = (0..<140).map { index in
            ChatEntry(id: UUID(), sender: identity.card, recipient: "*", recipientName: "Общий чат",
                text: String(repeating: "x", count: 1000), isPublic: true, outgoing: true, state: .delivered,
                date: now.addingTimeInterval(Double(index)), hops: 0, isSaved: true)
        }
        for entry in entries { try store.enqueue(entry, packets: []) }
        XCTAssertLessThan(try store.history(limit: 200).count, entries.count)
        let restored = try reopen(identity, at: root)
        XCTAssertTrue(try group(restored,id).isClosed)
        XCTAssertEqual(restored.groupEvents(id).count, 2)
        XCTAssertLessThanOrEqual(try store.usage().historyFiles, store.limits.historyBytes)
    }
    func testCorruptEventGapInStorageFailsClosedWithoutErasingOtherData() throws {
        let a = try node("a")
        let id = try a.createClosedGroup(name: "group")
        try a.setGroupMemberLimit(3, groupID: id)
        let store = try MeshStore(directory: roots[0], identity: a.identity)
        try store.own.transaction { try store.own.remove(space: "group-event", id: id.uuidString + ":1") }
        XCTAssertThrowsError(try reopen(a.identity, at: roots[0]))
        XCTAssertNotNil(try store.own.row(space: "group-event", id: id.uuidString + ":2"))
    }
    func testMissingTailCannotReopenPreviouslyClosedGroup() throws {
        let a = try node("a")
        let id = try a.createClosedGroup(name: "group")
        try a.leaveClosedGroup(id)
        let store = try MeshStore(directory: roots[0], identity: a.identity)
        try store.own.transaction { try store.own.remove(space: "group-event", id: id.uuidString + ":2") }
        XCTAssertThrowsError(try reopen(a.identity, at: roots[0]))
        XCTAssertNotNil(try store.own.row(space: "group-head", id: id.uuidString))
    }
}
