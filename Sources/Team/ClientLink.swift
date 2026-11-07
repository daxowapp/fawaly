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
        let expected = ["mcp", "--client", primary.rawValue]
        if let existing = try await entry(primary, executable: binary) {
            guard existing.command == application.path, existing.arguments == expected else {
                throw FawalyError.invalid("A different Fawaly team connection already exists. Open your agent’s MCP settings to review it before reconnecting.")
            }
        } else {
            let arguments = primary == .codex
                ? ["mcp", "add", Self.serverName, "--", application.path] + expected
                : ["mcp", "add", "--scope", "user", "--transport", "stdio", Self.serverName, "--", application.path] + expected
            let reply = try await execute(LoginCommand(executable: binary, arguments: arguments, environment: environment, directory: root), 30, { _ in })
            guard reply.exitCode == 0 else { throw FawalyError.invalid("The team connection could not be saved in your primary agent. Please retry.") }
        }
        guard let saved = try await entry(primary, executable: binary), saved.command == application.path,
              saved.arguments == expected else { throw FawalyError.invalid("The primary agent has not confirmed its team settings. Please retry.") }
        if primary == .codex {
            try await CodexSettingsWriter.setTeamTimeout(executable: binary, home: home, directory: root, environment: environment)
        }
        try await checkEngine(primary)
    }

    func checkEngine(_ primary: EngineAgent) async throws {
        let requests: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "fawaly-setup", "version": "0.6.0"]]],
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
        return Entry(command: value["command"] as? String ?? "", arguments: value["args"] as? [String] ?? [])
    }
}
