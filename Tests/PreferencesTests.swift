import Foundation
import Testing
@testable import FawalyApp

@Test @MainActor func preferenceBackupRoundTripsWithoutAccountsProjectsOrHistory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fawaly-backup-test-" + UUID().uuidString)
    try Paths.ensurePrivateDirectory(root)
    defer { try? FileManager.default.removeItem(at: root) }
    var state = WorkshopState()
    state.team = TeamSettings(primary: .codex, advisor: .claude, workers: [.kimi])
    state.arabic = false
    state.advisors.mode = .important
    state.preferences = WorkshopPreferences(notifications: true, morningCheck: true, morningHour: 11)
    state.projectDirectory = URL(fileURLWithPath: "/private/do-not-export")
    state.work = [WorkItem(title: "PRIVATE_TASK", details: "PRIVATE_DETAILS")]
    var policy = DelegationPolicy(); policy.orders["code"] = [.kimi]
    state.delegationPolicy = policy
    let file = root.appendingPathComponent("backup.json")
    try PreferencesBackup(state: state).write(to: file)
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(!text.contains("PRIVATE_TASK")); #expect(!text.contains("PRIVATE_DETAILS")); #expect(!text.contains("do-not-export"))
    #expect(!text.contains("notifications")); #expect(!text.contains("credentials"))
    var target = WorkshopState(); target.team = state.team
    try WorkshopStore(root: root).save(target)
    let model = AppModel(root: root)
    try model.importPreferences(PreferencesBackup.read(file))
    #expect(!model.arabic)
    #expect(model.state.preferences?.morningHour == 11)
    #expect(model.state.preferences?.notifications == false)
    #expect(model.state.team == target.team)
    #expect(model.state.projectDirectory == nil)
    #expect(model.state.work.isEmpty)
    #expect(model.state.delegationPolicy?.orders["code"] == [.kimi])
}

@Test func morningChecksUseTheLocalDayAndRunAtMostOnce() throws {
    var preferences = WorkshopPreferences(morningCheck: true, morningHour: 9)
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try #require(TimeZone(identifier: "Asia/Dubai"))
    let formatter = ISO8601DateFormatter()
    let before = try #require(formatter.date(from: "2026-11-07T04:59:00Z"))
    let after = try #require(formatter.date(from: "2026-11-07T05:01:00Z"))
    #expect(!preferences.checkIsDue(now: before, last: nil, calendar: calendar))
    #expect(preferences.checkIsDue(now: after, last: nil, calendar: calendar))
    #expect(!preferences.checkIsDue(now: after.addingTimeInterval(3600), last: after, calendar: calendar))
    #expect(preferences.checkIsDue(now: after.addingTimeInterval(86400), last: after, calendar: calendar))
    preferences.morningCheck = false
    #expect(!preferences.checkIsDue(now: after, last: nil, calendar: calendar))
}

@Test func signedCatalogAcceptsOriginalAndRefusesTamperingWithoutReplacingIt() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fawaly-catalog-test-" + UUID().uuidString)
    try Paths.ensurePrivateDirectory(root)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try #require(Bundle.main.url(forResource: "catalog.signed", withExtension: "json"))
    let catalog = try SignedCatalog.importFile(file, root: root)
    #expect(catalog.providers.count == 10)
    let original = try Data(contentsOf: root.appendingPathComponent("catalog.signed.json"))
    var envelope = try #require(JSONSerialization.jsonObject(with: original) as? [String: String])
    var payload = try #require(Data(base64Encoded: envelope["payload"] ?? ""))
    payload[0] ^= 1
    envelope["payload"] = payload.base64EncodedString()
    let modified = root.appendingPathComponent("modified.json")
    try JSONSerialization.data(withJSONObject: envelope).write(to: modified)
    #expect(throws: (any Error).self) { try SignedCatalog.importFile(modified, root: root) }
    #expect(try Data(contentsOf: root.appendingPathComponent("catalog.signed.json")) == original)
}

@Test func earlierPreferencesWithoutAnAppearanceChoiceStillDecode() throws {
    let data = Data(#"{"notifications":false,"morningCheck":false,"morningHour":9}"#.utf8)
    let preferences = try JSONDecoder().decode(WorkshopPreferences.self, from: data)
    #expect(preferences.appearance == nil)
}

@Test func damagedSavedCatalogFallsBackToTheVerifiedBundledSnapshot() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fawaly-catalog-fallback-" + UUID().uuidString)
    try Paths.ensurePrivateDirectory(root)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("damaged".utf8).write(to: root.appendingPathComponent("catalog.signed.json"))
    let catalog = try SignedCatalog.load(root: root)
    #expect(catalog.providers.count == 10)
    #expect(catalog.publishedAt == "2026-10-25T00:00:00Z")
}

@Test func signedCatalogDatesCompareInstantsAcrossTimeZoneOffsets() throws {
    let installed = try SignedCatalog.publishedDate("2026-11-01T00:00:00Z")
    let actuallyOlder = try SignedCatalog.publishedDate("2026-11-01T09:00:00+10:00")
    let actuallyNewer = try SignedCatalog.publishedDate("2026-10-31T20:00:00-05:00")
    #expect(actuallyOlder < installed)
    #expect(actuallyNewer > installed)
}
