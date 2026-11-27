import Foundation

public enum MeshStorageArea: String, Identifiable, Sendable {
    case history, relay
    public var id: String { rawValue }
    public var title: String { self == .history ? "История переписки" : "Буфер ретрансляции" }
    public var minimumMegabytes: Int64 { self == .history ? 1 : 5 }
}

public struct StorageResizePlan: Identifiable {
    public let id = UUID()
    public let area: MeshStorageArea
    public let previousLimit: Int64
    public let newLimit: Int64
    public let currentBytes: Int64
    public let resultingBytes: Int64
    public let removedMessages: Int
    public let canceledTasks: Int
    public var bytesToFree: Int64 { max(0, currentBytes - resultingBytes) }
    public var requiresConfirmation: Bool {
        newLimit < previousLimit && (removedMessages > 0 || canceledTasks > 0 || currentBytes > newLimit)
    }
    let copy: SQLiteArchive.ResizeCopy
}

struct StorageResizeResult {
    let removedHistoryIDs: Set<UUID>
    let notices: [MeshPacket]
    let warning: String?
}

extension MeshStore {
    private func archive(for area: MeshStorageArea) -> SQLiteArchive { area == .history ? own : relay }
    private func validateResize(_ area: MeshStorageArea, bytes: Int64) throws {
        guard bytes >= area.minimumMegabytes * 1_000_000, bytes % 1_000_000 == 0,
              bytes / 1_000_000 <= Int64(Int32.max),
              (bytes - 8192) / 8200 <= 4_294_967_294 else { throw MeshStorageError.invalidBudget }
    }
    public func prepareResize(_ area: MeshStorageArea, to bytes: Int64, now: Date = Date()) throws -> StorageResizePlan {
        try validateResize(area, bytes: bytes)
        try cleanup(now: now)
        let archive = archive(for: area)
        let records = try archive.recordInfo()
        let candidates = records.filter { record in
            area == .history ? record.space == "history" : ["relay", "origin", "originAwaiting"].contains(record.space)
        }
        func excluded(_ count: Int) -> Set<String> {
            let victims = candidates.prefix(count)
            if area == .relay { return Set(victims.map(\.key)) }
            let ids = Set(victims.map(\.id))
            return Set(records.filter {
                ($0.space == "history" && ids.contains($0.id)) ||
                (["outbox", "awaiting", "delivery", "secure-intent"].contains($0.space) && ids.contains(String($0.id.prefix(36))))
            }.map(\.key))
        }
        var low = 0, high = candidates.count
        var best: SQLiteArchive.ResizeCopy?
        // Find the smallest FIFO prefix whose compacted result fits, without modifying the source.
        do { best = try archive.resizedCopy(to: bytes, excluding: []) }
        catch MeshStorageError.budgetFull {
            guard bytes < archive.budget else { throw MeshStorageError.capacity }
            low = 1
        }
        if best == nil {
            guard !candidates.isEmpty else { throw MeshStorageError.budgetTooSmall }
            do { best = try archive.resizedCopy(to: bytes, excluding: excluded(high)) }
            catch MeshStorageError.budgetFull { throw MeshStorageError.budgetTooSmall }
            while low < high {
                let middle = low + (high - low) / 2
                do {
                    let copy = try archive.resizedCopy(to: bytes, excluding: excluded(middle))
                    high = middle; best = copy
                } catch MeshStorageError.budgetFull { low = middle + 1 }
            }
            // The last successful midpoint may precede the final lower bound.
            best = try archive.resizedCopy(to: bytes, excluding: excluded(low))
        }
        guard let copy = best else { throw MeshStorageError.budgetTooSmall }
        return makePlan(area: area, bytes: bytes, copy: copy)
    }
    private func makePlan(area: MeshStorageArea, bytes: Int64, copy: SQLiteArchive.ResizeCopy) -> StorageResizePlan {
        let tasks = copy.removed.filter { ["outbox", "awaiting", "secure-intent", "relay", "origin", "originAwaiting"].contains($0.space) }.count
        return StorageResizePlan(area: area, previousLimit: archive(for: area).budget, newLimit: bytes,
            currentBytes: copy.currentBytes, resultingBytes: copy.resultingBytes,
            removedMessages: copy.removed.filter { $0.space == "history" }.count, canceledTasks: tasks, copy: copy)
    }
    func applyResize(_ plan: StorageResizePlan, confirmed: Bool, now: Date) throws -> StorageResizeResult {
        guard !plan.requiresConfirmation || confirmed else { throw MeshStorageError.confirmationRequired }
        let archive = archive(for: plan.area)
        guard archive.budget == plan.previousLimit else { throw MeshStorageError.resizeChanged }
        let current = try prepareResize(plan.area, to: plan.newLimit, now: now)
        guard current.copy.fingerprint == plan.copy.fingerprint,
              current.resultingBytes == plan.resultingBytes,
              current.canceledTasks == plan.canceledTasks else { throw MeshStorageError.resizeChanged }
        let notices = plan.area == .relay ? try releaseNotices(for: current.copy.removed, now: now) : []
        let result = try archive.resizedCopy(to: plan.newLimit, excluding: Set(current.copy.removed.map(\.key))) {
            $0.fingerprint == current.copy.fingerprint && $0.resultingBytes == current.resultingBytes
        }
        guard result.installed else { throw MeshStorageError.resizeChanged }
        let removedIDs = Set(current.copy.removed.filter { $0.space == "history" }.compactMap { UUID(uuidString: $0.id) })
        removeUnread(removedIDs)
        return StorageResizeResult(removedHistoryIDs: removedIDs, notices: notices, warning: result.warning)
    }
    private func releaseNotices(for removed: [SQLiteArchive.RecordInfo], now: Date) throws -> [MeshPacket] {
        let offers = try relay.all(space: "accepted").map { try JSONDecoder().decode(AcceptedOffer.self, from: $0.data) }
        var notices: [MeshPacket] = []
        for row in removed where row.space == "relay" {
            guard let task = try relay.decode(TransferTask.self, space: "relay", id: row.id),
                  task.packet.deadline > now, let ownOffer = task.packet.offer else { continue }
            for parent in offers where parent.ownOfferID == ownOffer.body.id {
                let value = ReleaseNotice(recipientID: task.packet.body.recipient ?? "", packetID: task.packet.body.id,
                    digest: try task.packet.digest(), offerID: parent.incoming.body.id)
                if let packet = try? MeshPacket.make(identity: identity, kind: .notice, recipient: parent.incoming.body.owner,
                    cleartext: JSONEncoder().encode(value), now: now, expiresAt: task.packet.deadline) {
                    notices.append(packet)
                }
            }
        }
        return notices
    }
}
