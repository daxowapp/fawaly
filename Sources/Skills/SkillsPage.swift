import AppKit
import SwiftUI

struct SkillsPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var catalog: [SkillPackage] = []
    @State private var directory: URL?
    @State private var statuses: [String: ProjectSkills.Status] = [:]
    @State private var query = ""
    @State private var installedOnly = false
    @State private var review: SkillInstallPlan?
    @State private var operation: Task<Void, Never>?
    @State private var active: String?
    @State private var feedback: String?
    @State private var picking = false
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
                    Text(model.text("مصادر منتقاة بإصدارات ثابتة وكريدت محفوظ. التثبيت للمشروع المختار؛ تعليماتك وإعدادات الفواعلي الحالية تفضل محفوظة. افتح محادثة جديدة في أجنتك بعد التثبيت.", "Curated sources with pinned revisions and preserved credit. Installs apply to the selected project and preserve your instructions and Fawaly setup. Start a new agent chat after installation.")).font(.callout)
                    HStack {
                        Label(directory?.lastPathComponent ?? model.text("اختار مشروعًا الأول", "Choose a project first"), systemImage: "folder")
                        Spacer()
                        Button(model.text("اختار فولدر المشروع…", "Choose project folder…")) { chooseProject() }.disabled(active != nil || picking)
                    }
                    if let directory { Text(directory.path).font(.caption.monospaced()).textSelection(.enabled) }
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
                        if item.hasScripts || item.hasHooks { Label(model.text("يتضمن سكربتات أو Hooks؛ راجعها قبل التثبيت", "Includes scripts or hooks; review before installing"), systemImage: "info.circle").font(.caption).foregroundStyle(.orange) }
                        HStack {
                            Button(model.text("المصدر والكريدت", "Source & credit")) { NSWorkspace.shared.open(item.sourceURL) }.buttonStyle(.link).tint(.blue)
                            Spacer()
                            Button(statuses[item.id] == .incomplete ? model.text("راجع وأكمل التثبيت…", "Review and resume…") : model.text("راجع وثبّت…", "Review & install…")) { prepare(item) }
                                .buttonStyle(WorkshopPrimaryButtonStyle())
                                .disabled(directory == nil || active != nil || model.busy || model.setup.busy || [.installed, .modified, .external].contains(statuses[item.id] ?? .absent))
                                .accessibilityLabel(model.text("راجع وثبّت \(item.name)", "Review and install \(item.name)"))
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
        .onDisappear { operation?.cancel() }
        .sheet(isPresented: Binding(get: { review != nil }, set: { if !$0 { review = nil } })) {
            if let review { SkillReviewSheet(plan: review, directory: directory!, arabic: model.arabic, cancel: { self.review = nil }, install: { install(review) }) }
        }
    }
    private func statusLabel(_ status: ProjectSkills.Status) -> String {
        switch status {
        case .absent: model.text("مش متسطّبة في المشروع", "Not installed in project")
        case .installed: model.text("متسطّبة في المشروع", "Installed in project")
        case .modified: model.text("موجودة وبها تغييرات — محفوظة", "Present with changes — preserved")
        case .incomplete: model.text("تثبيت غير مكتمل", "Incomplete installation")
        case .external: model.text("موجودة من خارج الفواعلي", "Existing external installation")
        case .global: model.text("موجودة في السكيلز العامة", "Detected in global skills")
        }
    }
    private func reload() {
        guard let directory else { statuses = [:]; return }
        let store = ProjectSkills(directory: directory)
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
    private func prepare(_ item: SkillPackage) {
        guard let directory else { return }
        active = model.text("بجهّز معاينة \(item.name)…", "Preparing \(item.name)…"); feedback = nil
        operation = Task {
            defer { active = nil; operation = nil }
            do {
                let contents = try await item.download()
                try Task.checkCancellation()
                review = try ProjectSkills(directory: directory).plan(item, contents: contents, catalog: catalog)
            } catch is CancellationError { feedback = model.text("اتلغى التنزيل قبل التثبيت.", "Download cancelled before installation.") }
            catch { model.report(error) }
        }
    }
    private func install(_ plan: SkillInstallPlan) {
        guard let directory else { return }
        review = nil; active = model.text("بثبّت \(plan.package.name)…", "Installing \(plan.package.name)…")
        operation = Task {
            defer { active = nil; operation = nil; reload() }
            do {
                let lease = try WorkActivityLease(root: model.dataDirectory)
                defer { withExtendedLifetime(lease) {} }
                try await ProjectSkills(directory: directory).install(plan)
                feedback = model.text("اتسطّبت \(plan.package.name) والكريدت محفوظ. افتح محادثة جديدة في أجنتك. تعليماتك القديمة وإعدادات الفواعلي ما اتستبدلتش.", "\(plan.package.name) installed with credit. Start a new agent chat. Existing instructions and Fawaly configuration were preserved.")
            } catch is CancellationError { feedback = model.text("اتوقف التثبيت. حالته ظاهرة في القائمة وتقدر تراجعه وتكمله.", "Installation stopped. Its state is shown below; review to resume.") }
            catch { model.report(error) }
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
    private func text(_ ar: String, _ en: String) -> String { arabic ? ar : en }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(text("راجع قبل التثبيت", "Review before installing")).font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(plan.package.title(arabic)).font(.headline)
                    Link(plan.package.repo, destination: plan.package.sourceURL)
                    Text("\(plan.package.author) · \(plan.package.license) · \(plan.package.revision)").font(.caption).textSelection(.enabled)
                    Text(directory.path).font(.caption.monospaced()).textSelection(.enabled)
                    Text(text("هنضيف ملفات السكيل للمشروع وقسمًا منفصلًا في CLAUDE.md وAGENTS.md. المحتوى القديم هيفضل كما هو، ونسخة منه تتخزن قبل الإضافة. مش هنعدل إعدادات MCP أو Hooks الحالية، ولا نشغّل سكربتات أثناء التثبيت.", "Adds project skill files and a separate section in CLAUDE.md and AGENTS.md. Existing content stays intact and is backed up before appending. Existing MCP/hook settings are not edited and scripts are not run during installation.")).font(.callout)
                    if !plan.warnings.isEmpty {
                        Label(text("تداخلات ومتطلبات محتاجة مراجعتك", "Overlaps and requirements to review"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        ForEach(plan.warnings, id: \.self) { warning in Text(localize(warning)).font(.caption) }
                    }
                    ForEach(plan.package.requirements, id: \.self) { Text(localizeRequirement($0)).font(.caption).foregroundStyle(.secondary) }
                    DisclosureGroup(text("الملفات اللي هتتضاف أو تتحدّث: \(plan.writes.count)", "Files to add or update: \(plan.writes.count)")) {
                        ForEach(plan.writes, id: \.path) { Text($0.path).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                    Text(text("معاينة التعليمات الأصلية", "Original instructions preview")).font(.headline)
                    Text(plan.preview).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).environment(\.layoutDirection, .leftToRight)
                }
            }
            if !plan.warnings.isEmpty { Toggle(text("راجعت التداخلات ومتطلبات التشغيل", "I reviewed overlaps and execution requirements"), isOn: $acknowledged) }
            HStack {
                Button(text("إلغاء", "Cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(text("ثبّت في المشروع", "Install in project"), action: install).buttonStyle(WorkshopPrimaryButtonStyle()).disabled(!plan.warnings.isEmpty && !acknowledged)
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
