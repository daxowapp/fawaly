import Foundation
import SQLite3
import Testing
@testable import FawalyApp

private func isolatedRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("fawaly-rebuilt-test-" + UUID().uuidString, isDirectory: true)
}

@Test @MainActor func previewTaskCompletesAndSurvivesReload() async throws {
    let root = isolatedRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(root: root)
    #expect(model.loaded)
    try model.addTask(title: "Check launch", details: "Use a clean state.")
    let item = try #require(model.state.work.first)
    try await model.runTask(item.id, provider: AppModel.preview)

    let restored = AppModel(root: root)
    let completed = try #require(restored.state.work.first)
    #expect(completed.id == item.id)
    #expect(completed.completed != nil)
    #expect(completed.result?.contains("Check launch") == true)
}

@Test @MainActor func previewConsultationRecordsRoundsAndDecision() async throws {
    let root = isolatedRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(root: root)
    try await model.consult(provider: AppModel.preview, by: .human, reason: .userRequest,
                            question: "Review the plan", context: "Private fixture")
    let first = try #require(model.consults.first)
    #expect(first.contextBytes == "Private fixture".utf8.count)
    #expect(first.contextSHA256 != nil)
    #expect(first.rounds.count == 1)

    try await model.consult(provider: AppModel.preview, by: .human, reason: .userRequest,
                            question: "What should I verify?", context: "", continuing: first.id)
    try model.decide(first.id, decision: .adopted, summary: "Start with a launch check.")

    let restored = AppModel(root: root)
    let finished = try #require(restored.consults.first)
    #expect(finished.rounds.map(\.index) == [1, 2])
    #expect(finished.status == .closed)
    #expect(finished.decision == .adopted)
}

@Test @MainActor func disabledAdvisorAndRoundLimitAreEnforced() async throws {
    let root = isolatedRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(root: root)
    try await model.updateAdvisors { $0.mode = .off }
    await #expect(throws: FawalyError.self) {
        try await model.consult(provider: AppModel.preview, by: .human, reason: .userRequest,
                                question: "Check", context: "")
    }
    try await model.updateAdvisors { $0.mode = .onRequest; $0.maxRounds = 1 }
    try await model.consult(provider: AppModel.preview, by: .human, reason: .userRequest,
                            question: "First", context: "")
    let first = try #require(model.consults.first)
    await #expect(throws: FawalyError.self) {
        try await model.consult(provider: AppModel.preview, by: .human, reason: .userRequest,
                                question: "Second", context: "", continuing: first.id)
    }
}

@Test func endpointValidationAndPayload() throws {
    #expect(throws: FawalyError.self) {
        try EndpointSettings(endpoint: "http://example.test/chat/completions", model: "fixture")
    }
    #expect(throws: FawalyError.self) {
        try EndpointSettings(endpoint: "https://user@example.test/chat/completions", model: "fixture")
    }
    let endpoint = try EndpointSettings(endpoint: "https://example.test/v1/chat/completions", model: "fixture")
    let request = try TextAdvisor.request(endpoint: endpoint, key: "fixture",
                                         messages: [.init(role: "user", content: "Check the queue")], timeout: 2)
    #expect(request.url == endpoint.url)
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
    let payload = try #require(request.httpBody)
    #expect(String(decoding: payload, as: UTF8.self).contains("Check the queue"))
}

@Test @MainActor func unreadableHistoryRowsAreSkippedAndTheWorkshopStaysEditable() async throws {
    let root = isolatedRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let newer = TeamJob(primary: .claude, worker: .kimi, title: "Newer", started: Date(timeIntervalSince1970: 2_000))
    try TeamJobLog(root: root).save(TeamJob(primary: .claude, worker: .codex, title: "Older", started: Date(timeIntervalSince1970: 1_000)))
    try TeamJobLog(root: root).save(newer)
    try ConsultLog(root: root).insert(ConsultRecord(caller: .human, reason: .userRequest, provider: AppModel.preview, model: "checklist",
                                                    modeAtStart: .important, question: "Kept", context: nil, rounds: [], created: Date()))
    // Rows a damaged file or a newer version could leave behind, sorted first.
    try WorkLog(root: root).database { handle in
        let rows = """
        INSERT INTO team_jobs(id, started, payload) VALUES ('unreadable', 9000000000, x'7b22');
        INSERT INTO consults(id, created, status, record) VALUES ('unreadable', 9000000000, 'open', '{"future":true}');
        """
        guard sqlite3_exec(handle, rows, nil, nil, nil) == SQLITE_OK else { throw FawalyError.invalid("The fixture rows were not inserted.") }
    }
    let history = try TeamJobLog(root: root).load(limit: nil)
    #expect(history.jobs.map(\.title) == ["Newer", "Older"] && history.unreadable == 1)
    // The limit counts readable entries, not rows.
    #expect(try TeamJobLog(root: root).recent(limit: 1).map(\.title) == ["Newer"])
    #expect(try ConsultLog(root: root).recent(limit: 1).map(\.question) == ["Kept"])

    let model = AppModel(root: root)
    #expect(model.loaded && model.teamJobs.count == 2 && model.consults.count == 1)
    #expect(model.problem?.contains("2") == true)
    model.setArabic(true)
    #expect(AppModel(root: root).state.arabic)

    // The window's periodic check reads again only after the work log changes.
    await model.refreshTeamActivity(force: true)
    await model.refreshTeamActivity()
    #expect(model.teamJobs.map(\.status) == ["running", "running"])
    var finished = newer
    finished.status = "completed"; finished.finished = Date()
    try TeamJobLog(root: root).save(finished)
    await model.refreshTeamActivity()
    #expect(model.teamJobs.map(\.status) == ["completed", "running"])
    #expect(model.consults.map(\.question) == ["Kept"])
}

@Test func activityIsReadAgainOnlyWhenTheWorkLogChanges() throws {
    let root = isolatedRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try TeamJobLog(root: root).save(TeamJob(primary: .claude, worker: .codex, title: "First"))
    // The first read creates the consultation table, which changes the file.
    _ = TeamActivitySnapshot.read(root: root, known: nil)
    let settled = TeamActivitySnapshot.read(root: root, known: nil)
    let signature = try #require(settled.logs?.signature)
    #expect(settled.logs?.jobs.count == 1 && settled.failure == nil)
    #expect(TeamActivitySnapshot.read(root: root, known: signature).logs == nil)
    try TeamJobLog(root: root).save(TeamJob(primary: .claude, worker: .kimi, title: "Second"))
    let changed = TeamActivitySnapshot.read(root: root, known: signature)
    #expect(changed.logs?.jobs.count == 2 && changed.logs?.signature != signature)
}
