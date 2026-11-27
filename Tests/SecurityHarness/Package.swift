// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "NearChatSecurityHarness", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../..")],
    targets: [.executableTarget(name: "NearChatSecurityHarness", dependencies: [.product(name: "NearChatCore", package: "NearChat")])],
    swiftLanguageModes: [.v5])
