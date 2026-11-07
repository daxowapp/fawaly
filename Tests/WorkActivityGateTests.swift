import Foundation
import Testing
import Darwin
@testable import FawalyApp

@Test func updateLeaseExcludesExternalWorkersAndReleasesOnDismiss() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = EngineConfiguration(root: root)
    let worker = try engine.lockWorkerAccess()
    #expect(throws: FawalyError.self) { _ = try WorkActivityLease(root: root) }
    close(worker)
    var update: WorkActivityLease? = try WorkActivityLease(root: root)
    #expect(update != nil)
    #expect(throws: FawalyError.self) { _ = try engine.lockWorkerAccess() }
    update = nil
    let retry = try engine.lockWorkerAccess()
    close(retry)
}

@Test func updateLeaseProtectsComparisonBetweenWorkerRuns() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = ComparisonSession(id: UUID(), project: "/fixture", commit: "fixture", brief: "fixture", runs: [.init(agent: .kimi)])
    let store = ComparisonStore(root: root)
    try store.save(session)
    let owner = open(root.appendingPathComponent("comparisons/" + session.id.uuidString + "/owner.lock").path, O_CREAT | O_RDWR, 0o600)
    #expect(owner >= 0)
    #expect(flock(owner, LOCK_EX | LOCK_NB) == 0)
    #expect(throws: FawalyError.self) { _ = try WorkActivityLease(root: root) }
    close(owner)
    let update = try WorkActivityLease(root: root)
    #expect(try store.recent().first?.runs.first?.status == "cancelled")
    withExtendedLifetime(update) {}
}
