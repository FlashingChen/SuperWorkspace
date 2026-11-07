import XCTest
@testable import SuperWorkspace

@MainActor
final class AgentConfigurationTests: XCTestCase {
    func testAgentLauncherFindsInterpreterBesideExecutable() async throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("agent bin \(UUID())")
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: directory) }

        let interpreter = directory.appendingPathComponent("workspace-test-interpreter")
        let launcher = directory.appendingPathComponent("agent")
        try "#!/bin/sh\nprintf 'interpreter started\\n'\n".write(to: interpreter, atomically: true, encoding: .utf8)
        try "#!/usr/bin/env workspace-test-interpreter\n".write(to: launcher, atomically: true, encoding: .utf8)
        for file in [interpreter, launcher] {
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }

        let output = try await Shell.run(launcher.path, arguments: [], timeout: 5)
        XCTAssertEqual(output, "interpreter started\n")
    }

    func testMissingBundledSkillFailsWithoutLookingInLocalSkills() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try IntegratedMotionSkill.locate(in: [missing]))
    }

    func testBundledSkillIncludesItsCameraAndMotionResources() throws {
        let skill = try SettingsStore.shared.motionSkillURL()
        XCTAssertEqual(skill.deletingLastPathComponent().lastPathComponent, IntegratedMotionSkill.name)
        let references = skill.deletingLastPathComponent().appendingPathComponent("references")
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: references.appendingPathComponent("world-camera.tsx").path))
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: references.appendingPathComponent("motion-recipes.md").path))
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: references.appendingPathComponent("chapter-connection.tsx").path))
        XCTAssertFalse(skill.path.contains("/.codex/skills/"))
        XCTAssertFalse(skill.path.contains("/.agents/skills/"))
    }

    func testLegacyPiChoiceUsesEmbeddedModeAndSharedMotionSkill() throws {
        let settings = SettingsStore.shared
        let previousAgent = settings.aiMotionAgent
        let previousExtra = settings.aiMotionExtraArgs
        defer {
            settings.aiMotionAgent = previousAgent
            settings.aiMotionExtraArgs = previousExtra
        }
        for legacy in ["pi", "deepseek", "automatic"] {
            settings.aiMotionAgent = legacy
            XCTAssertEqual(settings.selectedAgent, .api)
            XCTAssertEqual(settings.resolvedLaunchPath(), "/bin/true")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let brief = root.appendingPathComponent("brief.txt")
        let briefContents = "Render the sample clip."
        try briefContents.write(to: brief, atomically: true, encoding: .utf8)
        let source = root.appendingPathComponent("input.mp4")
        let output = root.appendingPathComponent("output.mp4")
        let request = try settings.motionRequest(source1: source, source2: output, brief: brief)
        let skill = try settings.motionSkillURL()
        XCTAssertTrue(request.system.contains(briefContents))
        XCTAssertTrue(request.system.contains(try String(contentsOf: skill, encoding: .utf8)))
        XCTAssertTrue(request.prompt.contains(output.path))

        settings.aiMotionAgent = MotionAgent.claude.rawValue
        settings.aiMotionExtraArgs = ""
        let claude = try settings.claudeMotionArguments(source1: source, source2: output, brief: brief)
        XCTAssertEqual(claude, ["-p", "--append-system-prompt", request.system, request.prompt])
    }
}
