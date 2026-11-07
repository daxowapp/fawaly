import SwiftUI

struct APIUsageSummary: View {
    let agent: EngineAgent
    let root: URL
    let arabic: Bool
    @State private var totals: APIUsage.Totals?
    @State private var profile: APIAssistant?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let totals, let profile {
                Text(arabic ? "طلبات النهارده (UTC): \(totals.requests) / \(profile.dailyRequestLimit)" : "API attempts today (UTC): \(totals.requests) / \(profile.dailyRequestLimit)")
                if totals.reports > 0 {
                    Text(arabic ? "توكنز مُبلّغ عنها في \(totals.reports) ردود: دخول \(totals.input) · خروج \(totals.output)" : "Tokens reported in \(totals.reports) responses: input \(totals.input) · output \(totals.output)").font(.caption)
                } else {
                    Text(arabic ? "لم تصل بيانات توكنز كاملة من الخدمة." : "No complete token-usage data was reported.").font(.caption)
                }
                Text(arabic ? "ده حد طلبات محلي. الطلب الفاشل بيتحسب احتياطيًا، وبعض الردود لا تتضمن بيانات توكنز. مش قياسًا لكل استخدام حسابك أو لفاتورته." : "This is a local request cap. Failed attempts count conservatively; some responses omit token usage. It does not measure your entire account usage or bill.").font(.caption).foregroundStyle(.secondary)
            }
        }.task {
            profile = try? APIAssistantStore(root: root).load(agent)
            totals = try? APIUsage(root: root).totals(agent)
        }
    }
}
