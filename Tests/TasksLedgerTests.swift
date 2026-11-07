import Foundation
import Testing
@testable import FawalyApp

// Pure ledger query/filter regressions. Fixtures are isolated values built in
// memory — no AppModel, no live store, no team settings.

private func ledgerWorkItem(
    title: String, details: String = "", created: TimeInterval,
    completed: TimeInterval? = nil, result: String? = nil
) -> WorkItem {
    var item = WorkItem(title: title, details: details, created: Date(timeIntervalSince1970: created))
    item.completed = completed.map { Date(timeIntervalSince1970: $0) }
    item.result = result
    return item
}

private func ledgerTeamJob(
    title: String, status: String, started: TimeInterval, finished: TimeInterval? = nil,
    result: String? = nil, reviews: [TeamReview]? = nil, reviewRequired: Bool = false
) -> TeamJob {
    var job = TeamJob(primary: .codex, worker: .kimi, title: title)
    job.status = status
    job.started = Date(timeIntervalSince1970: started)
    job.finished = finished.map { Date(timeIntervalSince1970: $0) }
    job.result = result
    job.reviews = reviews
    job.reviewRequired = reviewRequired
    return job
}

private func ledgerReview(
    decision: TeamReview.Decision, summary: String, verification: String,
    score: Int? = nil, created: TimeInterval = 1_000
) -> TeamReview {
    TeamReview(decision: decision, primary: .codex, summary: summary,
               verification: verification, score: score, created: Date(timeIntervalSince1970: created))
}

@Test func combinedLedgerMergesLocalTasksAndTeamJobsNewestFirst() {
    let oldLocal = ledgerWorkItem(title: "Old local", created: 100, completed: 500, result: "done old")
    let reviewedJob = ledgerTeamJob(title: "New job", status: "reviewed", started: 900, finished: 1_000, result: "ok")
    let runningJob = ledgerTeamJob(title: "Running job", status: "running", started: 1_100)

    let entries = TasksLedgerQuery.entries(work: [oldLocal], jobs: [reviewedJob, runningJob])

    #expect(entries.map(\.title) == ["Running job", "New job", "Old local"])
    #expect(entries.map(\.status) == [.running, .accepted, .completed])
}

@Test func everyFilterSelectsOnlyItsOwnStatuses() {
    let queued = ledgerWorkItem(title: "Queued", created: 10)
    let doneLocal = ledgerWorkItem(title: "Done local", created: 20, completed: 30)
    let running = ledgerTeamJob(title: "Running", status: "running", started: 40)
    let needs = ledgerTeamJob(title: "Needs", status: "needs_handoff", started: 50, finished: 60, reviewRequired: true)
    let completedJob = ledgerTeamJob(title: "Completed", status: "completed", started: 70, finished: 80)
    let accepted = ledgerTeamJob(title: "Accepted", status: "reviewed", started: 90, finished: 100)
    let changes = ledgerTeamJob(title: "Changes", status: "changes_requested", started: 110, finished: 120)
    let rejected = ledgerTeamJob(title: "Rejected", status: "rejected", started: 130, finished: 140)
    let failed = ledgerTeamJob(title: "Failed", status: "failed", started: 150, finished: 160, result: "boom")
    let unknown = ledgerTeamJob(title: "Unknown", status: "exploded", started: 170, finished: 180)
    let cancelled = ledgerTeamJob(title: "Cancelled", status: "cancelled", started: 190, finished: 200)

    let all = TasksLedgerQuery.entries(
        work: [queued, doneLocal],
        jobs: [running, needs, completedJob, accepted, changes, rejected, failed, unknown, cancelled])

    func titles(_ filter: LedgerFilter) -> [String] {
        all.filter { $0.matches(filter) }.map(\.title)
    }

    #expect(titles(.all).count == 11)
    #expect(titles(.running) == ["Running"])
    #expect(titles(.needsReview) == ["Needs"])
    #expect(titles(.completed).sorted() == ["Completed", "Done local"])
    #expect(titles(.accepted) == ["Accepted"])
    #expect(titles(.changes) == ["Changes"])
    #expect(titles(.failed).sorted() == ["Failed", "Unknown"])
    #expect(titles(.rejected) == ["Rejected"])
    #expect(titles(.cancelled) == ["Cancelled"])
    #expect(titles(.queued) == ["Queued"])
    // Every state also remains visible in the combined ledger.
    #expect(titles(.all).contains("Rejected"))
    #expect(titles(.all).contains("Cancelled"))
    #expect(titles(.all).contains("Queued"))
}

@Test func searchFoldsCaseAndDiacriticsAcrossResultAndReviewEvidence() {
    let job = ledgerTeamJob(
        title: "Paint Café signage", status: "reviewed", started: 10, finished: 20,
        result: "Delivered the façade boards",
        reviews: [ledgerReview(decision: .accepted, summary: "Résumé approved",
                               verification: "Checked the résumé diff myself", score: 5)])
    let entry = TasksLedgerQuery.entries(work: [], jobs: [job])[0]

    #expect(TasksLedgerQuery.matches(entry, query: "cafe"))     // diacritic fold in title
    #expect(TasksLedgerQuery.matches(entry, query: "FAÇADE"))   // case + diacritic fold in worker report
    #expect(TasksLedgerQuery.matches(entry, query: "resume"))   // review summary folds too
    #expect(TasksLedgerQuery.matches(entry, query: "myself"))   // verification evidence
    #expect(TasksLedgerQuery.matches(entry, query: "kimi"))     // worker name
    #expect(TasksLedgerQuery.matches(entry, query: "codex"))    // primary name
    #expect(!TasksLedgerQuery.matches(entry, query: "plumbing"))
    #expect(TasksLedgerQuery.matches(entry, query: "   "))      // blank search = no narrowing
}

@Test func filterAndSearchComposeWithoutLeakingRows() {
    let fixLogin = ledgerTeamJob(title: "Fix login", status: "completed", started: 10, finished: 20, result: "green tests")
    let fixLogout = ledgerTeamJob(title: "Fix logout", status: "failed", started: 30, finished: 40, result: "red tests")

    let entries = TasksLedgerQuery.entries(work: [], jobs: [fixLogin, fixLogout])
    let completedLogin = entries.filter { $0.matches(.completed) && TasksLedgerQuery.matches($0, query: "login") }
    #expect(completedLogin.map(\.title) == ["Fix login"])
    #expect(entries.filter { $0.matches(.failed) && TasksLedgerQuery.matches($0, query: "login") }.isEmpty)
}

@Test func legacyTeamJobWithoutReviewsDecodesAndFlagsTheMissingReview() throws {
    var job = TeamJob(primary: .codex, worker: .kimi, title: "Legacy handoff")
    job.finished = Date(timeIntervalSince1970: 99)
    job.status = "needs_handoff"
    job.reviewRequired = true
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
    object.removeValue(forKey: "reviews")   // pre-review storage shape

    let legacy = try JSONDecoder().decode(TeamJob.self, from: JSONSerialization.data(withJSONObject: object))
    let entry = try #require(TasksLedgerQuery.entries(work: [], jobs: [legacy]).first)

    #expect(entry.status == .needsReview)
    #expect(entry.reviews.isEmpty)
    #expect(entry.showsMissingReviewNotice)   // UI must say "no review yet", not invent one
}

@Test func unfinishedJobsDoNotClaimAMissingReviewNote() {
    let running = ledgerTeamJob(title: "Still going", status: "running", started: 10)
    let entry = TasksLedgerQuery.entries(work: [], jobs: [running])[0]
    #expect(!entry.showsMissingReviewNotice)
}

@Test func independentReviewHistorySurvivesIntoEntriesInOrder() throws {
    let first = ledgerReview(decision: .changesRequested, summary: "Found a defect",
                             verification: "fixture check failed", score: 2, created: 10)
    let second = ledgerReview(decision: .accepted, summary: "Corrected",
                              verification: "reran the fixture check", score: 4, created: 20)
    let job = ledgerTeamJob(title: "Iterated", status: "reviewed", started: 1, finished: 30,
                            result: "worker output", reviews: [first, second])

    let entry = try #require(TasksLedgerQuery.entries(work: [], jobs: [job]).first)
    #expect(entry.reviews.map(\.decision) == [.changesRequested, .accepted])
    #expect(entry.reviews.map(\.score) == [2, 4])
    #expect(entry.reviews.map(\.primary) == [.codex, .codex])
    #expect(entry.resultText == "worker output")   // worker report stays separate evidence
}

@Test func sortIsDeterministicWhenTimestampsCollide() {
    let a = ledgerWorkItem(title: "A", created: 100, completed: 200)
    let b = ledgerWorkItem(title: "B", created: 100, completed: 200)

    let first = TasksLedgerQuery.entries(work: [a, b], jobs: []).map(\.id)
    let second = TasksLedgerQuery.entries(work: [b, a], jobs: []).map(\.id)
    #expect(first == second)   // same record set → same order, whatever the input order
}

@Test func filteredConvenienceEqualsFilterThenSearch() {
    let work = ledgerWorkItem(title: "Café plan", details: "mocktails only", created: 10, completed: 20, result: "menu ready")
    let job = ledgerTeamJob(title: "Café build", status: "completed", started: 30, finished: 40, result: "signage up")

    let manual = TasksLedgerQuery.entries(work: [work], jobs: [job])
        .filter { $0.matches(.completed) && TasksLedgerQuery.matches($0, query: "café") }
    let direct = TasksLedgerQuery.filtered(work: [work], jobs: [job], filter: .completed, search: "CAFE")
    #expect(manual.map(\.id) == direct.map(\.id))
    #expect(direct.count == 2)
}

@Test func legacyCompletedJobRequiringReviewIsNotMisfiledAsUnreviewedSuccess() {
    let job = ledgerTeamJob(title: "Legacy result", status: "completed", started: 1, finished: 2, reviewRequired: true)
    let entry = LedgerEntry.job(job)
    #expect(entry.matches(.needsReview))
    #expect(!entry.matches(.completed))
    #expect(entry.showsMissingReviewNotice)
}
