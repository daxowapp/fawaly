import SwiftUI

struct TeamRoleEditor: View {
    @EnvironmentObject private var model: AppModel
    @Binding var team: TeamSettings
    @Binding var advisorMode: AdvisorMode
    private var selectable: [EngineAgent] {
        let configured = (try? APIAssistantStore(root: model.dataDirectory).all().map(\.agent)) ?? []
        let assigned = model.state.team?.supporters ?? []
        return EngineAgent.nativeAgents + EngineAgent.allCases.filter { !$0.isNative && (configured.contains($0) || assigned.contains($0)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.text("اختار فريقك", "Choose your team")).font(.title2.weight(.semibold))
            Text(model.text("هتكمّل شغلك في تطبيق أجنتك المعتاد. الأساسي يقود الشغل، والمستشار يديله رأي مستقل، والفواعلي ينفّذوا الأجزاء اللي يفوّضها لهم.", "Keep working in your usual agent app. Your primary leads the work, an advisor provides an independent opinion, and workers handle delegated tasks.")).font(.callout).foregroundStyle(.secondary)
            Picker(model.text("الأجنت الأساسي", "Primary agent"), selection: Binding(get: { team.primary }, set: { team.choosePrimary($0) })) {
                ForEach(EngineAgent.primaryAgents, id: \.self) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented)
            Picker(model.text("مستشاره", "Its advisor"), selection: Binding(get: { team.advisor }, set: { value in
                team.advisor = value
                if value != nil && advisorMode == .off { advisorMode = .important }
                team.workers.removeAll { $0 == value }
            })) {
                Text(model.text("من غير مستشار حاليًا", "No advisor for now")).tag(Optional<EngineAgent>.none)
                ForEach(selectable.filter { $0 != team.primary }, id: \.self) { Text($0.label).tag(Optional($0)) }
            }
            if team.advisor != nil {
                Picker(model.text("المستشار يتدخل", "Advisor involvement"), selection: $advisorMode) {
                    Text(model.text("قبل الخطط والقرارات المهمة", "Before plans and important decisions")).tag(AdvisorMode.important)
                    Text(model.text("لما أطلب بس", "Only when I ask")).tag(AdvisorMode.onRequest)
                    Text(model.text("متوقف حاليًا", "Paused for now")).tag(AdvisorMode.off)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(model.text("الفواعلي", "Workers")).font(.headline)
                let available = selectable.filter { $0 != team.primary && $0 != team.advisor }
                if available.isEmpty {
                    Text(model.text("فريقك الحالي أساسي ومستشار. تقدر تغيّر الأدوار في أي وقت.", "Your current team has a primary and an advisor. You can change roles at any time.")).font(.callout).foregroundStyle(.secondary)
                }
                ForEach(available, id: \.self) { agent in
                    Toggle(agent.label, isOn: Binding(get: { team.workers.contains(agent) }, set: { selected in
                        team.workers.removeAll { $0 == agent }
                        if selected { team.workers.append(agent) }
                    }))
                }
            }
        }
    }
}
