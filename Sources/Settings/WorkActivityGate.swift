import Foundation
import Darwin
import AppKit

/// A lease excludes *new* workers, including MCP processes outside the GUI.
/// Release it only after the protected configuration/update operation ends.
final class WorkActivityLease {
    private var descriptor: Int32
    init(root: URL) throws {
        descriptor = try EngineConfiguration(root: root).lockJob()
        do {
            try ComparisonStore(root: root).recoverInterrupted()
            guard try !ComparisonStore(root: root).recent().contains(where: {
                $0.runs.contains { ["running", "waiting"].contains($0.status) }
            }) else { throw FawalyError.invalid("A comparison is still active. Wait for it to finish.") }
        } catch { close(descriptor); descriptor = -1; throw error }
    }
    deinit { if descriptor >= 0 { close(descriptor) } }
}

@MainActor
final class WorkshopLifecycle: NSObject, NSApplicationDelegate {
    static weak var model: AppModel?
    static var allowQuitOnce = false
    static var showWorkshop: (() -> Void)?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model else { return .terminateNow }
        if Self.allowQuitOnce { Self.allowQuitOnce = false; return .terminateNow }
        // The updater already owns the exclusive lease; workers cannot start.
        if model.updates.installationPending { return .terminateNow }
        do {
            let lease = try WorkActivityLease(root: model.dataDirectory)
            withExtendedLifetime(lease) {}
            if !model.busy && !model.setup.busy { return .terminateNow }
        } catch { /* A worker/setup process still owns an engine lease. */ }
        model.requestedPage = .worklog
        Self.showWorkshop?()
        model.confirmQuit = true
        sender.activate(ignoringOtherApps: true)
        sender.windows.first(where: { $0.identifier?.rawValue == "workshop" })?.makeKeyAndOrderFront(nil)
        return .terminateCancel
    }
}
