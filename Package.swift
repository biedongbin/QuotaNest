// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "QuotaNest",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "QuotaNest",
            path: "Sources/TokenHUD",
            resources: [.copy("providers"), .copy("mjs"), .process("Resources")]
        ),
        .testTarget(
            name: "QuotaNestTests",
            dependencies: ["QuotaNest"],
            path: "Tests/TokenHUDTests"
        ),
    ]
)
