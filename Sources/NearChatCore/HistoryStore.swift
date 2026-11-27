import Foundation
import CryptoKit

/// Local conversation history only. Forwarded packets never enter this archive.
public final class HistoryStore {
    public enum StorageError: Error, LocalizedError {
        case invalidArchive, archiveTooLarge
        public var errorDescription: String? {
            switch self {
            case .invalidArchive: return "Некорректный формат локальной истории"
            case .archiveTooLarge: return "Файл истории превышает допустимый размер"
            }
        }
    }
    private struct Archive: Codable {
        let version: Int
        let ownerID: String
        let messages: [ChatEntry]
    }
    public let fileURL: URL
    private let ownerID: String
    private let key: SymmetricKey
    private let maxFileBytes = 4 * 1024 * 1024

    public init(fileURL: URL, identity: MeshIdentity) {
        self.fileURL = fileURL
        ownerID = identity.card.id
        // Independent domain-separated storage key; secret material stays in the existing Keychain item.
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: identity.signingKeyData),
            salt: Data("NearChat-local-history-v1".utf8), info: Data(ownerID.utf8), outputByteCount: 32)
    }
    public func load() throws -> [ChatEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= maxFileBytes else {
            throw StorageError.archiveTooLarge
        }
        let encrypted = try Data(contentsOf: fileURL)
        guard encrypted.count <= maxFileBytes else { throw StorageError.archiveTooLarge }
        let clear = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: encrypted), using: key,
                                       authenticating: Data(ownerID.utf8))
        let archive = try JSONDecoder().decode(Archive.self, from: clear)
        guard archive.version == 1, archive.ownerID == ownerID else { throw StorageError.invalidArchive }
        let entries = Array(archive.messages.suffix(MeshEngine.historyLimit))
        try validate(entries)
        return entries
    }
    public func save(_ messages: [ChatEntry]) throws {
        let entries = Array(messages.suffix(MeshEngine.historyLimit))
        try validate(entries)
        let archive = Archive(version: 1, ownerID: ownerID, messages: entries)
        let clear = try JSONEncoder().encode(archive)
        let encrypted = try ChaChaPoly.seal(clear, using: key, authenticating: Data(ownerID.utf8)).combined
        guard encrypted.count <= maxFileBytes else { throw StorageError.archiveTooLarge }
        var directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Keep local chat data out of cloud/device backups; the matching identity is device-only too.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try encrypted.write(to: fileURL, options: options)
    }
    private func validate(_ entries: [ChatEntry]) throws {
        var ids: Set<UUID> = []
        for entry in entries {
            try entry.sender.validate()
            try ChatPayload.validate(entry.text)
            guard ids.insert(entry.id).inserted, (0...6).contains(entry.hops),
                  (entry.outgoing ? entry.sender.id == ownerID : entry.recipient == ownerID) else {
                throw StorageError.invalidArchive
            }
        }
    }
}
