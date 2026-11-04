import XCTest
@testable import SuperWorkspace

@MainActor
final class AgentConfigurationTests: XCTestCase {
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
        XCTAssertFalse(skill.path.contains("/.codex/skills/"))
        XCTAssertFalse(skill.path.contains("/.agents/skills/"))
    }

    func testDeepSeekRoutesThroughPiWithBoundedVerification() throws {
        let settings = SettingsStore.shared
        let previousAgent = settings.aiMotionAgent
        let previousModel = settings.deepseekMotionModel
        let previousPath = settings.aiMotionLaunchPath
        let previousExtra = settings.aiMotionExtraArgs
        defer {
            settings.aiMotionAgent = previousAgent
            settings.deepseekMotionModel = previousModel
            settings.aiMotionLaunchPath = previousPath
            settings.aiMotionExtraArgs = previousExtra
        }
        settings.aiMotionAgent = MotionAgent.deepseek.rawValue
        settings.deepseekMotionModel = "deepseek-flash"
        settings.aiMotionLaunchPath = "/bin/true"
        settings.aiMotionExtraArgs = ""
        let root = FileManager.default.temporaryDirectory
        let args = try settings.aiMotionArguments(source1: root.appendingPathComponent("input.mp4"),
            source2: root.appendingPathComponent("output.mp4"), brief: root.appendingPathComponent("brief.txt"))
        func argument(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        XCTAssertEqual(argument("--provider"), "deepseek")
        XCTAssertEqual(argument("--model"), "deepseek-flash")
        XCTAssertEqual(argument("--thinking"), "low")
        XCTAssertTrue(args.contains("--no-session"))
        XCTAssertTrue(args.contains("--no-skills"))
        XCTAssertTrue(args.contains(SettingsStore.boundedMotionPrompt))
        XCTAssertEqual(argument("--skill"), try settings.motionSkillURL().path)
        XCTAssertTrue(args.contains(SettingsStore.scopedMotionPrompt(skill: try settings.motionSkillURL())))
        XCTAssertFalse(settings.resolvedLaunchPath().hasSuffix("claude"))
        settings.aiMotionAgent = MotionAgent.claude.rawValue
        let claudeArgs = try settings.aiMotionArguments(source1: root.appendingPathComponent("input.mp4"),
            source2: root.appendingPathComponent("output.mp4"), brief: root.appendingPathComponent("brief.txt"))
        XCTAssertFalse(claudeArgs.contains("--provider"))
        XCTAssertTrue(claudeArgs.contains(SettingsStore.boundedMotionPrompt))
    }
}
