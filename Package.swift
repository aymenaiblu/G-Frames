// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GFrames",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GFrames",
            path: "Sources/GFrames",
            exclude: ["Assets.xcassets"],
            swiftSettings: [
                .unsafeFlags(["-Ounchecked"], .when(configuration: .release))
            ]
        )
    ]
)
