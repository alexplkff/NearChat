// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NearChat",
    platforms: [.macOS(.v14), .iOS("18.0")],
    products: [.library(name: "NearChatCore", targets: ["NearChatCore"])],
    targets: [
        .target(name: "BoundedSQLite", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "Noise", path: "Vendor/SwiftNoise", resources: [.copy("LICENSE.md"), .copy("PROVENANCE.md")]),
        .target(name: "NearChatCore", dependencies: ["BoundedSQLite", "Noise"]),
        .testTarget(name: "NearChatCoreTests", dependencies: ["NearChatCore"])
    ],
    swiftLanguageModes: [.v5]
)
