// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VerticalRecord",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "VerticalRecord",
            path: "Sources/VerticalRecord",
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
