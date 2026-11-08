import AppKit
import SwiftUI

enum DailyIssue {
    case cache, save, reading, limit, throttled
    func label(_ arabic: Bool) -> String {
        switch self {
        case .cache: arabic ? "تعذّر قراءة الأخبار المحفوظة. جرّب تحديث الأخبار." : "Saved news could not be read. Refresh to try again."
        case .save: arabic ? "تعذّر حفظ الأخبار الجديدة. النسخة السابقة لسه متاحة." : "News could not be saved. Your previous edition is still available."
        case .reading: arabic ? "تعذّر حفظ اختيار القراءة." : "Your reading choice could not be saved."
        case .limit: arabic ? "تقدر تحفظ حتى ٢٠٠ مقال. ألغي حفظ مقال علشان تضيف غيره." : "You can save up to 200 articles. Unsave one to make room."
        case .throttled: arabic ? "استنى دقيقة بين كل تحديث يدوي والتاني." : "Please wait one minute between manual refreshes."
        }
    }
}

@MainActor final class DailyViewModel: ObservableObject {
    @Published var snapshot = DailySnapshot()
    @Published var reading = DailyReadingState()
    @Published var working = false
    @Published var issue: DailyIssue?
    @Published var lastManualRefresh: Date?
    private var loaded = false
    func update(root: URL, force: Bool) async {
        guard !working else { return }
        if force, let lastManualRefresh, Date().timeIntervalSince(lastManualRefresh) < 60 { issue = .throttled; return }
        if force { lastManualRefresh = Date() }
        let store = DailyStore(root: root)
        if !loaded {
            do { snapshot = try store.load(); reading = try store.reading(); loaded = true }
            catch { issue = .cache; loaded = true }
        }
        guard force || snapshot.due(now: Date()) else { return }
        working = true
        defer { working = false }
        do {
            let value = try await DailyFetcher.refresh(previous: snapshot)
            try store.save(value); snapshot = value; issue = nil
        } catch is CancellationError { }
        catch { issue = .save }
    }
    func toggle(_ article: DailyArticle, saved: Bool, root: URL) {
        var next = reading
        if saved {
            if next.saved.contains(article.id) {
                next.saved.remove(article.id); next.bookmarks?.removeAll { $0.id == article.id }
            } else {
                guard next.saved.count < 200 else { issue = .limit; return }
                next.saved.insert(article.id); next.bookmarks = (next.bookmarks ?? []) + [article]
            }
        } else {
            if !next.read.insert(article.id).inserted { next.read.remove(article.id) }
        }
        do { try DailyStore(root: root).save(next, reading: true); reading = next }
        catch { issue = .reading }
    }
}

struct DeveloperDailyPage: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var daily = DailyViewModel()
    @State private var refreshID = 0
    @State private var topic: DailyTopic?
    @State private var savedOnly = false
    @State private var search = ""
    @State private var copied: String?
    @State private var sourceID: String?
    private var articles: [DailyArticle] {
        let values = savedOnly
            ? (daily.reading.bookmarks ?? []).filter { DailyContent.validBookmark($0, now: Date()) && daily.reading.saved.contains($0.id) }.sorted { $0.published > $1.published }
            : DailyContent.recent(daily.snapshot.articles, now: Date())
        return values.filter {
            (topic == nil || $0.topic == topic) && (sourceID == nil || $0.sourceID == sourceID) && (!savedOnly || daily.reading.saved.contains($0.id)) &&
            (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || ($0.source?.name.localizedCaseInsensitiveContains(search) ?? false))
        }
    }
    private var today: [DailyArticle] { articles.filter { $0.published >= Date().addingTimeInterval(-86_400) } }
    private var earlier: [DailyArticle] { articles.filter { $0.published < Date().addingTimeInterval(-86_400) } }
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            WorkshopCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label(model.text("خُد فكرة مفيدة لشغل النهارده", "Find one useful idea for today"), systemImage: "newspaper").font(.title3.weight(.semibold))
                        Spacer()
                        if daily.working { ProgressView().controlSize(.small).accessibilityLabel("Refreshing news") }
                        Button(model.text("تحديث الأخبار", "Refresh news")) { refreshID += 1 }.disabled(daily.working)
                    }
                    Text(model.text("أخبار من مصادرها، وتحديث يومي عند فتح الصفحة. القهوة عليك؛ قراءة الأخبار من غير حساب AI.", "Original sources. A daily refresh when opened. Bring coffee; no AI account needed.")).font(.callout).foregroundStyle(.secondary)
                    if let checked = daily.snapshot.checkedAt {
                        Text(model.text("آخر فحص: ", "Last checked: ") + checked.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    if !daily.snapshot.failures.isEmpty {
                        Label(model.text("تعذّر تحديث بعض المصادر: ", "Some sources could not be refreshed: ") + daily.snapshot.failures.compactMap { id in DailySource.all.first { $0.id == id }?.name }.joined(separator: ", "), systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(model.text("الأخبار المحفوظة بتفضل ظاهرة بتاريخ نشرها. جرّب تحديث الأخبار لاحقًا.", "Cached items keep their original publication dates. Try Refresh news again later.")).font(.caption)
                    }
                    if let issue = daily.issue { Label(issue.label(model.arabic), systemImage: "exclamationmark.circle").font(.caption) }
                }
            }
            HStack {
                Picker(model.text("الموضوع", "Topic"), selection: $topic) {
                    Text(model.text("كل المواضيع", "All topics")).tag(Optional<DailyTopic>.none)
                    ForEach(DailyTopic.allCases) { Text($0.title(model.arabic)).tag(Optional($0)) }
                }.frame(maxWidth: 290)
                Toggle(model.text("المحفوظة", "Saved"), isOn: $savedOnly).toggleStyle(.checkbox)
                TextField(model.text("ابحث في العناوين والمصادر", "Search headlines and sources"), text: $search).textFieldStyle(.roundedBorder)
            }
            Picker(model.text("المصدر", "Source"), selection: $sourceID) {
                Text(model.text("كل المصادر", "All sources")).tag(Optional<String>.none)
                ForEach(DailySource.all) { Text($0.name).tag(Optional($0.id)) }
            }.frame(maxWidth: 360)
            if savedOnly {
                Text(model.text("محفوظة للقراءة لاحقًا", "Saved for later")).font(.title2.weight(.semibold))
                ForEach(articles) { articleCard($0) }
            } else if today.isEmpty {
                Text(model.text("مفيش أخبار خلال آخر ٢٤ ساعة مطابقة لاختياراتك. مش هنعتبر الأخبار القديمة أخبار النهارده.", "No matching headlines from the past 24 hours. Earlier items are shown below with their publication dates.")).foregroundStyle(.secondary)
            } else {
                Text(model.text("آخر ٢٤ ساعة", "Past 24 hours")).font(.title2.weight(.semibold))
                ForEach(today) { articleCard($0) }
            }
            if !savedOnly && !earlier.isEmpty {
                Text(model.text("الأيام السابقة — حتى ١٤ يومًا", "Earlier — up to 14 days")).font(.title2.weight(.semibold))
                ForEach(earlier) { articleCard($0) }
            }
            if articles.isEmpty && !daily.working {
                ContentUnavailableView(model.text("لا توجد أخبار للعرض", "No headlines to show"), systemImage: "newspaper", description: Text(model.text("غيّر الفلاتر أو حدّث الأخبار. تحتاج الإنترنت للتحديث؛ المحتوى المحفوظ متاح دون اتصال.", "Change filters or refresh. Refreshing needs internet; saved editions remain available offline.")))
            }
            DisclosureGroup(model.text("المصادر وطريقة اختيار الأخبار", "Sources & how this works")) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(DailySource.all) { source in
                        HStack {
                            Link(source.name, destination: source.feed)
                            if let updated = daily.snapshot.sourceUpdatedAt?[source.id] {
                                Text(model.text("آخر تحديث ناجح: ", "Last successful update: ") + updated.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            } else { Text(model.text("لم ينجح التحديث بعد", "Not refreshed successfully yet")).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    Text(model.text("العناوين والتواريخ من خلاصات الناشرين. لا نعيد نشر المقالات ولا نتحقق مستقلًا من كل ادعاء. اقتراحات الخطوات عامة ومن الفواعلي، وليست تقييمًا لقدرات أداة بعينها. لا يتم تنزيل صور أو تشغيل محتوى المصادر. يتصل التحديث بمواقع المصادر مباشرة؛ لا تُرسل ملفات مشروعك أو محادثاتك.", "Headlines and publication dates come from publisher feeds. Articles are not republished and claims are not independently verified. Next steps are general Fawaly suggestions, not assessments of a specific tool. No source scripts or images are loaded. Refresh contacts the publishers directly; project files and chats are never sent.")).font(.caption).foregroundStyle(.secondary)
                    Text(model.text("بتفضل المقالات المحفوظة عندك لحد ما تلغي حفظها (حتى ٢٠٠ مقال)، حتى بعد خروجها من نافذة الأخبار ذات الـ١٤ يومًا. عناوين المصادر بتفضل بلغتها الأصلية.", "Saved articles stay on this Mac until you unsave them (up to 200), including after they leave the 14-day news window. Publisher headlines keep their original language.")).font(.caption).foregroundStyle(.secondary)
                    Text(model.text("التحديث التلقائي مرة كل ٢٤ ساعة عند فتح الصفحة؛ اليدوي مرة في الدقيقة. لا يتم إرسال طلبات AI أو استخدام اشتراكاتك لتحديث الأخبار.", "Automatic refresh checks once every 24 hours when this page opens; manual refresh is limited to once a minute. News refresh never sends AI requests or uses your subscriptions.")).font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 10)
            }
        }
        .task(id: refreshID) { await daily.update(root: model.dataDirectory, force: refreshID > 0) }
    }
    private func articleCard(_ article: DailyArticle) -> some View {
        WorkshopCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(article.source?.name ?? "Publisher").font(.caption.weight(.semibold))
                    Text(model.text("· نشر المصدر: ", "· Published: ") + article.published.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if daily.reading.read.contains(article.id) { Label(model.text("مقروء", "Read"), systemImage: "checkmark").font(.caption) }
                    Text(article.topic.title(model.arabic)).font(.caption).padding(6).background(Workshop.yellow.opacity(0.15), in: Capsule())
                }
                Text(article.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                Text(model.text("اقتراح من الفواعلي · ", "Fawaly suggestion · ") + article.topic.nextStep(model.arabic)).font(.callout).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack { actions(article) }
                    VStack(alignment: .leading) { actions(article) }
                }
                if copied == article.id { Text(model.text("اتنسخ طلب مراجعة المصدر وخطة تجربة. الصقه في محادثتك المعتادة مع الأساسي.", "Copied a source-review and trial-planning request. Paste it into your usual primary-agent chat.")).font(.caption).foregroundStyle(.secondary) }
            }
        }.accessibilityElement(children: .contain)
    }
    @ViewBuilder private func actions(_ article: DailyArticle) -> some View {
        Link(model.text("اقرأ المصدر", "Read original"), destination: article.url)
        Button(model.text("جهّز مهمة لفريقي", "Prepare a team task")) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(article.taskPrompt(arabic: model.arabic), forType: .string); copied = article.id
        }
        Button(daily.reading.saved.contains(article.id) ? model.text("إلغاء الحفظ", "Unsave") : model.text("احفظ لوقت لاحق", "Save for later")) { daily.toggle(article, saved: true, root: model.dataDirectory) }
        Button(daily.reading.read.contains(article.id) ? model.text("علّمه غير مقروء", "Mark unread") : model.text("علّمه مقروء", "Mark read")) { daily.toggle(article, saved: false, root: model.dataDirectory) }
    }
}
