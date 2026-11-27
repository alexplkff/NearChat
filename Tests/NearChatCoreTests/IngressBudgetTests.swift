import XCTest
@testable import NearChatCore

final class IngressBudgetTests: XCTestCase {
    func testOneFloodingLinkLeavesBudgetForAnotherNeighbor() {
        var budget = IngressBudget()
        for _ in 0..<IngressBudget.framesPerLink { XCTAssertTrue(budget.admit(bytes: 1, link: "flood", uptime: 10)) }
        XCTAssertFalse(budget.admit(bytes: 1, link: "flood", uptime: 10))
        XCTAssertTrue(budget.admit(bytes: 1, link: "neighbor", uptime: 10))
    }
    func testAggregateLimitSurvivesLinkReconnections() {
        var budget = IngressBudget()
        for _ in 0..<IngressBudget.totalFrames {
            XCTAssertTrue(budget.admit(bytes: 1, link: "reconnect", uptime: 10))
            budget.removeLink("reconnect")
        }
        XCTAssertFalse(budget.admit(bytes: 1, link: "new", uptime: 10))
        budget.removeLinks()
        XCTAssertFalse(budget.admit(bytes: 1, link: "new session", uptime: 10))
        XCTAssertTrue(budget.admit(bytes: 1, link: "new", uptime: 11))
    }
    func testByteLimitsApplyBeforePacketParsing() {
        var budget = IngressBudget()
        for _ in 0..<32 { XCTAssertTrue(budget.admit(bytes: MeshPacket.maxWireBytes, link: "a", uptime: 10)) }
        XCTAssertFalse(budget.admit(bytes: 1, link: "a", uptime: 10))
        for _ in 0..<32 { XCTAssertTrue(budget.admit(bytes: MeshPacket.maxWireBytes, link: "b", uptime: 10)) }
        XCTAssertFalse(budget.admit(bytes: 1, link: "c", uptime: 10))
        XCTAssertTrue(budget.admit(bytes: MeshPacket.maxWireBytes, link: "a", uptime: 11))
    }
    func testInvalidSizesAndClockDoNotConsumeBudget() {
        var budget = IngressBudget()
        for size in [-1, 0, MeshPacket.maxWireBytes + 1, Int.max] {
            XCTAssertFalse(budget.admit(bytes: size, link: "a", uptime: 10))
        }
        XCTAssertFalse(budget.admit(bytes: 1, link: "a", uptime: .nan))
        XCTAssertFalse(budget.admit(bytes: 1, link: "a", uptime: .infinity))
        for _ in 0..<IngressBudget.framesPerLink { XCTAssertTrue(budget.admit(bytes: 1, link: "a", uptime: 10)) }
        XCTAssertFalse(budget.admit(bytes: 1, link: "a", uptime: 9), "A backwards clock cannot reset admission")
    }
    func testEngineUsesGlobalBudgetAcrossDifferentLinks() throws {
        let engine = MeshEngine(identity: try MeshIdentity(name: "owner"))
        engine.receiveUptime = { 10 }
        for index in 0..<3 { engine.linkOpened(id: "\(index)", transport: "test") }
        let bad = Data("invalid JSON".utf8)
        for index in 0..<256 { engine.receive(bad, from: "\(index % 3)") }
        let eventCount = engine.events.count
        let sender = try MeshIdentity(name: "sender")
        let packet = try MeshPacket.make(identity: sender, kind: .presence,
            cleartext: JSONEncoder().encode(PresenceInfo(sessionID: UUID())), now: Date())
        engine.receive(try packet.encoded(), from: "0")
        XCTAssertNil(engine.links["0"]?.peerID)
        XCTAssertEqual(engine.events.count, eventCount, "Over-budget frames never reach parsing/logging")
        engine.receiveUptime = { 11 }
        engine.receive(try packet.encoded(), from: "0")
        XCTAssertEqual(engine.links["0"]?.peerID, sender.card.id)
    }
}
