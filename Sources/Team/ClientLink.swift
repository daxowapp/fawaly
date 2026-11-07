import Foundation

struct ClientLink: Sendable {
    static let serverName = "fawaly_team"
    let root: URL
    let application: URL
    var home = FileManager.default.homeDirectoryForCurrentUser
    var execute: @Sendable (LoginCommand, TimeInterval, @escaping @Sendable (URL) -> Void) async throws -> LoginReply = { command, timeout, callback in
        try await LoginProcess.run(command, timeout: timeout, onURL: callback)
    }

    private var environment: [String: String] {
        ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
         "CODEX_HOME": home.appendingPathComponent(".codex").path, "TERM": "dumb"]
    }

    func connect(_ primary: EngineAgent) async throws {
        guard EngineAgent.primaryAgents.contains(primary), FileManager.default.isExecutableFile(atPath: application.path),
              let binary = primary.executable(root: root) else { throw FawalyError.invalid("Prepare your primary agent first.") }
        try Paths.ensurePrivateDirectory(root)
        let lease = try WorkActivityLease(root: root)
        defer { withExtendedLifetime(lease) {} }
        let launcher = ClientLauncher(root: root)
        let expected = ["mcp", "--client", primary.rawValue]
        var savedEntry = try await entry(primary, executable: binary)
        if let existing = savedEntry {
            guard [application.path, launcher.url.path].contains(existing.command) || Self.ownsApplicationExecutable(existing.command), existing.arguments == expected,
                  existing.environment.isEmpty else {
                throw FawalyError.invalid("A different Fawaly team connection already exists. Open your agent’s MCP settings to review it before reconnecting.")
            }
        }
        try launcher.prepare(application: application)
        if primary == .claude { try migrateOwnedDesktopOverride() }
        // Migrate only our exact previous registration, preserving unrelated servers.
        if let previous = savedEntry, previous.command != launcher.url.path {
            let arguments = primary == .codex ? ["mcp", "remove", Self.serverName] : ["mcp", "remove", "--scope", "user", Self.serverName]
            let reply = try await execute(LoginCommand(executable: binary, arguments: arguments, environment: environment, directory: root), 30, { _ in })
            guard reply.exitCode == 0 else { throw FawalyError.invalid("The previous team connection could not be migrated. Please retry.") }
            savedEntry = nil
        }
        if savedEntry == nil {
            let arguments = primary == .codex
                ? ["mcp", "add", Self.serverName, "--", launcher.url.path] + expected
                : ["mcp", "add", "--scope", "user", "--transport", "stdio", Self.serverName, "--", launcher.url.path] + expected
            let reply = try await execute(LoginCommand(executable: binary, arguments: arguments, environment: environment, directory: root), 30, { _ in })
            guard reply.exitCode == 0 else { throw FawalyError.invalid("The team connection could not be saved in your primary agent. Please retry.") }
        }
        guard let saved = try await entry(primary, executable: binary), saved.command == launcher.url.path,
              saved.arguments == expected else { throw FawalyError.invalid("The primary agent has not confirmed its team settings. Please retry.") }
        if primary == .codex {
            try await CodexSettingsWriter.setTeamTimeout(executable: binary, home: home, directory: root, environment: environment)
        }
        try await checkEngine(primary)
    }

    func checkEngine(_ primary: EngineAgent) async throws {
        let requests: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "fawaly-setup", "version": "0.7.0"]]],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list"]
        ]
        let input = try requests.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        let command = LoginCommand(executable: application, arguments: ["mcp", "--client", primary.rawValue],
                                   environment: environment, directory: root, input: input)
        let reply = try await execute(command, 15, { _ in })
        let replies = reply.output.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let listing = replies.first { $0["id"] as? Int == 2 }?["result"] as? [String: Any]
        let tools = listing?["tools"] as? [[String: Any]] ?? []
        let names = Set(tools.compactMap { $0["name"] as? String })
        guard reply.exitCode == 0, Set(["roster_get", "consult", "delegate"]).isSubset(of: names) else {
            throw FawalyError.invalid("The team connection was saved, but its engine check failed. Please retry.")
        }
    }

    private struct Entry {
        let command: String
        let arguments: [String]
        let environment: [String: String]
    }

    static func ownsApplicationExecutable(_ command: String) -> Bool {
        let binary = URL(fileURLWithPath: command)
        let bundleURL = binary.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard bundleURL.pathExtension == "app", let bundle = Bundle(url: bundleURL),
              bundle.bundleIdentifier == "com.daxow.fawaly.rebuilt",
              bundle.executableURL?.resolvingSymlinksInPath() == binary.resolvingSymlinksInPath() else { return false }
        return FileManager.default.isExecutableFile(atPath: command)
    }

    /// Local Code-tab sessions give this file precedence over Claude Code's
    /// user scope. Migrate only a matching Fawaly registration, never another
    /// server that happens to use our name.
    func migrateOwnedDesktopOverride() throws {
        let file = home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        var coordinationError: NSError?, bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: file, options: .forReplacing, error: &coordinationError) { url in
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw FawalyError.invalid("Claude Desktop settings must be a regular file.") }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: 1_048_577) ?? Data()
                guard data.count <= 1_048_576, var settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FawalyError.invalid("Claude Desktop settings could not be read safely.") }
                guard settings["mcpServers"] != nil else { return }
                guard var servers = settings["mcpServers"] as? [String: Any] else { throw FawalyError.invalid("Claude Desktop has invalid MCP settings. Review them before reconnecting.") }
                guard servers[Self.serverName] != nil else { return }
                guard var entry = servers[Self.serverName] as? [String: Any] else { throw FawalyError.invalid("Claude Desktop has an invalid Fawaly connection.") }
                let command = entry["command"] as? String ?? ""
                let launcher = ClientLauncher(root: root).url.path
                guard entry["args"] as? [String] == ["mcp", "--client", "claude"],
                      entry["env"] == nil || (entry["env"] as? [String: String])?.isEmpty == true,
                      command == launcher || command == application.path || Self.ownsApplicationExecutable(command) else {
                    throw FawalyError.invalid("Claude Desktop has a different Fawaly connection that overrides the Code tab. Review that named connection in Claude’s settings before reconnecting; other connections were preserved.")
                }
                guard command != launcher else { return }
                entry["command"] = launcher; servers[Self.serverName] = entry; settings["mcpServers"] = servers
                try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch { bodyError = error }
        }
        if let bodyError { throw bodyError }
        if let coordinationError { throw coordinationError }
    }

    private func entry(_ primary: EngineAgent, executable: URL) async throws -> Entry? {
        let value: [String: Any]?
        if primary == .codex {
            let command = LoginCommand(executable: executable, arguments: ["mcp", "get", Self.serverName, "--json"], environment: environment, directory: root)
            let reply = try await execute(command, 15, { _ in })
            if reply.exitCode != 0 {
                guard (reply.output + reply.errorOutput).contains("No MCP server named") else {
                    throw FawalyError.invalid("Codex settings could not be read. Check your agent’s settings and retry.")
                }
                return nil
            }
            value = (try JSONSerialization.jsonObject(with: Data(reply.output.utf8)) as? [String: Any])?["transport"] as? [String: Any]
        } else {
            let file = home.appendingPathComponent(".claude.json")
            do {
                let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
                value = (settings?["mcpServers"] as? [String: Any])?[Self.serverName] as? [String: Any]
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        }
        guard let value else { return nil }
        return Entry(command: value["command"] as? String ?? "", arguments: value["args"] as? [String] ?? [], environment: value["env"] as? [String: String] ?? [:])
    }
}
