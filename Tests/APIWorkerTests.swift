import Foundation
import Testing
@testable import FawalyApp

private actor APIFixture {
    var requests: [URLRequest] = []
    let replies: [[String: Any]]
    init(_ replies: [[String: Any]]) { self.replies = replies }
    func send(_ request: URLRequest) throws -> (Data, Int) {
        requests.append(request)
        guard requests.count <= replies.count else { throw FawalyError.invalid("Unexpected retry") }
        return (try JSONSerialization.data(withJSONObject: replies[requests.count - 1]), 200)
    }
}

@Test func modelDiscoveryUsesTheSelectedServiceAndDoesNotGenerateText() async throws {
    let root = try apiRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var worker = APIWorker(root: root)
    worker.credential = { _ in "fixture-service-key" }
    worker.transport = { request in
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://fixture.invalid/v1/models")
        #expect(request.httpBody == nil)
        return (try JSONSerialization.data(withJSONObject: ["data": [["id": "loaded-model"], ["id": "loaded-model"], ["id": "bad model"]]]), 200)
    }
    #expect(try await worker.models(apiProfile()) == ["loaded-model"])
    #expect(try APIUsage(root: root).totals(.openAIAPI).requests == 0)
}
private func apiRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("api-test-" + UUID().uuidString)
    try Paths.ensurePrivateDirectory(root)
    return root
}
private func apiProfile(format: APIAssistant.Format = .openAI) -> APIAssistant {
    APIAssistant(agent: format == .openAI ? .openAIAPI : .anthropicAPI,
                 endpoint: URL(string: format == .openAI ? "https://fixture.invalid/v1/chat/completions" : "https://fixture.invalid/v1/messages")!, model: "fixture-model", format: format)
}

@Test func truncatedProviderRepliesNeverCompleteOrExecuteToolCalls() async throws {
    let root = try apiRoot(), project = root.appendingPathComponent("project")
    defer { try? FileManager.default.removeItem(at: root) }
    try Paths.ensurePrivateDirectory(project)
    let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["path": "partial.txt", "content": "must not be written", "expected_sha256": ""]), as: UTF8.self)
    let fixtures: [(APIAssistant.Format, [String: Any])] = [
        (.openAI, ["choices": [["finish_reason": "length", "message": ["content": "partial answer"]]]]),
        (.openAI, ["choices": [["finish_reason": "length", "message": ["tool_calls": [["id": "cut-call", "function": ["name": "write_file", "arguments": arguments]]]]]]]),
        (.anthropic, ["stop_reason": "max_tokens", "content": [["type": "text", "text": "partial answer"]]]),
        (.anthropic, ["stop_reason": "max_tokens", "content": [["type": "tool_use", "id": "cut-call", "name": "write_file", "input": ["path": "partial.txt", "content": "must not be written", "expected_sha256": ""]]]])
    ]
    for (format, reply) in fixtures {
        let fixture = APIFixture([reply])
        var worker = APIWorker(root: root)
        worker.credential = { _ in "fixture-key" }
        worker.transport = { try await fixture.send($0) }
        await #expect(throws: FawalyError.self) {
            try await worker.run(apiProfile(format: format), prompt: "fixture", workspace: project, timeout: 3)
        }
        #expect(await fixture.requests.count == 1)
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("partial.txt").path))
    }
}

@Test func deniedCredentialEndsTheJobWithoutChargingOrFallingBack() async throws {
    let root = try apiRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = apiProfile(), fixture = APIFixture([])
    var configured = APIWorker(root: root)
    configured.credential = { _ in throw FawalyError.invalid("Fixture Keychain access denied") }
    configured.transport = { try await fixture.send($0) }
    let worker = configured
    var state = WorkshopState()
    state.team = TeamSettings(primary: .claude, advisor: .codex, workers: [profile.agent, .kimi])
    try WorkshopStore(root: root).save(state)
    let bridge = EngineBridge(configuration: .init(root: root), client: .claude, worker: { _, brief, workspace, timeout in
        try await worker.run(profile, prompt: brief, workspace: workspace, timeout: timeout)
    }, ready: { _ in true })
    await #expect(throws: FawalyError.self) {
        try await bridge.delegate(brief: "A denied key must not reach a provider", cwd: nil, provider: nil, timeout: 2)
    }
    #expect(await fixture.requests.isEmpty)
    #expect(try APIUsage(root: root).totals(profile.agent).requests == 0)
    let job = try #require(TeamJobLog(root: root).recent().first)
    #expect(job.worker == profile.agent && job.status == "failed" && job.finished != nil)
    #expect(job.reviews?.isEmpty != false)
    #expect(try WorkshopStore(root: root).load().team == state.team)
}

@Test func apiWorkerWritesApprovedFileAndRequiresIndependentPrimaryReview() async throws {
    let root = try apiRoot(), project = root.appendingPathComponent("project")
    defer { try? FileManager.default.removeItem(at: root) }
    try Paths.ensurePrivateDirectory(project)
    let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["path": "src/result.txt", "content": "real fixture result", "expected_sha256": ""]), as: UTF8.self)
    let fixture = APIFixture([
        ["choices": [["message": ["role": "assistant", "content": NSNull(), "tool_calls": [["id": "call-1", "type": "function", "function": ["name": "write_file", "arguments": arguments]]]]]], "usage": ["prompt_tokens": 10, "completion_tokens": 5]],
        ["choices": [["message": ["role": "assistant", "content": "Wrote src/result.txt. Primary must review."]]], "usage": ["prompt_tokens": 12, "completion_tokens": 8]]
    ])
    var worker = APIWorker(root: root)
    worker.credential = { _ in "fixture-service-key" }
    worker.transport = { try await fixture.send($0) }
    let output = try await worker.run(apiProfile(), prompt: "Create the fixture file", workspace: project, timeout: 10)
    #expect(output.contains("Primary must review"))
    #expect(try String(contentsOf: project.appendingPathComponent("src/result.txt")) == "real fixture result")
    let requests = await fixture.requests
    #expect(requests.count == 2)
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer fixture-service-key")
    #expect(!String(decoding: requests[0].httpBody!, as: UTF8.self).contains("fixture-service-key"))
    let usage = try APIUsage(root: root).totals(.openAIAPI)
    #expect(usage.requests == 2 && usage.input == 22 && usage.output == 13)
}

@Test func anthropicToolReplayPreservesAllProviderContentBlocks() async throws {
    let root = try apiRoot(), project = root.appendingPathComponent("project")
    defer { try? FileManager.default.removeItem(at: root) }
    try Paths.ensurePrivateDirectory(project)
    let blocks: [[String: Any]] = [["type": "thinking", "thinking": "fixture", "signature": "provider-signature"], ["type": "tool_use", "id": "call-1", "name": "list_files", "input": [:]]]
    let fixture = APIFixture([["content": blocks], ["content": [["type": "text", "text": "Reviewed the empty fixture."]]]])
    var worker = APIWorker(root: root)
    worker.credential = { _ in "fixture-service-key" }; worker.transport = { try await fixture.send($0) }
    _ = try await worker.run(apiProfile(format: .anthropic), prompt: "List project files", workspace: project, timeout: 10)
    let requests = await fixture.requests
    let body = try #require(JSONSerialization.jsonObject(with: requests[1].httpBody!) as? [String: Any])
    let messages = try #require(body["messages"] as? [[String: Any]])
    let replay = try #require(messages[1]["content"] as? [[String: Any]])
    #expect(replay[0]["signature"] as? String == "provider-signature")
    #expect(requests[0].value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
}

@Test func apiWorkerCapAndProviderFailureNeverRetryOrFallback() async throws {
    let root = try apiRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var profile = apiProfile(); profile.dailyRequestLimit = 1
    var worker = APIWorker(root: root)
    worker.credential = { _ in "fixture-service-key" }
    worker.transport = { _ in (Data("provider body is not exposed".utf8), 429) }
    await #expect(throws: FawalyError.self) { try await worker.run(profile, prompt: "fixture", workspace: nil, timeout: 2) }
    #expect(try APIUsage(root: root).totals(profile.agent).requests == 1)
    worker.transport = { _ in Issue.record("A capped request reached the provider"); return (Data(), 500) }
    await #expect(throws: FawalyError.self) { try await worker.run(profile, prompt: "fixture", workspace: nil, timeout: 2) }
    #expect(try APIUsage(root: root).totals(profile.agent).requests == 1)
}

@Test func apiWorkspaceRejectsTraversalLinksGitAndStaleWrites() throws {
    let root = try apiRoot(), project = root.appendingPathComponent("project")
    defer { try? FileManager.default.removeItem(at: root) }
    try Paths.ensurePrivateDirectory(project)
    let outside = root.appendingPathComponent("outside.txt")
    try Data("private outside".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("link"), withDestinationURL: outside)
    let files = try APIWorkspace(project)
    for path in ["../outside.txt", "/etc/passwd", ".git/config", ".GIT/hooks/test", ".Git/config", ".gi\u{200c}t/config", "link"] {
        #expect(throws: FawalyError.self) { _ = try files.read(path) }
        #expect(throws: FawalyError.self) { try files.write(path, content: "bad", expectedDigest: "") }
    }
    try files.write("good.txt", content: "first", expectedDigest: "")
    let first = try files.read("good.txt")
    try files.write("good.txt", content: "second", expectedDigest: first.digest)
    #expect(throws: FawalyError.self) { try files.write("good.txt", content: "stale", expectedDigest: first.digest) }
    #expect(try files.read("good.txt").text == "second")
    #expect(try String(contentsOf: outside) == "private outside")
    #expect(try files.list() == ["good.txt"])
}

@Test func apiProfilesRejectUnsafeDestinationsAndNeverExportCredentials() throws {
    var profile = apiProfile()
    for raw in ["http://remote.example/v1/chat/completions", "https://user:pass@host/v1/chat/completions", "https://host/v1/chat/completions?key=bad"] {
        profile.endpoint = URL(string: raw)!
        #expect(throws: FawalyError.self) { try profile.validate() }
    }
    var local = APIAssistant.preset(.ollama); local.model = "fixture-model"
    try local.validate()
    local.endpoint = URL(string: "https://remote.example/v1/chat/completions")!
    #expect(throws: FawalyError.self) { try local.validate() }
    let root = try apiRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try APIAssistantStore(root: root).save(apiProfile())
    #expect(try APIAssistantStore(root: root).load(.openAIAPI)?.model == "fixture-model")
    let backup = String(decoding: try JSONEncoder().encode(PreferencesBackup(state: WorkshopState())), as: UTF8.self)
    #expect(!backup.contains("fixture.invalid"))
    #expect(!backup.contains("api-assistants"))
}

@Test func serviceKeysRoundTripThroughKeychainAndRemainScopedToTheirDestination() throws {
    var profile = apiProfile()
    profile.endpoint = URL(string: "https://" + UUID().uuidString.lowercased() + ".invalid/v1/chat/completions")!
    defer { try? APIAssistantKeychain.remove(profile) }
    try APIAssistantKeychain.save("fixture-only-not-a-real-credential", for: profile)
    #expect(APIAssistantKeychain.contains(profile))
    #expect(try APIAssistantKeychain.read(profile) == "fixture-only-not-a-real-credential")
    var other = profile
    other.endpoint = URL(string: "https://different.invalid/v1/chat/completions")!
    #expect(!APIAssistantKeychain.contains(other))
    #expect(try APIAssistantKeychain.read(other).isEmpty)
    try APIAssistantKeychain.save("fixture-replacement-not-a-real-credential", for: profile)
    #expect(try APIAssistantKeychain.read(profile) == "fixture-replacement-not-a-real-credential")
    try APIAssistantKeychain.remove(profile)
    #expect(!APIAssistantKeychain.contains(profile))
}

@Test func rosterReportsLocalCapsAndDoesNotStartACappedWorker() async throws {
    let root = try apiRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var profile = apiProfile(); profile.dailyRequestLimit = 1
    try APIAssistantStore(root: root).save(profile)
    try APIUsage(root: root).reserve(profile)
    var state = WorkshopState(); state.team = TeamSettings(primary: .codex, advisor: .claude, workers: [.openAIAPI])
    try WorkshopStore(root: root).save(state)
    let bridge = EngineBridge(configuration: .init(root: root), client: .codex, worker: { _, _, _, _ in
        Issue.record("The capped worker must not start"); return "unexpected"
    }, ready: { _ in true })
    let status = try bridge.status()
    #expect(status.providers[EngineAgent.openAIAPI.providerID]?.status == "local_limit_reached")
    #expect(status.providers[EngineAgent.openAIAPI.providerID]?.workerModel == "fixture-model")
    await #expect(throws: FawalyError.self) { try await bridge.delegate(brief: "capped fixture", cwd: nil, provider: EngineAgent.openAIAPI.providerID, timeout: 2) }
    #expect(try TeamJobLog(root: root).recent().isEmpty)
}

@Test func editFileChangesExactPassagesAtomicallyThroughTheAnchoredWrite() throws {
    let root = try apiRoot(), project = root.appendingPathComponent("project")
    defer { try? FileManager.default.removeItem(at: root) }
    try Paths.ensurePrivateDirectory(project)
    let outside = root.appendingPathComponent("outside.txt")
    try Data("private outside".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("link"), withDestinationURL: outside)
    let files = try APIWorkspace(project)
    let first = try files.write("notes.txt", content: "alpha\r\nbeta ✓\nbeta again\n", expectedDigest: "")
    #expect(try files.read("notes.txt").digest == first)

    // Edits apply in order, each to the result of the one before.
    let second = try files.edit("notes.txt", edits: [.init(old: "alpha\r\n", new: "gamma\r\n"), .init(old: "gamma", new: "delta")], expectedDigest: first)
    let changed = try files.read("notes.txt")
    #expect(changed.text == "delta\r\nbeta ✓\nbeta again\n" && changed.digest == second)

    // A missing, repeated or empty passage, a later edit that fails, no edits,
    // a stale digest and an oversized result all leave the file untouched.
    let rejected: [[APIWorkspace.Edit]] = [
        [.init(old: "absent", new: "x")], [.init(old: "beta", new: "x")], [.init(old: "", new: "x")],
        [.init(old: "delta", new: "must not stay"), .init(old: "absent", new: "x")], [],
        [.init(old: "delta", new: String(repeating: "x", count: APIWorkspace.limit))]
    ]
    for edits in rejected {
        #expect(throws: FawalyError.self) { _ = try files.edit("notes.txt", edits: edits, expectedDigest: second) }
    }
    #expect(throws: FawalyError.self) { _ = try files.edit("notes.txt", edits: [.init(old: "delta", new: "stale")], expectedDigest: first) }
    #expect(try files.read("notes.txt").digest == second)

    // The same confinement as read and write.
    for path in ["../outside.txt", "/etc/passwd", "link", ".git/config", "missing.txt"] {
        #expect(throws: FawalyError.self) { _ = try files.edit(path, edits: [.init(old: "private", new: "leaked")], expectedDigest: second) }
    }
    #expect(try String(contentsOf: outside) == "private outside")

    // A change made elsewhere after the last read is never overwritten.
    try Data("changed elsewhere".utf8).write(to: project.appendingPathComponent("notes.txt"))
    #expect(throws: FawalyError.self) { _ = try files.edit("notes.txt", edits: [.init(old: "changed", new: "lost")], expectedDigest: second) }
    #expect(try String(contentsOf: project.appendingPathComponent("notes.txt")) == "changed elsewhere")
    #expect(try files.list() == ["notes.txt"])
}

@Test func apiWorkerEditsPartOfALargeFileAndSendsTheConfiguredReplyLimit() async throws {
    for format in APIAssistant.Format.allCases {
        let root = try apiRoot(), project = root.appendingPathComponent("project")
        defer { try? FileManager.default.removeItem(at: root) }
        try Paths.ensurePrivateDirectory(project)
        // About 60 KB: far more than one reply could resend as a whole file.
        let unchanged = String(repeating: "unchanged line\n", count: 4000)
        let digest = try APIWorkspace(project).write("big.txt", content: unchanged + "old ending\n", expectedDigest: "")
        let edits = [["old_text": "old ending", "new_text": "new ending"]]
        let call: [String: Any], done: [String: Any]
        if format == .openAI {
            let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["path": "big.txt", "expected_sha256": digest, "edits": edits]), as: UTF8.self)
            call = ["choices": [["message": ["role": "assistant", "content": NSNull(), "tool_calls": [["id": "call-1", "type": "function", "function": ["name": "edit_file", "arguments": arguments]]]]]]]
            done = ["choices": [["message": ["role": "assistant", "content": "Changed the ending."]]]]
        } else {
            // Some models send the array as JSON text; it is accepted.
            let text = String(decoding: try JSONSerialization.data(withJSONObject: edits), as: UTF8.self)
            call = ["content": [["type": "tool_use", "id": "call-1", "name": "edit_file", "input": ["path": "big.txt", "expected_sha256": digest, "edits": text]]]]
            done = ["content": [["type": "text", "text": "Changed the ending."]]]
        }
        let fixture = APIFixture([call, done])
        var worker = APIWorker(root: root)
        worker.credential = { _ in "fixture-service-key" }
        worker.transport = { try await fixture.send($0) }
        var profile = apiProfile(format: format)
        profile.maxOutputTokens = 8192
        #expect(try await worker.run(profile, prompt: "Change the ending", workspace: project, timeout: 10) == "Changed the ending.")
        let result = try APIWorkspace(project).read("big.txt")
        #expect(result.text == unchanged + "new ending\n")
        let requests = await fixture.requests
        let body = try #require(JSONSerialization.jsonObject(with: requests[0].httpBody!) as? [String: Any])
        #expect(body["max_tokens"] as? Int == 8192)
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.contains { ($0["name"] as? String ?? ($0["function"] as? [String: Any])?["name"] as? String) == "edit_file" })
        // The worker is told the new digest, so a further edit needs no re-read.
        #expect(String(decoding: requests[1].httpBody!, as: UTF8.self).contains("New SHA-256: " + result.digest))
    }
}

@Test func replyLimitIsOptionalBoundedAndDefaultsToTheOldValue() async throws {
    var profile = apiProfile()
    try profile.validate()
    let stored = try JSONEncoder().encode(profile)
    #expect(!String(decoding: stored, as: UTF8.self).contains("maxOutputTokens"))
    #expect(try JSONDecoder().decode(APIAssistant.self, from: stored).maxOutputTokens == nil)
    for value in [-1, 0, 1023, 65537] {
        profile.maxOutputTokens = value
        #expect(throws: FawalyError.self) { try profile.validate() }
    }
    profile.maxOutputTokens = 65536
    try profile.validate()
    #expect(try JSONDecoder().decode(APIAssistant.self, from: JSONEncoder().encode(profile)).maxOutputTokens == 65536)

    let root = try apiRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = APIFixture([["choices": [["message": ["role": "assistant", "content": "ready"]]]]])
    var worker = APIWorker(root: root)
    worker.credential = { _ in "fixture-service-key" }
    worker.transport = { try await fixture.send($0) }
    _ = try await worker.run(apiProfile(), prompt: "fixture", workspace: nil, timeout: 5)
    let requests = await fixture.requests
    let body = try #require(JSONSerialization.jsonObject(with: requests[0].httpBody!) as? [String: Any])
    #expect(body["max_tokens"] as? Int == 4096)
}
