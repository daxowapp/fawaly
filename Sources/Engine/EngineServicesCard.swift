import SwiftUI

struct EngineServicesCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var profiles: [APIAssistant] = []
    @State private var editing: EngineAgent?
    @State private var feedback: String?

    var body: some View {
        VStack(spacing: 16) {
            EngineConnections(setup: model.setup, profiles: profiles, feedback: feedback) { editing = $0 }
            APIServicesView(configured: Set(profiles.map(\.agent))) { editing = $0 }
        }
        .onAppear(perform: reload)
        .sheet(item: $editing) { agent in
            APIServiceEditor(agent: agent, root: model.dataDirectory, arabic: model.arabic) { saved in
                reload(); model.refreshEngine(); model.setup.scan()
                feedback = saved
                    ? model.text("اتحفظ \(agent.label) وظهر في حساباتك. تقدر تعيّنه من إعداد الفريق.", "\(agent.label) is saved in Your accounts. Assign it from Team setup.")
                    : model.text("اتشال ربط \(agent.label).", "\(agent.label) connection removed.")
            }
        }
    }
    private func reload() { do { profiles = try APIAssistantStore(root: model.dataDirectory).all() } catch { model.report(error) } }
}

extension EngineAgent: Identifiable { var id: String { rawValue } }

private struct EngineConnections: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var setup: SetupCoordinator
    let profiles: [APIAssistant]
    let feedback: String?
    let edit: (EngineAgent) -> Void

    var body: some View {
        WorkshopCard {
            VStack(alignment: .leading, spacing: 15) {
                Text(model.text("حساباتك", "Your accounts")).font(.headline)
                ConnectionList(setup: setup, agents: EngineAgent.nativeAgents)
                ForEach(profiles.sorted { $0.agent.rawValue < $1.agent.rawValue }, id: \.agent) { profile in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: ready(profile) ? "checkmark.circle.fill" : "pause.circle")
                                .foregroundStyle(ready(profile) ? .green : .orange)
                            Text(profile.agent.label).font(.callout.weight(.semibold))
                            Spacer()
                            Text(!profile.enabled ? model.text("متوقف مؤقتًا", "Paused") : ready(profile)
                                 ? model.text("مضاف وجاهز", "Added and ready") : model.text("مضاف — محتاج مفتاح", "Added — key needed"))
                                .font(.caption).foregroundStyle(ready(profile) ? .green : .orange)
                        }
                        Text(profile.model).font(.caption).foregroundStyle(.secondary)
                        ServiceAccessLinks(agent: profile.agent, arabic: model.arabic, endpoint: profile.endpoint)
                        HStack {
                            Button(model.text("إدارة الربط…", "Manage connection…")) { edit(profile.agent) }
                                .accessibilityLabel(model.text("إدارة ربط \(profile.agent.label)", "Manage \(profile.agent.label) connection"))
                            Button(model.text("إعداد الفريق", "Team setup")) { model.editTeam() }
                        }.disabled(model.busy || setup.busy)
                    }
                    Divider()
                }
                if let feedback { Label(feedback, systemImage: "info.circle").font(.caption) }
                HStack {
                    Button(model.text("افتح الإعداد", "Open setup")) { model.restartOnboarding() }.disabled(setup.busy)
                    Button(model.text("تحقق من الربط", "Check connections")) { setup.verifyConnections() }.disabled(setup.busy)
                    if setup.busy {
                        Button(model.text("إلغاء", "Cancel")) { setup.cancel() }
                    }
                }.disabled(model.busy)
                Text(model.text("تسجيل الدخول بيتم في صفحة الخدمة الرسمية، وبعدها الفواعلي بيتحقق من الربط.", "Sign-in uses the service’s official page. Fawaly then checks the connection."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { setup.scan(); setup.verifyConnections() }
    }
    private func ready(_ profile: APIAssistant) -> Bool { profile.enabled && (profile.local || APIAssistantKeychain.contains(profile)) }
}
