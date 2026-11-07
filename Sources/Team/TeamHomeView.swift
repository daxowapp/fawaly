import AppKit
import SwiftUI

struct TeamHomeView: View {
    @EnvironmentObject private var model: AppModel
    let team: TeamSettings
    @State private var selectingProject = false

    var body: some View {
        WorkshopCard {
            VStack(alignment: .leading, spacing: 16) {
                Text(model.text("فريقك", "Your team")).font(.title2.weight(.semibold))
                HStack(alignment: .top, spacing: 24) {
                    role(model.text("الأساسي", "Primary"), name: team.primary.label, detail: model.text("يقود الشغل وياخد القرار", "Leads the work and makes decisions"))
                    role(model.text("المستشار", "Advisor"), name: team.advisor?.label ?? model.text("اختياري", "Optional"), detail: model.text("يراجع ويقدّم رأي مستقل", "Reviews and gives an independent opinion"))
                    role(model.text("الفواعلي", "Workers"), name: team.workers.map(\.label).joined(separator: ", ").isEmpty ? model.text("مفيش فواعلي متعينين", "No workers assigned") : team.workers.map(\.label).joined(separator: ", "), detail: model.text("ينفّذوا المهام المفوّضة", "Handle delegated tasks"))
                }
                Text(model.text("ابدأ محادثتك في \(team.primary.label). الأساسي يخطّط ويستخدم الفريق حسب القواعد المحفوظة، ويراجع تغييرات العامل وأدلة التحقق قبل تسجيل قراره. النتائج والقرارات هتظهر في السجل.", "Start your chat in \(team.primary.label). The primary plans, uses the team according to saved rules, and independently checks worker changes and verification evidence before recording its decision. Results and decisions appear in the ledger.")).font(.callout)
                HStack {
                    Button(model.text("افتح \(team.primary.label)", "Open \(team.primary.label)")) { openPrimary() }.buttonStyle(WorkshopPrimaryButtonStyle())
                    Button(model.text("عدّل الفريق", "Edit team")) { model.editTeam() }.disabled(model.busy)
                    Button(model.text("حدّث نشاط الفريق", "Refresh team activity")) { model.load() }.disabled(model.busy)
                }
                ForEach(model.teamJobs.filter { $0.status == "running" }) { job in
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(job.worker.label + " · " + job.title).font(.callout)
                    }
                }
                Divider()
                Text(model.text("صلاحية المشروع", "Project access")).font(.headline)
                if let project = model.state.projectDirectory {
                    Text(project.path).font(.caption.monospaced()).textSelection(.enabled)
                    Button(model.text("اسحب صلاحية الفواعلي", "Revoke worker access")) {
                        do { try model.removeProject() } catch { model.report(error) }
                    }.disabled(model.busy)
                } else {
                    Text(model.text("اختار فولدر مشروع لما تحب الفواعلي يقرأوا ملفاته ويعدّلوها أثناء مهمة مفوّضة.", "Choose a project folder when you want workers to read and edit its files during a delegated task.")).font(.caption).foregroundStyle(.secondary)
                }
                Button(model.text("اختار فولدر المشروع…", "Choose project folder…")) { chooseProject() }.disabled(model.busy)
            }
        }
    }

    private func role(_ title: String, name: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(name).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chooseProject() {
        guard !selectingProject else { return }
        selectingProject = true
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = model.text("اسمح للفواعلي", "Allow workers")
        panel.message = model.text("الفواعلي المربوطين هيقدروا يقرأوا ويعدّلوا ملفات الفولدر ده أثناء المهام اللي الأساسي يفوّضها لهم. راجع التعديلات بعد التنفيذ.", "Connected workers can read and edit this folder during tasks delegated by your primary. Review changes after each run.")
        panel.begin { response in
            selectingProject = false
            guard response == .OK, let url = panel.url else { return }
            do { try model.allowProject(url) } catch { model.report(error) }
        }
    }

    private func openPrimary() {
        let identifier = team.primary == .codex ? "com.openai.codex" : "com.anthropic.claudefordesktop"
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
            openCommandLineAgent()
            return
        }
        NSWorkspace.shared.openApplication(at: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { Task { @MainActor in model.report(error) } }
        }
    }
    private func openCommandLineAgent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = model.text("ابدأ الجلسة", "Start session")
        panel.message = model.text("اختار مشروعك. الفواعلي هيفتح جلسة الأجنت الأساسي في تطبيق الطرفية تلقائيًا.", "Choose your project. Fawaly opens your primary agent’s session in Terminal automatically.")
        panel.begin { response in
            guard response == .OK, let directory = panel.url else { return }
            do {
                guard let executable = team.primary.executable() else { throw FawalyError.invalid("Prepare your primary agent in Fawaly setup first.") }
                let launchers = Paths.rebuiltRoot().appendingPathComponent("launchers", isDirectory: true)
                try Paths.ensurePrivateDirectory(launchers)
                let script = launchers.appendingPathComponent(team.primary.rawValue + ".command")
                func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                let command = "#!/bin/zsh\ncd -- " + quoted(directory.path) + " || exit 1\nexec " + quoted(executable.path) + "\n"
                try command.write(to: script, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
                guard NSWorkspace.shared.open(script) else { throw FawalyError.invalid("The primary agent’s session could not be opened.") }
            } catch { model.report(error) }
        }
    }

}
