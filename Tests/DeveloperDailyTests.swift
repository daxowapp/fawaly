import Foundation
import Testing
@testable import FawalyApp

@Test func newWorkshopsStartInEnglishAndSavedArabicIsPreserved() throws {
    #expect(WorkshopState().arabic == false)
    var old = WorkshopState(); old.arabic = true
    #expect(try JSONDecoder().decode(WorkshopState.self, from: JSONEncoder().encode(old)).arabic)
}

@Test func dailyRSSHandlesDatesDedupeUnsafeLinksAndFutureItems() throws {
    let source = DailySource.all[1]
    let rss = """
    <rss><channel>
    <item><title>Agent &amp; MCP update</title><link>https://github.blog/changelog/new/?utm_source=example</link><pubDate>Sat, 07 Nov 2026 00:27:19 +0000</pubDate></item>
    <item><title>Duplicate</title><link>https://github.blog/changelog/new/</link><pubDate>Sat, 07 Nov 2026 00:27:19 +0000</pubDate></item>
    <item><title>Unsafe</title><link>https://github.blog.attacker.example/a</link><pubDate>Sat, 07 Nov 2026 00:27:19 +0000</pubDate></item>
    <item><title>Future</title><link>https://github.blog/future</link><pubDate>Sat, 07 Nov 2027 00:27:19 +0000</pubDate></item>
    <item><title>Undated</title><link>https://github.blog/undated</link></item>
    </channel></rss>
    """
    let parsed = try DailyFeedParser(source: source).parse(Data(rss.utf8))
    let recent = DailyContent.recent(parsed, now: try #require(DailyContent.date("2026-11-08T00:00:00Z")))
    #expect(recent.count == 1)
    #expect(recent.first?.title == "Agent & MCP update")
    #expect(recent.first?.topic == .agents)
    #expect(recent.first?.url.absoluteString == "https://github.blog/changelog/new/")
    #expect(recent.first?.taskPrompt(arabic: false).contains("untrusted data") == true)
}

@Test func dailyRejectsEntitiesAndParsesAtomWithoutExecutingHTML() throws {
    let parser = DailyFeedParser(source: DailySource.all[0])
    #expect(throws: (any Error).self) { try parser.parse(Data("<!DOCTYPE feed [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><rss/>".utf8)) }
    let atom = """
    <feed xmlns="http://www.w3.org/2005/Atom"><entry><title>Research update</title><link rel="alternate" href="https://openai.com/research/example"/><published>2026-11-07T01:02:03.000Z</published></entry></feed>
    """
    let values = try DailyFeedParser(source: DailySource.all[0]).parse(Data(atom.utf8))
    #expect(values.count == 1)
    #expect(values.first?.published == DailyContent.date("2026-11-07T01:02:03Z"))
    #expect(DailyContent.safeURL("https://user:secret@openai.com/a", source: DailySource.all[0]) == nil)
    #expect(DailyContent.safeURL("javascript:alert(1)", source: DailySource.all[0]) == nil)
    #expect(DailyContent.safeURL("https://openai.com:8443/a", source: DailySource.all[0]) == nil)
}

@Test func dailyCacheAndReadingChoicesStaySeparateFromWorkshopSettings() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DailyStore(root: root)
    #expect(try store.load().due(now: Date()))
    let snapshot = DailySnapshot(checkedAt: Date(), articles: [], failures: ["huggingface"])
    try store.save(snapshot)
    try store.save(DailyReadingState(saved: ["https://openai.com/a"], read: []), reading: true)
    #expect(try !store.load().due(now: Date()))
    #expect(try store.load().due(now: Date().addingTimeInterval(86_401)))
    #expect(try store.reading().saved.contains("https://openai.com/a"))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("workshop.json").path))
}

@Test func dailyPartialFailureKeepsDatedCacheAndSuccessfulSourcesStillUpdate() async throws {
    let now = try #require(DailyContent.date("2026-11-08T00:00:00Z"))
    let old = DailyArticle(sourceID: "huggingface", title: "Earlier research", url: URL(string: "https://huggingface.co/blog/earlier")!, published: now.addingTimeInterval(-90_000), topic: .models)
    let fresh = DailyArticle(sourceID: "github", title: "New coding tool", url: URL(string: "https://github.blog/new-tool")!, published: now.addingTimeInterval(-100), topic: .coding)
    let value = try await DailyFetcher.refresh(previous: DailySnapshot(checkedAt: now.addingTimeInterval(-86_500), articles: [old]), now: now) { source in
        if source.id == "huggingface" { throw FawalyError.invalid("HTTP 429 fixture") }
        return source.id == "github" ? [fresh] : []
    }
    #expect(value.failures == ["huggingface"])
    #expect(value.articles == [fresh, old])
    #expect(value.articles.last?.published == old.published)
    #expect(value.checkedAt == now)
    #expect(value.sourceUpdatedAt?["github"] == now)
    #expect(value.sourceUpdatedAt?["huggingface"] == nil)
}

@Test @MainActor func dailyBookmarksOutliveTheFeedWindowAndCanBeRemoved() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let article = DailyArticle(sourceID: "github", title: "Useful earlier release", url: URL(string: "https://github.blog/earlier-release")!, published: Date().addingTimeInterval(-30 * 86_400), topic: .coding)
    #expect(DailyContent.recent([article], now: Date()).isEmpty)
    #expect(DailyContent.validBookmark(article, now: Date()))
    let model = DailyViewModel()
    model.toggle(article, saved: true, root: root)
    #expect(try DailyStore(root: root).reading().bookmarks == [article])
    model.toggle(article, saved: true, root: root)
    #expect(try DailyStore(root: root).reading().bookmarks == [])
    #expect(model.reading.saved.isEmpty)
}

@Test func dailyAcceptsLiteralHTMLInIgnoredCDATAAndRejectsRealDeclarations() throws {
    let xml = """
    <rss><channel><item><title><![CDATA[Tool \u{202E}update]]></title><link>https://github.blog/safe</link><pubDate>Sat, 07 Nov 2026 00:27:19 +0000</pubDate><description><![CDATA[<!DOCTYPE html><script>ignored()</script>]]></description></item></channel></rss>
    """
    let values = try DailyFeedParser(source: DailySource.all[1]).parse(Data(xml.utf8))
    #expect(values.first?.title == "Tool update")
    #expect(values.first?.taskPrompt(arabic: false).contains("Untrusted publisher metadata") == true)
    #expect(values.first?.taskPrompt(arabic: false).contains("ignored()") == false)
    #expect(throws: (any Error).self) { try DailyFeedParser(source: DailySource.all[1]).parse(Data("<!DOCTYPE rss><rss><channel><![CDATA[literal]]></channel></rss>".utf8)) }
}
