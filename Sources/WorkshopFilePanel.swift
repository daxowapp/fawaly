import AppKit

extension NSSavePanel {
    @MainActor func presentInWorkshop(completion: @escaping (NSApplication.ModalResponse) -> Void) {
        // AX/keyboard actions can arrive while the workshop is not the key app.
        // Find its real document window, excluding the file panel itself, then
        // activate it so the sheet stays in the same full-screen space.
        let candidates = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 } + NSApp.windows
        let owner = candidates.first { $0 !== self && !($0 is NSPanel) && $0.isVisible && $0.canBecomeMain }
        NSApp.activate(ignoringOtherApps: true)
        if let owner {
            owner.makeKeyAndOrderFront(nil)
            beginSheetModal(for: owner, completionHandler: completion)
        } else {
            collectionBehavior.insert(.fullScreenAuxiliary)
            begin(completionHandler: completion)
            makeKeyAndOrderFront(nil)
        }
    }
}
