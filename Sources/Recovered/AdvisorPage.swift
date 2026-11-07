import SwiftUI

enum AdvisorCopy {
    static func mode(_ mode: AdvisorMode, arabic: Bool) -> String {
        switch mode {
        case .off: arabic ? "مقفول" : "Off"
        case .onRequest: arabic ? "لما أطلب بس" : "Only when I ask"
        case .important: arabic ? "القرارات المهمة" : "Important decisions"
        }
    }
    static func modeDetail(_ mode: AdvisorMode, arabic: Bool) -> String {
        switch mode {
        case .off: arabic ? "الاستشارات مقفولة." : "Consultations are disabled."
        case .onRequest: arabic ? "الاستشارات اللي سببها «بطلبك» هي اللي مسموح بيها." : "Only requests marked “You asked” are allowed."
        case .important: arabic ? "تقدر تسجّل إن الاستشارة قبل خطة أو تغيير خطير أو بسبب خلاف على مراجعة." : "You can also label a request as a plan, a risky change, or a disputed review."
        }
    }
    static func reason(_ reason: ConsultReason, arabic: Bool) -> String {
        switch reason {
        case .userRequest: arabic ? "بطلبك" : "You asked"
        case .plan: arabic ? "قبل خطة" : "Before a plan"
        case .riskyChange: arabic ? "تغيير خطير" : "Risky change"
        case .disputedReview: arabic ? "مراجعة عليها خلاف" : "Disputed review"
        }
    }
    static func decision(_ decision: ConsultDecision, arabic: Bool) -> String {
        switch decision {
        case .adopted: arabic ? "أخد بالنصيحة" : "Advice adopted"
        case .partly: arabic ? "أخد بجزء منها" : "Partly adopted"
        case .rejected: arabic ? "ما أخدش بيها" : "Advice rejected"
        }
    }
    static func status(_ status: ConsultStatus, arabic: Bool) -> String {
        switch status {
        case .open: arabic ? "مستني قرار" : "Waiting for decision"
        case .closed: arabic ? "اتقفلت" : "Closed"
        case .noDecision: arabic ? "ما اتسجّلش قرار" : "No decision recorded"
        }
    }
    static func round(_ status: String, arabic: Bool) -> String {
        switch status {
        case "completed": arabic ? "رد" : "Answered"
        case "stopped": arabic ? "اتوقف" : "Stopped"
        case "timeout": arabic ? "خلص الوقت" : "Timed out"
        case "credential_cleanup_failed": arabic ? "فولدر الإعداد ما اتمسحش" : "Config folder not deleted"
        default: arabic ? "ما ردش" : "No answer"
        }
    }

}

struct AdvisorPage: View {
    @EnvironmentObject var model: AppModel
    @State private var addingSeat = false
    @State private var expanded: Set<UUID> = []
    @State private var issue: String?
    private var settings: AdvisorSettings { model.roster.advisors }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack { SectionHeader(title: AppPage.advisor.title(model.arabic), subtitle: model.state.team == nil ? model.text("اطلب رأي تاني في السؤال والسياق اللي تكتبهم هنا.", "Ask for a second opinion on the question and context you enter here.") : model.text("تابع الاستشارات والقرارات بين الأساسي ومستشاره.", "Follow consultations and decisions between your primary and its advisor."), ar: model.arabic, page: .advisor); Spacer() }
                if let issue { Text(issue).font(.caption).foregroundStyle(.orange) }
                if let team = model.state.team {
                    WorkshopCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.text("مستشار الأجنت الأساسي", "Your primary’s advisor")).font(.headline)
                            Text(team.primary.label + " ← " + (team.advisor?.label ?? model.text("من غير مستشار", "No advisor")))
                            Text(model.text("اطلب الاستشارة من الأجنت الأساسي في تطبيقه. هنا تتابع الردود والجولات والقرار اللي أخده.", "Ask for advice through your primary in its usual app. Follow the responses, rounds, and decisions here.")).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    modeCard
                    consultationsCard
                    DisclosureGroup(model.text("اختبار استشارة يدويًا", "Test a consultation manually")) {
                        ConsultationComposer()
                        seatsCard
                    }
                } else {
                    ConsultationComposer()
                    modeCard
                    seatsCard
                    consultationsCard
                }
            }.padding(28)
        }
        .sheet(isPresented: $addingSeat) { AdvisorSeatSheet().environmentObject(model) }
    }
    private func run(_ work: @escaping () async throws -> Void) {
        Task { do { try await work(); issue = nil } catch { issue = model.text("التغيير ما اتحفظش. لو الإعدادات اتغيّرت، حدّث الورشة وجرّب تاني.", "The change was not saved. If settings changed, refresh the workshop and retry.") } }
    }
    private var modeCard: some View {
        WorkshopCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.text("إمتى يستشير؟", "When to consult")).font(.headline)
                Picker(model.text("الوضع", "Mode"), selection: Binding(get: { settings.mode }, set: { mode in run { try await model.updateAdvisors { $0.mode = mode } } })) {
                    ForEach(AdvisorMode.allCases, id: \.self) { Text(AdvisorCopy.mode($0, arabic: model.arabic)).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().disabled(!model.loaded || model.busy)
                Text(AdvisorCopy.modeDetail(settings.mode, arabic: model.arabic)).font(.callout)
                Stepper(model.text("أقصى عدد جولات نقاش: \(settings.maxRounds)", "Discussion rounds at most: \(settings.maxRounds)"), value: Binding(get: { settings.maxRounds }, set: { n in run { try await model.updateAdvisors { $0.maxRounds = n } } }), in: AdvisorSettings.rounds)
                Stepper(model.text("مهلة كل جولة: \(settings.timeoutMinutes) دقيقة", "Time per round: \(settings.timeoutMinutes) min"), value: Binding(get: { settings.timeoutMinutes }, set: { n in run { try await model.updateAdvisors { $0.timeoutMinutes = n } } }), in: AdvisorSettings.minutes)
                Text(model.text("المعاينة بتشتغل محليًا. إرسال استشارة لخدمة متصلة يحتاج تأكيدك.", "Local previews run on this Mac. Sending a consultation to a connected service requires your confirmation.")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var seatsCard: some View {
        WorkshopCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(model.text("المستشارين بالترتيب", "Advisors in order")).font(.headline); Spacer()
                    Button { addingSeat = true } label: { Label(model.text("أضف مستشار…", "Add advisor…"), systemImage: "plus") }.disabled(!model.loaded || model.busy)
                }
                Text(model.text("اختار مستشار شغّال من القائمة قبل ما تبدأ الاستشارة.", "Choose an enabled advisor from this list when you start a consultation.")).font(.caption).foregroundStyle(.secondary)
                if settings.seats.isEmpty { Text(model.text("لسه مفيش مستشار.", "No advisor yet.")).foregroundStyle(.secondary) }
                ForEach(Array(settings.seats.enumerated()), id: \.offset) { index, seat in
                    HStack(spacing: 10) {
                        Text(String(format: "%02d", index + 1)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        WorkerAvatar(id: seat.provider, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.name(seat.provider)).font(.headline)
                            Text(seat.model + (model.roster.providers[seat.provider]?.billing == .metered ? model.text(" · مدفوع — بالطلب بس", " · metered — explicit only") : "")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle(model.text("شغّال", "On"), isOn: Binding(get: { seat.enabled }, set: { on in run { try await model.updateAdvisors { if $0.seats.indices.contains(index) { $0.seats[index].enabled = on } } } })).toggleStyle(.switch).labelsHidden()
                        Button { run { try await model.updateAdvisors { if index > 0, $0.seats.indices.contains(index) { $0.seats.swapAt(index, index - 1) } } } } label: { Image(systemName: "chevron.up") }.disabled(index == 0).accessibilityLabel(model.text("قدّمه", "Move up"))
                        Button { run { try await model.updateAdvisors { if $0.seats.indices.contains(index + 1) { $0.seats.swapAt(index, index + 1) } } } } label: { Image(systemName: "chevron.down") }.disabled(index == settings.seats.count - 1).accessibilityLabel(model.text("أخّره", "Move down"))
                        Button(role: .destructive) { run { try await model.updateAdvisors { if $0.seats.indices.contains(index) { $0.seats.remove(at: index) } } } } label: { Image(systemName: "trash") }.accessibilityLabel(model.text("شيله", "Remove"))
                    }.buttonStyle(.borderless)
                }
            }
        }
    }
    private var consultationsCard: some View {
        WorkshopCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.text("الاستشارات", "Consultations")).font(.headline)
                if model.consults.isEmpty { Text(model.text("لسه مفيش استشارة. ابدأ من نموذج الاستشارة فوق.", "No consultations yet. Start one using the form above.")).font(.callout).foregroundStyle(.secondary) }
                ForEach(model.consults) { consult in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            WorkerAvatar(id: consult.provider, size: 24)
                            Text(consult.question).font(.subheadline).lineLimit(expanded.contains(consult.id) ? nil : 2)
                            Spacer()
                            Button { if expanded.contains(consult.id) { expanded.remove(consult.id) } else { expanded.insert(consult.id) } } label: { Image(systemName: expanded.contains(consult.id) ? "chevron.up" : "chevron.down") }.buttonStyle(.borderless)
                        }
                        Text([consult.caller.rawValue, AdvisorCopy.reason(consult.reason, arabic: model.arabic), model.name(consult.provider) + " · " + consult.model, model.text("\(consult.rounds.count) جولة", "\(consult.rounds.count) round(s)"), consult.decision.map { AdvisorCopy.decision($0, arabic: model.arabic) } ?? AdvisorCopy.status(consult.status, arabic: model.arabic)].joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        if expanded.contains(consult.id) {
                            ForEach(consult.rounds, id: \.index) { round in
                                VStack(alignment: .leading, spacing: 4) {
                                    if round.index > 1 { Text(model.text("الوكيل: ", "Agent: ") + round.prompt).font(.caption) }
                                    Text(model.text("المستشار (\(AdvisorCopy.round(round.status, arabic: true))): ", "Advisor (\(AdvisorCopy.round(round.status, arabic: false))): ") + (round.advice.isEmpty ? "—" : round.advice)).font(.caption).textSelection(.enabled)
                                    if let note = round.note { Text(note).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                                }.padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Workshop.yellow.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            }
                            if consult.status == .open { ConsultationActions(record: consult) }
                            if let summary = consult.summary { Text(model.text("القرار: ", "Decision: ") + summary).font(.caption.bold()) }
                        }
                    }
                    Divider()
                }
            }
        }
    }
}

struct AdvisorSeatSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var provider = ""
    @State private var selectedModel = ""
    @State private var saving = false
    @State private var issue: String?
    private var models: [String] { model.models(provider) }
    func needsSetup(_ id: String) -> Bool { model.models(id).isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.text("أضف مستشار", "Add an advisor")).font(Workshop.heading(28, ar: model.arabic))
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.roster.providers.keys.sorted(), id: \.self) { id in
                        Button { provider = id; selectedModel = models.first ?? "" } label: {
                            HStack {
                                WorkerAvatar(id: id, size: 30); Text(model.name(id)).font(.headline); Spacer()
                                Text(model.roster.providers[id]?.billing == .metered ? model.text("مدفوع — بالطلب بس", "Metered — explicit only") : model.roster.providers[id]?.billing == .local ? model.text("محلي", "Local") : model.text("اشتراك", "Subscription")).font(.caption).foregroundStyle(.secondary)
                                Image(systemName: provider == id ? "checkmark.circle.fill" : "circle").foregroundStyle(provider == id ? Workshop.yellow : .secondary)
                            }.padding(10).contentShape(Rectangle()).background(Workshop.card, in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain)
                    }
                    if !provider.isEmpty {
                        if needsSetup(provider) || models.isEmpty {
                            Text(model.text("المساعد ده محتاج ربط أو موديل متاح قبل ما يبقى مستشار.", "Connect this service and choose an available model before making it an advisor.")).font(.callout).foregroundStyle(.orange)
                            Button(model.text("كمّل ربط \(model.name(provider))…", "Set up \(model.name(provider))…")) { dismiss(); model.showProviderSheet = true }
                        } else {
                            Picker(model.text("الموديل", "Model"), selection: $selectedModel) { ForEach(models, id: \.self) { Text($0).tag($0) } }
                        }
                    }
                    Divider()
                    Button(model.text("اربط خدمة جديدة…", "Connect another service…")) { dismiss(); model.showProviderSheet = true }
                }
            }
            if let issue { Text(issue).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button(model.text("إلغاء", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                Button(model.text("أضفه", "Add")) {
                    saving = true
                    Task {
                        do { let seat = AdvisorSeat(provider: provider, model: selectedModel); try await model.updateAdvisors { if !$0.seats.contains(where: { $0.provider == seat.provider && $0.model == seat.model }) { $0.seats.append(seat) } }; dismiss() }
                        catch { issue = model.text("ما اتحفظش. جرّب تاني.", "Not saved. Try again.") }
                        saving = false
                    }
                }.buttonStyle(WorkshopPrimaryButtonStyle()).disabled(provider.isEmpty || selectedModel.isEmpty || needsSetup(provider) || !models.contains(selectedModel) || saving || model.busy)
            }
        }.padding(24).frame(width: 600, height: 600).interactiveDismissDisabled(saving)
            .environment(\.layoutDirection, model.arabic ? .rightToLeft : .leftToRight)
    }
}
