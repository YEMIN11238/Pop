// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pop",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Pop", targets: ["Pop"])],
    targets: [
        .executableTarget(name: "Pop"),
        .testTarget(name: "PopTests", dependencies: ["Pop"])
    ],
    swiftLanguageModes: [.v5]
)
