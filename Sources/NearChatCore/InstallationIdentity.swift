import Foundation
import Darwin

public protocol IdentityKeyStorage {
    func readKey(account: String) throws -> Data?
    func storeKey(_ data: Data, account: String) throws
}
public enum InstallationIdentityError: Error, LocalizedError {
    case invalidState, missingKey, invalidKey, couldNotSynchronize
    public var errorDescription: String? {
        switch self {
        case .invalidState: return "Маркер установки повреждён. Исходные ключи и переписка сохранены"
        case .missingKey: return "Ключ этой установки недоступен. Прежнее хранилище не изменено"
        case .invalidKey: return "Ключ не соответствует этой установке. Прежнее хранилище не изменено"
        case .couldNotSynchronize: return "Не удалось надёжно сохранить маркер установки"
        }
    }
}
private struct InstallationState: Codable {
    let version: Int
    let account: String
    let peerID: String?
}
/// Serial bootstrap. An installation-local pointer selects one Keychain account;
/// a retained key from a deleted installation is never selected on a clean install.
public struct InstallationIdentity {
    private let keys: IdentityKeyStorage
    private let directory: URL
    private let historyDirectory: URL
    private let legacyPreferencesPresent: Bool
    var commitState: (Data, URL) throws -> Void = Self.writeState
    public init(keys: IdentityKeyStorage, directory: URL, historyDirectory: URL, legacyPreferencesPresent: Bool) {
        self.keys = keys; self.directory = directory; self.historyDirectory = historyDirectory
        self.legacyPreferencesPresent = legacyPreferencesPresent
    }
    public func load(name: String) throws -> MeshIdentity {
        let file = directory.appendingPathComponent("installation-v1.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let state: InstallationState
            do { state = try JSONDecoder().decode(InstallationState.self, from: Data(contentsOf: file)) }
            catch let error as CocoaError where error.code == .fileReadNoPermission { throw error }
            catch { throw InstallationIdentityError.invalidState }
            guard state.version == 1, state.account == "device" ||
                    (state.account.hasPrefix("installation.") && UUID(uuidString: String(state.account.dropFirst(13))) != nil),
                  state.peerID == nil || (state.peerID?.count == 64 && state.peerID?.allSatisfy(\.isHexDigit) == true)
                else { throw InstallationIdentityError.invalidState }
            let identity: MeshIdentity
            if let data = try keys.readKey(account: state.account) { identity = try decode(data, name: name) }
            else {
                guard state.peerID == nil, !hasArchive else { throw InstallationIdentityError.missingKey }
                identity = try MeshIdentity(name: name)
                try keys.storeKey(identity.signingKeyData + identity.agreementKeyData, account: state.account)
            }
            if let expected = state.peerID {
                guard expected == identity.card.id else { throw InstallationIdentityError.invalidKey }
            } else {
                try validateExisting(identity)
                try save(InstallationState(version: 1, account: state.account, peerID: identity.card.id), file: file)
            }
            return identity
        }
        if hasArchive || legacyPreferencesPresent {
            if let data = try keys.readKey(account: "device") {
                let identity = try decode(data, name: name)
                try validateExisting(identity)
                // Existing archive/preferences already bind this legacy install.
                // A full disk must not make its unchanged valid key unusable;
                // retry the pointer migration on the next launch.
                try? save(InstallationState(version: 1, account: "device", peerID: identity.card.id), file: file)
                return identity
            }
            guard !hasArchive else { throw InstallationIdentityError.missingKey }
        }
        let account = "installation." + UUID().uuidString
        // Commit the selected account BEFORE creating a key. A crash/retry after
        // key creation continues this same installation, rather than rotating it.
        try save(InstallationState(version: 1, account: account, peerID: nil), file: file)
        return try load(name: name)
    }
    private var hasArchive: Bool {
        ["archive.sqlite", "history-v1.sealed", "relay/archive.sqlite"].contains {
            FileManager.default.fileExists(atPath: historyDirectory.appendingPathComponent($0).path)
        }
    }
    private func validateExisting(_ identity: MeshIdentity) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: historyDirectory.appendingPathComponent("archive.sqlite").path) {
            _ = try SQLiteArchive(directory: historyDirectory, category: "history", budget: MeshStorageLimits.defaults.historyBytes, identity: identity)
        }
        let relay = historyDirectory.appendingPathComponent("relay")
        if fm.fileExists(atPath: relay.appendingPathComponent("archive.sqlite").path) {
            _ = try SQLiteArchive(directory: relay, category: "relay", budget: MeshStorageLimits.defaults.relayBytes, identity: identity)
        }
        if fm.fileExists(atPath: historyDirectory.appendingPathComponent("history-v1.sealed").path) {
            _ = try HistoryStore(fileURL: historyDirectory.appendingPathComponent("history-v1.sealed"), identity: identity).load()
        }
    }
    private func decode(_ data: Data, name: String) throws -> MeshIdentity {
        guard data.count == 64 else { throw InstallationIdentityError.invalidKey }
        return try MeshIdentity(name: name, signingKey: Data(data.prefix(32)), agreementKey: Data(data.suffix(32)))
    }
    private func save(_ state: InstallationState, file: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
        try commitState(JSONEncoder().encode(state), file)
    }
    private static func writeState(_ data: Data, file: URL) throws {
        try data.write(to: file, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
        #endif
        let fd = open(file.path, O_RDONLY)
        guard fd >= 0 else { throw InstallationIdentityError.couldNotSynchronize }
        let result = fsync(fd); close(fd)
        guard result == 0 else { throw InstallationIdentityError.couldNotSynchronize }
        let parent = open(file.deletingLastPathComponent().path, O_RDONLY)
        guard parent >= 0 else { throw InstallationIdentityError.couldNotSynchronize }
        let synced = fsync(parent); close(parent)
        guard synced == 0 else { throw InstallationIdentityError.couldNotSynchronize }
    }
}
