import Foundation
import Testing
import Darwin
@testable import FawalyApp

@Test func shippedUpdateConfigurationHasAValidPublicKeyAndNoAutomaticInstall() throws {
    let key = try #require(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
    #expect(Data(base64Encoded: key)?.count == 32)
    let feed = try #require(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)
    #expect(URL(string: feed)?.scheme == "https")
    #expect(feed == "https://raw.githubusercontent.com/daxowapp/fawaly/main/updates/appcast.xml")
    #expect(Bundle.main.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool == false)
    #expect(Bundle.main.object(forInfoDictionaryKey: "SUAllowsAutomaticUpdates") as? Bool == false)
}

@Test @MainActor func localRecoveryBuildCannotStartAnUpdateOrBlockNewWork() throws {
    guard !WorkshopUpdates.signedBaseline else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let updates = WorkshopUpdates(root: root)
    updates.canBegin = { true }
    updates.check(arabic: false)
    #expect(updates.message?.contains("first notarized release") == true)
    #expect(!updates.checking && !updates.installationPending)
    let worker = try EngineConfiguration(root: root).lockWorkerAccess()
    close(worker)
}
