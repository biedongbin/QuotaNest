// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TokenHUD",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TokenHUD",
            resources: [.copy("providers")]
        ),
        .testTarget(
            name: "TokenHUDTests",
            dependencies: ["TokenHUD"],
            path: "Tests/TokenHUDTests"
        ),
    ]
)
