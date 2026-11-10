import Foundation
import SwiftUI

struct RosterView {
    let advisors: AdvisorSettings
    let providers: [String: Provider]
}

@MainActor
final class AppModel: ObservableObject {
    nonisolated static let preview = "local-preview"
    nonisolated static let connected = "connected-text"

    @Published private(set) var state = WorkshopState()
    @Published private(set) var teamJobs: [TeamJob] = []
    @Published private(set) var consults: [ConsultRecord] = []
    @Published private(set) var nativeAgents: [EngineAgent] = []
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    @Published var requestedPage: AppPage?
    @Published var confirmQuit = false
    @Published private(set) var activeComparisons = 0
    private var monitor: Task<Void, Never>?
    private let monitoringStarted = Date()
    private var notified = Set<UUID>()
    private var launcherChecked = false
    private var refreshingActivity = false
    private var activitySignature: WorkLogSignature?
    private var lastActivityFailure: String?
    private var reportedUnreadable = false
    private var consultsRevision = 0
    var activeWorkCount: Int { teamJobs.filter { $0.status == "running" }.count + activeComparisons + (skillActivity.active == nil ? 0 : 1) }

    @Published var problem: String?
    @Published var showProviderSheet = false
    @Published var showOnboarding = false
    let skillActivity = SkillActivity()
    let daily = DailyViewModel()
    let setup: SetupCoordinator
    let updates: WorkshopUpdates
    let preferencesSync: PreferencesSyncController

    @Published private(set) var checkingAccounts = false
    @Published private var accountCheckCounts: (connected: Int, checked: Int)?
    var accountCheckSummary: String? {
        accountCheckCounts.map { text("اتراجع تسجيل الدخول المحلي: \($0.connected) من \($0.checked) حسابات متاحة.", "Local sign-in checked: \($0.connected) of \($0.checked) accounts available.") }
    }
    private var apiKey = ""
    private let store: WorkshopStore
    private let consultLog: ConsultLog
    private let engine: EngineConfiguration

    init(root: URL = Paths.rebuiltRoot(), setupDependencies: SetupCoordinator.Dependencies? = nil) {
        updates = WorkshopUpdates(root: root)
        preferencesSync = PreferencesSyncController(root: root)
        setup = SetupCoordinator(dependencies: setupDependencies ?? .live(root: root))
        store = WorkshopStore(root: root)
        consultLog = ConsultLog(root: root)
        engine = EngineConfiguration(root: root)
        load()
        updates.canBegin = { [weak self] in
            guard let self else { return false }
            return self.loaded && !self.busy && !self.setup.busy && !self.showOnboarding && self.activeWorkCount == 0
        }
    }

    var arabic: Bool { state.arabic }
    var dataDirectory: URL { store.root }
    var roster: RosterView {
        var providers = [Self.preview: Provider(name: text("معاينة محلية", "Local preview"), models: ["checklist"], billing: .local)]
        if let endpoint = state.provider {
            providers[Self.connected] = Provider(name: endpoint.url.host ?? "HTTPS", models: [endpoint.model], billing: .metered)
        }
        for agent in nativeAgents {
            providers[agent.providerID] = Provider(name: agent.label, models: [agent.modelLabel], billing: agent.isNative ? .subscription : .metered)
        }
        return RosterView(advisors: state.advisors, providers: providers)
    }

    func text(_ ar: String, _ en: String) -> String { WorkshopCopy.text(ar, en, arabic: arabic) }
    func name(_ id: String) -> String { roster.providers[id]?.name ?? id }
    func models(_ id: String) -> [String] { roster.providers[id]?.models ?? [] }

    func load() {
        refreshEngine()
        do {
            state = try store.load()
            loaded = true
            showOnboarding = state.onboardingVersion != 2
            setup.team = state.team ?? TeamSettings()
            setup.advisorMode = state.team == nil ? .important : state.advisors.mode
            setup.kimiRegion = state.kimiRegion ?? .global
            problem = nil
        } catch {
            loaded = false
            report(error)
            return
        }
        // History is display data. A damaged or busy work log is reported, but
        // must not leave the workshop unable to save its settings.
        do {
            try consultLog.expireOpen(now: Date())
            let records = try consultLog.load()
            let jobs = try TeamJobLog(root: engine.root).load(limit: nil)
            consults = records.records
            consultsRevision += 1
            teamJobs = jobs.jobs
            noteUnreadable(jobs.unreadable + records.unreadable)
        } catch { report(error) }
    }

    /// Reads the history away from the main thread and applies what changed.
    /// The regular check skips the read while the work log file is unchanged;
    /// `force` always reads.
    func refreshTeamActivity(force: Bool = false) async {
        guard loaded, !refreshingActivity else { return }
        refreshingActivity = true
        defer { refreshingActivity = false }
        let root = engine.root, known = force ? nil : activitySignature, revision = consultsRevision
        let snapshot = await Task.detached(priority: .utility) { TeamActivitySnapshot.read(root: root, known: known) }.value
        if snapshot.activeComparisons != activeComparisons { activeComparisons = snapshot.activeComparisons }
        // Only the last failure is remembered: the same one is shown once, and
        // a successful read lets it be shown again if it comes back.
        if snapshot.failure != lastActivityFailure {
            lastActivityFailure = snapshot.failure
            if let failure = snapshot.failure { problem = failure }
        }
        guard let logs = snapshot.logs else { return }
        for job in logs.jobs where job.finished != nil {
            guard notified.insert(job.id).inserted, let finished = job.finished,
                  finished >= monitoringStarted, state.preferences?.notifications == true else { continue }
            let language = arabic
            Task { await WorkshopNotifications.completed(agent: job.worker, needsReview: job.reviewRequired,
                failed: ["failed", "cancelled"].contains(job.status), arabic: language) }
        }
        if logs.jobs != teamJobs { teamJobs = logs.jobs }
        // A consultation saved here while the read was running is newer than
        // the snapshot; keep it and read again on the next check.
        if revision == consultsRevision {
            if logs.consults != consults { consults = logs.consults }
            activitySignature = logs.signature
        } else { activitySignature = nil }
        noteUnreadable(logs.unreadable)
    }

    private func noteUnreadable(_ count: Int) {
        guard count > 0, !reportedUnreadable else { return }
        reportedUnreadable = true
        problem = text("فيه \(count) سجل محفوظ مش مقروء واتخطّى. باقي السجل سليم.",
                       "\(count) saved history entries could not be read and were skipped. The rest of the history is intact.")
    }

    func startMonitoring() {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard let self else { return }
                await self.refreshTeamActivity()
                self.refreshClientLauncher()
                await self.checkAccountsIfDue()
                await self.preferencesSync.poll(state: self.state, idle: !self.busy && !self.setup.busy && !self.showOnboarding && !self.checkingAccounts && self.activeWorkCount == 0)
            }
        }
    }

    func refreshClientLauncher() {
        guard !launcherChecked, !busy, !setup.busy, let application = Bundle.main.executableURL else { return }
        let launcher = ClientLauncher(root: dataDirectory)
        guard FileManager.default.fileExists(atPath: launcher.url.path), let lease = try? WorkActivityLease(root: dataDirectory) else { return }
        defer { withExtendedLifetime(lease) {} }
        do { try launcher.prepare(application: application); launcherChecked = true }
        catch { launcherChecked = true; report(error) }
    }

    func saveWorkerModel(_ agent: EngineAgent, model: String?) throws {
        guard model.map(OfficialModels.valid) ?? true else { throw FawalyError.invalid("Invalid worker model identifier.") }
        try change {
            var choices = $0.workerModels ?? [:]
            choices[agent.rawValue] = model
            $0.workerModels = choices.isEmpty ? nil : choices
        }
    }

    func stopJob(_ id: UUID) throws { try engine.requestStop(id) }

    func savePreferences(_ preferences: WorkshopPreferences) throws {
        guard preferences.appearance.map({ ["light", "dark"].contains($0) }) ?? true else { throw FawalyError.invalid("Choose a valid workshop appearance.") }
        guard (0...23).contains(preferences.morningHour) else { throw FawalyError.invalid("Choose a valid check hour.") }
        try change { $0.preferences = preferences }
    }

    func importPreferences(_ backup: PreferencesBackup) throws {
        guard backup.appearance.map({ ["light", "dark"].contains($0) }) ?? true else { throw FawalyError.invalid("Invalid appearance in preferences backup.") }
        guard backup.workerModels?.allSatisfy({ EngineAgent(rawValue: $0.key) != nil && OfficialModels.valid($0.value) }) ?? true else { throw FawalyError.invalid("Invalid assistant model preferences.") }
        guard backup.schema == "fawaly.preferences.v1", AdvisorSettings.rounds.contains(backup.advisorRounds), AdvisorSettings.minutes.contains(backup.advisorMinutes), (0...23).contains(backup.morningHour) else { throw FawalyError.invalid("Invalid preferences backup.") }
        var policy = backup.policy
        let workers = state.team?.workers ?? []
        policy.orders = policy.orders.mapValues { order in order.filter { workers.contains($0) } }
        try policy.validate(team: state.team)
        try change {
            $0.arabic = backup.arabic
            $0.advisors.mode = $0.team.map { $0.advisor == nil ? AdvisorMode.off : backup.advisorMode } ?? backup.advisorMode
            $0.advisors.maxRounds = backup.advisorRounds
            $0.advisors.timeoutMinutes = backup.advisorMinutes
            $0.delegationPolicy = policy
            $0.workerModels = backup.workerModels
            var preferences = $0.preferences ?? WorkshopPreferences()
            preferences.morningCheck = backup.morningCheck
            preferences.morningHour = backup.morningHour
            preferences.appearance = backup.appearance
            $0.preferences = preferences
        }
    }

    func checkAccountsIfDue(now: Date = Date()) async {
        let stamp = dataDirectory.appendingPathComponent("last-account-check.json")
        let last = (try? Data(contentsOf: stamp)).flatMap { try? JSONDecoder().decode(Date.self, from: $0) }
        guard (state.preferences ?? WorkshopPreferences()).checkIsDue(now: now, last: last),
              !showOnboarding, !busy, !checkingAccounts, !teamJobs.contains(where: { $0.status == "running" }) else { return }
        try? JSONEncoder().encode(now).write(to: stamp, options: .atomic)
        Task { await checkAccountsNow() }
    }

    func checkAccountsNow() async {
        guard !checkingAccounts, !showOnboarding, !teamJobs.contains(where: { $0.status == "running" }) else { return }
        checkingAccounts = true
        defer { checkingAccounts = false }
        let service = NativeSignIn(configuration: engine)
        var checked = 0, connected = 0
        for agent in EngineAgent.nativeAgents where engine.isReady(agent) {
            do { if try await service.verify(agent) { connected += 1 }; checked += 1 }
            catch is CancellationError { return }
            catch { checked += 1 }
        }
        refreshEngine()
        accountCheckCounts = (connected, checked)
    }


    func refreshEngine() {
        nativeAgents = EngineAgent.allCases.filter(engine.isReady)
    }
    
    func finishOnboarding(previewOnly: Bool) {
        guard !setup.busy, previewOnly || (setup.teamReady && setup.integrationReady) else { return }
        do {
            try change {
                $0.onboardingVersion = 2
                $0.kimiRegion = setup.kimiRegion
                if !previewOnly {
                    $0.team = setup.team
                    $0.advisors.mode = setup.team.advisor == nil ? .off : setup.advisorMode
                }
            }
            refreshEngine()
            showOnboarding = false
        } catch { report(error) }
    }

    func allowProject(_ directory: URL) throws {
        let approved = try engine.allowWorkspace(directory.path)
        try change { $0.projectDirectory = approved }
    }

    func removeProject() throws {
        guard let directory = state.projectDirectory else { return }
        try engine.denyWorkspace(directory.path)
        try change { $0.projectDirectory = nil }
    }

    func restartOnboarding() {
        guard !busy, !setup.busy else { return }
        setup.editingTeam = false
        setup.resetIntegration()
        setup.step = .welcome
        setup.scan()
        showOnboarding = true
    }

    func editTeam() {
        guard !busy, !setup.busy else { return }
        setup.team = state.team ?? TeamSettings()
        setup.advisorMode = state.advisors.mode
        setup.resetIntegration()
        setup.editingTeam = true
        setup.step = .team
        setup.scan()
        setup.verifyConnections()
        showOnboarding = true
    }

    func cancelTeamEdit() {
        guard setup.editingTeam, !setup.busy else { return }
        setup.team = state.team ?? TeamSettings()
        setup.advisorMode = state.advisors.mode
        showOnboarding = false
    }

    func providerDestination(_ provider: String, url: URL?) -> String {
        EngineAgent(provider: provider)?.label ?? url?.absoluteString ?? ""
    }
    
    func report(_ error: Error) { problem = error.localizedDescription }

    private func change(_ update: (inout WorkshopState) -> Void) throws {
        guard loaded else { throw FawalyError.invalid(text("افتح سجل الورشة الأول.", "Load the workshop before saving.")) }
        var next = state
        update(&next)
        try store.save(next)
        state = next
    }

    var cachedOfficialModels: [String] { OfficialModels.codex(root: engine.root) }

    func saveDelegationPolicy(_ policy: DelegationPolicy, advisors: AdvisorSettings) throws {
        try policy.validate(team: state.team)
        guard AdvisorSettings.rounds.contains(advisors.maxRounds), AdvisorSettings.minutes.contains(advisors.timeoutMinutes) else {
            throw FawalyError.invalid("Choose valid advisor rounds and timeout.")
        }
        try change {
            $0.delegationPolicy = policy
            $0.advisors.mode = advisors.mode
            $0.advisors.maxRounds = advisors.maxRounds
            $0.advisors.timeoutMinutes = advisors.timeoutMinutes
        }
    }

    func setArabic(_ value: Bool) {
        do { try change { $0.arabic = value } } catch { report(error) }
    }

    func updateAdvisors(_ edit: (inout AdvisorSettings) -> Void) async throws {
        try change { edit(&$0.advisors) }
    }

    func configure(_ endpoint: EndpointSettings, key: String) throws {
        guard !busy, !key.contains(where: \.isNewline) else { throw FawalyError.invalid("An access key must be on one line.") }
        try change {
            $0.provider = endpoint
            $0.advisors.seats.removeAll { $0.provider == Self.connected && $0.model != endpoint.model }
        }
        apiKey = key
    }

    func disconnect() throws {
        guard !busy else { return }
        try change {
            $0.provider = nil
            $0.advisors.seats.removeAll { $0.provider == Self.connected }
        }
        apiKey = ""
    }

    func addTask(title: String, details: String) throws {
        try TextAdvisor.validate(question: title, context: details)
        try change { $0.work.insert(WorkItem(title: title, details: details), at: 0) }
    }

    func removeTask(_ id: UUID) throws {
        guard !busy else { return }
        try change { $0.work.removeAll { $0.id == id && $0.completed == nil } }
    }

    func runTask(_ id: UUID, provider: String, destination: URL? = nil) async throws {
        guard !busy, let item = state.work.first(where: { $0.id == id && $0.completed == nil }) else { return }
        busy = true
        defer { busy = false }
        let result = try await respond(provider: provider, question: item.title, context: item.details, previous: [], purpose: .task, destination: destination)
        try change {
            guard let index = $0.work.firstIndex(where: { $0.id == id }) else { return }
            $0.work[index].completed = Date()
            $0.work[index].result = ConsultRound.cap(result).0
        }
    }

    func consult(
        provider: String, by: Rater, reason: ConsultReason, question: String, context: String,
        continuing id: UUID? = nil, destination: URL? = nil
    ) async throws {
        guard loaded, !busy, state.advisors.mode != .off,
              state.advisors.mode == .important || reason == .userRequest else {
            throw FawalyError.invalid(text("وضع المستشار الحالي مش سامح بالطلب ده.", "The current advisor mode does not allow this request."))
        }
        try TextAdvisor.validate(question: question, context: context)
        guard let seat = state.advisors.seats.first(where: {
            $0.provider == provider && $0.enabled && models(provider).contains($0.model)
        }) else {
            throw FawalyError.invalid(text("اختار مستشار شغّال من القائمة.", "Choose an enabled advisor from the roster."))
        }
        try consultLog.expireOpen(now: Date())
        let started = Date()
        let original: ConsultRecord?
        var record: ConsultRecord
        if let id {
            guard let existing = try consultLog.get(id), existing.status == .open,
                  existing.provider == provider, existing.model == seat.model,
                  existing.rounds.count < state.advisors.maxRounds else {
                throw FawalyError.invalid(text("الاستشارة دي مش متاحة لجولة تانية.", "This consultation is unavailable for another round."))
            }
            original = existing
            record = existing
        } else {
            original = nil
            record = ConsultRecord(caller: by, reason: reason, provider: provider, model: seat.model,
                                   modeAtStart: state.advisors.mode, question: question, context: context, rounds: [], created: started)
        }
        busy = true
        defer { busy = false }
        let result = try await respond(provider: provider, question: question, context: context, previous: record.rounds, purpose: .consultation, destination: destination)
        let finished = Date()
        record.rounds.append(ConsultRound(index: record.rounds.count + 1, prompt: question, advice: result,
                                         status: "completed", startedAt: started, finishedAt: finished))
        record.updated = finished
        if let original { try consultLog.update(record, replacing: original) } else { try consultLog.insert(record) }
        try refreshConsults()
    }

    func decide(_ id: UUID, decision: ConsultDecision, summary: String) throws {
        guard !busy, summary.utf8.count <= 2_048 else {
            throw FawalyError.invalid(text("الملخص لازم يبقى أقل من ٢ كيلوبايت.", "The summary must be at most 2 KB."))
        }
        try consultLog.expireOpen(now: Date())
        guard let original = try consultLog.get(id), original.status == .open else { try refreshConsults(); return }
        var record = original
        record.status = .closed
        record.decision = decision
        record.summary = summary
        record.updated = Date()
        try consultLog.update(record, replacing: original)
        try refreshConsults()
    }

    private func refreshConsults() throws {
        try consultLog.expireOpen(now: Date())
        consults = try consultLog.recent()
        consultsRevision += 1
    }

    private func respond(
        provider: String, question: String, context: String, previous: [ConsultRound], purpose: TextAdvisor.Purpose, destination: URL?
    ) async throws -> String {
        if provider == Self.preview { return TextAdvisor.demo(question: question, context: context, arabic: arabic) }
        if let agent = EngineAgent(provider: provider) {
                let prompt = purpose == .consultation
                ? EngineBridge.consultationPrompt(question: question, context: context, previous: previous)
                : "Respond to this text task.\n\n\(question)\n\n\(context)"
            return try await AgentWorker(configuration: engine).run(agent, prompt: prompt, timeout: state.advisors.timeoutMinutes * 60)
        }
        guard provider == Self.connected, let endpoint = state.provider, endpoint.url == destination else {
            throw FawalyError.invalid(text("عنوان الخدمة اتغيّر. راجعه قبل الإرسال.", "The service destination changed. Review it before sending."))
        }
        return try await TextAdvisor.send(endpoint: endpoint, key: apiKey, question: question, context: context,
                                          previous: previous, purpose: purpose, timeout: Double(state.advisors.timeoutMinutes * 60))
    }
}
