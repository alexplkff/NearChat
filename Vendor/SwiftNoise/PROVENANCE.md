Vendored from https://github.com/swift-libp2p/swift-noise
Commit: 0adfd28786322784860fb3c8f228591c6e8fd92f (MIT).

Local changes: import CryptoKit instead of swift-crypto's Crypto on Apple platforms;
add narrow key persistence / authenticated-data adapters and remote static-key accessor.
Handshake, HKDF, cipher and rekey algorithms are unchanged. IK vectors are checked in NearChat tests.
