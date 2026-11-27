import XCTest
import CryptoKit
import Noise

/// IK vector from swift-libp2p/swift-noise, commit 0adfd287 (MIT; Vendor/SwiftNoise/LICENSE.md).
final class NoiseVectorTests: XCTestCase {
    private func hex(_ text: String) -> Data {
        var bytes: [UInt8] = []; var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: 2)
            bytes.append(UInt8(text[index..<end], radix: 16)!); index = end
        }
        return Data(bytes)
    }
    func testIK25519ChaChaPolySHA256MatchesPublishedVector() throws {
        let aKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"))
        let bKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex("0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"))
        let aEphemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"))
        let bEphemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex("4142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f60"))
        let suite = Noise.CipherSuite(keyCurve: .x25519, cipher: .ChaChaPoly1305, hashFunction: .sha256)
        let a = try Noise.HandshakeState(config: .init(cipherSuite: suite, handshake: .IK_Initiator(remoteStatic: bKey.publicKey), staticKeypair: aKey, ephemeralKeypair: aEphemeral))
        let b = try Noise.HandshakeState(config: .init(cipherSuite: suite, handshake: .IK_Responder, staticKeypair: bKey, ephemeralKeypair: bEphemeral))
        let first = try a.writeMessage(payload: [])
        XCTAssertEqual(Data(first.buffer), hex("358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd1662544f8445e5dc2467b1e32653192d05dee85c4781bf0dd8d33ceebb5905a7a069f09e0d3f2cad1c842930a762eb75e52827f01d2c85189d527644b3221b4c3fc5cc"))
        _ = try b.readMessage(first.buffer)
        let second = try b.writeMessage(payload: [])
        XCTAssertEqual(Data(second.buffer), hex("64b101b1d0be5a8704bd078f9895001fc03e8e9f9522f188dd128d9846d48466aabfe2e5b1650bbaa88e33679893fc77"))
        let finish = try a.readMessage(second.buffer)
        let encrypt = try XCTUnwrap(finish.c1), decrypt = try XCTUnwrap(second.c1)
        let cipher = try encrypt.encrypt(plaintext: Array(hex("79656c6c6f777375626d6172696e65")))
        XCTAssertEqual(Data(cipher), hex("226ca869f2777611f37350a7ab446f650c0cfe2855b7f020ce658bcf100f2d"))
        XCTAssertEqual(try decrypt.decrypt(ciphertext: cipher), Array(hex("79656c6c6f777375626d6172696e65")))
    }
    func testRekeyMatchesNoiseDefinitionAndDoesNotRestorePreviousKey() throws {
        let key = Data(repeating: 42, count: 32)
        let cipher = try Noise.CipherState.restoring(key: key)
        try cipher.rekey()
        let nonce = try ChaChaPoly.Nonce(data: Data([0,0,0,0] + Array(repeating: UInt8(255), count: 8)))
        let reference = try ChaChaPoly.seal(Data(repeating: 0, count: 32), using: SymmetricKey(data: key), nonce: nonce, authenticating: Data())
        XCTAssertEqual(cipher.keyBytes, Data(reference.ciphertext.prefix(32)))
        XCTAssertNotEqual(cipher.keyBytes, key)
    }
}
