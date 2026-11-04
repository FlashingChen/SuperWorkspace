import Foundation

enum IntegratedMotionSkill {
    static let name = "workspace-tutorial-motion"
    static let relativePath = "AgentSkills/\(name)/SKILL.md"

    static func locate(in resourceRoots: [URL]) throws -> URL {
        for root in resourceRoots {
            let candidate = root.appendingPathComponent(relativePath)
            if FileManager.default.isReadableFile(atPath: candidate.path) { return candidate }
        }
        throw ShellError.exitStatus(-1, "应用内置动效技能缺失，请重新安装应用。")
    }

    static func bundledURL() throws -> URL {
        if let root = Bundle.main.resourceURL,
           let skill = try? locate(in: [root]) { return skill }
        guard let root = Bundle.module.resourceURL else {
            throw ShellError.exitStatus(-1, "无法读取应用内置动效技能。")
        }
        return try locate(in: [root])
    }
}
