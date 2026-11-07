import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkshopSettingsPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var dialogOpen = false
    @State private var requestingNotifications = false
    @State private var pendingBackup: PreferencesBackup?
    @State private var feedback: String?
    @State private var catalog: SignedCatalog?
    private var preferences: WorkshopPreferences { model.state.preferences ?? WorkshopPreferences() }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkshopCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.text("على ذوقك", "Make it yours")).font(.headline)
                    Picker(model.text("لغة الورشة", "Workshop language"), selection: Binding(get: { model.arabic }, set: model.setArabic)) {
                        Text("العربية").tag(true); Text("English").tag(false)
                    }.pickerStyle(.segmented)
                    Picker(model.text("شكل الورشة", "Appearance"), selection: Binding(get: { preferences.appearance ?? "system" }, set: { value in save { $0.appearance = value == "system" ? nil : value } })) {
                        Text(model.text("زي النظام", "System")).tag("system")
                        Text(model.text("فاتح", "Light")).tag("light")
                        Text(model.text("داكن", "Dark")).tag("dark")
                    }.pickerStyle(.segmented)
                    Toggle(model.text("نبّهني لما العامل يخلص", "Notify me when a worker finishes"), isOn: Binding(get: { preferences.notifications }, set: setNotifications))
                        .disabled(requestingNotifications)
                    Toggle(model.text("راجع تسجيل الدخول كل صباح", "Check saved sign-ins each morning"), isOn: Binding(get: { preferences.morningCheck }, set: { value in save { $0.morningCheck = value } }))
                    if preferences.morningCheck {
                        Picker(model.text("الساعة", "Time"), selection: Binding(get: { preferences.morningHour }, set: { value in save { $0.morningHour = value } })) {
                            ForEach(0..<24) { hour in Text(String(format: "%02d:00", hour)).tag(hour) }
                        }
                    }
                    Text(model.text("الفحص والتنبيهات بيشتغلوا والواجهة مفتوحة. فحص الحساب محلي، ومش بيبعت مهمة للموديل.", "Checks and notifications run while Fawaly is open. Account checks inspect saved sign-in and do not send a model task.")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(model.text("راجع الحسابات دلوقتي", "Check accounts now")) { Task { await model.checkAccountsNow() } }
                            .disabled(model.checkingAccounts || model.showOnboarding || model.teamJobs.contains(where: { $0.status == "running" }))
                        if model.checkingAccounts { ProgressView().controlSize(.small) }
                    }
                    if let summary = model.accountCheckSummary { Text(summary).font(.caption) }
                }
            }
            WorkshopCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.text("نسخة من إعداداتك", "Back up your preferences")).font(.headline)
                    Text(model.text("احفظ اللغة وقواعد التفويض وموعد الفحص في ملف. تقدر تحفظه في iCloud Drive وتنقله لماك تاني. الحسابات والمفاتيح وإذن التنبيهات وملفات المشاريع وسجل الشغل بيفضلوا على الماك ده.", "Save language, delegation rules and check time in a file. Save it in iCloud Drive to carry it to another Mac. Accounts, keys, notification permission, project files and history stay on this Mac.")).font(.callout)
                    HStack {
                        Button(model.text("تصدير الإعدادات…", "Export preferences…")) { exportPreferences() }
                        Button(model.text("استيراد نسخة…", "Import backup…")) { importPreferences() }
                    }.disabled(dialogOpen || model.busy)
                    if let feedback { Label(feedback, systemImage: "info.circle").font(.caption) }
                }
            }
            WorkshopCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.text("كتالوج المقاولين", "Provider catalog")).font(.headline)
                    if let catalog {
                        Text(model.text("نسخة موقّعة بتاريخ ", "Signed snapshot dated ") + String(catalog.publishedAt.prefix(10))).font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup(model.text("المقاولون في الكتالوج: \(catalog.providers.count)", "Providers in the catalog: \(catalog.providers.count)")) {
                            ForEach(catalog.providers) { entry in
                                HStack {
                                    Text(entry.name).font(.callout)
                                    Spacer()
                                    if let docs = entry.docsURL { Link(model.text("دليل الخدمة", "Provider guide"), destination: docs) }
                                }.padding(.vertical, 3)
                            }
                        }
                    }
                    Text(model.text("التحديث لازم يكون موقّعًا من ناشر الفواعلي. الكتالوج مرجع للخدمات؛ ربط الحسابات بيتم من صفحة المساعدين.", "Updates must carry the Fawaly publisher’s signature. The catalog is a provider reference; accounts connect from Assistants & plans.")).font(.caption).foregroundStyle(.secondary)
                    Button(model.text("استيراد كتالوج موقّع…", "Import signed catalog…")) { importCatalog() }.disabled(dialogOpen)
                }
            }
            WorkshopCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.text("الورشة على الماك ده", "Your workshop on this Mac")).font(.headline)
                    Text(model.text("الشغل وسجله محفوظين محليًا. عند تنفيذ مهمة، السياق والملفات اللي سمحت بيها ممكن تتبعت لمزوّد المساعد المختار.", "Work and history are saved locally. During a task, authorized context and files may be sent to the selected assistant’s provider.")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(model.text("افتح ملفات الورشة", "Open workshop files")) { NSWorkspace.shared.open(model.dataDirectory) }
                        Button(model.text("إعداد الفريق", "Team setup")) { model.editTeam() }.disabled(model.busy)
                    }
                    DisclosureGroup(model.text("تفاصيل التخزين", "Storage details")) {
                        Text(model.dataDirectory.path).font(.caption.monospaced()).textSelection(.enabled)
                        Button(model.text("إعادة قراءة السجل", "Reload saved data")) { model.load() }
                    }
                    Link(model.text("موقع الفواعلي وتنزيل الماك", "Fawaly website & Mac download"), destination: URL(string: "https://daxow.com/fawaly")!)
                    Link(model.text("سياسة الخصوصية الأصلية", "Original privacy policy"), destination: URL(string: "https://daxow.com/fawaly/privacy")!)
                    Text(model.text("الفكرة والاسم: أحمد نجدي — Ahmed Nagdy. تطوير الفواعلي: Daxow.", "Original idea and name: Ahmed Nagdy. Fawaly development: Daxow.")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { do { catalog = try SignedCatalog.load(root: model.dataDirectory) } catch { model.report(error) } }
        .confirmationDialog(model.text("استيراد الإعدادات؟", "Import these preferences?"), isPresented: Binding(get: { pendingBackup != nil }, set: { if !$0 { pendingBackup = nil } })) {
            Button(model.text("استيراد", "Import")) {
                guard let backup = pendingBackup else { return }
                do { try model.importPreferences(backup); feedback = model.text("اتسترجعت الإعدادات.", "Preferences restored.") } catch { model.report(error) }
                pendingBackup = nil
            }
            Button(model.text("إلغاء", "Cancel"), role: .cancel) { pendingBackup = nil }
        } message: {
            Text(model.text("هتتغيّر اللغة وسياسة المستشار وترتيب العمال المرتبطين حاليًا وموديلات المساعدين وموعد الفحص. راجع النسخة قبل التأكيد.", "This changes language, advisor policy, the order of currently assigned workers, assistant models, and check time."))
        }
    }
    private func save(_ update: (inout WorkshopPreferences) -> Void) {
        var value = preferences; update(&value)
        do { try model.savePreferences(value) } catch { model.report(error) }
    }
    private func setNotifications(_ enabled: Bool) {
        if !enabled { save { $0.notifications = false }; return }
        requestingNotifications = true
        Task {
            defer { requestingNotifications = false }
            do {
                let granted = try await WorkshopNotifications.authorize()
                save { $0.notifications = granted }
                if !granted { feedback = model.text("تقدر تسمح بالتنبيهات من إعدادات النظام.", "You can allow notifications in System Settings.") }
            } catch { model.report(error) }
        }
    }
    private func exportPreferences() {
        dialogOpen = true
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Fawaly-preferences.json"
        panel.presentInWorkshop { result in
            dialogOpen = false
            guard result == .OK, let file = panel.url else { return }
            do { try PreferencesBackup(state: model.state).write(to: file); feedback = model.text("اتحفظت نسخة الإعدادات.", "Preferences backed up.") } catch { model.report(error) }
        }
    }
    private func importPreferences() {
        dialogOpen = true
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.presentInWorkshop { result in
            dialogOpen = false
            guard result == .OK, let file = panel.url else { return }
            do { pendingBackup = try PreferencesBackup.read(file) } catch { model.report(error) }
        }
    }
    private func importCatalog() {
        dialogOpen = true
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.presentInWorkshop { result in
            dialogOpen = false
            guard result == .OK, let file = panel.url else { return }
            do { catalog = try SignedCatalog.importFile(file, root: model.dataDirectory); feedback = model.text("الكتالوج الموقّع اتحفظ.", "Signed catalog imported.") } catch { model.report(error) }
        }
    }
}
