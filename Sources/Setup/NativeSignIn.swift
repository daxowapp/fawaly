import Foundation
import Darwin

struct NativeSignIn: Sendable {
    let configuration: EngineConfiguration
    var execute: @Sendable (LoginCommand, TimeInterval, @escaping @Sendable (URL) -> Void) async throws -> LoginReply = { command, timeout, onURL in
        try await LoginProcess.run(command, timeout: timeout, onURL: onURL)
    }

    func command(_ agent: EngineAgent, login: Bool, region: KimiRegion = .global) throws -> LoginCommand {
        guard let executable = agent.executable(root: configuration.root) else {
            throw FawalyError.invalid("This service needs to be prepared first.")
        }
        try configuration.prepareAuthDirectory(agent)
        let directory = configuration.nativeAuthDirectory(agent)
        var environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "TERM": "dumb", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "DISABLE_AUTOUPDATER": "1"
        ]
        let arguments: [String]
        if agent == .codex {
            environment["CODEX_HOME"] = directory.path
            arguments = (login ? ["login"] : ["login", "status"]) + ["-c", "cli_auth_credentials_store=\"file\""]
        } else if agent == .kimi {
            environment["KIMI_CODE_HOME"] = directory.path
            environment["KIMI_DISABLE_TELEMETRY"] = "1"
            arguments = login ? ["login", "--region", region.rawValue] : ["provider", "list", "--json"]
        } else {
            environment["CLAUDE_CONFIG_DIR"] = directory.path
            arguments = login ? ["auth", "login", "--claudeai"] : ["auth", "status", "--json"]
        }
        return LoginCommand(executable: executable, arguments: arguments, environment: environment, directory: directory)
    }

    func signIn(_ agent: EngineAgent, region: KimiRegion = .global, onURL: @escaping @Sendable (URL) -> Void) async throws {
        let result = try await execute(command(agent, login: true, region: region), 600, onURL)
        guard result.exitCode == 0 else { throw FawalyError.invalid("Sign-in was not completed. You can retry from this screen.") }
        if agent == .kimi { try configuration.recordNativeSignIn(agent, connected: true) }
        guard try await verify(agent) else { throw FawalyError.invalid("The service has not confirmed your sign-in yet.") }
    }

    @discardableResult
    func verify(_ agent: EngineAgent) async throws -> Bool {
        let result = try await execute(command(agent, login: false), 20, { _ in })
        let connected: Bool
        switch agent {
        case .codex:
            connected = result.exitCode == 0 && (result.output + result.errorOutput).localizedCaseInsensitiveContains("logged in")
        case .kimi:
            let object = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any]
            let providers = object?["providers"] as? [String: Any] ?? [:]
            connected = result.exitCode == 0 && !providers.isEmpty && configuration.hasNativeSignIn(.kimi)
                && KimiWorker.hasCredentials(configuration.nativeAuthDirectory(.kimi))
        case .claude:
            let data = Data(result.output.utf8)
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            connected = result.exitCode == 0 && object?["loggedIn"] as? Bool == true
        }
        try configuration.recordNativeSignIn(agent, connected: connected)
        return connected
    }

    func signOut(_ agent: EngineAgent) async throws {
        let access = try configuration.lockJob()
        defer { close(access) }
        if agent == .kimi {
            try configuration.prepareAuthDirectory(.kimi)
            let credentials = configuration.nativeAuthDirectory(.kimi).appendingPathComponent("credentials")
            if FileManager.default.fileExists(atPath: credentials.path) { try FileManager.default.removeItem(at: credentials) }
            try configuration.recordNativeSignIn(.kimi, connected: false)
            return
        }
        let base = try command(agent, login: false)
        let args = agent == .codex ? ["logout", "-c", "cli_auth_credentials_store=\"file\""] : ["auth", "logout"]
        let command = LoginCommand(executable: base.executable, arguments: args, environment: base.environment, directory: base.directory)
        let reply = try await execute(command, 20, { _ in })
        guard reply.exitCode == 0 else { throw FawalyError.invalid("Sign-out could not be completed. Please retry.") }
        try configuration.recordNativeSignIn(agent, connected: false)
        if agent == .claude { try EngineKeychain.forgetClaudeToken() }
    }
}

extension EngineConfiguration {
    func nativeAuthDirectory(_ agent: EngineAgent) -> URL {
        root.appendingPathComponent("official", isDirectory: true).appendingPathComponent(agent.rawValue, isDirectory: true)
    }

    func prepareAuthDirectory(_ agent: EngineAgent) throws {
        if agent == .codex { try prepareCodexHome(); return }
        let directory = nativeAuthDirectory(agent)
        try Paths.ensurePrivateDirectory(directory)
        guard directory.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().appendingPathComponent("official/" + agent.rawValue).path else {
            throw FawalyError.invalid("The service sign-in folder could not be prepared.")
        }
    }

    func recordNativeSignIn(_ agent: EngineAgent, connected: Bool) throws {
        try prepareAuthDirectory(agent)
        let marker = nativeAuthDirectory(agent).appendingPathComponent("fawaly-verified.json")
        try JSONEncoder().encode(NativeSignInRecord(connected: connected, checked: Date())).write(to: marker, options: .atomic)
    }

    func hasNativeSignIn(_ agent: EngineAgent) -> Bool {
        let directory = nativeAuthDirectory(agent)
        guard directory.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().appendingPathComponent("official/" + agent.rawValue).path,
              let data = try? Data(contentsOf: directory.appendingPathComponent("fawaly-verified.json")),
              let record = try? JSONDecoder().decode(NativeSignInRecord.self, from: data) else { return false }
        return record.connected
    }

    private struct NativeSignInRecord: Codable {
        let connected: Bool
        let checked: Date
    }
}
