import Foundation
import Testing
@testable import FawalyApp

private func comparisonGit(_ args: [String], at directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "user.name=Fixture", "-c", "user.email=fixture@localhost", "-C", directory.path] + args
    process.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

@Test func comparisonsUseIndependentCommittedCopiesAndKeepWorkingFilesUntouched() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fawaly-comparison-test-" + UUID().uuidString)
    let project = folder.appendingPathComponent("project"), state = folder.appendingPathComponent("state")
    try Paths.ensurePrivateDirectory(project)
    defer { try? FileManager.default.removeItem(at: folder) }
    try "committed".write(to: project.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
    try comparisonGit(["init", "--quiet"], at: project)
    try comparisonGit(["add", "."], at: project)
    try comparisonGit(["commit", "--quiet", "-m", "fixture"], at: project)
    try "uncommitted".write(to: project.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
    try "private untracked".write(to: project.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
    let runner = ComparisonRunner(configuration: .init(root: state), execute: { agent, _, snapshot in
        #expect(try String(contentsOf: snapshot.appendingPathComponent("base.txt"), encoding: .utf8) == "committed")
        #expect(!FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("untracked.txt").path))
        try agent.rawValue.write(to: snapshot.appendingPathComponent("worker.txt"), atomically: true, encoding: .utf8)
        return "Fixture complete"
    })
    let result = try await runner.run(project: project, agents: [.claude, .kimi], brief: "Write worker.txt in your snapshot") { _ in
        // UI reloads must not mistake this live same-process session for a crash.
        try? ComparisonStore(root: state).recoverInterrupted()
    }
    #expect(result.runs.allSatisfy { $0.succeeded == true })
    #expect(result.runs.allSatisfy { $0.changedFiles == ["worker.txt"] })
    #expect(try String(contentsOf: project.appendingPathComponent("base.txt"), encoding: .utf8) == "uncommitted")
    #expect(try String(contentsOf: project.appendingPathComponent("untracked.txt"), encoding: .utf8) == "private untracked")
    #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("worker.txt").path))
    #expect(try String(contentsOf: result.snapshot(root: state, agent: .kimi).appendingPathComponent("worker.txt"), encoding: .utf8) == "kimi")
    #expect(try String(contentsOf: result.snapshot(root: state, agent: .claude).appendingPathComponent("worker.txt"), encoding: .utf8) == "claude")
    let store = ComparisonStore(root: state)
    #expect(throws: FawalyError.self) { try store.chooseWinner(id: result.id, agent: .kimi, note: "") }
    try store.chooseWinner(id: result.id, agent: .kimi, note: "Independently inspected both fixture files")
    #expect(try store.recent().first?.winner == .kimi)
    #expect(try store.recent().first?.runs.allSatisfy { $0.status == "needs_review" } == true)
    #expect(throws: FawalyError.self) { try AgentWorker(configuration: .init(root: state)).validateManagedSnapshot(state.appendingPathComponent("official/kimi"), agent: .kimi) }
}

@Test func comparisonSandboxProtectsBaselineGitMetadata() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fawaly-comparison-git-" + UUID().uuidString)
    let snapshot = folder.appendingPathComponent("snapshot"), command = folder.appendingPathComponent("command")
    try Paths.ensurePrivateDirectory(snapshot.appendingPathComponent(".git")); try Paths.ensurePrivateDirectory(command)
    defer { try? FileManager.default.removeItem(at: folder) }
    let config = snapshot.appendingPathComponent(".git/config")
    try Data("baseline".utf8).write(to: config)
    let invocation = AgentWorker.Invocation(program: URL(fileURLWithPath: "/bin/sh"), arguments: [], environment: [:])
    let policy = command.appendingPathComponent("sandbox.sb")
    try AgentWorker.sandboxProfile(invocation: invocation, directory: command, workspace: snapshot, codexHome: nil, protectGitMetadata: true).write(to: policy, atomically: true, encoding: .utf8)
    let script = "if printf changed > \"$1/.git/config\"; then exit 3; fi; printf OK > \"$1/allowed.txt\"; cat \"$1/allowed.txt\""
    let output = try await WorkerProcess.run(program: "/usr/bin/sandbox-exec", arguments: ["-f", policy.path, "/bin/sh", "-c", script, "fixture", snapshot.path], environment: ["PATH": "/usr/bin:/bin"], directory: command, workingDirectory: command, prompt: "", timeout: 5)
    #expect(String(decoding: output, as: UTF8.self) == "OK")
    #expect(try String(contentsOf: config, encoding: .utf8) == "baseline")
}

@Test func interruptedComparisonsBecomeReviewableAndCannotChooseAFailedWinner() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fawaly-comparison-interrupt-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var session = ComparisonSession(id: UUID(), project: "/fixture", commit: "fixture", brief: "Fixture", runs: [.init(agent: .kimi), .init(agent: .claude)])
    session.runs[0].status = "running"
    let store = ComparisonStore(root: root)
    try store.save(session)
    try store.recoverInterrupted()
    let recovered = try #require(store.recent().first)
    #expect(recovered.runs[0].status == "needs_review")
    #expect(recovered.runs[1].status == "cancelled")
    #expect(throws: FawalyError.self) { try store.chooseWinner(id: session.id, agent: .kimi, note: "Fixture") }
}

@Test func recoveryRereadsAfterTakingOwnershipAndPreservesJustFinishedResults() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fawaly-recovery-race-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var session = ComparisonSession(id: UUID(), project: "/fixture", commit: "fixture", brief: "Fixture", runs: [.init(agent: .kimi)])
    session.runs[0].status = "running"
    let store = ComparisonStore(root: root)
    try store.save(session)
    try store.recoverInterrupted { _ in
        session.runs[0].status = "needs_review"
        session.runs[0].succeeded = true
        session.runs[0].answer = "Completed successfully"
        try store.save(session)
    }
    let saved = try #require(store.recent().first)
    #expect(saved.runs[0].succeeded == true)
    #expect(saved.runs[0].answer == "Completed successfully")
}

@Test func cancelledComparisonStillInventoriesItsPartialChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fawaly-cancel-inventory-" + UUID().uuidString)
    let project = root.appendingPathComponent("project"), state = root.appendingPathComponent("state")
    try Paths.ensurePrivateDirectory(project)
    defer { try? FileManager.default.removeItem(at: root) }
    try "baseline".write(to: project.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
    try comparisonGit(["init", "--quiet"], at: project)
    try comparisonGit(["add", "."], at: project)
    try comparisonGit(["commit", "--quiet", "-m", "fixture"], at: project)
    let runner = ComparisonRunner(configuration: .init(root: state), execute: { _, _, snapshot in
        try "partial".write(to: snapshot.appendingPathComponent("partial.txt"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .seconds(20))
        return "Unexpected completion"
    })
    let task = Task { try await runner.run(project: project, agents: [.kimi, .claude], brief: "Cancellation fixture") { _ in } }
    defer { task.cancel() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    var wrote = false
    while ContinuousClock.now < deadline {
        if let session = try ComparisonStore(root: state).recent().first {
            wrote = FileManager.default.fileExists(atPath: session.snapshot(root: state, agent: .kimi).appendingPathComponent("partial.txt").path)
            if wrote { break }
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(wrote)
    task.cancel()
    let result = try await task.value
    #expect(result.runs[0].changedFiles == ["partial.txt"])
    #expect(result.runs[1].status == "cancelled")
    #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("partial.txt").path))
}
