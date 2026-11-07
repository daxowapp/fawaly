import Foundation
import Testing
@testable import FawalyApp

@Test func stoppedWorkspaceWorkerKeepsPartialChangesForPrimaryReview() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fawaly-stop-state-" + UUID().uuidString)
    let project = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".fawaly-stop-project-" + UUID().uuidString)
    try Paths.ensurePrivateDirectory(project)
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: project) }
    let config = EngineConfiguration(root: root)
    _ = try config.allowWorkspace(project.path)
    var state = WorkshopState()
    state.team = TeamSettings(primary: .codex, advisor: .claude, workers: [.kimi])
    try WorkshopStore(root: root).save(state)
    let bridge = EngineBridge(configuration: config, client: .codex, worker: { _, _, workspace, _ in
        let command = root.appendingPathComponent("fixture-command")
        try Paths.ensurePrivateDirectory(command)
        _ = try await WorkerProcess.run(program: "/bin/sh", arguments: ["-c", "printf partial > \"$1/partial.txt\"; /bin/sleep 20", "fixture", workspace!.path],
            environment: ["PATH": "/usr/bin:/bin"], directory: command, workingDirectory: command, prompt: "", timeout: 25, stopFile: WorkerContext.stopFile)
        return "Unexpected completion"
    }, ready: { _ in true })
    let running = Task { try await bridge.delegate(brief: "Fixture stop after partial edit", cwd: project.path, provider: nil, timeout: 25) }
    defer { running.cancel() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while !FileManager.default.fileExists(atPath: project.appendingPathComponent("partial.txt").path), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("partial.txt").path))
    let job = try #require(TeamJobLog(root: root).recent().first)
    #expect(throws: FawalyError.self) { try config.requestStop(job.id, primary: .claude) }
    try config.requestStop(job.id, primary: .codex)
    let result = try await running.value
    #expect(result.status == "needs_handoff")
    #expect(result.reviewRequired)
    #expect(try String(contentsOf: project.appendingPathComponent("partial.txt"), encoding: .utf8) == "partial")
    #expect(!FileManager.default.fileExists(atPath: config.stopFile(job.id).path))
    #expect(try TeamJobLog(root: root).recent().first?.reviewRequired == true)
    #expect(throws: FawalyError.self) { try config.requestStop(job.id) }
}

@Test func mcpSchemasExplainEnumValuesAndRejectUnknownReasons() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fawaly-schema-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let server = EngineMCP(bridge: EngineBridge(configuration: .init(root: root), client: .codex))
    var initialized = true
    let bytes = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"consult","arguments":{"question":"Fixture","reason":"a free-form reason"}}}"#.utf8)
    let result = await server.handle(bytes, initialized: &initialized)
    let reply = result?["result"] as? [String: Any]
    #expect(reply?["isError"] as? Bool == true)
    let text = (reply?["content"] as? [[String: String]])?.first?["text"] ?? ""
    #expect(text.contains("risky_change"))
    #expect(text.contains("plan"))
    let status = await server.handle(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"status","arguments":{}}}"#.utf8), initialized: &initialized)
    #expect((status?["result"] as? [String: Any])?["isError"] as? Bool == false)
}

#if DEBUG
@Test func stdioStopRespondsWhileDelegationIsStillInFlight() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fawaly-stdio-stop-" + UUID().uuidString)
    try Paths.ensurePrivateDirectory(root.appendingPathComponent("runtimes"))
    defer { try? FileManager.default.removeItem(at: root) }
    var state = WorkshopState()
    state.team = TeamSettings(primary: .claude, advisor: nil, workers: [.codex])
    try WorkshopStore(root: root).save(state)
    let config = EngineConfiguration(root: root)
    try config.prepareCodexHome()
    try Data("fixture".utf8).write(to: config.codexHome.appendingPathComponent("auth.json"))
    let executable = root.appendingPathComponent("runtimes/codex")
    try "#!/bin/sh\n/bin/sleep 20\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let output = root.appendingPathComponent("protocol-output")
    FileManager.default.createFile(atPath: output.path, contents: nil)
    let writer = try FileHandle(forWritingTo: output)
    defer { try? writer.close() }
    let process = Process()
    process.executableURL = try #require(Bundle.main.executableURL)
    process.arguments = ["mcp", "--client", "claude"]
    process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin", "FAWALY_ENGINE_TEST_ROOT": root.path]
    let input = Pipe()
    process.standardInput = input
    process.standardOutput = writer
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
    func send(_ id: Int, method: String, params: [String: Any]) throws {
        var bytes = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        bytes.append(10)
        try input.fileHandleForWriting.write(contentsOf: bytes)
    }
    func response(_ id: Int) async throws -> [String: Any] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            let data = (try? Data(contentsOf: output)) ?? Data()
            for line in data.split(separator: 10) {
                if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], object["id"] as? Int == id { return object }
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw FawalyError.invalid("A stop response was blocked behind the running delegation.")
    }
    try send(1, method: "initialize", params: ["protocolVersion": "2025-11-25"])
    _ = try await response(1)
    try send(2, method: "tools/call", params: ["name": "delegate", "arguments": ["brief": "Wait for stop fixture", "timeout": "25s"]])
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    var job: TeamJob?
    while ContinuousClock.now < deadline {
        job = try TeamJobLog(root: root).recent().first
        if job != nil { break }
        try await Task.sleep(for: .milliseconds(25))
    }
    let id = try #require(job?.id)
    try send(3, method: "tools/call", params: ["name": "stop", "arguments": ["jobId": id.uuidString]])
    let stopped = try await response(3)["result"] as? [String: Any]
    #expect(stopped?["isError"] as? Bool == false)
    let result = try await response(2)["result"] as? [String: Any]
    let payload = result?["structuredContent"] as? [String: Any]
    #expect(payload?["status"] as? String == "cancelled")
    #expect(try TeamJobLog(root: root).recent().first?.status == "cancelled")
}

#endif
