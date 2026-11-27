import XCTest
import BoundedSQLite
@testable import NearChatCore

final class RobustnessTests: XCTestCase {
    private struct Generator {
        var state: UInt64 = 0x4e65617243686174
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }
    func testMalformedPacketCorpusAndTruncationsFailWithoutCrashing() throws {
        let sender = try MeshIdentity(name: "sender"), now = Date()
        let valid = try MeshPacket.make(identity: sender, kind: .presence,
            cleartext: JSONEncoder().encode(PresenceInfo(sessionID: UUID())), now: now).encoded()
        for count in 0..<valid.count { XCTAssertThrowsError(try MeshPacket.decode(valid.prefix(count), now: now)) }
        var generator = Generator()
        for _ in 0..<1000 {
            let count = Int(generator.next() % 2048)
            let bytes = Data((0..<count).map { _ in UInt8(truncatingIfNeeded: generator.next() >> 32) })
            XCTAssertThrowsError(try MeshPacket.decode(bytes, now: now))
        }
        XCTAssertThrowsError(try MeshPacket.decode(Data(repeating: 0, count: MeshPacket.maxWireBytes + 1), now: now))
        XCTAssertThrowsError(try MeshPacket.decode(Data((String(repeating: "[", count: 1000) + String(repeating: "]", count: 1000)).utf8), now: now))
        XCTAssertNoThrow(try MeshPacket.decode(valid, now: now))
    }
    func testRandomChunkingPreservesFramesAndInvalidStreamCanBeReset() throws {
        var random = Generator(), decoder = FrameDecoder()
        let expected = (0..<70).map { Data(repeating: UInt8($0), count: 1 + $0 * 9) }
        let wire = expected.reduce(Data()) { $0 + FrameDecoder.frame($1) }
        var decoded: [Data] = [], offset = 0
        while offset < wire.count {
            let end = min(wire.count, offset + 1 + Int(random.next() % 1000))
            decoded += try decoder.append(wire.subdata(in: offset..<end)); offset = end
        }
        XCTAssertEqual(decoded, expected)
        for header: [UInt8] in [[0,0,0,0], [0,0,128,1], [255,255,255,255]] {
            XCTAssertThrowsError(try decoder.append(Data(header)))
            XCTAssertEqual(try decoder.append(FrameDecoder.frame(Data([42]))), [Data([42])])
        }
        XCTAssertThrowsError(try decoder.append(Data(repeating: 0, count: 65_537)))
        XCTAssertEqual(try decoder.append(FrameDecoder.frame(Data([43]))), [Data([43])])
    }
    func testTamperedSQLiteCiphertextFailsClosedAndIsNotReset() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try MeshIdentity(name: "owner"), peer = try MeshIdentity(name: "peer")
        let file = root.appendingPathComponent("archive.sqlite")
        do {
            let store = try MeshStore(directory: root, identity: identity)
            let entry = ChatEntry(id: UUID(), sender: peer.card, recipient: identity.card.id, recipientName: "owner",
                text: "private \(UUID())", isPublic: false, outgoing: false, state: .received, date: Date(), hops: 1)
            try store.importLegacy([entry])
        }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "UPDATE records SET value=zeroblob(length(value)) WHERE space='history'", nil, nil, nil), SQLITE_OK)
        func rows() throws -> [String] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT space,id,hex(value),seq FROM records ORDER BY seq", -1, &statement, nil) == SQLITE_OK else { throw MeshStorageError.corrupt }
            defer { sqlite3_finalize(statement) }
            var values: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                values.append((0..<4).map { String(cString: sqlite3_column_text(statement, Int32($0))) }.joined(separator: "|"))
            }
            return values
        }
        let damagedRows = try rows()
        XCTAssertThrowsError(try MeshStore(directory: root, identity: identity))
        XCTAssertEqual(try rows(), damagedRows, "A failed open must preserve records, including corrupt ciphertext")
    }
    #if os(macOS)
    func testKilledWriterRollsBackHotJournalWithoutLosingHistoryOrOutbox() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try MeshIdentity(name: "owner"), peer = try MeshIdentity(name: "peer")
        let now = Date(), file = root.appendingPathComponent("archive.sqlite")
        var ids: [UUID] = []
        do {
            let store = try MeshStore(directory: root, identity: identity)
            for _ in 0..<30 {
                let text = String(repeating: "я", count: 1000)
                let packet = try MeshPacket.make(identity: identity, kind: .message, recipient: peer.card,
                    cleartext: JSONEncoder().encode(ChatPayload(text: text, isPublic: false)), now: now)
                let entry = ChatEntry(id: packet.body.id, sender: identity.card, recipient: peer.card.id,
                    recipientName: "peer", text: text, isPublic: false, outgoing: true, state: .queued, date: now, hops: 0)
                try store.enqueue(entry, packets: [(packet, peer.card)]); ids.append(entry.id)
            }
        }
        let before = try Data(contentsOf: file)
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-interactive", file.path]
        process.standardInput = input; process.standardOutput = output; process.standardError = output
        let marker = root.appendingPathComponent("writer-ready")
        try process.run()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            try? input.fileHandleForWriting.close()
        }
        try input.fileHandleForWriting.write(contentsOf: Data(".timeout 1000\nPRAGMA cache_size=1;\nPRAGMA cache_spill=ON;\nBEGIN IMMEDIATE;\nUPDATE records SET value=zeroblob(length(value)) WHERE space IN ('history','outbox');\n.once \(marker.path)\nSELECT 'ready';\n".utf8))
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while (try? String(contentsOf: marker, encoding: .utf8)) != "ready\n", ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard (try? String(contentsOf: marker, encoding: .utf8)) == "ready\n" else { return XCTFail("Writer did not reach crash point") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path + "-journal"))
        XCTAssertNotEqual(try Data(contentsOf: file), before, "Exercise recovery after actual page writes")
        kill(process.processIdentifier, SIGKILL); process.waitUntilExit()
        let transcript = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertFalse(transcript.contains("Error"), transcript)
        let recovered = try MeshStore(directory: root, identity: identity)
        XCTAssertEqual(try recovered.history().map(\.id), ids)
        XCTAssertEqual(Set(try recovered.outgoing().map { $0.packet.body.id }), Set(ids))
        XCTAssertEqual(recovered.limits.historyBytes, MeshStorageLimits.defaults.historyBytes)
    }
    #endif
}
