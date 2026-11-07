import Foundation
import Testing
@testable import FawalyApp

private func teamRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fawaly-team-test-" + UUID().uuidString)
    try Paths.ensurePrivateDirectory(root)
    return root
}

@Test func workerReviewRequiresItsPrimaryAndIndependentEvidenceAndPersistsHistory() throws {
    let root = try teamRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var state = WorkshopState()
    state.team = TeamSettings(primary: .codex, advisor: .claude, workers: [.kimi])
    try WorkshopStore(root: root).save(state)
    let log = TeamJobLog(root: root)
    var job = TeamJob(primary: .codex, worker: .kimi, title: "Real review fixture")
    job.finished = Date()
    job.status = "needs_handoff"
    job.reviewRequired = true
    try log.save(job)
    let bridge = EngineBridge(configuration: .init(root: root), client: .codex)
    #expect(throws: FawalyError.self) {
        try bridge.review(id: job.id, decision: .accepted, summary: "Claims passed", verification: "", score: 5)
    }
    let wrong = EngineBridge(configuration: .init(root: root), client: .claude)
    #expect(throws: FawalyError.self) {
        try wrong.review(id: job.id, decision: .accepted, summary: "Wrong primary", verification: "Fixture", score: nil)
    }
    let failed = try bridge.review(id: job.id, decision: .changesRequested, summary: "Found a defect", verification: "Fixture check failed", score: 2)
    #expect(failed.reviewRequired)
    let accepted = try bridge.review(id: job.id, decision: .accepted, summary: "Corrected", verification: "Independently checked the diff and reran the fixture check", score: 4)
    #expect(accepted.status == "reviewed")
    #expect(!accepted.reviewRequired)
    #expect(accepted.reviews?.count == 2)
    #expect(accepted.latestReview?.primary == .codex)
    _ = try bridge.review(id: job.id, decision: .accepted, summary: "Corrected", verification: "Independently checked the diff and reran the fixture check", score: 4)
    #expect(try log.recent().first?.reviews?.count == 2)
    #expect(try log.recent().first?.started == job.started)
}

@Test func unfinishedWorkersCannotBeReviewedAndOldRecordsStillDecode() throws {
    let root = try teamRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let log = TeamJobLog(root: root)
    let job = TeamJob(primary: .codex, worker: .kimi, title: "In progress")
    try log.save(job)
    #expect(throws: FawalyError.self) {
        try log.recordReview(id: job.id, review: TeamReview(decision: .accepted, primary: .codex, summary: "Too soon", verification: "Fixture", score: nil))
    }
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
    object.removeValue(forKey: "reviews")
    let old = try JSONDecoder().decode(TeamJob.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(old.latestReview == nil)
}

@Test func teamRoutesAdviceAndDelegationToTheirAssignedRoles() async throws {
    let root = try teamRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var state = WorkshopState()
    state.team = TeamSettings()
    try WorkshopStore(root: root).save(state)
    let bridge = EngineBridge(configuration: .init(root: root), client: .codex, worker: { agent, _, _, _ in agent.rawValue }, ready: { _ in true })
    let consultation = try await bridge.consult(question: "Fixture review", context: "", reason: .userRequest, provider: nil)
    #expect(consultation.provider == EngineAgent.claude.providerID)
    await #expect(throws: FawalyError.self) { try await bridge.delegate(brief: "fixture", cwd: nil, provider: nil, timeout: 1) }
    state.team?.advisor = nil
    state.team?.workers = [.claude]
    try WorkshopStore(root: root).save(state)
    let result = try await bridge.delegate(brief: "Fixture worker task", cwd: nil, provider: nil, timeout: 1)
    #expect(result.provider == EngineAgent.claude.providerID)
    let records = try TeamJobLog(root: root).recent()
    #expect(records.count == 1)
    #expect(records[0].status == "completed")
    #expect(records[0].id == result.jobId)
    #expect(records[0].result == "claude")
    #expect(records[0].finished != nil)
    await #expect(throws: FawalyError.self) { try await bridge.consult(question: "Fixture", context: "", reason: .userRequest, provider: nil) }
}

@Test func primaryRoleIsNotReplacedByAWorkerOrAdvisor() async throws {
    let root = try teamRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var state = WorkshopState()
    state.team = TeamSettings()
    try WorkshopStore(root: root).save(state)
    let wrongClient = EngineBridge(configuration: .init(root: root), client: .claude, worker: { _, _, _, _ in "Unexpected" }, ready: { _ in true })
    await #expect(throws: FawalyError.self) { try await wrongClient.consult(question: "Fixture", context: "", reason: .userRequest, provider: nil) }
    var invalid = TeamSettings()
    invalid.workers = [.codex]
    #expect(throws: FawalyError.self) { try invalid.validate() }
    invalid.workers = [.claude]
    #expect(throws: FawalyError.self) { try invalid.validate() }
    invalid.choosePrimary(.claude)
    #expect(invalid.primary == .claude)
    #expect(invalid.advisor == .codex)
    #expect(invalid.workers.isEmpty)
}

@Test func failedWorkerLeavesAnActivityRecordAndPreservesStartTime() async throws {
    let root = try teamRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let bridge = EngineBridge(configuration: .init(root: root), client: .codex, worker: { _, _, _, _ in throw FawalyError.invalid("Fixture unavailable") }, ready: { _ in true })
    await #expect(throws: FawalyError.self) { try await bridge.delegate(brief: "Fixture", cwd: nil, provider: nil, timeout: 1) }
    let record = try #require(TeamJobLog(root: root).recent().first)
    #expect(record.status == "failed")
    #expect(record.result == "Fixture unavailable")
    let reloaded = try #require(TeamJobLog(root: root).recent().first)
    #expect(reloaded.started == record.started)
}

@Test @MainActor func projectAccessCanBeGrantedAndRevokedWithoutACommand() throws {
    let root = try teamRoot()
    let project = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".fawaly-project-test-" + UUID().uuidString)
    try Paths.ensurePrivateDirectory(project)
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: project) }
    let model = AppModel(root: root)
    try model.allowProject(project)
    #expect(try EngineConfiguration(root: root).approvedWorkspace(project.path).path == project.path)
    #expect(model.state.projectDirectory?.path == project.path)
    try model.removeProject()
    #expect(model.state.projectDirectory == nil)
    #expect(throws: FawalyError.self) { try EngineConfiguration(root: root).approvedWorkspace(project.path) }
}

@Test func nativeClientIntegrationPreservesOtherSettingsAndChecksTheEngine() async throws {
    let root = try teamRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try #require(Bundle.main.executableURL)
    for agent in EngineAgent.primaryAgents where agent.executable(root: root) != nil {
        let home = root.appendingPathComponent(agent.rawValue + "-home")
        try Paths.ensurePrivateDirectory(home.appendingPathComponent(".codex"))
        if agent == .codex {
            try Data("model = \"fixture-model\"\n".utf8).write(to: home.appendingPathComponent(".codex/config.toml"))
        } else {
            try JSONSerialization.data(withJSONObject: ["numStartups": 7, "mcpServers": ["fixture_server": ["command": "/usr/bin/true", "args": []]]])
                .write(to: home.appendingPathComponent(".claude.json"))
        }
        let link = ClientLink(root: root, application: app, home: home)
        try await link.connect(agent)
        try await link.connect(agent)
        if agent == .codex {
            let config = try String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
            #expect(config.contains("fixture-model"))
            #expect(config.contains(ClientLink.serverName))
            #expect(config.contains("tool_timeout_sec = 3610"))
        } else {
            let settings = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(".claude.json"))) as? [String: Any])
            #expect(settings["numStartups"] as? Int == 7)
            #expect((settings["mcpServers"] as? [String: Any])?["fixture_server"] != nil)
        }
    }
}
