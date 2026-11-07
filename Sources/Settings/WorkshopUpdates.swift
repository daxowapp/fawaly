import AppKit
import Security
import Sparkle
import SwiftUI

/// Only a Developer ID baseline may replace itself. Ad-hoc recovery builds use
/// the website until the first notarized release has been installed manually.
@MainActor
final class WorkshopUpdates: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var checking = false
    @Published private(set) var message: String?
    private var lease: WorkActivityLease?
    private var controller: SPUStandardUpdaterController?
    @Published private(set) var installationPending = false
    private let root: URL
    var canBegin: () -> Bool = { false }

    init(root: URL) { self.root = root; super.init() }

    static var signedBaseline: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists" as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    func check(arabic: Bool) {
        guard Self.signedBaseline else {
            message = arabic ? "نسخة الاسترجاع دي محلية. أول نسخة موثّقة هتتنزّل من موقع الفواعلي؛ بعدها التحديثات الموقّعة هتبقى من هنا." : "This recovery build is local. Install the first notarized release from the Fawaly website; signed updates will then be available here."
            return
        }
        guard !checking else { return }
        do {
            guard canBegin() else { throw FawalyError.invalid(arabic ? "استنى إعداد الفريق والمهام يخلصوا الأول." : "Finish setup and active work before updating.") }
            if controller == nil {
                let value = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
                // Updates are deliberate. Never download/install on a schedule.
                value.updater.automaticallyChecksForUpdates = false
                value.updater.automaticallyDownloadsUpdates = false
                try value.updater.start()
                controller = value
            }
            guard controller?.updater.canCheckForUpdates == true else {
                message = arabic ? "المحدّث بيتجهّز؛ جرّب بعد لحظة." : "The updater is getting ready; try again in a moment."
                return
            }
            lease = try WorkActivityLease(root: root)
            checking = true
            message = nil
            controller?.checkForUpdates(nil)
        } catch { lease = nil; checking = false; message = error.localizedDescription }
    }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard canBegin(), lease != nil else { throw FawalyError.invalid("Finish active work before updating Fawaly.") }
    }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard lease != nil else { throw FawalyError.invalid("The update no longer has exclusive engine access.") }
    }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { installationPending = true }
    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        // Sparkle may schedule an already installing update for the next quit.
        // Retain the lease in that case so no external MCP worker can start.
        if state.stage == .installing { installationPending = true }
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if error != nil { installationPending = false }
        checking = installationPending
        if !installationPending { lease = nil }
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        installationPending = false; checking = false; lease = nil
    }
}

struct WorkshopUpdatesView: View {
    @ObservedObject var updates: WorkshopUpdates
    let arabic: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(arabic ? "تحديثات الفواعلي" : "Fawaly updates").font(.headline)
            Text((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") + " · " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")).font(.caption).foregroundStyle(.secondary)
            Text(arabic ? "التحديثات موقّعة، وباختيارك. الشغل لازم يخلص قبل بدء التحديث، والمهام الجديدة بتستنى لحد ما تقفل نافذته أو تعيد تشغيل الفواعلي." : "Updates are signed and started by you. Finish work before checking; new work waits until you dismiss the update or restart Fawaly.").font(.caption).foregroundStyle(.secondary)
            Button(arabic ? "افحص التحديثات" : "Check for updates") { updates.check(arabic: arabic) }.disabled(updates.checking)
            if updates.installationPending { Text(arabic ? "التحديث جاهز. أعد تشغيل الفواعلي لإكماله." : "An update is ready. Restart Fawaly to finish.").font(.caption) }
            if let message = updates.message { Text(message).font(.caption).textSelection(.enabled) }
            Link(arabic ? "موقع الفواعلي والتنزيل" : "Fawaly website & download", destination: URL(string: "https://daxow.com/fawaly")!)
        }
    }
}
