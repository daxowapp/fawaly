import Foundation
import Testing
@testable import FawalyApp

@Test func workerModelsArePinnedForAConsultationAndDoNotChangePrimaryModels() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fawaly-model-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var state = WorkshopState()
    state.team = TeamSettings(primary: .codex, advisor: .claude, workers: [.kimi])
    state.advisors.mode = .important
    state.workerModels = ["claude": "sonnet", "kimi": "kimi-code/k3"]
    try WorkshopStore(root: root).save(state)
    let bridge = EngineBridge(configuration: .init(root: root), client: .codex, worker: { _, _, _, _ in WorkerContext.modelPreference?.model ?? "provider-default" }, ready: { _ in true })
    let first = try await bridge.consult(question: "First fixture", context: "", reason: .plan, provider: nil)
    #expect(first.rounds.last?.advice == "sonnet")
    #expect(first.model == "sonnet")
    state.workerModels?["claude"] = "opus"
    try WorkshopStore(root: root).save(state)
    let followup = try await bridge.consult(question: "Follow-up", context: "", reason: .plan, provider: nil, continuing: first.id)
    #expect(followup.rounds.last?.advice == "sonnet")
    #expect(followup.model == "sonnet")
    let worker = try await bridge.delegate(brief: "A bounded fixture assignment", cwd: nil, provider: nil, timeout: 5, title: "اختبار اختيار الموديل")
    #expect(worker.finalMessage == "kimi-code/k3")
    #expect(worker.model == "kimi-code/k3")
    #expect(try TeamJobLog(root: root).recent().first?.title == "اختبار اختيار الموديل")
    #expect(try WorkshopStore(root: root).load().team?.primary == .codex)
}

@Test func modelArgumentsCannotBecomeCLIOptionsAndListsExcludeCredentialMetadata() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fawaly-model-invocation-" + UUID().uuidString)
    #expect(throws: FawalyError.self) {
        try AgentWorker.invocation(.codex, executable: URL(fileURLWithPath: "/usr/bin/true"), directory: root, workspace: nil, codexHome: root, token: nil, model: "--help")
    }
    let invocation = try AgentWorker.invocation(.codex, executable: URL(fileURLWithPath: "/usr/bin/true"), directory: root, workspace: nil, codexHome: root, token: nil, model: "fixture-model")
    #expect(invocation.arguments.suffix(3) == ["--model", "fixture-model", "-"])
    let response = Data(#"{"providers":{"fixture":{"oauth":{"key":"CREDENTIAL_STORAGE_NAME"}}},"models":{"kimi-code/k3":{},"invalid option --help":{}}}"#.utf8)
    #expect(NativeModelCatalog.kimiModels(response) == ["kimi-code/k3"])
}

@Test func mcpAcceptsReadableTaskTitlesInTheSavedWorkshopLanguage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fawaly-title-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var state = WorkshopState(); state.team = TeamSettings(primary: .codex, advisor: .claude, workers: [.kimi])
    try WorkshopStore(root: root).save(state)
    let server = EngineMCP(bridge: EngineBridge(configuration: .init(root: root), client: .codex, worker: { _, _, _, _ in "Fixture result" }, ready: { _ in true }))
    var initialized = true
    let call = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"delegate","arguments":{"brief":"Technical detailed task specification","title":"استرجاع دفتر المهام"}}}"#.utf8)
    let result = await server.handle(call, initialized: &initialized)
    #expect((result?["result"] as? [String: Any])?["isError"] as? Bool == false)
    #expect(try TeamJobLog(root: root).recent().first?.title == "استرجاع دفتر المهام")
}
