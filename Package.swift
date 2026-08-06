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
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        .target(name: "MTouchKit"),
        .executableTarget(
            name: "mtouch",
            dependencies: [
                "MTouchKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "MTouchKitTests",
            dependencies: ["MTouchKit"]
        ),
    ]
)
