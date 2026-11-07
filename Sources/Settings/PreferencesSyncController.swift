import Foundation
import SwiftUI
import CryptoKit

@MainActor
final class PreferencesSyncController: ObservableObject {
    private struct Configuration: Codable {
        var folder: URL?
        var deviceID = UUID()
        var revision: UUID?
        var fingerprint: String?
    }
    @Published private(set) var folder: URL?
    @Published private(set) var pending: PreferencesSyncEnvelope?
    @Published private(set) var message: String?
    @Published private(set) var working = false
    private var configuration: Configuration
    private let root: URL
    private var file: URL { root.appendingPathComponent("preferences-sync-local.json") }
    init(root: URL) {
        self.root = root
        configuration = (try? Data(contentsOf: root.appendingPathComponent("preferences-sync-local.json")))
            .flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) } ?? Configuration()
        folder = configuration.folder
    }
    func choose(_ folder: URL) throws {
        let info = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else { throw FawalyError.invalid("Choose a real preferences folder.") }
        configuration.folder = folder; configuration.revision = nil; configuration.fingerprint = nil
        try persist(); self.folder = folder; pending = nil; message = nil
    }
    func disable() throws {
        configuration.folder = nil; configuration.revision = nil; configuration.fingerprint = nil
        try persist(); folder = nil; pending = nil; message = nil
    }
    func poll(state: WorkshopState, idle: Bool) async {
        guard idle, !working, let folder else { return }
        working = true
        defer { working = false }
        do {
            let remote = try await Task.detached { try PreferencesSyncStore(folder: folder).read() }.value
            guard self.folder == folder else { return }
            if let remote, remote.id != configuration.revision {
                // An own-device revision is also acknowledged, never re-imported.
                if remote.deviceID == configuration.deviceID {
                    configuration.revision = remote.id
                    configuration.fingerprint = try Self.fingerprint(remote.preferences)
                    try persist()
                } else { pending = remote; return }
            }
            guard pending == nil else { return }
            let backup = PreferencesBackup(state: state)
            let fingerprint = try Self.fingerprint(backup)
            if fingerprint != configuration.fingerprint {
                let deviceID = configuration.deviceID
                let revision = configuration.revision
                let published = try await Task.detached { try PreferencesSyncStore(folder: folder).publish(backup, deviceID: deviceID, replacing: revision) }.value
                configuration.revision = published.id; configuration.fingerprint = fingerprint
                try persist(); message = nil
            }
        } catch { message = error.localizedDescription }
    }
    func acknowledgeApplied(state: WorkshopState) throws {
        guard let pending else { return }
        configuration.revision = pending.id
        configuration.fingerprint = try Self.fingerprint(PreferencesBackup(state: state))
        try persist(); self.pending = nil
    }
    func dismissRemote() throws {
        // Disabling avoids silently replacing the remote device's preferences.
        try disable()
    }
    private func persist() throws {
        try Paths.ensurePrivateDirectory(root)
        try JSONEncoder().encode(configuration).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    static func fingerprint(_ backup: PreferencesBackup) throws -> String {
        let data = try JSONEncoder().encode(backup)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object.removeValue(forKey: "created")
        return SHA256.hash(data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).map { String(format: "%02x", $0) }.joined()
    }
}

struct PreferencesSyncView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var sync: PreferencesSyncController
    @State private var choosing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.text("إعداداتك بين أجهزة الماك", "Preferences across your Macs")).font(.headline)
            Text(model.text("اختار نفس فولدر iCloud Drive على الجهازين. الإعدادات تتحدّث والفواعلي شغّال، وأي تغيير من الجهاز التاني محتاج موافقتك. الحسابات والمفاتيح والأدوار والمشاريع والسجل ما بيتنقلوش.", "Choose the same iCloud Drive folder on both Macs. Preferences sync while Fawaly runs; changes from another Mac need your approval. Accounts, keys, team roles, projects and history stay on each Mac.")).font(.caption).foregroundStyle(.secondary)
            if let folder = sync.folder {
                Text(folder.path).font(.caption).textSelection(.enabled)
                Button(model.text("إيقاف المزامنة", "Turn off sync")) { do { try sync.disable() } catch { model.report(error) } }.disabled(sync.working)
            } else {
                Button(model.text("اختار فولدر المزامنة…", "Choose sync folder…")) { choose() }.disabled(choosing)
            }
            if let pending = sync.pending {
                Label(model.text("وصلت إعدادات من ماك تاني", "Preferences arrived from another Mac"), systemImage: "arrow.triangle.2.circlepath").font(.headline)
                Text(pending.updatedAt, style: .date).font(.caption)
                Text(model.text("اللغة: ", "Language: ") + (pending.preferences.arabic ? "العربية" : "English"))
                Text(model.text("وضع المستشار: ", "Advisor mode: ") + pending.preferences.advisorMode.rawValue).font(.caption)
                Text(model.text("هيتغيّر كمان ترتيب العمال والموديلات ومظهر الورشة وموعد الفحص. الأدوار والصلاحيات الحالية بتفضل زي ما هي.", "Worker order, model choices, appearance and check time also change. Current roles and permissions are preserved.")).font(.caption)
                HStack {
                    Button(model.text("طبّق الإعدادات دي", "Apply these preferences")) {
                        do {
                            let lease = try WorkActivityLease(root: model.dataDirectory)
                            defer { withExtendedLifetime(lease) {} }
                            try model.importPreferences(pending.preferences)
                            try sync.acknowledgeApplied(state: model.state)
                        } catch { model.report(error) }
                    }.disabled(model.busy || model.setup.busy || model.activeWorkCount > 0)
                    Button(model.text("احتفظ بإعداداتي وأوقف المزامنة", "Keep mine and stop syncing")) { do { try sync.dismissRemote() } catch { model.report(error) } }
                }
            }
            if let message = sync.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func choose() {
        choosing = true
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.message = model.text("اختار فولدر مخصص لإعدادات الفواعلي، ويفضل داخل iCloud Drive. أول مزامنة هتشارك إعداداتك الحالية لو الفولدر فاضي.", "Choose a dedicated Fawaly preferences folder, preferably in iCloud Drive. If empty, the first sync shares your current preferences.")
        panel.presentInWorkshop { result in
            choosing = false
            guard result == .OK, let folder = panel.url else { return }
            do { try sync.choose(folder) } catch { model.report(error) }
        }
    }
}
