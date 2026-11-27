import Foundation
import CryptoKit
import BoundedSQLite

public enum MeshStorageError: Error, LocalizedError, Equatable {
    case nothingToCleanup, sqlite(Int32), corrupt, invalidBudget, capacity, budgetFull, recordTooLarge, unavailable, resizeChanged, budgetTooSmall, confirmationRequired
    public var errorDescription: String? {
        switch self {
        case .nothingToCleanup: return "Нет старых сообщений для очистки. Освободите место в других приложениях"
        case .sqlite(let code): return "Ошибка локального хранилища (\(code))"
        case .corrupt: return "Хранилище повреждено или принадлежит другой идентичности"
        case .invalidBudget: return "Недопустимый лимит хранилища"
        case .capacity: return "Не удалось записать данные: нет места на устройстве"
        case .budgetFull: return "Достигнут выделенный лимит хранилища"
        case .recordTooLarge: return "Запись превышает допустимый размер"
        case .confirmationRequired: return "Подтвердите уменьшение лимита и очистку."
        case .resizeChanged: return "Данные изменились. Проверьте обновлённый расчёт очистки."
        case .budgetTooSmall: return "Лимит слишком мал для оставшихся служебных данных. Выберите больший объём."
        case .unavailable: return "Хранилище недоступно после ошибки восстановления транзакции"
        }
    }
}

/// One connection, used by MeshEngine's serial executor. Payloads are encrypted;
/// row kinds, UUIDs, order and expiry remain SQLite metadata, protected by iOS file protection.
final class SQLiteArchive {
    struct Row {
        let space: String
        let id: String
        let data: Data
        let expiry: Date?
        let order: Int64
    }
    let directory: URL
    private(set) var budget: Int64
    private let identity: MeshIdentity
    private let fileName: String
    private let ownsQuota: Bool
    private let ownerID: String
    private let category: String
    private let key: SymmetricKey
    private var database: OpaquePointer?
    private var quota: OpaquePointer?
    private var usable = true
    var historyChanges: Set<String> = []
    var historyNeedsReload = false
    private var stagedHistoryChanges: Set<String> = []
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    static let maxRecordBytes = 262_144

    init(directory: URL, category: String, budget requestedBudget: Int64, identity: MeshIdentity,
         fileName: String = "archive.sqlite", sharedQuota: OpaquePointer? = nil) throws {
        let budget = sharedQuota == nil ? try Self.configuredBudget(at: directory.appendingPathComponent(fileName)) ?? requestedBudget : requestedBudget
        guard budget >= 131_072 else { throw MeshStorageError.invalidBudget }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.category = category
        self.budget = budget
        self.identity = identity
        self.fileName = fileName
        ownsQuota = sharedQuota == nil
        ownerID = identity.card.id
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: identity.signingKeyData),
            salt: Data("NearChat-transactional-store-v2".utf8),
            info: Data("\(category)|\(ownerID)".utf8), outputByteCount: 32)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        var folder = self.directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                             ofItemAtPath: folder.path)
        #endif
        let protect: @convention(c) (UnsafePointer<CChar>?) -> Int32 = { path in
            guard let path else { return 0 }
            #if os(iOS)
            do {
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: String(cString: path))
            } catch { return 0 }
            #endif
            return 1
        }
        if sharedQuota == nil {
            // A prepared copy is never the commit point. After a crash only archive.sqlite is authoritative.
            try removeStagingFiles()
        }
        quota = sharedQuota ?? nc_quota_create(folder.path, "nearchat-\(UUID().uuidString)", budget, protect)
        guard let quota else { throw MeshStorageError.invalidBudget }
        do { try openConnection(initializeSchema: ownsQuota) }
        catch {
            if let database { sqlite3_close(database) }
            self.database = nil
            if ownsQuota { nc_quota_destroy(quota) }
            self.quota = nil
            throw error
        }
    }
    private func openConnection(initializeSchema: Bool = true) throws {
        usable = true
        try check(sqlite3_open_v2(directory.appendingPathComponent(fileName).path, &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nc_quota_name(quota)))
        sqlite3_busy_timeout(database, 1000)
        try execute("PRAGMA page_size=4096")
        try execute("PRAGMA auto_vacuum=INCREMENTAL")
        try execute("PRAGMA journal_mode=DELETE")
        try execute("PRAGMA synchronous=EXTRA")
        try execute("PRAGMA fullfsync=ON")
        try execute("PRAGMA temp_store=MEMORY")
        try execute("PRAGMA secure_delete=ON")
        try execute("PRAGMA mmap_size=0")
        try execute("PRAGMA cache_spill=OFF")
        // Reserve a complete rollback journal, including its per-page record headers.
        let maxPages = max(6, (budget - 8192) / (2 * 4096 + 8))
        guard maxPages <= 4_294_967_294 else { throw MeshStorageError.invalidBudget }
        try execute("PRAGMA max_page_count=\(maxPages)")
        guard try scalar("PRAGMA synchronous") == 3,
              try textScalar("PRAGMA journal_mode") == "delete" else { throw MeshStorageError.corrupt }
        if initializeSchema {
            try createSchema()
            if let row = try row(space: "meta", id: "owner") {
                guard String(data: row.data, encoding: .utf8) == ownerID else { throw MeshStorageError.corrupt }
            } else {
                guard try scalar("SELECT count(*) FROM records") == 0 else { throw MeshStorageError.corrupt }
                try transaction { try put(space: "meta", id: "owner", data: Data(ownerID.utf8)) }
            }
            let header = try scalar("PRAGMA user_version")
            if header != 0 {
                guard header * 1_000_000 == budget,
                      try decode(Int64.self, space: "meta", id: "budget") == budget else {
                    throw MeshStorageError.corrupt
                }
            }
        }
    }
    private func createSchema() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS records (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                space TEXT NOT NULL, id TEXT NOT NULL, value BLOB NOT NULL, expiry REAL,
                UNIQUE(space,id)
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS records_expiry ON records(expiry)")
        try execute("CREATE INDEX IF NOT EXISTS records_order ON records(space,seq)")
    }
    private static func configuredBudget(at file: URL) throws -> Int64? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 64) ?? Data()
        guard header.count >= 64 else { return nil }
        guard header.prefix(16) == Data("SQLite format 3\0".utf8) else { throw MeshStorageError.corrupt }
        // Resizing installs a completed database atomically. Its public header supplies
        // the opening ceiling; the matching encrypted record is verified after opening.
        let megabytes = header[60..<64].reduce(Int64(0)) { ($0 << 8) | Int64($1) }
        guard megabytes <= Int64(Int32.max) else { throw MeshStorageError.corrupt }
        return megabytes == 0 ? nil : megabytes * 1_000_000
    }
    private func removeStagingFiles() throws {
        for suffix in ["-journal", ""] {
            let path = directory.appendingPathComponent("resize.sqlite" + suffix)
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        }
    }
    deinit {
        // Never free a VFS while SQLite can still refer to it.
        if database == nil || sqlite3_close(database) == SQLITE_OK {
            if ownsQuota, let quota { nc_quota_destroy(quota) }
        }
    }
    var bytesOnDisk: Int64 { quota.map(nc_quota_usage) ?? -1 }
    func count(space: String) throws -> Int {
        let statement = try prepare("SELECT count(*) FROM records WHERE space=?")
        defer { sqlite3_finalize(statement) }
        try bind(space, at: 1, to: statement)
        try check(sqlite3_step(statement), expected: SQLITE_ROW)
        return Int(sqlite3_column_int64(statement, 0))
    }
    func last(space: String, suffix: String) throws -> Row? {
        try rows(sql: "SELECT space,id,value,expiry,seq FROM records WHERE space=? AND id LIKE ? ORDER BY seq DESC LIMIT 1",
                 arguments: [space, "%" + suffix]).first
    }

    struct RecordInfo: Codable, Equatable {
        let space: String
        let id: String
        let order: Int64
        var key: String { space + "\0" + id }
    }
    struct ResizeCopy {
        let currentBytes: Int64
        let resultingBytes: Int64
        let removed: [RecordInfo]
        let fingerprint: Data
        var installed = false
        var warning: String?
    }
    func recordInfo() throws -> [RecordInfo] {
        let statement = try prepare("SELECT space,id,seq FROM records ORDER BY seq")
        defer { sqlite3_finalize(statement) }
        var result: [RecordInfo] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { return result }
            try check(rc, expected: SQLITE_ROW)
            result.append(RecordInfo(space: String(cString: sqlite3_column_text(statement, 0)),
                id: String(cString: sqlite3_column_text(statement, 1)), order: sqlite3_column_int64(statement, 2)))
        }
    }
    private func fileBytes(_ name: String) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return (size + 4095) / 4096 * 4096
    }
    /// Prepare under the existing VFS ceiling. Only installIf can authorize the rename.
    func resizedCopy(to newBudget: Int64, excluding: Set<String>,
                     installIf: ((ResizeCopy) -> Bool)? = nil) throws -> ResizeCopy {
        let before = bytesOnDisk
        guard before >= 0 else { throw MeshStorageError.unavailable }
        let otherBytes = before - (try fileBytes(fileName))
        let stage = try SQLiteArchive(directory: directory, category: category, budget: newBudget,
            identity: identity, fileName: "resize.sqlite", sharedQuota: quota)
        defer { try? stage.closeConnection(); try? removeStagingFiles() }
        var removed: [RecordInfo] = [], hash = SHA256()
        do {
            try stage.transaction {
                try stage.createSchema()
                let read = try prepare("SELECT space,id,value,expiry,seq FROM records ORDER BY seq")
                defer { sqlite3_finalize(read) }
                let write = try stage.prepare("INSERT INTO records(seq,space,id,value,expiry) VALUES(?,?,?,?,?)")
                defer { sqlite3_finalize(write) }
                while true {
                    let rc = sqlite3_step(read)
                    if rc == SQLITE_DONE { break }
                    try check(rc, expected: SQLITE_ROW)
                    let record = RecordInfo(space: String(cString: sqlite3_column_text(read, 0)),
                        id: String(cString: sqlite3_column_text(read, 1)), order: sqlite3_column_int64(read, 4))
                    let count = sqlite3_column_bytes(read, 2)
                    guard count > 0, let blob = sqlite3_column_blob(read, 2) else { throw MeshStorageError.corrupt }
                    if excluding.contains(record.key) {
                        removed.append(record)
                        hash.update(data: try MeshPacket.encoder.encode(record))
                        hash.update(data: Data(bytes: blob, count: Int(count)))
                        continue
                    }
                    try stage.check(sqlite3_bind_int64(write, 1, record.order))
                    try stage.bind(record.space, at: 2, to: write); try stage.bind(record.id, at: 3, to: write)
                    try stage.check(sqlite3_bind_blob(write, 4, blob, count, Self.transient))
                    if sqlite3_column_type(read, 3) == SQLITE_NULL { try stage.check(sqlite3_bind_null(write, 5)) }
                    else { try stage.check(sqlite3_bind_double(write, 5, sqlite3_column_double(read, 3))) }
                    try stage.check(sqlite3_step(write), expected: SQLITE_DONE)
                    try stage.check(sqlite3_reset(write)); try stage.check(sqlite3_clear_bindings(write))
                }
                try stage.put(space: "meta", id: "budget", value: newBudget)
                try stage.execute("PRAGMA user_version=\(newBudget / 1_000_000)")
            }
        } catch MeshStorageError.budgetFull {
            // A temporary-file ceiling is not evidence that more user messages
            // must be deleted. Only the target pager limit drives FIFO selection.
            if nc_quota_failure(quota) == 1 { throw MeshStorageError.capacity }
            throw MeshStorageError.budgetFull
        }
        guard try stage.textScalar("PRAGMA quick_check") == "ok",
              try stage.row(space: "meta", id: "owner")?.data == Data(ownerID.utf8) else {
            throw MeshStorageError.corrupt
        }
        let after = try stage.fileBytes("resize.sqlite") + otherBytes
        guard after <= newBudget else { throw MeshStorageError.budgetTooSmall }
        var result = ResizeCopy(currentBytes: before, resultingBytes: after,
            removed: removed, fingerprint: Data(hash.finalize()))
        if installIf?(result) == true {
            try stage.closeConnection()
            try closeConnection()
            var installed: Int32 = 0
            let rc = nc_quota_install(quota, directory.appendingPathComponent("resize.sqlite").path,
                directory.appendingPathComponent(fileName).path, newBudget, &installed)
            if installed == 0 {
                do { try openConnection() } catch { usable = false; throw error }
                try check(rc)
                throw MeshStorageError.unavailable
            }
            result.installed = true; budget = newBudget
            historyNeedsReload = true
            if rc != SQLITE_OK { result.warning = "Лимит изменён; синхронизация каталога не подтверждена." }
            do { try openConnection() }
            catch {
                usable = false
                result.warning = "Лимит изменён, но хранилище не удалось открыть. Перезапустите приложение."
            }
        }
        return result
    }
    private func closeConnection() throws {
        if let database {
            try check(sqlite3_close(database))
            self.database = nil
        }
    }

    func transaction<T>(_ work: () throws -> T) throws -> T {
        if let quota { nc_quota_reset_failure(quota) }
        try execute("BEGIN IMMEDIATE")
        stagedHistoryChanges.removeAll()
        do {
            let value = try work()
            try execute("COMMIT")
            historyChanges.formUnion(stagedHistoryChanges); stagedHistoryChanges.removeAll()
            return value
        } catch {
            stagedHistoryChanges.removeAll()
            if sqlite3_get_autocommit(database) == 0 {
                do { try execute("ROLLBACK") }
                catch { usable = false; throw error }
            }
            throw error
        }
    }
    func put<T: Encodable>(space: String, id: String, value: T, expiry: Date? = nil) throws {
        try put(space: space, id: id, data: JSONEncoder().encode(value), expiry: expiry)
    }
    func put(space: String, id: String, data: Data, expiry: Date? = nil) throws {
        guard data.count <= Self.maxRecordBytes else { throw MeshStorageError.recordTooLarge }
        let aad = Data("\(ownerID)|\(category)|\(space)|\(id)".utf8)
        let encrypted = try ChaChaPoly.seal(data, using: key, authenticating: aad).combined
        let statement = try prepare("""
            INSERT INTO records(space,id,value,expiry) VALUES(?,?,?,?)
            ON CONFLICT(space,id) DO UPDATE SET value=excluded.value,expiry=excluded.expiry
            """)
        defer { sqlite3_finalize(statement) }
        try bind(space, at: 1, to: statement)
        try bind(id, at: 2, to: statement)
        try encrypted.withUnsafeBytes {
            try check(sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), Self.transient))
        }
        if let expiry { try check(sqlite3_bind_double(statement, 4, expiry.timeIntervalSince1970)) }
        else { try check(sqlite3_bind_null(statement, 4)) }
        try check(sqlite3_step(statement), expected: SQLITE_DONE)
        if space == "history" { stagedHistoryChanges.insert(id) }
    }
    func decode<T: Decodable>(_ type: T.Type, space: String, id: String) throws -> T? {
        try row(space: space, id: id).map { try JSONDecoder().decode(type, from: $0.data) }
    }
    func row(space: String, id: String) throws -> Row? {
        try rows(sql: "SELECT space,id,value,expiry,seq FROM records WHERE space=? AND id=?",
                 arguments: [space, id]).first
    }
    func oldestRows(space: String, limit: Int) throws -> [Row] {
        try rows(sql: "SELECT space,id,value,expiry,seq FROM records WHERE space=? ORDER BY seq LIMIT \(max(0, limit))", arguments: [space])
    }
    func freelistPages() throws -> Int64 { try scalar("PRAGMA freelist_count") }
    func reclaimFreePages(_ count: Int) throws {
        guard try scalar("PRAGMA auto_vacuum") == 2 else { throw MeshStorageError.unavailable }
        try execute("PRAGMA incremental_vacuum(\(max(1, count)))")
    }
    func oldest(space: String, offset: Int) throws -> Row? {
        try rows(sql: "SELECT space,id,value,expiry,seq FROM records WHERE space=? ORDER BY seq LIMIT 1 OFFSET \(max(0, offset))", arguments: [space]).first
    }
    func all(space: String, prefix: String) throws -> [Row] {
        try rows(sql: "SELECT space,id,value,expiry,seq FROM records WHERE space=? AND id LIKE ? ORDER BY seq",
                 arguments: [space, prefix + "%"])
    }
    func removePrefix(space: String, prefix: String) throws {
        let statement = try prepare("DELETE FROM records WHERE space=? AND id LIKE ?")
        defer { sqlite3_finalize(statement) }
        try bind(space, at: 1, to: statement); try bind(prefix + "%", at: 2, to: statement)
        try check(sqlite3_step(statement), expected: SQLITE_DONE)
    }
    func all(space: String, limit: Int? = nil) throws -> [Row] {
        if let limit {
            return try rows(sql: """
                SELECT space,id,value,expiry,seq FROM
                (SELECT * FROM records WHERE space=? ORDER BY seq DESC LIMIT \(max(0, limit)))
                ORDER BY seq
                """, arguments: [space])
        }
        return try rows(sql: "SELECT space,id,value,expiry,seq FROM records WHERE space=? ORDER BY seq",
                        arguments: [space])
    }
    func remove(space: String, id: String) throws {
        let statement = try prepare("DELETE FROM records WHERE space=? AND id=?")
        defer { sqlite3_finalize(statement) }
        try bind(space, at: 1, to: statement); try bind(id, at: 2, to: statement)
        try check(sqlite3_step(statement), expected: SQLITE_DONE)
        if space == "history" { stagedHistoryChanges.insert(id) }
    }
    /// Caller supplies a transaction. A phase transition retains the original FIFO position.
    func move<T: Encodable>(from space: String, to destination: String, id: String, value: T, expiry: Date) throws {
        guard let previous = try row(space: space, id: id) else { throw MeshStorageError.corrupt }
        try remove(space: space, id: id)
        try put(space: destination, id: id, value: value, expiry: expiry)
        let statement = try prepare("UPDATE records SET seq=? WHERE space=? AND id=?")
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_int64(statement, 1, previous.order))
        try bind(destination, at: 2, to: statement); try bind(id, at: 3, to: statement)
        try check(sqlite3_step(statement), expected: SQLITE_DONE)
    }
    func expired(space: String, now: Date) throws -> [Row] {
        return try rows(sql: "SELECT space,id,value,expiry,seq FROM records WHERE space=? AND expiry<=CAST(? AS REAL)",
                        arguments: [space, String(now.timeIntervalSince1970)])
    }
    func removeExpired(now: Date) throws {
        let statement = try prepare("DELETE FROM records WHERE expiry IS NOT NULL AND expiry<=?")
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_double(statement, 1, now.timeIntervalSince1970))
        try check(sqlite3_step(statement), expected: SQLITE_DONE)
    }
    private func rows(sql: String, arguments: [String]) throws -> [Row] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, argument) in arguments.enumerated() { try bind(argument, at: Int32(index + 1), to: statement) }
        var result: [Row] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { return result }
            try check(rc, expected: SQLITE_ROW)
            let space = String(cString: sqlite3_column_text(statement, 0))
            let id = String(cString: sqlite3_column_text(statement, 1))
            let count = Int(sqlite3_column_bytes(statement, 2))
            guard count > 0, count <= Self.maxRecordBytes + 64,
                  let bytes = sqlite3_column_blob(statement, 2) else { throw MeshStorageError.corrupt }
            let encrypted = Data(bytes: bytes, count: count)
            let aad = Data("\(ownerID)|\(category)|\(space)|\(id)".utf8)
            let clear = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: encrypted),
                                           using: key, authenticating: aad)
            let expiry = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil :
                Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            result.append(Row(space: space, id: id, data: clear, expiry: expiry,
                              order: sqlite3_column_int64(statement, 4)))
        }
    }
    private func execute(_ sql: String) throws {
        guard usable else { throw MeshStorageError.unavailable }
        try check(sqlite3_exec(database, sql, nil, nil, nil))
    }
    private func scalar(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        try check(sqlite3_step(statement), expected: SQLITE_ROW)
        return sqlite3_column_int64(statement, 0)
    }
    private func textScalar(_ sql: String) throws -> String {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        try check(sqlite3_step(statement), expected: SQLITE_ROW)
        return String(cString: sqlite3_column_text(statement, 0))
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard usable else { throw MeshStorageError.unavailable }
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(database, sql, -1, &statement, nil))
        guard let statement else { throw MeshStorageError.corrupt }
        return statement
    }
    private func bind(_ string: String, at index: Int32, to statement: OpaquePointer) throws {
        try check(sqlite3_bind_text(statement, index, string, -1, Self.transient))
    }
    private func check(_ code: Int32, expected: Int32 = SQLITE_OK) throws {
        guard code == expected else {
            if code & 255 == SQLITE_FULL {
                if nc_quota_failure(quota) == 2 { throw MeshStorageError.capacity }
                throw MeshStorageError.budgetFull
            }
            throw MeshStorageError.sqlite(code)
        }
    }
}
