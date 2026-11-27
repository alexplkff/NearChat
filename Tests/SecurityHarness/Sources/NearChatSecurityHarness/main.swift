import Foundation
import NearChatCore

struct Failed: Error { let message: String }
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failed(message: message) }
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("NearChat-Sanitizer-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: root) }
var time = Date(), queue: [(Int, Data)] = [], frames: [Data] = []
let firstIdentity = try MeshIdentity(name: "sanitizer-a"), secondIdentity = try MeshIdentity(name: "sanitizer-b")
let firstStore = try MeshStore(directory: root.appendingPathComponent("a"), identity: firstIdentity)
let secondStore = try MeshStore(directory: root.appendingPathComponent("b"), identity: secondIdentity)
let a = try MeshEngine(identity: firstIdentity, store: firstStore, clock: { time })
let b = try MeshEngine(identity: secondIdentity, store: secondStore, clock: { time })
a.onTransmit = { _, data in queue.append((1, data)); frames.append(data) }
b.onTransmit = { _, data in queue.append((0, data)); frames.append(data) }
func drain() throws {
    var count = 0
    while !queue.isEmpty {
        count += 1; try check(count < 5000, "unbounded network loop")
        let (target, bytes) = queue.removeFirst()
        if target == 0 { a.receive(bytes, from: "peer") } else { b.receive(bytes, from: "peer") }
    }
}
a.linkOpened(id: "peer", transport: "sanitizer"); b.linkOpened(id: "peer", transport: "sanitizer")
try drain()
try a.requestContact(to: secondIdentity.card.id); try drain()
guard let request = b.contact(for: firstIdentity.card.id)?.incomingRequestID else { throw Failed(message: "missing request") }
try b.respondToContact(from: firstIdentity.card.id, requestID: request, accept: true); try drain()
for index in 0..<5 {
    time.addTimeInterval(1)
    let id = try a.send(text: "sanitizer text \(index)", to: secondIdentity.card.id); try drain()
    b.markRead(id); try drain()
}
try check(b.messages.count == 5 && b.unreadCount == 0, "endpoint state mismatch")
try check(a.messages.allSatisfy { $0.state == .read }, "receipt state mismatch")
let textPackets = frames.compactMap { try? MeshPacket.decode($0, now: time) }.filter { $0.body.kind == .message }
try check(!textPackets.isEmpty && textPackets.allSatisfy { $0.body.version == 3 && $0.body.secure != nil }, "text transport must remain forward secure")
let valid = frames[0]
for length in 0..<valid.count { _ = try? MeshPacket.decode(Data(valid.prefix(length)), now: time) }
var seed: UInt64 = 0x4e65617243686174
func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed }
for _ in 0..<1000 {
    let count = Int(next() % 2048)
    let bytes = Data((0..<count).map { _ in UInt8(truncatingIfNeeded: next() >> 32) })
    _ = try? MeshPacket.decode(bytes, now: time)
    var decoder = FrameDecoder(); _ = try? decoder.append(bytes)
}
var decoder = FrameDecoder(), restored: [Data] = []
let wire = frames.reduce(Data()) { $0 + FrameDecoder.frame($1) }
for byte in wire { restored += try decoder.append(Data([byte])) }
try check(restored == frames, "framing mismatch")
a.endNetworking(); b.endNetworking()
let reopened = try MeshStore(directory: root.appendingPathComponent("b"), identity: secondIdentity)
let saved = try reopened.history()
try check(saved.count == 5 && saved.allSatisfy { $0.readAt != nil }, "restart mismatch")
print("PASS: in-process consent, encrypted messages, receipts, SQLite restart, 1000 malformed inputs, truncations, fragmented frames")
