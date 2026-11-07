import AppKit
import SwiftUI

struct ComparisonPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var project: URL?
    @State private var first = EngineAgent.claude
    @State private var second = EngineAgent.kimi
    @State private var brief = ""
    @State private var preparing = false
    @State private var sessions: [ComparisonSession] = []
    @State private var operation: Task<Void, Never>?
    @State private var selectingProject = false
    private var store: ComparisonStore { ComparisonStore(root: model.dataDirectory) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkshopCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.text("مين يشيلها أحسن؟", "Who handles it better?")).font(.headline)
                    if model.nativeAgents.count < 2 {
                        Text(model.text("اربط مساعدَين من إعداد الفريق عشان تقارن بينهم.", "Connect two assistants in team setup to compare them."))
                        Button(model.text("إعداد الفريق", "Team setup")) { model.editTeam() }
                    }
                    Text(model.text("نفس المهمة على نسختين منفصلتين من آخر commit في مشروع Git. شغلك الحالي مش بيتعدّل، ومفيش دمج تلقائي.", "The same task in two separate snapshots of the latest Git commit. Your working files stay intact; results are never merged automatically."))
                    Button(model.text("اختار مشروع Git…", "Choose Git project…")) { chooseProject() }.disabled(operation != nil || preparing || selectingProject)
                    if let project { Text(project.path).font(.caption.monospaced()).textSelection(.enabled) }
                    HStack {
                        Picker(model.text("المساعد الأول", "First assistant"), selection: $first) {
                            ForEach(model.nativeAgents, id: \.self) { Text($0.label).tag($0) }
                        }
                        Picker(model.text("المساعد الثاني", "Second assistant"), selection: $second) {
                            ForEach(model.nativeAgents, id: \.self) { Text($0.label).tag($0) }
                        }
                    }
                    TextField(model.text("الشغل المطلوب، الملفات المسموحة، والاختبارات", "Task, allowed files, and acceptance checks"), text: $brief, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(4...8)
                    Text(model.text("كل محاولة بتستخدم اشتراك المساعد المختار. التنفيذ بالتتابع؛ الملفات والنتائج محفوظة للمراجعة.", "Each attempt uses the selected assistant’s subscription. Attempts run in sequence; files and results are kept for review.")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(model.text("ابدأ المقارنة", "Start comparison")) { start() }.buttonStyle(WorkshopPrimaryButtonStyle())
                            .disabled(operation != nil || sessions.contains(where: { $0.runs.contains(where: { ["running", "waiting"].contains($0.status) }) }) || preparing || project == nil || first == second || !model.nativeAgents.contains(first) || !model.nativeAgents.contains(second) || brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if preparing { ProgressView().controlSize(.small); Text(model.text("بنجهّز النسخ…", "Preparing snapshots…")).font(.caption) }
                    }
                }
            }
            ForEach(sessions) { session in
                ComparisonResultCard(session: session, root: model.dataDirectory, onChange: reload)
            }
        }
        .onAppear {
            model.refreshEngine()
            if !model.nativeAgents.contains(first), let agent = model.nativeAgents.first { first = agent }
            if !model.nativeAgents.contains(second) || second == first, let agent = model.nativeAgents.first(where: { $0 != first }) { second = agent }
            reload()
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                if sessions.contains(where: { $0.runs.contains(where: { ["running", "waiting"].contains($0.status) }) }) { reload() }
            }
        }
    }

    private func chooseProject() {
        guard !selectingProject else { return }
        selectingProject = true
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = model.text("اختار المشروع", "Choose project")
        panel.message = model.text("المساعدان هيشتغلوا على نسختين من الملفات المحفوظة في Git، وممكن يبعثوا سياق المهمة لخدماتهم. ملفاتك الحالية مش هتتعدّل.", "The selected assistants work on two copies of committed files and may send task context to their services. Your working files are not modified.")
        panel.begin { result in
            selectingProject = false
            if result == .OK { project = panel.url }
        }
    }
    private func start() {
        guard let project, operation == nil else { return }
        preparing = true
        let runner = ComparisonRunner(configuration: EngineConfiguration(root: model.dataDirectory))
        let selected = [first, second], assignment = brief
        operation = Task {
            defer { preparing = false; operation = nil; reload() }
            do {
                _ = try await runner.run(project: project, agents: selected, brief: assignment) { _ in
                    await MainActor.run { preparing = false; reload() }
                }
            } catch is CancellationError {} catch { model.report(error) }
        }
    }
    private func reload() { do { try store.recoverInterrupted(); sessions = try store.recent() } catch { model.report(error) } }
}

private struct ComparisonResultCard: View {
    @EnvironmentObject private var model: AppModel
    let session: ComparisonSession
    let root: URL
    let onChange: () -> Void
    @State private var note = ""
    private var running: Bool { session.runs.contains { ["running", "waiting"].contains($0.status) } }

    var body: some View {
        WorkshopCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(session.brief).font(.headline).lineLimit(3)
                Text(String(session.commit.prefix(12)) + " · " + session.created.formatted(date: .abbreviated, time: .shortened)).font(.caption.monospaced()).foregroundStyle(.secondary)
                if running {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(model.text("المقارنة شغّالة", "Comparison running"))
                        Spacer()
                        Button(model.text("إيقاف المقارنة", "Stop comparison")) {
                            do { try ComparisonStore(root: root).requestStop(session.id) } catch { model.report(error) }
                        }
                    }
                }
                ForEach(session.runs, id: \.agent) { run in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(run.agent.label).font(.headline)
                        Text(status(run)).font(.caption).foregroundStyle(run.succeeded == true ? .green : .secondary)
                        if let answer = run.answer {
                            DisclosureGroup(model.text("تقرير المساعد", "Assistant report")) {
                                Text((try? AttributedString(markdown: answer, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(answer)).font(.callout).textSelection(.enabled)
                            }
                        }
                        if let changed = run.changedFiles {
                            DisclosureGroup(model.text("الملفات المتغيرة: \(changed.count)", "Changed files: \(changed.count)")) {
                                ForEach(changed, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                            }
                        }
                        if run.finished != nil {
                            HStack {
                                Button(model.text("افتح نسخة \(run.agent.label)", "Open \(run.agent.label) snapshot")) { NSWorkspace.shared.open(session.snapshot(root: root, agent: run.agent)) }
                                if !running && run.succeeded == true {
                                    Button(model.text("اختار \(run.agent.label) بعد المراجعة", "Choose \(run.agent.label) after review")) {
                                        do { try ComparisonStore(root: root).chooseWinner(id: session.id, agent: run.agent, note: note); onChange() } catch { model.report(error) }
                                    }.disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            }
                        }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                }
                if !running {
                    TextField(model.text("نتيجة مراجعتك واختباراتك قبل اختيار الفائز", "Your inspection and test evidence before choosing a winner"), text: $note, axis: .vertical).textFieldStyle(.roundedBorder)
                }
                if let winner = session.winner {
                    Label(model.text("اختيارك: \(winner.label)", "Your choice: \(winner.label)"), systemImage: "trophy.fill").foregroundStyle(Workshop.yellow)
                    Text(session.review ?? "").font(.callout).textSelection(.enabled)
                }
            }
        }
    }
    private func status(_ run: ComparisonSession.Run) -> String {
        switch run.status {
        case "waiting": model.text("مستني دوره", "Waiting")
        case "running": model.text("شغّال على نسخته المنفصلة", "Working in its own snapshot")
        case "cancelled": model.text("اتلغت قبل التنفيذ", "Cancelled before execution")
        default: run.succeeded == true ? model.text("خلص — محتاج مراجعتك", "Finished — needs your review") : model.text("اتوقف — راجع أي تعديلات جزئية", "Stopped — inspect partial changes")
        }
    }
}
