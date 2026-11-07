import AppKit
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var setup: SetupCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(setup.editingTeam ? model.text("عدّل فريقك", "Edit your team") : model.text("أهلًا بيك في الفواعلي", "Welcome to Fawaly")).font(Workshop.heading(34, ar: model.arabic))
                    Text(model.text("جهّز فريقك، وكمّل شغلك مع أجنتك الأساسي.", "Set up your team and keep working with your primary agent.")).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    if !setup.editingTeam { Text("\(setup.step.rawValue + 1) / 5").monospacedDigit().foregroundStyle(.secondary) }
                    Button(model.arabic ? "English" : "العربية") { model.setArabic(!model.arabic) }
                }
            }
            if !setup.editingTeam { ProgressView(value: Double(setup.step.rawValue), total: 4).tint(Workshop.yellow) }
            ScrollView {
              Group {
                switch setup.step {
                case .welcome: welcome
                case .team: TeamRoleEditor(team: $setup.team, advisorMode: $setup.advisorMode).disabled(setup.busy)
                case .prepare: prepare
                case .accounts: accounts
                case .finish: finish
                }
            }
              .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            controls
        }
        .padding(30)
        .frame(width: 700, height: 600)
        .environment(\.layoutDirection, model.arabic ? .rightToLeft : .leftToRight)
        .interactiveDismissDisabled(!setup.editingTeam || setup.busy)
        .onChange(of: setup.busy) { _, busy in
            if !busy && setup.integrationReady { model.finishOnboarding(previewOnly: false) }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(model.text("اختار الأساسي والمستشار والفواعلي", "Choose your primary, advisor, and workers"), systemImage: "person.3")
            Label(model.text("سجّل الدخول في المتصفح", "Sign in using your browser"), systemImage: "person.crop.circle")
            Label(model.text("وصّل الفريق وارجع لتطبيق أجنتك", "Connect the team and return to your agent app"), systemImage: "checkmark.seal")
            Text(model.text(
                "الفواعلي هيجهّز الربط بنفسه. كل خدمة هتطلب منك تسجيل الدخول في صفحتها الرسمية. بيانات الدخول الخاصة بالفواعلي بتتحفظ بشكل مستقل.",
                "Fawaly handles the setup. Each service asks you to sign in on its official page. Fawaly keeps its service sign-ins separate."
            )).font(.callout).foregroundStyle(.secondary)
        }.padding(.vertical, 15)
    }

    private var prepare: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.text("اختار الخدمات اللي هتستخدمها", "Choose the services you want")).font(.headline)
            ForEach(EngineAgent.allCases, id: \.self) { agent in
                if setup.selected.contains(agent) {
                    ConnectionStatus(agent: agent, phase: setup.phases[agent] ?? .missing)
                }
            }
            if setup.selected.contains(where: { if case .failed = setup.phases[$0] { return true }; return false }) {
                Text(model.text("التجهيز ما اكتملش. راجع اتصال الإنترنت واضغط جهّز الخدمات للمحاولة تاني.", "Preparation could not finish. Check your internet connection and choose Prepare services to retry.")).font(.caption).foregroundStyle(.orange)
            }
            Text(model.text(
                "لو خدمة ناقصة، هننزّل نسختها الرسمية ونتحقق منها. التجهيز جوّه حسابك على الماك ومش محتاج كلمة سر المدير.",
                "Missing services are downloaded from their official source and verified. Setup stays in your Mac account and does not require an administrator password."
            )).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var accounts: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(model.text("اربط حسابات فريقك", "Connect your team’s accounts")).font(.headline)
            Text(model.text("الأساسي هيستخدم حسابه في تطبيقه المعتاد. اربط هنا المستشار والفواعلي اللي اخترتهم.", "Your primary uses its account in its usual app. Connect your chosen advisor and workers here.")).font(.callout).foregroundStyle(.secondary)
            ConnectionList(setup: setup, agents: setup.team.supporters)
        }
    }

    private var finish: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.text("فريقك جاهز للربط", "Your team is ready to connect")).font(.title2.weight(.semibold))
            Text(model.text("الأساسي", "Primary") + " · " + setup.team.primary.label).font(.headline)
            ForEach(setup.team.supporters, id: \.self) { agent in
                ConnectionStatus(agent: agent, phase: setup.phases[agent] ?? .available)
            }
            Text(model.text(
                "هنوصّل الفريق بإعدادات \(setup.team.primary.label). بعد الربط افتح محادثة جديدة في تطبيق أجنتك، ولو الفريق ما ظهرش أعد فتح التطبيق. الأجنت ممكن يطلب موافقتك على استخدام الفريق.",
                "We’ll connect the team in \(setup.team.primary.label)’s settings. Start a new chat afterward. If the team does not appear, reopen your agent app. Your agent may ask you to approve team tools."
            )).foregroundStyle(.secondary)
            if let issue = setup.integrationIssue {
                Text(issue.contains("different Fawaly")
                     ? model.text("في ربط سابق للفواعلي محتاج مراجعة من إعدادات الأجنت.", "An existing Fawaly connection needs review in your agent’s settings.")
                     : model.text("الربط ما اكتملش. تأكد إن إعدادات الأجنت متاحة واضغط وصّل الفريق للمحاولة تاني.", "Connection did not complete. Check that your agent’s settings are available, then retry Connect team."))
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var controls: some View {
        HStack {
            if setup.busy {
                ProgressView().controlSize(.small)
                Text(model.text("لحظات…", "Working…")).font(.caption)
                Button(model.text("إلغاء", "Cancel")) { setup.cancel() }
            } else if setup.editingTeam {
                Button(model.text("إلغاء التعديل", "Cancel changes")) { model.cancelTeamEdit() }
            } else if setup.step != .welcome {
                Button(model.text("رجوع", "Back")) { setup.step = SetupCoordinator.Step(rawValue: setup.step.rawValue - 1) ?? .welcome }
            }
            Spacer()
            if setup.step == .welcome || setup.step == .prepare {
                Button(model.text("جرّب المعاينة المحلية", "Try local preview")) { model.finishOnboarding(previewOnly: true) }.disabled(setup.busy)
            }
            switch setup.step {
            case .welcome:
                Button(model.text("ابدأ الإعداد", "Start setup")) { setup.scan(); setup.step = .team }
                    .buttonStyle(WorkshopPrimaryButtonStyle())
            case .team:
                Button(setup.editingTeam ? model.text("احفظ الفريق", "Save team") : model.text("جهّز الفريق", "Prepare team")) {
                    do {
                        try setup.team.validate()
                        setup.resetIntegration()
                        setup.selected = Set([setup.team.primary] + setup.team.supporters)
                        setup.scan()
                        setup.step = setup.editingTeam && setup.teamReady ? .finish : .prepare
                    } catch { model.report(error) }
                }.buttonStyle(WorkshopPrimaryButtonStyle()).disabled(setup.busy)
            case .prepare:
                Button(model.text("جهّز الخدمات", "Prepare services")) { setup.prepare() }
                    .buttonStyle(WorkshopPrimaryButtonStyle()).disabled(setup.busy || setup.selected.isEmpty)
            case .accounts:
                Button(model.text("أكمل بمعاينة محلية", "Use local preview for now")) { model.finishOnboarding(previewOnly: true) }.disabled(setup.busy)
                Button(model.text("التالي", "Continue")) { setup.step = .finish }
                    .buttonStyle(WorkshopPrimaryButtonStyle()).disabled(setup.busy || !setup.teamReady)
            case .finish:
                Button(model.text("وصّل الفريق بـ\(setup.team.primary.label)", "Connect team to \(setup.team.primary.label)")) { setup.integrateTeam() }
                    .buttonStyle(WorkshopPrimaryButtonStyle()).disabled(!setup.teamReady || setup.busy)
            }
        }
    }
}

struct ConnectionStatus: View {
    @EnvironmentObject private var model: AppModel
    let agent: EngineAgent
    let phase: SetupCoordinator.Phase

    var body: some View {
        HStack {
            if busy { ProgressView().controlSize(.small) }
            else { Image(systemName: phase == .connected ? "checkmark.circle.fill" : "circle").foregroundStyle(phase == .connected ? .green : .secondary) }
            Text(agent.label).font(.callout.weight(.semibold))
            Spacer()
            Text(status).font(.caption).foregroundStyle(phase == .connected ? .green : .secondary)
        }
    }
    private var busy: Bool { phase == .preparing || phase == .signingIn || phase == .verifying }
    private var status: String {
        switch phase {
        case .missing: model.text("جاهزة للتجهيز", "Ready to prepare")
        case .available: model.text("جاهزة لتسجيل الدخول", "Ready for sign-in")
        case .preparing: model.text("جاري التجهيز…", "Preparing…")
        case .signingIn: model.text("كمّل تسجيل الدخول في المتصفح", "Complete sign-in in your browser")
        case .verifying: model.text("بنتحقق من الربط…", "Checking connection…")
        case .connected: model.text("تم التحقق من تسجيل الدخول", "Sign-in verified")
        case .failed: model.text("محتاج محاولة تانية", "Please retry")
        }
    }
}

struct ConnectionList: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var setup: SetupCoordinator
    let agents: [EngineAgent]

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            ForEach(agents, id: \.self) { agent in
                VStack(alignment: .leading, spacing: 8) {
                    ConnectionStatus(agent: agent, phase: setup.phases[agent] ?? .available)
                    if case .failed(let issue) = setup.phases[agent] {
                        Text(model.text("الربط ما اكتملش. جرّب تاني، أو ارجع لتجهيز الخدمات.", "Connection was not completed. Try again, or return to service preparation."))
                            .font(.caption).foregroundStyle(.orange)
                        if issue.contains("timed out") { Text(model.text("انتهى وقت الانتظار.", "The sign-in timed out.")).font(.caption) }
                    }
                    if agent == .kimi && setup.phases[agent] != .connected {
                        Picker(model.text("حساب Kimi", "Kimi account"), selection: $setup.kimiRegion) {
                            Text(model.text("دولي (kimi.ai)", "Global (kimi.ai)")).tag(KimiRegion.global)
                            Text("kimi.com").tag(KimiRegion.mainland)
                        }.disabled(setup.busy)
                    }
                    HStack {
                        if setup.phases[agent] == .connected {
                            Button(model.text("تسجيل خروج", "Sign out")) { setup.disconnect(agent) }.disabled(setup.busy)
                        } else {
                            Button(model.text("اربط", "Connect") + " " + agent.label) { setup.connect(agent) }
                                .buttonStyle(WorkshopPrimaryButtonStyle()).disabled(setup.busy || setup.phases[agent] == .missing)
                        }
                        if setup.activeAgent == agent, let url = setup.browserURL {
                            Button(model.text("افتح صفحة تسجيل الدخول", "Open sign-in page")) { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                Divider()
            }
        }
        .disabled(model.busy)
        .onChange(of: setup.connected) { before, after in
            model.refreshEngine()
            if after.count > before.count { NSApp.activate() }
        }
    }
}
