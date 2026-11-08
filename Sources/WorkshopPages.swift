import SwiftUI

struct PrimaryConnectionPage: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkshopCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.text("ابدأ مهمتك مع فريقك", "Start work with your team")).font(.headline)
                    Text(model.text("افتح الأساسي واكتب مهمتك. قواعدك بتوجّه الاستشارة والتفويض؛ هنا هتتابع شغل الفواعلي ونتايجهم ومراجعة الأساسي.", "Open your primary and give it your task. Your rules guide consultation and delegation; follow worker results and your primary’s review here."))
                    DisclosureGroup(model.text("تفاصيل الربط", "Connection details")) {
                        Text(model.text("ربط MCP محفوظ أثناء الإعداد. توفر الحساب محليًا وحده مش إثبات تنفيذ؛ التقارير وأدلة المراجعة بتظهر في السجل.", "MCP is saved during setup. Local account availability alone does not prove execution; inspect reports and review evidence in the ledger.")).font(.caption)
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
                        Text(model.nativeAgents.contains(agent) ? (agent.isNative ? model.text("تسجيل الدخول متاح محليًا", "Local sign-in available") : model.text("إعداد الخدمة محفوظ ومفعّل", "Service configured and enabled")) : model.text("غير متاح حاليًا", "Currently unavailable"))
                        if !agent.isNative { APIUsageSummary(agent: agent, root: model.dataDirectory, arabic: model.arabic) }
                        Text(model.text("الرصيد والحدود الرسمية غير متاحة عبر هذا الربط. راجع حسابك لدى الخدمة.", "Official balance and limits are unavailable through this connection. Check your provider account.")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
