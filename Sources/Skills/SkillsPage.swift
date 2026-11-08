import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SkillActivity: ObservableObject {
    @Published var active: String?
    @Published var feedback: String?
    var operation: Task<Void, Never>?
    var installing = false
    func leavePage() {
        // Installation survives navigation; preview downloads require a visible review sheet.
        if !installing { operation?.cancel() }
    }
}

struct SkillsPage: View {
    @ObservedObject var activity: SkillActivity
    private var active: String? { get { activity.active } nonmutating set { activity.active = newValue } }
    private var feedback: String? { get { activity.feedback } nonmutating set { activity.feedback = newValue } }
    private var operation: Task<Void, Never>? { get { activity.operation } nonmutating set { activity.operation = newValue } }
    @EnvironmentObject private var model: AppModel
    @State private var catalog: [SkillPackage] = []
    @State private var directory: URL?
    @State private var statuses: [String: ProjectSkills.Status] = [:]
    @State private var query = ""
    @State private var installedOnly = false
    @State private var review: SkillInstallPlan?
    @State private var picking = false
    @State private var scope = SkillInstallScope.project
    @State private var selecting: SkillPackage?
    @State private var pendingChoice: SkillInstallChoice?
    private var target: URL? { scope == .allProjects ? FileManager.default.homeDirectoryForCurrentUser : directory }
    private var items: [SkillPackage] {
        catalog.filter {
            (!installedOnly || (statuses[$0.id] ?? .absent) != .absent)
                && (query.isEmpty || ($0.name + $0.nameAR + $0.repo + $0.tags.joined()).localizedCaseInsensitiveContains(query))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkshopCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.text("سكيلز على مقاس مشروعك", "Skills for your project")).font(.headline)
                    Text(model.text("اختار لكل مهارة: تثبيت لكل المشاريع على الماك، أو لمشروع تحدده. تعليماتك وإعدادات الفواعلي الحالية تفضل محفوظة. افتح محادثة جديدة في أجنتك بعد التثبيت.", "For each skill, choose all local projects or a specific project folder. Existing instructions and Fawaly settings stay intact. Start a new agent chat after installation.")).font(.callout)
                    Picker(model.text("اعرض حالة التثبيت في", "Show installation state for"), selection: $scope) {
                        Text(model.text("المشروع المختار", "Selected project")).tag(SkillInstallScope.project)
                        Text(model.text("كل المشاريع", "All projects")).tag(SkillInstallScope.allProjects)
                    }.pickerStyle(.segmented).disabled(active != nil)
                    if scope == .project { HStack {
                        Label(directory?.lastPathComponent ?? model.text("اختار مشروعًا الأول", "Choose a project first"), systemImage: "folder")
                        Spacer()
                        Button(model.text("اختار فولدر المشروع…", "Choose project folder…")) { chooseProject() }.disabled(active != nil || picking)
                    }
                    if let directory { Text(directory.path).font(.caption.monospaced()).textSelection(.enabled).environment(\.layoutDirection, .leftToRight) }
                    } else { Text(model.text("حسابك على الماك · Codex وClaude Code. ملاحظات كل مشروع تفضل منفصلة.", "Your Mac account · Codex and Claude Code. Each project's notes remain separate.")).font(.caption).foregroundStyle(.secondary) }
                    TextField(model.text("ابحث عن Skill أو صاحبها", "Search skills or authors"), text: $query).textFieldStyle(.roundedBorder)
                    Toggle(model.text("اعرض المتسطّبة والموجودة بس", "Show installed and detected only"), isOn: $installedOnly)
                    if let active {
                        HStack { ProgressView().controlSize(.small); Text(active).font(.caption); Spacer(); Button(model.text("إلغاء", "Cancel")) { operation?.cancel() } }
                    }
                    if let feedback { Label(feedback, systemImage: "info.circle").font(.caption) }
                }
            }
            ForEach(items) { item in
                WorkshopCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(item.title(model.arabic)).font(.headline)
                            Spacer()
                            Text(statusLabel(statuses[item.id] ?? .absent)).font(.caption).foregroundStyle((statuses[item.id] == .installed) ? .green : .secondary)
                        }
                        Text(model.arabic ? item.descriptionAR : item.description).font(.callout)
                        HStack {
                            Link(item.author, destination: item.sourceURL).tint(.blue)
                            Text(item.license)
                            if item.stars > 0 { Label(item.stars.formatted(), systemImage: "star") }
                        }.font(.caption).foregroundStyle(.secondary)
                        Text(model.text("لقطة GitHub: \(item.checked) · إصدار \(item.revision.prefix(8))", "GitHub snapshot: \(item.checked) · revision \(item.revision.prefix(8))")).font(.caption2).foregroundStyle(.secondary)
                        if item.hasScripts || item.hasHooks { Label(model.text("يتضمن سكربتات أو Hooks؛ راجعها قبل التثبيت", "Includes scripts or hooks; review before installing"), systemImage: "info.circle").font(.caption).foregroundStyle(Workshop.warning) }
                        HStack {
                            Button(model.text("المصدر والكريدت", "Source & credit")) { NSWorkspace.shared.open(item.sourceURL) }.buttonStyle(.link).tint(.blue)
                            Spacer()
                            Button([.installed, .modified, .external].contains(statuses[item.id] ?? .absent) ? model.text("اختيار نطاق التثبيت…", "Choose installation scope…") : statuses[item.id] == .incomplete ? model.text("راجع وأكمل التثبيت…", "Review and resume…") : model.text("راجع وثبّت…", "Review & install…")) { selecting = item }
                                .buttonStyle(WorkshopPrimaryButtonStyle())
                                .disabled(active != nil || model.busy || model.setup.busy)
                                .accessibilityLabel(actionLabel(item) + " " + item.title(model.arabic))
                        }
                    }
                }
            }
            WorkshopCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.text("عن الذاكرة والتعارض", "Memory & compatibility")).font(.headline)
                    Text(model.text("Planning with Files بيحفظ الخطة والنتائج والتقدم على ملفات المشروع. لما تكون ذاكرة المشروع متسطّبة، الفواعلي يرفق الملاحظات الجذرية الصغيرة لعمال الفريق داخل المشروع المصرّح به. ده مش تسجيل تلقائي لكل محادثاتك ولا ضمان إن أي موديل هيلتزم بكل التعليمات.", "Planning with Files keeps plans, findings and progress on project files. When project memory is installed, Fawaly attaches small root planning notes to delegated workers in the approved project. This does not record every chat or guarantee model compliance.")).font(.caption)
                    Text(model.text("بنمنع استبدال ملفات أو سكيلز موجودة، وننبّه للتداخلات المعروفة في قواعد التخطيط والتصميم والاختبارات. الفحص مش ضمان لاكتشاف كل تعارض معنوي. اكتشاف التثبيت العام يراجع مسارات السكيلز المعتادة؛ إضافات المتاجر قد تحتاج فحصًا في أجنتها.", "Existing files and skills are never replaced. Known planning, design and test-rule overlaps are highlighted; not every semantic conflict can be detected. Global detection checks standard skill folders; marketplace plugins may need their agent's own status view.")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Link("Claude-Mem", destination: URL(string: "https://github.com/thedotmack/claude-mem")!)
                        Link("Basic Memory", destination: URL(string: "https://github.com/basicmachines-co/basic-memory")!)
                    }.font(.caption)
                    Text(model.text("دول إضافات ذاكرة تشغيلية مستقلة، مش سكيلز ملفات بس؛ ليهم تثبيت وصلاحيات ومزوّد ذاكرة مختلف. روابطهم هنا للبحث، ومش بنعرضهم كأنهم اتسطّبوا.", "These are separate memory runtimes, not just file skills. They have their own installation, permissions and memory providers. Links are references; they are not shown as installed.")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            do { catalog = try SkillPackage.catalog(); if directory == nil { directory = model.state.projectDirectory }; reload() } catch { model.report(error) }
        }
        .onDisappear { activity.leavePage() }
        .onChange(of: activity.active) { _, _ in reload() }
        .onChange(of: scope) { _, _ in reload() }
        .sheet(item: $selecting, onDismiss: {
            if let choice = pendingChoice { pendingChoice = nil; prepare(choice) }
        }) { item in
            SkillScopeSheet(item: item, initialScope: scope, initialDirectory: directory, arabic: model.arabic,
                            cancel: { selecting = nil }, selected: { selectedScope, selectedDirectory in
                pendingChoice = .init(package: item, scope: selectedScope, project: selectedDirectory)
                selecting = nil
            })
        }
        .sheet(isPresented: Binding(get: { review != nil }, set: { if !$0 { review = nil } })) {
            if let review { SkillReviewSheet(plan: review, directory: review.directory, arabic: model.arabic, cancel: { self.review = nil }, install: { install(review) }) }
        }
    }
    private func actionLabel(_ item: SkillPackage) -> String {
        switch statuses[item.id] ?? .absent {
        case .installed, .modified, .external: model.text("اختيار نطاق التثبيت", "Choose installation scope")
        case .incomplete: model.text("راجع وأكمل التثبيت", "Review and resume")
        default: model.text("راجع وثبّت", "Review and install")
        }
    }
    private func statusLabel(_ status: ProjectSkills.Status) -> String {
        switch status {
        case .absent: scope == .project ? model.text("مش متسطّبة في المشروع", "Not installed in project") : model.text("مش متسطّبة لكل المشاريع", "Not installed globally")
        case .installed: scope == .project ? model.text("متسطّبة في المشروع", "Installed in project") : model.text("متسطّبة لكل المشاريع", "Installed for all projects")
        case .modified: model.text("موجودة وبها تغييرات — محفوظة", "Present with changes — preserved")
        case .incomplete: model.text("تثبيت غير مكتمل", "Incomplete installation")
        case .external: model.text("موجودة من خارج الفواعلي", "Existing external installation")
        case .global: model.text("موجودة في السكيلز العامة", "Detected in global skills")
        }
    }
    private func reload() {
        guard let target else { statuses = [:]; return }
        let store = ProjectSkills(directory: target, scope: scope)
        statuses = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, store.status($0)) })
    }
    private func chooseProject() {
        picking = true
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.presentInWorkshop { result in
            picking = false
            guard result == .OK, let selected = panel.url else { return }
            directory = selected.resolvingSymlinksInPath(); feedback = nil; reload()
        }
    }
    private func prepare(_ choice: SkillInstallChoice) {
        let item = choice.package
        guard let destination = choice.scope == .allProjects ? FileManager.default.homeDirectoryForCurrentUser : choice.project else { return }
        scope = choice.scope
        if let project = choice.project { directory = project }
        reload()
        active = model.text("بجهّز معاينة \(item.name)…", "Preparing \(item.name)…"); feedback = nil
        operation = Task {
            defer { active = nil; operation = nil }
            do {
                let contents = try await item.download()
                try Task.checkCancellation()
                review = try ProjectSkills(directory: destination, scope: choice.scope).plan(item, contents: contents, catalog: catalog)
            } catch is CancellationError { feedback = model.text("اتلغى التنزيل قبل التثبيت.", "Download cancelled before installation.") }
            catch { model.report(error) }
        }
    }
    private func install(_ plan: SkillInstallPlan) {
        activity.installing = true
        review = nil; active = model.text("بثبّت \(plan.package.name)…", "Installing \(plan.package.name)…")
        operation = Task {
            defer { activity.installing = false; active = nil; operation = nil; reload() }
            do {
                let lease = try WorkActivityLease(root: model.dataDirectory)
                defer { withExtendedLifetime(lease) {} }
                try await ProjectSkills(directory: plan.directory, scope: plan.scope).install(plan)
                let destination = plan.scope == .allProjects ? model.text("لكل المشاريع", "for all projects") : model.text("في \(plan.directory.lastPathComponent)", "in \(plan.directory.lastPathComponent)")
                feedback = model.text("اتسطّبت \(plan.package.name) \(destination) والكريدت محفوظ. افتح محادثة جديدة في أجنتك. تعليماتك القديمة وإعدادات الفواعلي ما اتستبدلتش.", "\(plan.package.name) installed \(destination) with credit. Start a new agent chat. Existing instructions and Fawaly configuration were preserved.")
            } catch is CancellationError { feedback = model.text("اتوقف التثبيت. حالته ظاهرة في القائمة وتقدر تراجعه وتكمله.", "Installation stopped. Its state is shown below; review to resume.") }
            catch { model.report(error) }
        }
    }
}

private struct SkillInstallChoice {
    let package: SkillPackage
    let scope: SkillInstallScope
    let project: URL?
}

private struct SkillScopeSheet: View {
    let item: SkillPackage
    let arabic: Bool
    let cancel: () -> Void
    let selected: (SkillInstallScope, URL?) -> Void
    @State private var scope: SkillInstallScope
    @State private var directory: URL?
    @State private var picking = false
    @State private var issue: String?
    init(item: SkillPackage, initialScope: SkillInstallScope, initialDirectory: URL?, arabic: Bool,
         cancel: @escaping () -> Void, selected: @escaping (SkillInstallScope, URL?) -> Void) {
        self.item = item; self.arabic = arabic; self.cancel = cancel; self.selected = selected
        _scope = State(initialValue: initialScope); _directory = State(initialValue: initialDirectory)
    }
    private func text(_ ar: String, _ en: String) -> String { WorkshopCopy.text(ar, en, arabic: arabic) }
    private var existing: ProjectSkills.Status {
        guard let target = scope == .allProjects ? FileManager.default.homeDirectoryForCurrentUser : directory else { return .absent }
        return ProjectSkills(directory: target, scope: scope).status(item)
    }
    private var canContinue: Bool { !picking && (scope == .allProjects || directory != nil) && ![.installed, .modified, .external].contains(existing) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(text("تحب تثبّتها فين؟", "Where should this be installed?")).font(.title2.weight(.semibold))
            Text(item.title(arabic)).font(.headline)
            Picker(text("نطاق التثبيت", "Installation scope"), selection: $scope) {
                Text(text("كل المشاريع تلقائيًا على الماك", "All projects automatically on this Mac")).tag(SkillInstallScope.allProjects)
                Text(text("مشروع محدد", "A specific project")).tag(SkillInstallScope.project)
            }.pickerStyle(.radioGroup)
            if scope == .allProjects {
                Text(text("هتكون متاحة لحسابك في Codex وClaude Code في المشاريع الحالية والجديدة، بعد فتح محادثة جديدة. ملاحظات وذاكرة كل مشروع تفضل منفصلة، وإعداداتك الحالية تفضل محفوظة.", "Available to your account in Codex and Claude Code for current and new projects after starting a new chat. Each project's notes and memory remain separate, and existing settings are preserved.")).font(.callout)
            } else {
                HStack {
                    Label(directory?.lastPathComponent ?? text("اختار المشروع", "Choose a project"), systemImage: "folder")
                    Spacer()
                    Button(text("اختار فولدر المشروع…", "Choose project folder…")) { picking = true }
                }
                if let directory { Text(directory.path).font(.caption.monospaced()).textSelection(.enabled).environment(\.layoutDirection, .leftToRight) }
                Text(text("التثبيت هيتطبق على فولدر المشروع ده بس.", "The installation applies only to this project folder.")).font(.caption).foregroundStyle(.secondary)
            }
            if let issue { Text(issue).font(.caption).foregroundStyle(.red) }
            if [.installed, .modified, .external].contains(existing) {
                Text(text("المهارة موجودة بالفعل في النطاق ده وملفاتها هتفضل محفوظة. تقدر تختار نطاقًا تاني أو مشروعًا مختلفًا.", "This scope already has this package; existing files are preserved. Choose another scope or project.")).font(.caption).foregroundStyle(Workshop.warning)
            }
            Text(text("بعد اختيار المكان، هتراجع الملفات والتداخلات قبل التثبيت.", "Next, review the files and overlaps before anything is installed.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(text("إلغاء", "Cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(text("متابعة للمراجعة", "Continue to review")) { selected(scope, directory) }
                    .buttonStyle(WorkshopPrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(!canContinue)
            }
        }.padding(24).frame(width: 610).environment(\.layoutDirection, arabic ? .rightToLeft : .leftToRight)
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                do { directory = try result.get().resolvingSymlinksInPath(); issue = nil }
                catch { if (error as NSError).code != NSUserCancelledError { issue = error.localizedDescription } }
            }
    }
}

private struct SkillReviewSheet: View {
    let plan: SkillInstallPlan
    let directory: URL
    let arabic: Bool
    let cancel: () -> Void
    let install: () -> Void
    @State private var acknowledged = false
    private func text(_ ar: String, _ en: String) -> String { WorkshopCopy.text(ar, en, arabic: arabic) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(text("راجع قبل التثبيت", "Review before installing")).font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(plan.package.title(arabic)).font(.headline)
                    Label(plan.scope == .allProjects ? text("التثبيت لكل المشاريع على الماك", "Installing for all local projects") : text("التثبيت لمشروع محدد", "Installing in a specific project"), systemImage: plan.scope == .allProjects ? "globe" : "folder").font(.headline)
                    Link(plan.package.repo, destination: plan.package.sourceURL)
                    Text("\(plan.package.author) · \(plan.package.license) · \(plan.package.revision)").font(.caption).textSelection(.enabled)
                    Text(directory.path).font(.caption.monospaced()).textSelection(.enabled).environment(\.layoutDirection, .leftToRight)
                    Text(plan.scope == .allProjects
                         ? text("هنضيف السكيلز العامة لحسابك وقسمًا منفصلًا في تعليمات Claude وCodex العامة. ملفات المشاريع مش هتتعدّل. تعليماتك القديمة هتفضل محفوظة، مع نسخة قبل الإضافة. مش هنعدّل إعدادات MCP أو Hooks ولا نشغّل سكربتات أثناء التثبيت.", "Adds user-level skills and a separate section in Claude and Codex global instruction files. Project files stay untouched. Existing instructions are preserved and backed up. MCP/hook settings are not edited and scripts are not run during installation.")
                         : text("هنضيف ملفات السكيل للمشروع وقسمًا منفصلًا في CLAUDE.md وAGENTS.md. المحتوى القديم هيفضل كما هو، ونسخة منه تتخزن قبل الإضافة. مش هنعدل إعدادات MCP أو Hooks الحالية، ولا نشغّل سكربتات أثناء التثبيت.", "Adds project skill files and a separate section in CLAUDE.md and AGENTS.md. Existing content stays intact and is backed up before appending. Existing MCP/hook settings are not edited and scripts are not run during installation.")).font(.callout)
                    if !plan.warnings.isEmpty {
                        Label(text("تداخلات ومتطلبات محتاجة مراجعتك", "Overlaps and requirements to review"), systemImage: "exclamationmark.triangle").foregroundStyle(Workshop.warning)
                        ForEach(plan.warnings, id: \.self) { warning in Text(localize(warning)).font(.caption) }
                    }
                    ForEach(plan.package.requirements, id: \.self) { Text(localizeRequirement($0)).font(.caption).foregroundStyle(.secondary) }
                    DisclosureGroup(text("الملفات اللي هتتضاف أو تتحدّث: \(plan.writes.count)", "Files to add or update: \(plan.writes.count)")) {
                        ForEach(plan.writes, id: \.path) { Text($0.path).font(.caption.monospaced()).environment(\.layoutDirection, .leftToRight).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                    Text(text("معاينة التعليمات الأصلية", "Original instructions preview")).font(.headline)
                    Text(plan.preview).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).environment(\.layoutDirection, .leftToRight)
                }
            }
            if !plan.warnings.isEmpty { Toggle(text("راجعت التداخلات ومتطلبات التشغيل", "I reviewed overlaps and execution requirements"), isOn: $acknowledged) }
            HStack {
                Button(text("إلغاء", "Cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(plan.scope == .allProjects ? text("ثبّت لكل المشاريع", "Install for all projects") : text("ثبّت في المشروع", "Install in project"), action: install).buttonStyle(WorkshopPrimaryButtonStyle()).disabled(!plan.warnings.isEmpty && !acknowledged)
            }
        }.padding(24).frame(width: 720, height: min(740, max(400, (NSScreen.main?.visibleFrame.height ?? 840) - 100)))
            .environment(\.layoutDirection, arabic ? .rightToLeft : .leftToRight)
    }
    private func localize(_ warning: String) -> String {
        guard arabic else { return warning }
        if warning.hasPrefix("May overlap with ") { return "قد يتداخل مع " + warning.dropFirst("May overlap with ".count).replacingOccurrences(of: "Review which guidance should apply.", with: "راجع أي تعليمات تناسب مشروعك.") }
        if warning.contains("already contains project rules") { return "فيه تعليمات مشروع موجودة في " + String(warning.prefix(while: { $0 != " " })) + ". القالب هيتضاف في قسم منفصل؛ راجع اختلاف قواعد الاختبارات والتنسيق." }
        if warning.hasPrefix("This package contains scripts") { return "الحزمة تحتوي على سكربتات أو Hooks. الفواعلي لا يشغّلها أثناء التثبيت، لكن أجنتك ممكن يشغّلها بعد كده. راجع المصدر والمتطلبات." }
        if warning.hasPrefix("A global skill") { return "فيه سكيل عامة بنفس الاسم، وأجنتك ممكن يديها أولوية عن نسخة المشروع. ملفات السكيل العامة هتفضل زي ما هي." }
        if warning.hasPrefix("Global installation applies") { return "التثبيت ده هيطبق على كل مشاريع حسابك في Codex وClaude Code. ملفات المشاريع وتثبيتها الحالي مش هتتغير؛ راجع تداخل القواعد. ذاكرة كل مشروع تفضل منفصلة." }
        if warning.hasPrefix("Codex has a global") { return "فيه ملف AGENTS.override.md عام لكودكس وقد تكون له أولوية على التعليمات الجديدة. ملفك مش هيتعدّل." }
        return warning
    }
    private func localizeRequirement(_ value: String) -> String {
        guard arabic else { return value }
        switch value {
        case "Python 3 and a POSIX shell for optional scripts; Claude skill hooks can run local scripts.": return "السكربتات الاختيارية تحتاج Python 3 وShell. الـHooks في Claude ممكن تشغّل سكربتات محلية عند استخدام السكيل."
        case "Includes an optional shell helper.": return "تحتوي على سكربت Shell مساعد اختياري."
        case "The skill may fetch current public design guidance when invoked.": return "السكيل قد تقرأ إرشادات التصميم العامة من الإنترنت عند استخدامها."
        case "Opinionated example: contains technology placeholders, TDD and coverage targets.": return "القالب يحتوي على افتراضات عن تقنيات المشروع وقواعد TDD ونسبة تغطية الاختبارات؛ عدّلها حسب مشروعك."
        default: return value
        }
    }
}
