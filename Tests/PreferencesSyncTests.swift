import Foundation
import Testing
@testable import FawalyApp

private let deviceA = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
private let deviceB = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
private let publishedAt = Date(timeIntervalSinceReferenceDate: 800_000_000.5)

private func makeCloudFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fawaly-sync-test-" + UUID().uuidString, isDirectory: true)
    try Paths.ensurePrivateDirectory(folder)
    return folder
}

private func makeBackup(arabic: Bool = false, morningHour: Int = 11, appearance: String? = "dark") -> PreferencesBackup {
    var state = WorkshopState()
    state.arabic = arabic
    state.advisors.mode = .important
    state.advisors.maxRounds = 5
    state.advisors.timeoutMinutes = 10
    state.preferences = WorkshopPreferences(morningCheck: true, morningHour: morningHour, appearance: appearance)
    state.workerModels = ["codex": "gpt-5.1-codex"]
    var policy = DelegationPolicy()
    policy.timeoutSeconds = 600
    state.delegationPolicy = policy
    return PreferencesBackup(state: state, now: Date(timeIntervalSinceReferenceDate: 700_000_000))
}

private func syncFile(in folder: URL) -> URL { folder.appendingPathComponent(PreferencesSyncStore.fileName) }

/// Re-serializes the synced document from `data` after letting `update` mutate its JSON object.
private func replaceSyncedDocument(in folder: URL, with data: Data, _ update: (inout [String: Any]) throws -> Void) throws {
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    try update(&object)
    try JSONSerialization.data(withJSONObject: object).write(to: syncFile(in: folder), options: .atomic)
}

@Test func twoDevicesSharingAFolderRoundTripTheLatestRevision() throws {
    let cloud = try makeCloudFolder()
    defer { try? FileManager.default.removeItem(at: cloud) }
    let firstDevice = PreferencesSyncStore(folder: cloud)
    let secondDevice = PreferencesSyncStore(folder: cloud)
    let absent = try firstDevice.read()
    #expect(absent == nil)

    let backup = makeBackup()
    let published = try firstDevice.publish(backup, deviceID: deviceA, now: publishedAt)
    #expect(published.schema == "fawaly.preferences-sync.v1")
    #expect(published.deviceID == deviceA)
    #expect(published.updatedAt == publishedAt)

    // Exactly one document with the fixed name exists after the atomic write.
    let entries = try FileManager.default.contentsOfDirectory(atPath: cloud.path)
    #expect(entries == [PreferencesSyncStore.fileName])

    let remote = try #require(try secondDevice.read())
    #expect(remote.schema == "fawaly.preferences-sync.v1")
    #expect(remote.id == published.id)
    #expect(remote.deviceID == deviceA)
    #expect(remote.updatedAt == publishedAt)
    #expect(remote.preferences.schema == "fawaly.preferences.v1")
    #expect(remote.preferences.created == backup.created)
    #expect(remote.preferences.arabic == false)
    #expect(remote.preferences.advisorMode == .important)
    #expect(remote.preferences.advisorRounds == 5)
    #expect(remote.preferences.advisorMinutes == 10)
    #expect(remote.preferences.morningCheck == true)
    #expect(remote.preferences.morningHour == 11)
    #expect(remote.preferences.appearance == "dark")
    #expect(remote.preferences.workerModels?["codex"] == "gpt-5.1-codex")
    #expect(remote.preferences.policy.timeoutSeconds == 600)
}

@Test func republishingBumpsTheRevisionAndDeviceSeenByTheOtherDevice() throws {
    let cloud = try makeCloudFolder()
    defer { try? FileManager.default.removeItem(at: cloud) }
    let firstDevice = PreferencesSyncStore(folder: cloud)
    let secondDevice = PreferencesSyncStore(folder: cloud)
    let first = try firstDevice.publish(makeBackup(), deviceID: deviceA, now: publishedAt)

    let later = publishedAt.addingTimeInterval(300)
    let second = try secondDevice.publish(makeBackup(arabic: true, morningHour: 6, appearance: "light"), deviceID: deviceB, now: later)
    #expect(second.id != first.id)
    #expect(second.deviceID == deviceB)
    #expect(second.updatedAt == later)

    let remote = try #require(try firstDevice.read())
    #expect(remote.id == second.id)
    #expect(remote.deviceID == deviceB)
    #expect(remote.updatedAt == later)
    #expect(remote.preferences.arabic == true)
    #expect(remote.preferences.morningHour == 6)
    #expect(remote.preferences.appearance == "light")
}

@Test func syncDocumentCarriesPreferencesWithoutAccountsProjectsRolesGrantsOrHistory() throws {
    let cloud = try makeCloudFolder()
    defer { try? FileManager.default.removeItem(at: cloud) }
    let store = PreferencesSyncStore(folder: cloud)
    var state = WorkshopState()
    state.team = TeamSettings(primary: .codex, advisor: .claude, workers: [.kimi])
    state.projectDirectory = URL(fileURLWithPath: "/private/do-not-export")
    state.work = [WorkItem(title: "PRIVATE_TASK", details: "PRIVATE_DETAILS")]
    state.arabic = false
    state.advisors.mode = .onRequest
    state.preferences = WorkshopPreferences(notifications: true, morningCheck: true, morningHour: 8, appearance: "dark")
    state.workerModels = ["kimi": "kimi-k2.5"]
    var policy = DelegationPolicy()
    policy.orders["code"] = [.kimi]
    state.delegationPolicy = policy

    try store.publish(PreferencesBackup(state: state), deviceID: deviceA, now: publishedAt)
    let text = try String(contentsOf: syncFile(in: cloud), encoding: .utf8)
    for marker in ["PRIVATE_TASK", "PRIVATE_DETAILS", "do-not-export", "notifications", "credentials", "apiKey", "token", "account", "history", "roles", "grants"] {
        #expect(!text.contains(marker), "The sync document leaked \(marker).")
    }
}

@Test func readRejectsOversizedMalformedAndForeignSchemaDocuments() throws {
    let cloud = try makeCloudFolder()
    defer { try? FileManager.default.removeItem(at: cloud) }
    let store = PreferencesSyncStore(folder: cloud)
    let published = try store.publish(makeBackup(), deviceID: deviceA, now: publishedAt)
    let valid = try Data(contentsOf: syncFile(in: cloud))

    // Oversized but otherwise decodable: the extra key is ignored by Codable, so only the byte limit can reject it.
    try replaceSyncedDocument(in: cloud, with: valid) { object in
        object["pad"] = String(repeating: "a", count: PreferencesSyncEnvelope.maximumBytes)
    }
    #expect(throws: (any Error).self) { try store.read() }

    for damaged in [Data("not json".utf8), Data("{}".utf8)] {
        try damaged.write(to: syncFile(in: cloud), options: .atomic)
        #expect(throws: (any Error).self) { try store.read() }
    }

    try replaceSyncedDocument(in: cloud, with: valid) { object in object["schema"] = "fawaly.preferences-sync.v2" }
    #expect(throws: (any Error).self) { try store.read() }

    // The good document reads again once restored.
    try valid.write(to: syncFile(in: cloud), options: .atomic)
    let restored = try #require(try store.read())
    #expect(restored.id == published.id)
}

@Test func readRejectsInvalidNestedPreferenceAndModelFields() throws {
    let cloud = try makeCloudFolder()
    defer { try? FileManager.default.removeItem(at: cloud) }
    let store = PreferencesSyncStore(folder: cloud)
    try store.publish(makeBackup(), deviceID: deviceA, now: publishedAt)
    let valid = try Data(contentsOf: syncFile(in: cloud))

    let mutations: [(name: String, mutate: (inout [String: Any]) -> Void)] = [
        ("morning hour", { $0["morningHour"] = 25 }),
        ("advisor rounds", { $0["advisorRounds"] = 9 }),
        ("advisor minutes", { $0["advisorMinutes"] = 0 }),
        ("policy timeout", { $0["policy"] = ["timeoutSeconds": 0, "orders": [:]] }),
        ("appearance", { $0["appearance"] = "neon" }),
        ("model slug", { $0["workerModels"] = ["codex": "bad slug!"] }),
        ("unknown worker model key", { $0["workerModels"] = ["mystery": "gpt-5"] }),
        ("nested schema", { $0["schema"] = "fawaly.preferences.v9" }),
    ]
    for (_, mutate) in mutations {
        try valid.write(to: syncFile(in: cloud), options: .atomic)
        try replaceSyncedDocument(in: cloud, with: valid) { object in
            var preferences = object["preferences"] as? [String: Any] ?? [:]
            mutate(&preferences)
            object["preferences"] = preferences
        }
        #expect(throws: (any Error).self) { try store.read() }
    }
}

@Test func readRejectsLinkedAndNonRegularDocuments() throws {
    let cloud = try makeCloudFolder()
    defer { try? FileManager.default.removeItem(at: cloud) }
    let store = PreferencesSyncStore(folder: cloud)
    try store.publish(makeBackup(), deviceID: deviceA, now: publishedAt)
    let file = syncFile(in: cloud)
    let valid = try Data(contentsOf: file)

    // A link to a perfectly valid document is still refused, and so is a dangling link.
    let outside = cloud.appendingPathComponent("target.json")
    try valid.write(to: outside)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
    #expect(throws: (any Error).self) { try store.read() }

    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: cloud.appendingPathComponent("missing.json").path)
    #expect(throws: (any Error).self) { try store.read() }

    // A directory at the document path is not a regular file.
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    #expect(throws: (any Error).self) { try store.read() }
}

@Test func publishRefusesLinksAndInvalidBackupsWithoutTouchingTheDocument() throws {
    let cloud = try makeCloudFolder()
    defer { try? FileManager.default.removeItem(at: cloud) }
    let store = PreferencesSyncStore(folder: cloud)
    try store.publish(makeBackup(), deviceID: deviceA, now: publishedAt)
    let file = syncFile(in: cloud)
    let valid = try Data(contentsOf: file)

    // A document swapped for a link is never replaced through the link.
    let outside = cloud.appendingPathComponent("target.json")
    try valid.write(to: outside)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
    #expect(throws: (any Error).self) { try store.publish(makeBackup(), deviceID: deviceB) }
    #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeSymbolicLink)
    #expect(try Data(contentsOf: outside) == valid)

    // An invalid backup is rejected before anything is written.
    try FileManager.default.removeItem(at: file)
    var badState = WorkshopState()
    badState.preferences = WorkshopPreferences(morningCheck: true, morningHour: 99)
    #expect(throws: (any Error).self) { try store.publish(PreferencesBackup(state: badState), deviceID: deviceB) }
    let absent = try store.read()
    #expect(absent == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: cloud.path) == ["target.json"])
}

@Test func envelopeInitUsesTheSyncSchemaAndAFreshRevisionId() throws {
    let backup = makeBackup()
    let first = PreferencesSyncEnvelope(deviceID: deviceA, updatedAt: publishedAt, preferences: backup)
    let second = PreferencesSyncEnvelope(deviceID: deviceA, updatedAt: publishedAt, preferences: backup)
    #expect(first.schema == "fawaly.preferences-sync.v1")
    #expect(first.deviceID == deviceA)
    #expect(first.updatedAt == publishedAt)
    #expect(first.preferences.created == backup.created)
    #expect(first.id != second.id)

    let fixed = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
    let explicit = PreferencesSyncEnvelope(schema: "custom", id: fixed, deviceID: deviceB, updatedAt: publishedAt, preferences: backup)
    #expect(explicit.schema == "custom")
    #expect(explicit.id == fixed)
    #expect(explicit.deviceID == deviceB)
}
