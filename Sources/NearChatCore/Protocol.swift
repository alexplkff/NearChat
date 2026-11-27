import Foundation
import CryptoKit

public enum MeshError: Error, LocalizedError {
    case invalidPacket, invalidIdentity, expiredPacket, textTooLong, unavailablePeer
    public var errorDescription: String? {
        switch self {
        case .invalidPacket: return "Некорректный пакет"
        case .invalidIdentity: return "Не удалось проверить подпись участника"
        case .expiredPacket: return "Истёк срок жизни пакета"
        case .textTooLong: return "Лимит: 1000 символов и 4096 байт UTF-8"
        case .unavailablePeer: return "Участник недоступен"
        }
    }
}

public struct PeerCard: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let signingKey: Data
    public let agreementKey: Data
    public var fingerprint: String { String(id.prefix(16)) }
    public func validate() throws {
        guard name.count <= 32, signingKey.count == 32, agreementKey.count == 32,
              id == Self.identifier(signingKey) else { throw MeshError.invalidIdentity }
        _ = try Curve25519.Signing.PublicKey(rawRepresentation: signingKey)
        _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: agreementKey)
    }
    static func identifier(_ key: Data) -> String {
        SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
    }
}

public struct MeshIdentity {
    let signing: Curve25519.Signing.PrivateKey
    let agreement: Curve25519.KeyAgreement.PrivateKey
    public var name: String
    public init(name: String, signingKey: Data? = nil, agreementKey: Data? = nil) throws {
        signing = try signingKey.map { try .init(rawRepresentation: $0) } ?? .init()
        agreement = try agreementKey.map { try .init(rawRepresentation: $0) } ?? .init()
        self.name = String(name.prefix(32))
    }
    public var signingKeyData: Data { signing.rawRepresentation }
    public var agreementKeyData: Data { agreement.rawRepresentation }
    public var card: PeerCard {
        let key = signing.publicKey.rawRepresentation
        return PeerCard(id: PeerCard.identifier(key), name: name, signingKey: key,
                        agreementKey: agreement.publicKey.rawRepresentation)
    }
    func sharedKey(with peer: PeerCard) throws -> SymmetricKey {
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer.agreementKey)
        let secret = try agreement.sharedSecretFromKeyAgreement(with: publicKey)
        let context = [card.id, peer.id].sorted().joined(separator: ":")
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self,
            salt: Data("NearChat-prototype-v1".utf8), sharedInfo: Data(context.utf8), outputByteCount: 32)
    }
}

public enum PacketKind: String, Codable, Sendable { case presence, message, receipt, control, notice, contact, group, handshake }

public struct PresenceInfo: Codable, Sendable {
    public let sessionID: UUID
    public var capabilities: [String]? = nil
    public var groups: [UUID]? = nil
}
extension PresenceInfo {
    static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard (value.capabilities?.count ?? 0) <= 16,
              value.capabilities?.allSatisfy({ $0.utf8.count <= 64 }) ?? true,
              (value.groups?.count ?? 0) <= 16 else { throw MeshError.invalidPacket }
        return value
    }
}
public enum ReceiptKind: String, Codable, Equatable, Sendable { case delivered, read }
public struct FinalReceipt: Codable, Equatable, Sendable {
    public let messageID: UUID
    public let recipientID: String
    public let digest: Data
    public let kind: ReceiptKind
}
public enum ControlKind: String, Codable, Sendable { case stored, applied }
public struct TransferControl: Codable, Sendable {
    public let recipientID: String
    public let packetID: UUID
    public let digest: Data
    public let offerID: UUID
    public let kind: ControlKind
}
public struct ReleaseNotice: Codable, Sendable {
    public let recipientID: String
    public let packetID: UUID
    public let digest: Data
    public let offerID: UUID
}
public struct OfferBody: Codable, Equatable, Sendable {
    public let id: UUID
    public let owner: PeerCard
    public let packetID: UUID
    public let digest: Data
    public let expiresAt: Int64
    public let hops: Int
}
public struct CustodyOffer: Codable, Equatable, Sendable {
    public let body: OfferBody
    public let signature: Data
    func validate(for packet: MeshPacket) throws {
        try body.owner.validate()
        guard body.packetID == packet.body.id, body.digest == (try packet.digest()),
              body.expiresAt == packet.body.expiresAt,
              body.hops >= packet.remainingHops, body.hops <= packet.body.hopLimit,
              signature.count == 64 else { throw MeshError.invalidPacket }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: body.owner.signingKey)
        guard key.isValidSignature(signature, for: try MeshPacket.encoder.encode(body)) else {
            throw MeshError.invalidIdentity
        }
    }
}
public struct SecureHeader: Codable, Equatable, Sendable {
    public let session: UUID
    public let sequence: Int
}
public struct PacketBody: Codable, Equatable, Sendable {
    public let version: Int
    public let id: UUID
    public let kind: PacketKind
    public let sender: PeerCard
    public let recipient: String?
    public let createdAt: Int64
    public let expiresAt: Int64
    public let hopLimit: Int
    public let payload: Data
    public var secure: SecureHeader? = nil
    var associatedData: Data {
        Data(("\(version)|\(id.uuidString)|\(kind.rawValue)|\(sender.id)|\(recipient ?? "*")|\(createdAt)|\(expiresAt)|\(hopLimit)" +
            (secure.map { "|noise-ik-rekey-v1|\($0.session.uuidString)|\($0.sequence)" } ?? "")).utf8)
    }
}
public struct MeshPacket: Codable, Equatable, Sendable {
    public let body: PacketBody
    public let signature: Data
    public var remainingHops: Int
    public var offer: CustodyOffer?
    public static let maxWireBytes = 32_768
    public static let lifetime: TimeInterval = 86_400
    public static let presenceLifetime: TimeInterval = 30
    public var deadline: Date { Date(timeIntervalSince1970: Double(body.expiresAt)) }
    public var storageKey: String { "\(body.id.uuidString):\(body.recipient ?? "*")" }
    public func encoded() throws -> Data { try Self.encoder.encode(self) }
    static var encoder: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }
    public func digest() throws -> Data { Data(SHA256.hash(data: try Self.encoder.encode(body) + signature)) }
    public static func decode(_ data: Data, now: Date) throws -> MeshPacket {
        guard data.count <= maxWireBytes else { throw MeshError.invalidPacket }
        let packet = try JSONDecoder().decode(Self.self, from: data)
        try packet.validate(now: now)
        return packet
    }
    public func validate(now: Date, checkingTime: Bool = true) throws {
        guard (body.version == 2 || body.version == 3), (1...256).contains(body.hopLimit),
              (1...body.hopLimit).contains(remainingHops), signature.count == 64,
              body.expiresAt > body.createdAt,
              Double(body.expiresAt) - Double(body.createdAt) <= Self.lifetime else {
            throw MeshError.invalidPacket
        }
        if checkingTime {
            guard now < deadline, Double(body.createdAt) <= now.timeIntervalSince1970 + 5 else {
                throw MeshError.expiredPacket
            }
        }
        if body.kind == .handshake {
            guard body.version == 3, body.secure == nil, body.recipient != nil, offer == nil,
                  body.payload.count <= 1024, Double(body.expiresAt) - Double(body.createdAt) <= 30 else { throw MeshError.invalidPacket }
        } else if let secure = body.secure {
            guard body.version == 3, body.kind != .presence, (0..<256).contains(secure.sequence) else { throw MeshError.invalidPacket }
        } else if body.version == 3 && body.kind != .presence { throw MeshError.invalidPacket }
        try body.sender.validate()
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: body.sender.signingKey)
        guard key.isValidSignature(signature, for: try Self.encoder.encode(body)) else {
            throw MeshError.invalidIdentity
        }
        if body.kind == .presence {
            guard body.recipient == nil, body.payload.count <= 1024, offer == nil,
                  Double(body.expiresAt) - Double(body.createdAt) <= Self.presenceLifetime else {
                throw MeshError.invalidPacket
            }
            _ = try PresenceInfo.decode(body.payload)
        } else {
            guard let recipient = body.recipient, recipient.utf8.count == 64,
                  recipient.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  body.payload.count >= (body.secure == nil ? (body.kind == .handshake ? 1 : 28) : 16) else {
                throw MeshError.invalidPacket
            }
            if body.kind == .control || body.kind == .handshake {
                guard offer == nil, Double(body.expiresAt) - Double(body.createdAt) <= Self.presenceLifetime else { throw MeshError.invalidPacket }
            } else {
                guard let offer else { throw MeshError.invalidPacket }
                try offer.validate(for: self)
            }
        }
    }
    public func decrypted(using identity: MeshIdentity) throws -> Data {
        guard body.secure == nil, body.kind != .handshake, body.recipient == identity.card.id else { throw MeshError.invalidIdentity }
        return try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: body.payload),
            using: identity.sharedKey(with: body.sender), authenticating: body.associatedData)
    }
    mutating func offerCustody(by identity: MeshIdentity) throws {
        let value = OfferBody(id: UUID(), owner: identity.card, packetID: body.id,
                              digest: try digest(), expiresAt: body.expiresAt, hops: remainingHops)
        offer = CustodyOffer(body: value, signature: try identity.signing.signature(for: Self.encoder.encode(value)))
    }
    static func make(identity: MeshIdentity, kind: PacketKind, recipient: PeerCard? = nil,
                     cleartext: Data = Data(), now: Date, hops: Int = 256,
                     id: UUID = UUID(), expiresAt: Date? = nil) throws -> MeshPacket {
        guard (1...256).contains(hops) else { throw MeshError.invalidPacket }
        let created = Int64(now.timeIntervalSince1970)
        let lifetime = (kind == .presence || kind == .control) ? presenceLifetime : Self.lifetime
        let expiry = Int64(min(expiresAt ?? now.addingTimeInterval(lifetime),
                               now.addingTimeInterval(lifetime)).timeIntervalSince1970)
        guard expiry > created else { throw MeshError.expiredPacket }
        let header = PacketBody(version: 2, id: id, kind: kind, sender: identity.card,
            recipient: recipient?.id, createdAt: created, expiresAt: expiry, hopLimit: hops, payload: Data())
        let payload: Data
        if let recipient {
            payload = try ChaChaPoly.seal(cleartext, using: identity.sharedKey(with: recipient),
                                         authenticating: header.associatedData).combined
        } else { payload = cleartext }
        let body = PacketBody(version: 2, id: id, kind: kind, sender: header.sender,
            recipient: header.recipient, createdAt: created, expiresAt: expiry, hopLimit: hops, payload: payload)
        var packet = MeshPacket(body: body, signature: try identity.signing.signature(for: encoder.encode(body)),
                                remainingHops: hops)
        if kind != .presence && kind != .control { try packet.offerCustody(by: identity) }
        return packet
    }
}

public struct ChatPayload: Codable, Sendable {
    public let text: String
    public let isPublic: Bool
    public var sessionID: UUID? = nil
    public var consent: ContactGrant? = nil
    public var group: GroupAudience? = nil
    public static func validate(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= 1000, text.utf8.count <= 4096 else { throw MeshError.textTooLong }
    }
}

/// Bounded framing for TCP byte streams and BLE fragments. Four-byte big endian length.
public struct FrameDecoder {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ bytes: Data) throws -> [Data] {
        // Each transport feeds at most 16 KiB per callback; never buffer unbounded input.
        guard bytes.count <= 65_536, buffer.count + bytes.count <= 98_304 else {
            buffer.removeAll(); throw MeshError.invalidPacket
        }
        buffer.append(bytes)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= MeshPacket.maxWireBytes else {
                buffer.removeAll(); throw MeshError.invalidPacket
            }
            guard buffer.count >= 4 + length else { break }
            frames.append(Data(buffer.dropFirst(4).prefix(length)))
            buffer = Data(buffer.dropFirst(4 + length))
        }
        return frames
    }
    public static func frame(_ payload: Data) -> Data {
        let n = UInt32(payload.count)
        return Data([UInt8((n >> 24) & 255), UInt8((n >> 16) & 255),
                     UInt8((n >> 8) & 255), UInt8(n & 255)]) + payload
    }
}
