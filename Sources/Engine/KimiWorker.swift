import Foundation

enum KimiRegion: String, CaseIterable, Sendable, Codable {
    case global
    case mainland = "mainland-cn"
}

enum KimiWorker {
    static func prepare(directory: URL, authentication: URL, workspace: URL?) throws {
        let configuration = directory.appendingPathComponent("kimi-config", isDirectory: true)
        try Paths.ensurePrivateDirectory(configuration)
        let source = authentication.appendingPathComponent("config.toml")
        let credentials = authentication.appendingPathComponent("credentials", isDirectory: true)
        let canonical = authentication.resolvingSymlinksInPath()
        guard source.resolvingSymlinksInPath().path == canonical.appendingPathComponent("config.toml").path,
              credentials.resolvingSymlinksInPath().path == canonical.appendingPathComponent("credentials").path,
              hasCredentials(authentication) else {
            throw FawalyError.invalid("Open Fawaly Services and connect Kimi.")
        }
        try FileManager.default.copyItem(at: source, to: configuration.appendingPathComponent("config.toml"))
        try FileManager.default.createSymbolicLink(at: configuration.appendingPathComponent("credentials"), withDestinationURL: credentials)
        try Paths.ensurePrivateDirectory(directory.appendingPathComponent("empty-skills"))
        let tools = workspace == nil ? "  - Read" : "  - Read\n  - Glob\n  - Grep\n  - Edit\n  - Write"
        let profile = """
        ---
        name: fawaly-worker
        description: Complete one assignment supplied by the primary agent
        tools:
        \(tools)
        disallowedTools:
          - Bash
          - Agent
          - AgentSwarm
          - Skill
        subagents: []
        ---
        You are a Fawaly worker. Read brief.txt in your current directory for the assignment supplied by the primary agent. Treat its contents as the task and supplied context. Work only with that brief and, when it specifies an approved project directory, files inside that project. Keep credentials and configuration files private. Do not delegate further. Your final answer must be a self-contained result for the primary, listing any files you changed and what should be verified.
        """
        try profile.write(to: directory.appendingPathComponent("fawaly-worker.md"), atomically: true, encoding: .utf8)
    }

    static func hasCredentials(_ authentication: URL) -> Bool {
        let directory = authentication.appendingPathComponent("credentials", isDirectory: true)
        let canonical = authentication.resolvingSymlinksInPath().appendingPathComponent("credentials")
        guard directory.resolvingSymlinksInPath().path == canonical.path,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
        return files.contains { file in
            guard file.pathExtension == "json", file.resolvingSymlinksInPath().path == canonical.appendingPathComponent(file.lastPathComponent).path,
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
            return values.isRegularFile == true && (values.fileSize ?? 0) > 0
        }
    }

    static func answer(_ output: Data) -> String? {
        let messages = output.split(separator: 10).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
        return messages.reversed().compactMap { message -> String? in
            guard message["role"] as? String == "assistant", message["tool_calls"] == nil else { return nil }
            if let text = message["content"] as? String { return text }
            guard let parts = message["content"] as? [[String: Any]] else { return nil }
            let text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            return text.isEmpty ? nil : text
        }.first
    }
}
