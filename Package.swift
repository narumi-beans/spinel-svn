// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SvnDesk",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SvnDesk",
            path: "Sources/SvnDesk"
        ),
        .testTarget(
            name: "SvnDeskTests",
            dependencies: ["SvnDesk"],
            path: "Tests/SvnDeskTests"
        )
    ]
)
