import Foundation
import CryptoKit

public struct HistoryCleanupPlan: Identifiable {
    public let id = UUID()
    public let removedMessages: Int
    public let canceledTasks: Int
    public let estimatedRecordBytes: Int64
    public let availableDeviceBytes: Int64?
    let fingerprint: Data
    let victims: [UUID]
    let rowKeys: Set<String>
}
public struct HistoryCleanupResult {
    public let removedMessages: Int
    public let canceledTasks: Int
    public let freedFileBytes: Int64
}
public enum DiskCapacity {
    public static func available(at directory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> Int64? {
        if let value = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage { return value }
        return (try? FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber)?.int64Value
    }
}
extension MeshStore {
    /// A bounded FIFO batch, never a whole-database copy. Reads only: cancellation is a no-op.
    public func prepareHistoryCleanup(availableDeviceBytes: Int64? = nil) throws -> HistoryCleanupPlan {
        var rows: [SQLiteArchive.Row] = [], victims: [UUID] = [], bytes: Int64 = 0
        for row in try own.oldestRows(space: "history", limit: 100) {
            guard let id = UUID(uuidString: row.id) else { throw MeshStorageError.corrupt }
            var batch = [row]
            for space in ["outbox", "awaiting", "delivery", "secure-intent"] { batch += try own.all(space: space, prefix: row.id + ":") }
            let size = batch.reduce(Int64(0)) { $0 + Int64($1.data.count + 64) }
            if !victims.isEmpty && bytes + size > 1_000_000 { break }
            victims.append(id); rows += batch; bytes += size
            if bytes >= 1_000_000 { break }
        }
        var hash = SHA256()
        for row in rows {
            hash.update(data: Data((row.space + "\0" + row.id + "\0" + String(row.order)).utf8)); hash.update(data: row.data)
        }
        let freePages = try own.freelistPages()
        hash.update(data: Data("pages:\(freePages)".utf8))
        guard !victims.isEmpty || freePages > 0 else { throw MeshStorageError.nothingToCleanup }
        return HistoryCleanupPlan(removedMessages: victims.count,
            canceledTasks: rows.filter { ["outbox", "awaiting", "secure-intent"].contains($0.space) }.count,
            estimatedRecordBytes: bytes, availableDeviceBytes: availableDeviceBytes,
            fingerprint: Data(hash.finalize()), victims: victims, rowKeys: Set(rows.map { $0.space + "\0" + $0.id }))
    }
    public func applyHistoryCleanup(_ plan: HistoryCleanupPlan, confirmed: Bool) throws -> HistoryCleanupResult {
        guard confirmed else { throw MeshStorageError.confirmationRequired }
        let current = try prepareHistoryCleanup(availableDeviceBytes: plan.availableDeviceBytes)
        guard current.fingerprint == plan.fingerprint, current.victims == plan.victims else { throw MeshStorageError.resizeChanged }
        let before = own.bytesOnDisk
        try own.transaction {
            for id in plan.victims {
                try own.remove(space: "history", id: id.uuidString)
                for space in ["outbox", "awaiting", "delivery", "secure-intent"] { try own.removePrefix(space: space, prefix: id.uuidString + ":") }
            }
            // Same rollback transaction: a failed compaction must not leave a
            // partially applied deletion. At most 256 free pages are reclaimed.
            try own.reclaimFreePages(256)
        }
        removeUnread(Set(plan.victims))
        return HistoryCleanupResult(removedMessages: plan.removedMessages, canceledTasks: plan.canceledTasks,
            freedFileBytes: max(0, before - own.bytesOnDisk))
    }
}
