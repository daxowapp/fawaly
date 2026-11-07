import AppKit
import SwiftUI
import ServiceManagement

struct WorkshopMenu: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.text("الفواعلي", "Fawaly"))
        if let team = model.state.team {
            Text(model.text("الأساسي: ", "Primary: ") + team.primary.label)
        }
        Text(model.activeWorkCount > 0
             ? model.text("مهام شغّالة: \(model.activeWorkCount)", "Active work: \(model.activeWorkCount)")
             : model.text("الفريق مستعد", "Team ready"))
        Divider()
        Button(model.text("افتح الورشة", "Open workshop")) { show(.home) }.keyboardShortcut("o")
        Button(model.text("المهام والمراجعات", "Tasks & reviews")) { show(.worklog) }
        Button(model.text("الإعدادات", "Settings")) { show(.settings) }
        Divider()
        Button(model.text("إنهاء الفواعلي…", "Quit Fawaly…")) {
            if model.activeWorkCount > 0 { show(.worklog); model.confirmQuit = true }
            else { NSApp.terminate(nil) }
        }.keyboardShortcut("q")
    }
    private func show(_ page: AppPage) {
        model.requestedPage = page
        openWindow(id: "workshop")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct WorkshopWindowCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(model.text("افتح الورشة", "Open workshop")) { openWindow(id: "workshop"); NSApp.activate(ignoringOtherApps: true) }.keyboardShortcut("o")
            Button(model.text("اقفل نافذة الورشة", "Close workshop window")) { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w")
        }
    }
}

@MainActor enum WorkshopLoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }
    static func setEnabled(_ value: Bool) throws {
        if value { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }
    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
