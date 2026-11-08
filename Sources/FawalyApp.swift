import SwiftUI
import CoreText

@main
enum FawalyEntry {
    @MainActor
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let command = arguments.first, ["mcp", "status", "codex-login", "claude-setup-token", "allow-workspace", "deny-workspace", "--help"].contains(command) {
            let code = await EngineCLI.run(arguments)
            exit(code)
        }
        FawalyApp.main()
    }
}

struct FawalyApp: App {
    @NSApplicationDelegateAdaptor(WorkshopLifecycle.self) private var lifecycle
    @StateObject private var model: AppModel

    init() {
        // Verification launches opt into a separate store; production always uses its existing store.
        var root = Paths.rebuiltRoot()
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["FAWALY_VERIFICATION_ROOT"], path.hasPrefix("/") {
            root = URL(fileURLWithPath: path, isDirectory: true)
        } else if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("fawaly-test-host-" + UUID().uuidString)
        }
        #endif
        _model = StateObject(wrappedValue: AppModel(root: root))
        if let font = Bundle.main.url(forResource: "Lalezar-Regular", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
        }
    }

    var body: some Scene {
        Window("الفواعلي · Fawaly", id: "workshop") {
            WorkshopWindow()
                .environmentObject(model)
                .frame(minWidth: 830, minHeight: 620)
        }
        .defaultSize(width: 1060, height: 760)
        .commands { WorkshopWindowCommands(model: model) }
        MenuBarExtra("الفواعلي", systemImage: "hammer.fill") {
            WorkshopMenu().environmentObject(model)
        }

    }
}

struct WorkshopWindow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var page: AppPage? = .home

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack {
                    HStack(spacing: 9) {
                        Image(systemName: "hammer.fill").foregroundStyle(Workshop.yellow)
                        Text(model.text("الفواعلي", "Fawaly")).font(Workshop.heading(26, ar: model.arabic))
                    }
                    Spacer()
                    Button(model.arabic ? "EN" : "عربي") { model.setArabic(!model.arabic) }.buttonStyle(.plain).accessibilityLabel(model.arabic ? "English" : "العربية")
                    Button { model.refreshTeamActivity() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).accessibilityLabel(model.text("تحديث النشاط", "Refresh activity"))
                }.padding(.horizontal, 24).padding(.top, 12)
                HazardStripe()
            }.background(.bar)
            HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    WorkshopGlyph(page: .shift, size: 36, active: false)
                        .padding(7).background(Workshop.yellow.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading) {
                        Text(model.text("الكبير يراجع", "The primary reviews")).font(Workshop.heading(19, ar: model.arabic))
                        Text(model.text("والفواعلي ينفّذوا", "Fawaly executes")).font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 14).padding(.top, 18)
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(AppPage.navigation) { item in
                            Button { page = item } label: {
                                HStack(spacing: 11) {
                                    WorkshopGlyph(page: item, size: 27, active: page == item)
                                    Text(item.title(model.arabic)).font(.callout.weight(page == item ? .semibold : .regular))
                                    Spacer(minLength: 0)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(page == item ? Workshop.yellow.opacity(0.23) : .clear, in: RoundedRectangle(cornerRadius: 12))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel(item.title(model.arabic)).accessibilityAddTraits(page == item ? .isSelected : [])
                        }
                    }.padding(.horizontal, 10)
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "mug.fill").foregroundStyle(Workshop.yellow).font(.title2)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.text("القهوة علينا. الشغل عليهم.", "Coffee’s on us. Work’s on them.")).font(.caption.weight(.semibold))
                        Text(model.text("محلي. ومفاتيحك عندك.", "Local. Your keys stay with you.")).font(.caption2).foregroundStyle(.secondary)
                    }
                }.padding(18)
            }
            .frame(width: 220).frame(maxHeight: .infinity).background(.bar)
                Divider()
                Group {
                    if page == .advisor {
                        AdvisorPage()
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                header(page ?? .home)
                                switch page ?? .home {
                                case .shift: TasksPage()
                                case .worklog:
                                    Button(model.text("اكتب مهمة محلية", "Compose a local task")) { page = .shift }
                                    TasksLedger()
                                case .connection: PrimaryConnectionPage()
                                case .rules: DelegationRulesPage()
                                case .hires: WorkerModelsPage()
                                case .contest: ComparisonPage()
                                case .contractors: services
                                case .settings: settings
                                case .usage: UsagePage()
                                default: home
                                }
                            }.padding(28)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .task {
            WorkshopLifecycle.model = model
            WorkshopLifecycle.showWorkshop = { openWindow(id: "workshop") }
            model.startMonitoring()
        }
        .onChange(of: model.requestedPage) { _, requested in
            if let requested { page = requested; model.requestedPage = nil }
        }
        .confirmationDialog(model.text("إنهاء الفواعلي؟", "Quit Fawaly?"), isPresented: $model.confirmQuit) {
            Button(model.text("إنهاء وإيقاف المهام التابعة للتطبيق", "Quit and stop app-owned work"), role: .destructive) { WorkshopLifecycle.allowQuitOnce = true; NSApp.terminate(nil) }
        } message: {
            Text(model.text("فيه شغل لسه شغّال. المهام التابعة للواجهة هتتوقف وقد تترك تعديلات جزئية تحتاج مراجعة. مهام MCP في برنامج الأساسي منفصلة.", "Work is still active. App-owned work will stop and may leave partial edits to review. MCP jobs in your primary client run separately."))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in LoginProcess.cancelAll(); WorkerProcess.cancelAll() }
        .tint(Workshop.yellow)
        .preferredColorScheme(model.state.preferences?.appearance == "light" ? .light : model.state.preferences?.appearance == "dark" ? .dark : nil)
        .environment(\.layoutDirection, model.arabic ? .rightToLeft : .leftToRight)
        .sheet(isPresented: $model.showOnboarding) { OnboardingView(setup: model.setup) }
        .sheet(isPresented: $model.showProviderSheet) { ProviderSheet() }
        .alert(model.text("الفواعلي", "Fawaly"), isPresented: Binding(
            get: { model.problem != nil },
            set: { if !$0 { model.problem = nil } }
        )) {
            Button(model.text("تمام", "OK"), role: .cancel) { model.problem = nil }
        } message: {
            Text(model.problem ?? "")
        }
    }

    private func header(_ section: AppPage) -> some View {
        let subtitle: String
        switch section {
        case .home: subtitle = model.text("جهّز فريقك وتابع شغله، وكمّل محادثتك مع الأجنت الأساسي.", "Set up your team, follow its work, and keep chatting with your primary agent.")
        case .shift: subtitle = model.text("اكتب مهمة وجرّبها محليًا أو اطلب رد نصي من خدمة ربطتها.", "Queue work for a local preview or request a text result from a connected service.")
        case .worklog: subtitle = model.text("نتائج المهام المحفوظة في الورشة دي.", "Task results saved in this workshop.")
        case .contractors: subtitle = model.text("حساباتك والمساعدون المرتبطون. أضف خدمة وعيّن دورها في الفريق.", "Your connected accounts and assistants. Add a service and assign its team role.")
        case .connection: subtitle = model.text("اربط الأساسي بفريقك وافتح محادثتك المعتادة.", "Connect your primary to the team and open your usual chat.")
        case .rules: subtitle = model.text("ترتيب العمال ومهل التنفيذ وسياسة المستشار.", "Worker order, execution timeouts and advisor policy.")
        case .hires: subtitle = model.text("افحص بيانات الموديلات الرسمية المحفوظة محليًا.", "Inspect locally cached official model data.")
        case .contest: subtitle = model.text("نفس المهمة في نسختين منفصلتين، والمراجعة قبل اختيار النتيجة.", "The same task in separate snapshots, reviewed before choosing a result.")
        case .usage: subtitle = model.text("أعداد المهام والاستشارات المحفوظة على الماك.", "Counts of tasks and consultations saved on this Mac.")
        case .settings: subtitle = model.text("اللغة وتخزين الورشة.", "Workshop language and storage.")
        default: subtitle = ""
        }
        return SectionHeader(title: section == .home ? model.text("وكيلك يخطّط. الفواعلي تنفّذ.", "Your agent plans. Fawaly executes.") : section.title(model.arabic), subtitle: subtitle, ar: model.arabic, page: section)
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 18) {
            RunningTeamPanel()
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                homeLink(.connection, subtitle: model.state.team?.primary.label ?? model.text("اربط الأساسي", "Connect your primary"))
                homeLink(.contractors, subtitle: model.text("حساباتك الأصلية ومساعدوك", "Your native accounts and assistants"))
                homeLink(.rules, subtitle: model.text("ترتيب المساعدين وسياسة المستشار", "Worker order and advisor policy"))
                homeLink(.advisor, subtitle: model.text("رأي مستقل وقرار من الأساسي", "Independent advice, primary decision"))
            }
            WorkshopCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label(model.text("النشاط والمراجعة", "Activity & review"), systemImage: "checkmark.bubble").font(.headline)
                    if let job = model.teamJobs.first {
                        Text(job.title).lineLimit(2)
                        Text(job.worker.label + " · " + job.statusLabel(arabic: model.arabic)).font(.caption).foregroundStyle(.secondary)
                        if let review = job.latestReview {
                            Text(model.text("قرار الأساسي: ", "Primary decision: ") + review.summary).lineLimit(3)
                        } else {
                            Text(model.text("لم تُسجّل مراجعة مستقلة من الأساسي بعد.", "No independent primary review recorded yet.")).font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(model.text("لسه مفيش مهمة تفويض مسجلة؛ حفظ الاتصال وحده مش إثبات تنفيذ.", "No delegated task recorded yet; saving a connection alone does not prove execution.")).foregroundStyle(.secondary)
                    }
                    Button(model.text("المهام والمراجعات", "Tasks & reviews")) { page = .worklog }
                }
            }
            WorkshopCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.text("جديد هنا؟ خد جولة سريعة", "New here? Take a quick tour")).font(.headline)
                    Text(model.text("١. اربط الأساسي. ٢. جهّز المساعدين. ٣. اكتب مهمتك عند الأساسي. ٤. راجع الأدلة وقرار الأساسي في السجل.", "1. Connect your primary. 2. Prepare assistants. 3. Give your primary a task. 4. Inspect evidence and the primary decision in the ledger."))
                    HStack {
                        Button(model.text("دليل الربط", "Connection guide")) { page = .connection }
                        Button(model.text("اكتب مهمة محلية", "Compose a local task")) { page = .shift }
                    }
                }
            }
        }
    }

    private func homeLink(_ target: AppPage, subtitle: String) -> some View {
        Button { page = target } label: {
            WorkshopCard {
                HStack(spacing: 14) {
                    WorkshopGlyph(page: target, size: 32, active: false)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(target.title(model.arabic)).font(.headline)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: model.arabic ? "chevron.left" : "chevron.right").foregroundStyle(.secondary)
                }.frame(minHeight: 58)
            }
        }.buttonStyle(.plain)
    }

    private var services: some View {
        VStack(alignment: .leading, spacing: 14) {
            EngineServicesCard()
            WorkshopCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label(model.text("المعاينة المحلية متاحة", "Local preview available"), systemImage: "checkmark.circle")
                    if let endpoint = model.state.provider {
                        Text(endpoint.model + " · " + endpoint.url.absoluteString).textSelection(.enabled)
                        Text(model.text("لو الخدمة بتطلب مفتاح، دخّله تاني بعد ما تعيد فتح التطبيق.", "If the service requires a key, re-enter it after reopening the app."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(model.text("إعداد خدمة نصية…", "Configure text service…")) { model.showProviderSheet = true }
                            .buttonStyle(WorkshopPrimaryButtonStyle())
                        if model.state.provider != nil {
                            Button(model.text("افصل الخدمة", "Disconnect"), role: .destructive) {
                                do { try model.disconnect() } catch { model.report(error) }
                            }
                        }
                    }.disabled(!model.loaded || model.busy)
                }
            }
        }
    }

    private var settings: some View { WorkshopSettingsPage() }

}

struct TasksPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var title = ""
    @State private var details = ""
    @State private var sending: WorkItem?
    @State private var confirmSend = false
    @State private var sendingProvider = AppModel.connected
    @State private var destination: URL?
    @State private var outcome: String?
    @State private var operation: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.text("جاري تنفيذ الطلب…", "Working on your request…"))
                    if operation != nil {
                        Button(model.text("إلغاء التنفيذ", "Cancel request")) { operation?.cancel() }
                    }
                }
            }
            if let outcome { Label(outcome, systemImage: "info.circle").font(.callout) }
            WorkshopCard {
                VStack(alignment: .leading, spacing: 12) {
                    TextField(model.text("المهمة", "Task"), text: $title).textFieldStyle(.roundedBorder)
                    TextField(model.text("التفاصيل", "Details"), text: $details, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(2...7)
                    Button(model.text("أضف للطابور", "Add to queue")) {
                        do { try model.addTask(title: title, details: details); title = ""; details = "" }
                        catch { model.report(error) }
                    }.buttonStyle(WorkshopPrimaryButtonStyle()).disabled(!model.loaded || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            ForEach(model.state.work.filter { $0.completed == nil }) { item in
                WorkshopCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.title).font(.headline)
                        if !item.details.isEmpty { Text(item.details).font(.callout).foregroundStyle(.secondary) }
                        HStack {
                            Button(model.text("معاينة محلية", "Local preview")) { run(item, provider: AppModel.preview) }
                            if model.state.provider != nil {
                                Button(model.text("إرسال للخدمة…", "Send to service…")) { prepareSend(item, provider: AppModel.connected) }
                            }
                            ForEach(model.nativeAgents, id: \.self) { agent in
                                Button(agent.label + "…") { prepareSend(item, provider: agent.providerID) }
                            }
                            Spacer()
                            Button(model.text("شيل من الطابور", "Remove from queue"), role: .destructive) {
                                do { try model.removeTask(item.id) } catch { model.report(error) }
                            }
                        }.disabled(model.busy)
                    }
                }
            }
        }
        .confirmationDialog(model.text("إرسال المهمة للخدمة؟", "Send this task?"), isPresented: $confirmSend, titleVisibility: .visible) {
            Button(model.text("إرسال", "Send")) {
                if let sending { run(sending, provider: sendingProvider) }
            }
        } message: {
            Text(sendMessage)
        }
    }

    private var sendMessage: String {
        let prefix = model.text("عنوان المهمة وتفاصيلها هيروحوا إلى", "The title and details will be sent to")
        return "\(prefix) \(model.providerDestination(sendingProvider, url: destination))."
    }
    
    private func prepareSend(_ item: WorkItem, provider: String) {
        sending = item
        sendingProvider = provider
        destination = model.state.provider?.url
        confirmSend = true
    }
    
    private func run(_ item: WorkItem, provider: String) {
        guard operation == nil, !model.busy else { return }
        outcome = nil
        operation = Task {
            defer { operation = nil }
            do {
                try await model.runTask(item.id, provider: provider, destination: destination)
                outcome = model.text("خلصت المهمة واتحفظت النتيجة في السجل.", "Task complete. Your result is saved in Work log.")
            } catch is CancellationError {
                outcome = model.text("اتلغى التنفيذ. المهمة لسه في الطابور.", "Request cancelled. The task is still in your queue.")
            } catch { model.report(error) }
        }
    }
}

struct ProviderSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint = ""
    @State private var modelID = ""
    @State private var key = ""
    @State private var issue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.text("خدمة نصية متوافقة", "Compatible text service")).font(.headline)
            TextField("HTTPS …/chat/completions", text: $endpoint).textFieldStyle(.roundedBorder)
            TextField(model.text("معرّف الموديل", "Model ID"), text: $modelID).textFieldStyle(.roundedBorder)
            SecureField(model.text("مفتاح اختياري للجلسة دي", "Optional key for this session"), text: $key)
                .textFieldStyle(.roundedBorder)
            Text(model.text("حفظ الإعدادات مش بيبعت طلب. مفتاح الوصول بيختفي عند إغلاق التطبيق.", "Saving does not send a request. The access key is discarded when the app closes."))
                .font(.caption).foregroundStyle(.secondary)
            if let issue { Text(issue).foregroundStyle(.red) }
            HStack {
                Button(model.text("إلغاء", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(model.text("حفظ", "Save")) {
                    do {
                        try model.configure(EndpointSettings(endpoint: endpoint, model: modelID), key: key)
                        dismiss()
                    } catch { issue = error.localizedDescription }
                }.buttonStyle(WorkshopPrimaryButtonStyle()).disabled(model.busy)
            }
        }.padding(24).frame(width: 510)
            .onAppear {
                endpoint = model.state.provider?.url.absoluteString ?? ""
                modelID = model.state.provider?.model ?? ""
            }
    }
}
