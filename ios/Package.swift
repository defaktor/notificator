// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ANBridgeCore", platforms: [.macOS(.v13), .iOS(.v17)], products: [.executable(name:"ANBridgeCoreCheck",targets:["ANBridgeCoreCheck"]), .library(name: "ANBridgeCore", targets: ["ANBridgeCore"])], dependencies: [
    .package(url: "https://github.com/swift-libp2p/swift-noise.git", revision: "0adfd28786322784860fb3c8f228591c6e8fd92f"),
    .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.0.0")
], targets: [.target(name: "ANBridgeCore", dependencies: [.product(name:"Noise",package:"swift-noise"), .product(name:"Crypto",package:"swift-crypto")]), .executableTarget(name:"ANBridgeCoreCheck",dependencies:["ANBridgeCore",.product(name:"Noise",package:"swift-noise"),.product(name:"Crypto",package:"swift-crypto")]), .testTarget(name:"ANBridgeCoreTests",dependencies:["ANBridgeCore", .product(name:"Noise",package:"swift-noise"), .product(name:"Crypto",package:"swift-crypto")])], swiftLanguageModes: [.v5])
