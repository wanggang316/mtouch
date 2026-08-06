// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mtouch",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MTouchKit", targets: ["MTouchKit"]),
        .executable(name: "mtouch", targets: ["mtouch"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
    ],
    targets: [
        .target(name: "MTouchKit"),
        .executableTarget(
            name: "mtouch",
            dependencies: [
                "MTouchKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .testTarget(
            name: "MTouchKitTests",
            dependencies: ["MTouchKit"]
        ),
    ]
)
