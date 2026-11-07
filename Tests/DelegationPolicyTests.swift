import Foundation
import Testing
@testable import FawalyApp

@Test @MainActor func savedPolicyDrivesEngineWithoutChangingRolesOrOtherSettings() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("policy-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var state = WorkshopState()
    state.team = TeamSettings(primary: .codex, advisor: nil, workers: [.claude, .kimi])
    state.arabic = false
    state.onboardingVersion = 2
    state.work = [WorkItem(title: "Keep", details: "Existing task")]
    try WorkshopStore(root: root).save(state)
    let model = AppModel(root: root)
    var advisors = state.advisors
    advisors.mode = .important
    advisors.maxRounds = 4
    advisors.timeoutMinutes = 3
    var policy = DelegationPolicy()
    policy.timeoutSeconds = 321
    policy.orders["code"] = [.kimi, .claude]
    try model.saveDelegationPolicy(policy, advisors: advisors)
    let persisted = try WorkshopStore(root: root).load()
    #expect(persisted.delegationPolicy == policy)
    #expect(persisted.team == state.team)
    #expect(persisted.work == state.work)
    #expect(persisted.arabic == false)
    #expect(persisted.onboardingVersion == 2)
    #expect(persisted.advisors.maxRounds == 4)
    let bridge = EngineBridge(configuration: .init(root: root), client: .codex,
        worker: { agent, _, _, timeout in "\(agent.rawValue):\(timeout)" }, ready: { _ in true })
    let ordered = try await bridge.delegate(brief: "Code", cwd: nil, provider: nil, timeout: nil, kind: "code")
    #expect(ordered.finalMessage == "kimi:321")
    let general = try await bridge.delegate(brief: "General", cwd: nil, provider: nil, timeout: 10)
    #expect(general.finalMessage == "claude:10")
    let unavailable = EngineBridge(configuration: .init(root: root), client: .codex,
        worker: { agent, _, _, _ in agent.rawValue }, ready: { $0 != .kimi })
    #expect(try await unavailable.delegate(brief: "Fallback", cwd: nil, provider: nil, timeout: nil, kind: "code").provider == "claude-official")
}

@Test func oldStateHasDefaultPolicyAndInvalidPolicyCannotPersist() throws {
    let original = WorkshopState()
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    object.removeValue(forKey: "delegationPolicy")
    let decoded = try JSONDecoder().decode(WorkshopState.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.delegationPolicy == nil)
    var policy = DelegationPolicy()
    let team = TeamSettings(primary: .codex, advisor: .claude, workers: [.kimi])
    policy.orders["code"] = [.codex]
    #expect(throws: FawalyError.self) { try policy.validate(team: team) }
    policy.orders["code"] = [.kimi, .kimi]
    #expect(throws: FawalyError.self) { try policy.validate(team: team) }
    policy.orders = [:]
    policy.timeoutSeconds = 0
    #expect(throws: FawalyError.self) { try policy.validate(team: team) }
}

@Test @MainActor func ledgerLoadsOlderJobsBeyondTheRecentActivityWindow() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-history-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let log = TeamJobLog(root: root)
    for index in 0..<55 {
        var job = TeamJob(primary: .codex, worker: .kimi, title: "History \(index)")
        job.started = Date(timeIntervalSince1970: Double(index))
        job.finished = job.started
        job.status = "completed"
        job.result = index == 0 ? "Old searchable evidence" : "Recent result"
        try log.save(job)
    }
    #expect(try log.recent().count == 50)
    let model = AppModel(root: root)
    #expect(model.teamJobs.count == 55)
    let found = TasksLedgerQuery.filtered(work: [], jobs: model.teamJobs, filter: .all, search: "old searchable")
    #expect(found.map(\.title) == ["History 0"])
}
