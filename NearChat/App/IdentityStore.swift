import Foundation
import Security
import NearChatCore

struct IdentityStore {
    func load(name: String) throws -> MeshIdentity {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return try InstallationIdentity(keys: KeychainIdentityKeys(),
            directory: support.appendingPathComponent("NearChatIdentity", isDirectory: true),
            historyDirectory: support.appendingPathComponent("NearChat", isDirectory: true),
            legacyPreferencesPresent: UserDefaults.standard.object(forKey: "nickname") != nil).load(name: name)
    }
}
private struct KeychainIdentityKeys: IdentityKeyStorage {
    private let service = "NearChatLab.identity.v1"
    func readKey(account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status == errSecSuccess ? errSecDecode : status))
        }
        return data
    }
    func storeKey(_ data: Data, account: String) throws {
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data]
        let result = SecItemAdd(add as CFDictionary, nil)
        guard result == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
    }
}
