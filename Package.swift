// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MiniOBS",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "MiniOBS",
            path: "Sources/MiniOBS",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreImage"),
                .linkedFramework("Metal"),
                .linkedFramework("Network"),
            ]
        ),
    ]
)
