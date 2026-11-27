import Foundation

/// Bounds parsing/signature work across all links. Used on the engine's serial executor.
/// The clock is monotonic in the app; transport reconnects cannot reset the global budget.
struct IngressBudget {
    static let framesPerLink = 100
    static let bytesPerLink = 1_048_576
    static let totalFrames = 256
    static let totalBytes = 2_097_152
    private struct Window {
        var start: TimeInterval
        var frames = 0
        var bytes = 0
        mutating func refresh(_ time: TimeInterval) {
            if time - start >= 1 { self = Window(start: time) }
        }
    }
    private var total: Window?
    private var links: [String: Window] = [:]
    mutating func admit(bytes: Int, link: String, uptime: TimeInterval) -> Bool {
        guard (1...MeshPacket.maxWireBytes).contains(bytes), uptime.isFinite else { return false }
        var global = total ?? Window(start: uptime), local = links[link] ?? Window(start: uptime)
        global.refresh(uptime); local.refresh(uptime)
        guard local.frames < Self.framesPerLink, bytes <= Self.bytesPerLink - local.bytes,
              global.frames < Self.totalFrames, bytes <= Self.totalBytes - global.bytes else {
            total = global; links[link] = local; return false
        }
        global.frames += 1; global.bytes += bytes
        local.frames += 1; local.bytes += bytes
        total = global; links[link] = local
        return true
    }
    mutating func removeLink(_ id: String) { links.removeValue(forKey: id) }
    mutating func removeLinks() { links.removeAll() }
}
