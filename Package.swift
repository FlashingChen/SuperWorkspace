// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SuperWorkspace",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "StudioTheme", path: "Sources/StudioTheme"),
        .target(name: "RecorderCore", path: "Sources/RecorderCore"),
        .target(name: "AudioWriterBridge", path: "Sources/AudioWriterBridge"),
        .target(name: "RecorderKit", dependencies: ["StudioTheme", "RecorderCore", "AudioWriterBridge"], path: "Sources/RecorderKit"),
        .executableTarget(
            name: "SuperWorkspace",
            dependencies: ["StudioTheme", "RecorderKit"],
            path: "Sources/SuperWorkspace",
            resources: [.copy("AgentSkills")]
        ),
        .testTarget(name: "SuperWorkspaceTests", dependencies: ["SuperWorkspace", "StudioTheme", "RecorderKit", "AudioWriterBridge"], path: "Tests/SuperWorkspaceTests"),
    ],
    swiftLanguageModes: [.v6]
)
