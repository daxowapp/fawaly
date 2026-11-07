import Foundation
import Testing
@testable import FawalyApp

@Test @MainActor func remotePreferencesNeedApprovalAndNeverEchoOrOverwriteOnArrival() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-controller-" + UUID().uuidString)
    let folder = root.appendingPathComponent("shared")
    defer { try? FileManager.default.removeItem(at: root) }
    try Paths.ensurePrivateDirectory(folder)
    let first = PreferencesSyncController(root: root.appendingPathComponent("mac-a"))
    let second = PreferencesSyncController(root: root.appendingPathComponent("mac-b"))
    try first.choose(folder); try second.choose(folder)
    var a = WorkshopState(), b = WorkshopState()
    a.arabic = false; b.arabic = true
    await first.poll(state: a, idle: true)
    let published = try #require(try PreferencesSyncStore(folder: folder).read())
    await second.poll(state: b, idle: true)
    #expect(second.pending?.id == published.id)
    #expect(second.pending?.preferences.arabic == false)
    #expect(try PreferencesSyncStore(folder: folder).read()?.id == published.id)
    b.arabic = false
    try second.acknowledgeApplied(state: b)
    await second.poll(state: b, idle: true)
    #expect(second.pending == nil)
    #expect(try PreferencesSyncStore(folder: folder).read()?.id == published.id)
    b.arabic = true
    await second.poll(state: b, idle: false)
    #expect(try PreferencesSyncStore(folder: folder).read()?.id == published.id)
    await second.poll(state: b, idle: true)
    let new = try #require(try PreferencesSyncStore(folder: folder).read())
    #expect(new.id != published.id)
    await first.poll(state: a, idle: true)
    #expect(first.pending?.id == new.id)
    try first.dismissRemote()
    #expect(first.folder == nil)
    #expect(try PreferencesSyncStore(folder: folder).read()?.id == new.id)
}

@Test func coordinatedSyncRejectsStaleRevisionWithoutReplacingNewerPreferences() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Paths.ensurePrivateDirectory(folder)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = PreferencesSyncStore(folder: folder), backup = PreferencesBackup(state: WorkshopState())
    let first = try store.publish(backup, deviceID: UUID(), replacing: nil)
    let second = try store.publish(backup, deviceID: UUID(), replacing: first.id)
    #expect(throws: FawalyError.self) { try store.publish(backup, deviceID: UUID(), replacing: first.id) }
    #expect(try store.read()?.id == second.id)
    #expect(throws: FawalyError.self) { try store.publish(backup, deviceID: UUID(), replacing: nil) }
}
