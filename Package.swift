// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "QuotaNest",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TokenHUD",
            resources: [.copy("providers"), .copy("mjs")]
        ),
        .testTarget(
            name: "TokenHUDTests",
            dependencies: ["TokenHUD"],
            path: "Tests/TokenHUDTests"
        ),
    ]
)
