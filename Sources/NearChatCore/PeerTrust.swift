import Foundation
import CryptoKit

public enum ChannelSecurityError: Error, LocalizedError, Equatable {
    case pending, keyChanged, unavailable, replay, invalidHandshake, limit
    public var errorDescription: String? {
        switch self {
        case .pending: return "Устанавливается защищённый сеанс. Повторите отправку после соединения."
        case .keyChanged: return "Ключи изменились. Сверьте код безопасности повторно."
        case .unavailable: return "Не удалось сохранить состояние шифрования. Передача приостановлена до восстановления хранилища."
        case .replay: return "Повтор или несовпадение зашифрованного пакета"
        case .invalidHandshake: return "Не удалось проверить защищённый сеанс"
        case .limit: return "Достигнут лимит защищённых сеансов. Дождитесь освобождения старых ключей."
        }
    }
}
public enum PeerTrustStatus: String, Codable { case unverified, verified, changed }
public struct PeerSecurityInfo: Identifiable {
    public var id: String { peer.id }
    public let peer: PeerCard
    public let status: PeerTrustStatus
    public let fingerprint: String
    public let safetyCode: String
}
extension PeerCard {
    public var keyFingerprint: String {
        SHA256.hash(data: Data("NearChat-key-identity-v1".utf8) + signingKey + agreementKey)
            .map { String(format: "%02x", $0) }.joined()
    }
    public func safetyCode(with other: PeerCard) -> String {
        let keys = [keyFingerprint, other.keyFingerprint].sorted().joined(separator: ":")
        return SHA256.hash(data: Data(("NearChat-safety-code-v1|" + keys).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
struct TrustRecord: Codable {
    var peer: PeerCard
    var baseline: String
    var verified = false
    var verifier: String? = nil
    var needsReview: Bool? = nil
    var retired: [String]? = nil
    var status: PeerTrustStatus { needsReview == true || peer.keyFingerprint != baseline ? .changed : (verified ? .verified : .unverified) }
}
final class PeerTrustBook {
    let identity: MeshIdentity
    let store: () -> MeshStore?
    private(set) var records: [String: TrustRecord] = [:]
    init(identity: MeshIdentity, store: @escaping () -> MeshStore?) { self.identity = identity; self.store = store }
    func load() throws {
        guard let archive = store()?.own else { return }
        for row in try archive.all(space: "peer-trust") {
            let value = try JSONDecoder().decode(TrustRecord.self, from: row.data)
            try value.peer.validate()
            guard row.id == value.peer.id, value.baseline.utf8.count == 64 else { throw MeshStorageError.corrupt }
            records[row.id] = value
        }
    }
    func observe(_ peer: PeerCard) throws {
        try peer.validate()
        guard peer.id != identity.card.id else { throw MeshError.invalidIdentity }
        if let old = records[peer.id] {
            if old.retired?.contains(peer.keyFingerprint) == true { throw ChannelSecurityError.keyChanged }
            if old.peer == peer { return }
        }
        guard records[peer.id] != nil || records.count < 1024 else { throw ChannelSecurityError.limit }
        var value = records[peer.id] ?? TrustRecord(peer: peer, baseline: peer.keyFingerprint)
        if value.peer.keyFingerprint != peer.keyFingerprint { value.needsReview = true }
        value.peer = peer
        try save(value)
    }
    private func status(_ value: TrustRecord) -> PeerTrustStatus {
        if value.verified && value.verifier != identity.card.keyFingerprint { return .changed }
        return value.status
    }
    func info(_ peer: PeerCard) -> PeerSecurityInfo {
        let value = records[peer.id] ?? TrustRecord(peer: peer, baseline: peer.keyFingerprint)
        return PeerSecurityInfo(peer: value.peer, status: status(value),
            fingerprint: value.peer.keyFingerprint, safetyCode: identity.card.safetyCode(with: value.peer))
    }
    func requireUnchanged(_ peer: PeerCard) throws {
        try observe(peer)
        guard records[peer.id].map({ status($0) != .changed }) == true else { throw ChannelSecurityError.keyChanged }
    }
    func verify(_ peer: PeerCard, code: String) throws {
        try peer.validate()
        guard var value = records[peer.id], value.peer.keyFingerprint == peer.keyFingerprint,
              code == identity.card.safetyCode(with: value.peer) else { throw ChannelSecurityError.keyChanged }
        if value.baseline != peer.keyFingerprint {
            var retired = value.retired ?? []; retired.append(value.baseline); value.retired = retired
        }
        value.baseline = peer.keyFingerprint; value.verified = true; value.needsReview = false
        value.verifier = identity.card.keyFingerprint
        try save(value)
    }
    private func save(_ value: TrustRecord) throws {
        guard let archive = store()?.own else { throw ChannelSecurityError.unavailable }
        try archive.transaction { try archive.put(space: "peer-trust", id: value.peer.id, value: value) }
        records[value.peer.id] = value
    }
}
