// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SuperWorkspace",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "RecorderCore", path: "dogsc-source/Sources/RecorderCore"),
        .target(name: "AudioWriterBridge", path: "Sources/AudioWriterBridge"),
        .target(name: "RecorderKit", dependencies: ["RecorderCore", "AudioWriterBridge"], path: ".build/IntegratedRecorder"),
        .executableTarget(
            name: "SuperWorkspace",
            dependencies: ["RecorderKit"],
            path: "Sources/SuperWorkspace",
            resources: [.copy("AgentSkills")]
        ),
        .testTarget(name: "SuperWorkspaceTests", dependencies: ["SuperWorkspace", "RecorderKit", "AudioWriterBridge"], path: "Tests/SuperWorkspaceTests"),
    ],
    swiftLanguageModes: [.v6]
)
