import SwiftUI

struct DelegationRulesPage<Header: View>: View {
    let header: Header
    @EnvironmentObject private var model: AppModel
    @State private var policy = DelegationPolicy()
    @State private var advisors = AdvisorSettings()
    @State private var selectedKind = DelegationPolicy.Kind.general
    @State private var saved = false
    @State private var showLimits = false

    private var hasChanges: Bool {
        policy != (model.state.delegationPolicy ?? DelegationPolicy()) ||
        advisors.mode != model.state.advisors.mode ||
        advisors.maxRounds != model.state.advisors.maxRounds ||
        advisors.timeoutMinutes != model.state.advisors.timeoutMinutes
    }

    private var workers: [EngineAgent] {
        model.state.team.map { policy.workers(kind: selectedKind.rawValue, team: $0) } ?? []
    }

    private var workerNames: String {
        let assigned = model.state.team?.workers ?? []
        return assigned.isEmpty ? model.text("لسه مفيش مساعدين", "No workers yet") : assigned.map(\.label).joined(separator: " · ")
    }

    var body: some View {
        GeometryReader { geometry in
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    teamOverview
                    if geometry.size.width >= 760 {
                        HStack(alignment: .top, spacing: 16) {
                            advisorCard.frame(width: 280)
                            workerCard.frame(maxWidth: .infinity)
                        }
                    } else {
                        VStack(spacing: 16) { advisorCard; workerCard }
                    }
                }.padding(28)
            }
            Divider()
            saveBar.padding(.horizontal, 24).padding(.vertical, 12).background(.bar)
        }
        }
        .onAppear(perform: loadSavedRules)
        .onChange(of: model.state.team) { _, _ in loadSavedRules() }
        .onChange(of: policy) { _, _ in saved = false }
        .onChange(of: advisors) { _, _ in saved = false }
    }

    private var teamOverview: some View {
        WorkshopCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(model.text("فريقك، بطريقتك", "Your team, your way"), systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.headline)
                    Spacer()
                    Button(model.text("تعديل الفريق", "Edit team")) { model.editTeam() }
                        .disabled(!model.loaded || model.busy)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: 3), alignment: .leading, spacing: 12) {
                    roleSummary(model.text("الوكيل الرئيسي", "Primary agent"),
                                value: model.state.team?.primary.label ?? model.text("غير محدد", "Not assigned"),
                                detail: model.text("يخطّط ويراجع النتيجة", "Plans and reviews the result"), icon: "person.crop.circle.badge.checkmark")
                    roleSummary(model.text("المستشار", "Advisor"),
                                value: model.state.team?.advisor?.label ?? model.text("غير محدد", "Not assigned"),
                                detail: model.text("رأي مستقل قبل القرار", "An independent second opinion"), icon: "bubble.left.and.bubble.right")
                    roleSummary(model.text("الفواعلي", "Workers"),
                                value: workerNames,
                                detail: model.text("ينفّذوا المهام المفوّضة", "Carry out delegated tasks"), icon: "hammer")
                }
            }
        }
    }

    private func roleSummary(_ title: String, value: String, detail: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(12).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private var advisorCard: some View {
        WorkshopCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionTitle(model.text("إمتى يستشير؟", "When to consult"), icon: "bubble.left.and.bubble.right")
                Text(model.text("حدّد متى يرجع الأساسي للمستشار قبل ما يكمل شغله.", "Choose when your primary asks the advisor for a second opinion."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.state.team?.advisor == nil {
                    Label(model.text("عيّن مستشار من تعديل الفريق لتفعيل الاستشارة.", "Assign an advisor in Edit team to use consultation."), systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach([AdvisorMode.important, .onRequest, .off], id: \.self) { mode in
                    advisorChoice(mode)
                }
                DisclosureGroup(isExpanded: $showLimits) {
                    VStack(alignment: .leading, spacing: 12) {
                        Stepper(value: $advisors.maxRounds, in: AdvisorSettings.rounds) {
                            Text(model.text("حد الجولات: \(advisors.maxRounds)", "Round limit: \(advisors.maxRounds)"))
                        }
                        Stepper(value: $advisors.timeoutMinutes, in: AdvisorSettings.minutes) {
                            Text(model.text("مهلة الاستشارة: \(advisors.timeoutMinutes) د", "Consultation timeout: \(advisors.timeoutMinutes) min"))
                        }
                    }.font(.callout).padding(.top, 10).disabled(advisors.mode == .off)
                } label: {
                    Text(model.text("حدود الاستشارة", "Consultation limits")).font(.callout.weight(.medium))
                }
            }
        }
    }

    private func advisorChoice(_ mode: AdvisorMode) -> some View {
        let selected = advisors.mode == mode
        return Button { advisors.mode = mode } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Workshop.yellow : .secondary).font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(modeTitle(mode)).font(.callout.weight(.semibold))
                    Text(modeDetail(mode)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Workshop.yellow.opacity(0.1) : .primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Workshop.yellow.opacity(0.85) : .primary.opacity(0.08)))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
            .accessibilityLabel(modeTitle(mode)).accessibilityValue(selected ? model.text("مختار", "Selected") : "")
            .accessibilityHint(modeDetail(mode)).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var workerCard: some View {
        WorkshopCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionTitle(model.text("الفواعلي الرئيسي ومساعدينه", "Lead worker & assistants"), icon: "list.number")
                Text(model.text("اختار لكل نوع شغل مساعد أول يشيل أغلب التنفيذ المفوّض، ورتّب باقي المساعدين بعده.", "Choose a lead for each task type to handle most delegated work, then order the other assistants."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker(model.text("نوع المهمة", "Task type"), selection: $selectedKind) {
                    ForEach(DelegationPolicy.Kind.allCases, id: \.self) { kind in
                        Text(kindTitle(kind)).tag(kind)
                    }
                }.pickerStyle(.segmented)
                if workers.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "person.2.badge.plus").font(.largeTitle).foregroundStyle(.secondary)
                        Text(model.text("ضيف مساعد، وابدأ التفويض", "Add a worker to start delegating")).font(.headline)
                        Text(model.text("اختار المساعدين من إعداد الفريق، وبعدها رتّبهم هنا.", "Assign workers in team setup, then arrange them here."))
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button(model.text("إعداد الفريق", "Set up team")) { model.editTeam() }.disabled(model.busy || !model.loaded)
                    }.frame(maxWidth: .infinity).padding(.vertical, 20)
                } else {
                    leadWorkerPicker
                    VStack(spacing: 8) {
                        ForEach(Array(workers.enumerated()), id: \.element) { index, worker in
                            workerRow(worker, index: index)
                        }
                    }
                    if workers.count > 1 {
                        Button(model.text("استخدم ترتيب الفريق الأصلي", "Use the team’s original order")) {
                            policy.orders.removeValue(forKey: selectedKind.rawValue)
                        }.font(.caption)
                            .disabled(policy.orders[selectedKind.rawValue]?.isEmpty != false)
                    }
                }
                Divider()
                Stepper(value: Binding(get: { max(1, policy.timeoutSeconds / 60) }, set: { policy.timeoutSeconds = $0 * 60 }), in: 1...60) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.text("مهلة التنفيذ: \(max(1, policy.timeoutSeconds / 60)) دقيقة", "Worker timeout: \(max(1, policy.timeoutSeconds / 60)) min"))
                            .font(.callout.weight(.medium))
                        Text(model.text("لكل مهمة، في كل أنواع الشغل", "Per task, across all task types")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel(model.text("مهلة تنفيذ العامل بالدقائق", "Worker timeout in minutes"))
                Label(model.text("الأساسي يتبع أول مساعد متاح في الترتيب، ويراجع النتيجة بنفسه.", "Your primary follows the order to the first available worker and reviews the result itself."), systemImage: "checkmark.shield")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(model.text("بعد فشل التنفيذ، مفيش إعادة محاولة أو تحويل مدفوع تلقائي.", "Execution failures do not trigger an automatic retry or paid fallback."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var leadWorkerPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.text("الفواعلي الرئيسي", "Lead worker"), systemImage: "star.circle.fill")
                .font(.callout.weight(.semibold))
            Picker(model.text("المساعد الأول لـ\(kindTitle(selectedKind))", "First worker for \(kindTitle(selectedKind))"), selection: Binding(
                get: { workers.first ?? .kimi },
                set: { chosen in
                    var order = workers
                    guard order.contains(chosen) else { return }
                    order.removeAll { $0 == chosen }
                    order.insert(chosen, at: 0)
                    policy.orders[selectedKind.rawValue] = order
                }
            )) {
                ForEach(workers, id: \.self) { Text($0.label).tag($0) }
            }.labelsHidden().frame(maxWidth: .infinity)
            Text(model.text("يبدأ المهام الجديدة لما يكون متاح. الباقي يستلموا حسب الترتيب أو لما الوكيل الرئيسي يكلّفهم بالاسم.", "Starts new tasks when available. Others are selected in order or explicitly by your primary agent."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(12).background(Workshop.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private func workerRow(_ worker: EngineAgent, index: Int) -> some View {
        HStack(spacing: 10) {
            Text("\(index + 1)").font(.callout.weight(.bold).monospacedDigit())
                .frame(width: 30, height: 30)
                .background(index == 0 ? Workshop.yellow.opacity(0.3) : .primary.opacity(0.055), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(worker.label).font(.callout.weight(.semibold)).environment(\.layoutDirection, .leftToRight)
                if index == 0 {
                    Text(model.text("الأولوية الأولى", "First choice")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                moveButton(worker, index: index, delta: -1)
                moveButton(worker, index: index, delta: 1)
            }
        }.padding(10).background(index == 0 ? Workshop.yellow.opacity(0.08) : .primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
    }

    private func moveButton(_ worker: EngineAgent, index: Int, delta: Int) -> some View {
        Button { move(worker, by: delta) } label: {
            Image(systemName: delta < 0 ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.semibold)).frame(width: 24, height: 26).contentShape(Rectangle())
        }.buttonStyle(.bordered)
            .disabled(!workers.indices.contains(index + delta))
            .help(delta < 0 ? model.text("قدّم \(worker.label)", "Move \(worker.label) earlier") : model.text("أخّر \(worker.label)", "Move \(worker.label) later"))
            .accessibilityLabel(delta < 0 ? model.text("قدّم \(worker.label) في \(kindTitle(selectedKind))", "Move \(worker.label) earlier for \(kindTitle(selectedKind))") : model.text("أخّر \(worker.label) في \(kindTitle(selectedKind))", "Move \(worker.label) later for \(kindTitle(selectedKind))"))
    }

    private var saveBar: some View {
        WorkshopCard {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { saveStatus; Spacer(minLength: 0); saveActions }
                VStack(alignment: .leading, spacing: 12) { saveStatus; saveActions }
            }
        }
    }

    private var saveStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(hasChanges ? model.text("فيه تغييرات لسه متحفظتش", "You have unsaved changes") : saved ? model.text("تم حفظ القواعد", "Rules saved") : model.text("القواعد الحالية محفوظة", "Current rules are saved"), systemImage: hasChanges ? "circle.dotted" : "checkmark.circle.fill")
                .font(.callout.weight(.semibold))
            Text(model.text("التغييرات للمهام الجديدة. الوكيل الرئيسي يخطّط ويراجع.", "Applies to new tasks. Your primary agent plans and reviews."))
                .font(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }

    private var saveActions: some View {
        HStack(spacing: 10) {
            if hasChanges {
                Button(model.text("تراجع عن التغييرات", "Discard changes"), action: loadSavedRules)
                    .disabled(model.busy)
            }
            Button(model.text("حفظ القواعد", "Save rules")) {
                do { try model.saveDelegationPolicy(policy, advisors: advisors); saved = true }
                catch { model.report(error) }
            }.buttonStyle(WorkshopPrimaryButtonStyle()).disabled(!model.loaded || model.busy || !hasChanges)
        }
    }

    private func sectionTitle(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).font(.headline).accessibilityAddTraits(.isHeader)
    }

    private func loadSavedRules() {
        policy = model.state.delegationPolicy ?? DelegationPolicy()
        advisors = model.state.advisors
        saved = false
    }

    private func modeTitle(_ mode: AdvisorMode) -> String {
        switch mode {
        case .important: model.text("في القرارات المهمة", "At important decisions")
        case .onRequest: model.text("لما أطلب منه", "When I ask")
        case .off: model.text("بدون استشارة", "Consultation off")
        }
    }

    private func modeDetail(_ mode: AdvisorMode) -> String {
        switch mode {
        case .important: model.text("قبل اعتماد خطة أو قرار مؤثر.", "Before committing to a plan or significant decision.")
        case .onRequest: model.text("يستشير بس لما تطلب رأي تاني.", "Get advice only when you request a second opinion.")
        case .off: model.text("الأساسي يكمل من غير الرجوع للمستشار.", "Your primary continues without consulting the advisor.")
        }
    }

    private func kindTitle(_ kind: DelegationPolicy.Kind) -> String {
        switch kind {
        case .general: model.text("عام", "General")
        case .code: model.text("برمجة", "Code")
        case .research: model.text("بحث", "Research")
        case .review: model.text("مراجعة", "Review")
        }
    }

    private func move(_ worker: EngineAgent, by delta: Int) {
        var order = workers
        guard let index = order.firstIndex(of: worker), order.indices.contains(index + delta) else { return }
        order.swapAt(index, index + delta)
        policy.orders[selectedKind.rawValue] = order
    }
}
