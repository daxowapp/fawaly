import SwiftUI

struct DelegationRulesPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var policy = DelegationPolicy()
    @State private var advisors = AdvisorSettings()
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkshopCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.text("المستشار المستقل", "Independent advisor")).font(.headline)
                    Picker(model.text("متى يستشير الأساسي؟", "When should the primary consult?"), selection: $advisors.mode) {
                        Text(model.text("متوقف", "Off")).tag(AdvisorMode.off)
                        Text(model.text("عند الطلب", "On request")).tag(AdvisorMode.onRequest)
                        Text(model.text("القرارات المهمة", "Important decisions")).tag(AdvisorMode.important)
                    }
                    Stepper(model.text("الجولات: \(advisors.maxRounds)", "Rounds: \(advisors.maxRounds)"), value: $advisors.maxRounds, in: AdvisorSettings.rounds)
                    Stepper(model.text("مهلة المستشار بالدقائق: \(advisors.timeoutMinutes)", "Advisor timeout in minutes: \(advisors.timeoutMinutes)"), value: $advisors.timeoutMinutes, in: AdvisorSettings.minutes)
                }
            }
            WorkshopCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.text("طابور التنفيذ", "Execution queue")).font(.headline)
                    Text(model.text("يُختار أول عامل متاح بالترتيب. لا تحويل مدفوع تلقائي ولا إعادة تنفيذ تلقائية بعد الفشل.", "The first available worker is selected in order. No automatic paid fallback or retry after failure."))
                    Stepper(model.text("مهلة العامل بالدقائق: \(max(1, policy.timeoutSeconds / 60))", "Worker timeout in minutes: \(max(1, policy.timeoutSeconds / 60))"), value: Binding(get: { max(1, policy.timeoutSeconds / 60) }, set: { policy.timeoutSeconds = $0 * 60 }), in: 1...60)
                    ForEach(DelegationPolicy.Kind.allCases, id: \.self) { kind in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(kindTitle(kind)).font(.subheadline.bold())
                            let workers = model.state.team.map { policy.workers(kind: kind.rawValue, team: $0) } ?? []
                            if workers.isEmpty { Text(model.text("اختار العمال من إعداد الفريق.", "Choose workers in team setup.")).foregroundStyle(.secondary) }
                            ForEach(Array(workers.enumerated()), id: \.element) { index, worker in
                                HStack {
                                    Text("\(index + 1). \(worker.label)")
                                    Spacer()
                                    Button { move(worker, in: kind, by: -1) } label: { Image(systemName: "arrow.up") }
                                        .disabled(index == 0).accessibilityLabel(model.text("قدّم \(worker.label)", "Move \(worker.label) earlier"))
                                    Button { move(worker, in: kind, by: 1) } label: { Image(systemName: "arrow.down") }
                                        .disabled(index == workers.count - 1).accessibilityLabel(model.text("أخّر \(worker.label)", "Move \(worker.label) later"))
                                }
                            }
                        }
                    }
                    Text(model.text("الأساسي يختار نوع الشغل ويتبع الترتيب المناسب. القواعد الجديدة تُطبق على المهام الجديدة.", "Your primary chooses the task type and follows its worker order. Changes apply to new tasks.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(model.text("حفظ القواعد", "Save rules")) {
                    do { try model.saveDelegationPolicy(policy, advisors: advisors); saved = true } catch { model.report(error) }
                }.buttonStyle(WorkshopPrimaryButtonStyle()).disabled(!model.loaded || model.busy)
                if saved { Text(model.text("اتحفظت. تُطبق على الطلبات الجديدة.", "Saved. Applies to new requests.")).font(.caption) }
            }
        }
        .onAppear { policy = model.state.delegationPolicy ?? DelegationPolicy(); advisors = model.state.advisors }
        .onChange(of: policy) { _, _ in saved = false }
        .onChange(of: advisors) { _, _ in saved = false }
    }

    private func kindTitle(_ kind: DelegationPolicy.Kind) -> String {
        switch kind {
        case .general: model.text("عام", "General")
        case .code: model.text("برمجة", "Code")
        case .research: model.text("بحث", "Research")
        case .review: model.text("مراجعة", "Review")
        }
    }
    private func move(_ worker: EngineAgent, in kind: DelegationPolicy.Kind, by delta: Int) {
        guard let team = model.state.team else { return }
        var order = policy.workers(kind: kind.rawValue, team: team)
        guard let index = order.firstIndex(of: worker), order.indices.contains(index + delta) else { return }
        order.swapAt(index, index + delta)
        policy.orders[kind.rawValue] = order
    }
}

struct PrimaryConnectionPage: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkshopCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.text("الربط ليس إثبات تنفيذ", "Connection is separate from execution")).font(.headline)
                    Text(model.text("إعداد MCP محفوظ أثناء الإعداد. ظهور الحساب كمتاح لا يثبت تشغيل مهمة. افتح الأساسي واكتب مهمتك؛ قواعد الفريق بتوجّه الاستشارة والتفويض. راجع تقرير العامل ثم قرار الأساسي في سجل المهام والمراجعات.", "MCP is saved during setup. An available account does not prove a task ran. Open your primary and give it your task. Team rules guide consultation and delegation; inspect the worker report and primary decision in Tasks & reviews."))
                    DisclosureGroup(model.text("تفاصيل الربط", "Connection details")) {
                        Text("roster_get · delegate · consult · consult_decide · review · stop").font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Button(model.text("إعداد الربط والفريق…", "Configure connection and team…")) { model.editTeam() }.disabled(model.busy)
                }
            }
            if let team = model.state.team { TeamHomeView(team: team) }
        }
    }
}

struct UsagePage: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkshopCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.text("النشاط المحلي", "Local activity")).font(.headline)
                    Text(model.text("مهام الفريق المحفوظة: \(model.teamJobs.count) · مراجعات الأساسي: \(model.teamJobs.reduce(0) { $0 + ($1.reviews?.count ?? 0) })", "Saved team tasks: \(model.teamJobs.count) · Primary reviews: \(model.teamJobs.reduce(0) { $0 + ($1.reviews?.count ?? 0) })"))
                    Text(model.text("مهام محلية: \(model.state.work.count) · استشارات محفوظة: \(model.consults.count)", "Local tasks: \(model.state.work.count) · Saved consultations: \(model.consults.count)"))
                    Text(model.text("تشمل أعداد الفريق كل السجلات المحلية، والاستشارات أحدث ٥٠ سجلًا. هذه أعداد نشاط وليست قياسًا للتوكنز أو التكلفة أو التوفير.", "Team counts include all local records; consultations include the latest 50 records. These are activity counts, not token, cost or savings measurements.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(EngineAgent.allCases, id: \.self) { agent in
                WorkshopCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(agent.label).font(.headline)
                        Text(model.nativeAgents.contains(agent) ? model.text("تسجيل الدخول متاح محليًا", "Local sign-in available") : model.text("لم يُؤكد تسجيل الدخول محليًا", "Local sign-in not confirmed"))
                        Text(model.text("الرصيد والحدود الرسمية غير متاحة عبر هذا الربط. راجع حسابك لدى الخدمة.", "Official balance and limits are unavailable through this connection. Check your provider account.")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
