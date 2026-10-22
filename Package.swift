// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpinelSvn",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SpinelSvn",
            path: "Sources/SpinelSvn"
        ),
        .testTarget(
            name: "SpinelSvnTests",
            dependencies: ["SpinelSvn"],
            path: "Tests/SpinelSvnTests"
        )
    ]
)
