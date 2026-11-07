import Darwin
import Foundation
import Testing
@testable import FawalyApp

@Test func advisorAndWorkerCanRunTogetherButNeverWriteTheSameProjectTogether() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fawaly-concurrency-" + UUID().uuidString)
    let project = root.appendingPathComponent("project"), otherProject = root.appendingPathComponent("other-project")
    try Paths.ensurePrivateDirectory(project); try Paths.ensurePrivateDirectory(otherProject)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = EngineConfiguration(root: root)
    let access1 = try config.lockWorkerAccess(), access2 = try config.lockWorkerAccess()
    defer { close(access1); close(access2) }
    let worker = try config.lockWorker(.kimi, workspace: project)
    defer { worker.forEach { close($0) } }
    #expect(config.isWorking(.kimi))
    #expect(!config.isWorking(.claude))
    let advisor = try config.lockWorker(.claude, workspace: nil)
    advisor.forEach { close($0) }
    #expect(throws: FawalyError.self) { try config.lockWorker(.claude, workspace: project) }
    #expect(!config.isWorking(.claude)) // A rejected project lock releases the agent lock.
    let independent = try config.lockWorker(.claude, workspace: otherProject)
    independent.forEach { close($0) }
    #expect(throws: FawalyError.self) { try config.lockWorker(.kimi, workspace: nil) }
    #expect(throws: FawalyError.self) { try config.lockJob() }
}

@Test func configurationChangesExcludeNewWorkers() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fawaly-admin-lock-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = EngineConfiguration(root: root)
    let access = try config.lockJob()
    defer { close(access) }
    #expect(throws: FawalyError.self) { try config.lockWorkerAccess() }
}

@Test func aBusyAssignedWorkerDoesNotAskTheUserToReconnectTheirTeam() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fawaly-busy-roster-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = EngineConfiguration(root: root)
    var state = WorkshopState(); state.team = TeamSettings(primary: .codex, advisor: .claude, workers: [.kimi])
    try WorkshopStore(root: root).save(state)
    let held = try config.lockWorker(.kimi, workspace: nil)
    defer { held.forEach { close($0) } }
    let bridge = EngineBridge(configuration: config, client: .codex, worker: { _, _, _, _ in "Unexpected" }, ready: { _ in true })
    do {
        _ = try await bridge.delegate(brief: "Busy fixture", cwd: nil, provider: nil, timeout: 1)
        Issue.record("A busy worker was selected")
    } catch {
        #expect(error.localizedDescription.contains("busy"))
        #expect(!error.localizedDescription.contains("setup"))
    }
}
