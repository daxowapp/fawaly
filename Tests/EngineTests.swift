import Foundation
import Testing
@testable import FawalyApp

private func engineFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fawaly-engine-test-" + UUID().uuidString)
    try Paths.ensurePrivateDirectory(root)
    return root
}

@Test func isolatedCLIInvocationsUseSafeFlagsAndStdin() throws {
    let directory = try engineFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = URL(fileURLWithPath: "/usr/bin/true")
    let config = EngineConfiguration(root: directory)
    let codex = try AgentWorker.invocation(.codex, executable: executable, directory: directory, workspace: nil,
                                          codexHome: config.codexHome, token: nil)
    #expect(codex.environment["CODEX_HOME"] == config.codexHome.path)
    #expect(codex.environment["OPENAI_API_KEY"] == nil)
    #expect(codex.arguments.contains("--ignore-user-config"))
    #expect(codex.arguments.contains("read-only"))
    #expect(codex.arguments.last == "-")
    let claude = try AgentWorker.invocation(.claude, executable: executable, directory: directory, workspace: nil,
                                           codexHome: config.codexHome, token: "fixture-token")
    #expect(claude.environment["CLAUDE_CODE_OAUTH_TOKEN"] == "fixture-token")
    #expect(!claude.arguments.contains("fixture-token"))
    #expect(claude.arguments.contains("--strict-mcp-config"))
    #expect(claude.arguments.contains("--safe-mode"))
    #expect(claude.arguments[try #require(claude.arguments.firstIndex(of: "--tools")) + 1].isEmpty)
}

@Test func workerReceivesInputAndCannotWriteOutsideItsJob() async throws {
    let root = try engineFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("job")
    try Paths.ensurePrivateDirectory(directory)
    let outside = root.appendingPathComponent("outside").path
    let invocation = AgentWorker.Invocation(program: URL(fileURLWithPath: "/bin/sh"), arguments: [], environment: [:])
    let profile = directory.appendingPathComponent("worker.sb")
    try AgentWorker.sandboxProfile(invocation: invocation, directory: directory, workspace: nil, codexHome: nil)
        .write(to: profile, atomically: true, encoding: .utf8)
    let output = try await WorkerProcess.run(
        program: "/usr/bin/sandbox-exec",
        arguments: ["-f", profile.path, "/bin/sh", "-c", "if /usr/bin/touch \"$1\"; then exit 7; fi; /bin/cat", "fixture", outside],
        environment: ["PATH": "/usr/bin:/bin"], directory: directory, workingDirectory: directory,
        prompt: "Fixture brief", timeout: 5
    )
    #expect(String(decoding: output, as: UTF8.self) == "Fixture brief")
    #expect(!FileManager.default.fileExists(atPath: outside))
}

@Test func workerTimeoutStopsTheProcessGroup() async throws {
    let directory = try engineFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("too-late").path
    await #expect(throws: FawalyError.self) {
        _ = try await WorkerProcess.run(
            program: "/bin/sh", arguments: ["-c", "(/bin/sleep 2; /usr/bin/touch \"$1\") & wait", "fixture", marker],
            environment: ["PATH": "/usr/bin:/bin"], directory: directory, workingDirectory: directory, prompt: "Fixture", timeout: 1
        )
    }
    try await Task.sleep(for: .milliseconds(1_300))
    #expect(!FileManager.default.fileExists(atPath: marker))
}

@Test func bridgeRoutesToTheOtherAgentAndRefusesUnapprovedProjects() async throws {
    let root = try engineFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = EngineConfiguration(root: root)
    let fake: @Sendable (EngineAgent, String, URL?, Int) async throws -> String = { agent, prompt, workspace, _ in
        #expect(workspace == nil)
        return agent.rawValue + ": " + prompt
    }
    let codex = EngineBridge(configuration: configuration, client: .codex, worker: fake, ready: { _ in true })
    let claude = EngineBridge(configuration: configuration, client: .claude, worker: fake, ready: { _ in true })
    let fromCodex = try await codex.delegate(brief: "fixture", cwd: nil, provider: nil, timeout: 1)
    let fromClaude = try await claude.delegate(brief: "fixture", cwd: nil, provider: nil, timeout: 1)
    #expect(fromCodex.provider == "claude-official")
    #expect(fromClaude.finalMessage == "codex: fixture")
    await #expect(throws: FawalyError.self) {
        _ = try await codex.delegate(brief: "fixture", cwd: root.path, provider: nil, timeout: 1)
    }
    await #expect(throws: FawalyError.self) {
        _ = try await codex.delegate(brief: "fixture", cwd: nil, provider: "codex", timeout: 1)
    }
}

@Test func MCPCompatibilityAndConsultationRounds() async throws {
    let root = try engineFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let bridge = EngineBridge(configuration: .init(root: root), client: .codex, worker: { _, prompt, _, _ in prompt }, ready: { _ in true })
    let server = EngineMCP(bridge: bridge)
    var ready = false
    let setup = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#.utf8)
    let hello = await server.handle(setup, initialized: &ready)
    #expect((hello?["result"] as? [String: Any])?["protocolVersion"] as? String == "2024-11-05")
    let list = await server.handle(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8), initialized: &ready)
    let schemas = (list?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
    #expect(schemas?.contains(where: { $0["name"] as? String == "delegate" }) == true)
    let call = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"delegate","arguments":{"brief":"fixture","lane":"routine","allowMetered":false}}}"#
    let reply = await server.handle(Data(call.utf8), initialized: &ready)
    let payload = (reply?["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
    #expect(payload?["schema"] as? String == "delegate-relay.result.v1")
    let first = try await bridge.consult(question: "Question", context: "", reason: .userRequest, provider: nil)
    let second = try await bridge.consult(question: "Follow-up", context: "", reason: .userRequest, provider: nil, continuing: first.id)
    #expect(second.rounds.count == 2)
    #expect(second.rounds.last?.advice.contains("Prior question") == true)
    let closed = try bridge.decide(id: first.id, decision: .adopted, summary: "Verified")
    #expect(closed.status == .closed)
    await #expect(throws: FawalyError.self) {
        _ = try await bridge.consult(question: "Too late", context: "", reason: .userRequest, provider: nil, continuing: first.id)
    }
}

@Test func codexCompletedEventSuppliesAnswerWhenFinalFileIsMissing() throws {
    let directory = try engineFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let message = #"{"type":"item.completed","item":{"type":"agent_message","text":"Verified fixture answer"}}"#
    let completed = Data((message + "\n{\"type\":\"turn.completed\"}\n").utf8)
    #expect(try AgentWorker.answer(.codex, directory: directory, output: completed) == "Verified fixture answer")
    let interrupted = Data((message + "\n{\"type\":\"turn.failed\"}\n").utf8)
    #expect(throws: FawalyError.self) { try AgentWorker.answer(.codex, directory: directory, output: interrupted) }
}

@Test func nativeAuthSandboxReadsOnlyTheSelectedKeychainAndCannotWriteIt() async throws {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".fawaly-auth-test-" + UUID().uuidString)
    try Paths.ensurePrivateDirectory(root)
    defer { try? FileManager.default.removeItem(at: root) }
    let job = root.appendingPathComponent("job")
    try Paths.ensurePrivateDirectory(job)
    let keychain = root.appendingPathComponent("fixture.keychain-db")
    let other = root.appendingPathComponent("other-private-file")
    try Data("fixture".utf8).write(to: keychain)
    try Data("private".utf8).write(to: other)
    let invocation = AgentWorker.Invocation(program: URL(fileURLWithPath: "/bin/sh"), arguments: [], environment: [:])
    let profile = job.appendingPathComponent("worker.sb")
    try AgentWorker.sandboxProfile(invocation: invocation, directory: job, workspace: nil, codexHome: nil, authKeychain: keychain)
        .write(to: profile, atomically: true, encoding: .utf8)
    let script = "cat \"$1\" || exit 3; if cat \"$2\"; then exit 4; fi; if printf changed >> \"$1\"; then exit 5; fi; exit 0"
    let output = try await WorkerProcess.run(program: "/usr/bin/sandbox-exec", arguments: ["-f", profile.path, "/bin/sh", "-c", script, "fixture", keychain.path, other.path],
        environment: ["PATH": "/usr/bin:/bin"], directory: job, workingDirectory: job, prompt: "Fixture", timeout: 5)
    #expect(String(decoding: output, as: UTF8.self) == "fixture")
    #expect(try String(contentsOf: keychain, encoding: .utf8) == "fixture")
}

@Test func kimiWorkerRestrictsToolsAndKeepsTheBriefOutOfArguments() throws {
    let root = try engineFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let authentication = root.appendingPathComponent("authentication")
    try Paths.ensurePrivateDirectory(authentication.appendingPathComponent("credentials"))
    let credential = authentication.appendingPathComponent("credentials/fixture.json")
    try Data("fixture".utf8).write(to: credential)
    try Data("default_model = \"fixture\"\n".utf8).write(to: authentication.appendingPathComponent("config.toml"))
    let job = root.appendingPathComponent("job")
    try Paths.ensurePrivateDirectory(job)
    try KimiWorker.prepare(directory: job, authentication: authentication, workspace: nil)
    let invocation = try AgentWorker.invocation(.kimi, executable: URL(fileURLWithPath: "/usr/bin/true"), directory: job, workspace: nil,
                                              codexHome: root, token: nil, kimiHome: authentication)
    #expect(invocation.arguments.contains("--agent-file"))
    #expect(invocation.arguments.contains("--skills-dir"))
    #expect(!invocation.arguments.contains("--auto"))
    #expect(invocation.environment["KIMI_CODE_HOME"] == job.appendingPathComponent("kimi-config").path)
    let profile = try String(contentsOf: job.appendingPathComponent("fawaly-worker.md"), encoding: .utf8)
    let allowed = try #require(profile.components(separatedBy: "disallowedTools:").first)
    #expect(allowed.contains("  - Read"))
    #expect(!allowed.contains("  - Bash"))
    #expect(!allowed.contains("  - Write"))
    #expect(profile.contains("subagents: []"))
    #expect(job.appendingPathComponent("kimi-config/credentials").resolvingSymlinksInPath().path == authentication.appendingPathComponent("credentials").resolvingSymlinksInPath().path)
    try FileManager.default.removeItem(at: job)
    #expect(FileManager.default.fileExists(atPath: credential.path))
}

@Test func workerSandboxAllowsCanonicalTemporaryPathsWithoutAllowingSiblingWrites() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fawaly-alias-test-" + UUID().uuidString)
    let job = root.appendingPathComponent("job")
    try Paths.ensurePrivateDirectory(job)
    defer { try? FileManager.default.removeItem(at: root) }
    let canonical = try #require(realpath(job.path, nil))
    defer { free(canonical) }
    let resolvedJob = String(cString: canonical)
    let invocation = AgentWorker.Invocation(program: URL(fileURLWithPath: "/bin/sh"), arguments: [], environment: [:])
    let profile = job.appendingPathComponent("worker.sb")
    try AgentWorker.sandboxProfile(invocation: invocation, directory: job, workspace: nil, codexHome: nil)
        .write(to: profile, atomically: true, encoding: .utf8)
    let script = "mkdir -p \"$1/nested\" || exit 3; printf OK > \"$1/nested/result\" || exit 4; if printf denied > \"$1/../outside\"; then exit 5; fi; cat \"$1/nested/result\""
    let output = try await WorkerProcess.run(program: "/usr/bin/sandbox-exec", arguments: ["-f", profile.path, "/bin/sh", "-c", script, "fixture", resolvedJob],
        environment: ["PATH": "/usr/bin:/bin"], directory: job, workingDirectory: job, prompt: "Fixture", timeout: 5)
    #expect(String(decoding: output, as: UTF8.self) == "OK")
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("outside").path))
}

@Test func kimiAnswersUseTheFinalAssistantMessage() throws {
    let output = Data(#"{"role":"assistant","content":"Reading the brief","tool_calls":[{"function":{"name":"Read"}}]}"#.utf8)
        + Data("\n".utf8)
        + Data(#"{"role":"tool","content":"fixture"}"#.utf8)
        + Data("\n".utf8)
        + Data(#"{"role":"assistant","content":"KIMI_FIXTURE_OK"}"#.utf8)
    let root = try engineFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(try AgentWorker.answer(.kimi, directory: root, output: output) == "KIMI_FIXTURE_OK")
}
