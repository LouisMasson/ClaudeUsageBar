// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "ClaudeUsageBar",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "ClaudeUsageBar",
            path: "ClaudeUsageBar/Sources"
        )
    ]
)
