import Foundation
import SwiftUI

/// The restored Tasks & reviews ledger: one combined, searchable list of local
/// work results and team jobs, with independent primary review history kept
/// clearly separate from each worker report. The query rules are pure and live
/// in `TasksLedgerQuery` so they can be regression-tested without any UI.

enum LedgerFilter: String, CaseIterable, Identifiable, Sendable {
    case all, queued, running, needsReview, accepted, changes, rejected, failed, cancelled, completed
    var id: Self { self }

    func label(_ arabic: Bool) -> String {
        switch self {
        case .all: arabic ? "الكل" : "All"
        case .queued: arabic ? "في الطابور" : "Queued"
        case .rejected: arabic ? "مرفوضة" : "Rejected"
        case .cancelled: arabic ? "ملغاة" : "Cancelled"
        case .running: arabic ? "شغّالة" : "Running"
        case .needsReview: arabic ? "محتاجة مراجعة" : "Needs review"
        case .accepted: arabic ? "مقبولة" : "Accepted"
        case .changes: arabic ? "طلب تعديل" : "Changes"
        case .failed: arabic ? "فاشلة" : "Failed"
        case .completed: arabic ? "مكتملة" : "Completed"
        }
    }
}

enum LedgerStatus: String, Equatable, Sendable {
    case queued, running, needsReview, completed, accepted, changesRequested, rejected, failed, cancelled

    init(jobStatus: String) {
        switch jobStatus {
        case "running": self = .running
        case "needs_handoff": self = .needsReview
        case "reviewed": self = .accepted
        case "changes_requested": self = .changesRequested
        case "rejected": self = .rejected
        case "completed": self = .completed
        case "cancelled": self = .cancelled
        default: self = .failed
        }
    }

    func label(_ arabic: Bool) -> String {
        switch self {
        case .queued: arabic ? "في الطابور" : "Queued"
        case .running: arabic ? "شغّالة" : "Running"
        case .needsReview: arabic ? "محتاجة مراجعة الأساسي" : "Needs primary review"
        case .completed: arabic ? "مكتملة" : "Completed"
        case .accepted: arabic ? "اتقبلت بعد المراجعة" : "Accepted after review"
        case .changesRequested: arabic ? "محتاجة تعديل" : "Changes requested"
        case .rejected: arabic ? "مرفوضة بعد المراجعة" : "Rejected after review"
        case .failed: arabic ? "فاشلة" : "Failed"
        case .cancelled: arabic ? "اتلغت" : "Cancelled"
        }
    }
}

/// A ledger row is either a saved local task or a team job; nothing is copied,
/// so old records (including legacy jobs without reviews) pass through intact.
enum LedgerEntry: Identifiable, Equatable, Sendable {
    case work(WorkItem)
    case job(TeamJob)

    var id: UUID {
        switch self {
        case .work(let item): item.id
        case .job(let job): job.id
        }
    }

    var isTeamJob: Bool {
        if case .job = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .work(let item): item.title
        case .job(let job): job.title
        }
    }

    var detail: String {
        switch self {
        case .work(let item): item.details
        case .job: ""
        }
    }

    var created: Date {
        switch self {
        case .work(let item): item.created
        case .job(let job): job.started
        }
    }

    var finished: Date? {
        switch self {
        case .work(let item): item.completed
        case .job(let job): job.finished
        }
    }

    /// Chronological position: when the result landed, or when the row began.
    var sortDate: Date { finished ?? created }

    var status: LedgerStatus {
        switch self {
        case .work(let item): item.completed == nil ? .queued : .completed
        case .job(let job): job.reviewRequired && job.status == "completed" ? .needsReview : LedgerStatus(jobStatus: job.status)
        }
    }

    var resultText: String? {
        switch self {
        case .work(let item): item.result
        case .job(let job): job.result
        }
    }

    var workerLabel: String? {
        switch self {
        case .work: nil
        case .job(let job): job.worker.label
        }
    }

    var primaryLabel: String? {
        switch self {
        case .work: nil
        case .job(let job): job.primary?.label
        }
    }

    var reviews: [TeamReview] {
        switch self {
        case .work: []
        case .job(let job): job.reviews ?? []
        }
    }

    /// Finished team jobs the primary has not reviewed yet; the UI shows an
    /// explicit no-review note instead of pretending a review exists.
    var showsMissingReviewNotice: Bool {
        isTeamJob && finished != nil && reviews.isEmpty
    }

    var searchableText: String {
        var parts = [title, detail]
        if let resultText { parts.append(resultText) }
        if let workerLabel { parts.append(workerLabel) }
        if let primaryLabel { parts.append(primaryLabel) }
        for review in reviews {
            parts.append(review.summary)
            parts.append(review.verification)
        }
        return parts.joined(separator: "\n")
    }

    func matches(_ filter: LedgerFilter) -> Bool {
        switch filter {
        case .all: true
        case .queued: status == .queued
        case .rejected: status == .rejected
        case .cancelled: status == .cancelled
        case .running: status == .running
        case .needsReview: status == .needsReview
        case .accepted: status == .accepted
        case .changes: status == .changesRequested
        case .failed: status == .failed
        case .completed: status == .completed
        }
    }

    func sourceLabel(_ arabic: Bool) -> String {
        isTeamJob ? (arabic ? "مهمة فريق" : "Team job") : (arabic ? "مهمة محلية" : "Local task")
    }
}

enum TasksLedgerQuery {
    /// Combined ledger, newest result first, with a deterministic tie-break so
    /// equal timestamps never shuffle between reloads.
    static func entries(work: [WorkItem], jobs: [TeamJob]) -> [LedgerEntry] {
        (work.map(LedgerEntry.work) + jobs.map(LedgerEntry.job)).sorted { lhs, rhs in
            if lhs.sortDate != rhs.sortDate { return lhs.sortDate > rhs.sortDate }
            if lhs.created != rhs.created { return lhs.created > rhs.created }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    static func filtered(work: [WorkItem], jobs: [TeamJob], filter: LedgerFilter, search: String) -> [LedgerEntry] {
        entries(work: work, jobs: jobs).filter { $0.matches(filter) && matches($0, query: search) }
    }

    /// Case- and diacritic-insensitive match over title, details, worker report,
    /// worker/primary names, and every independent review's summary + evidence.
    /// A blank query matches everything under the current filter.
    static func matches(_ entry: LedgerEntry, query: String) -> Bool {
        let needle = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return true }
        return normalized(entry.searchableText).contains(needle)
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

struct TasksLedger: View {
    @EnvironmentObject private var model: AppModel
    @State private var filter = LedgerFilter.all
    @State private var search = ""

    private var baseEntries: [LedgerEntry] {
        TasksLedgerQuery.entries(work: model.state.work, jobs: model.teamJobs)
    }

    private var entries: [LedgerEntry] {
        baseEntries.filter { $0.matches(filter) && TasksLedgerQuery.matches($0, query: search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            controls
            if entries.isEmpty {
                emptyState
            } else {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(entries) { entry in LedgerEntryRow(entry: entry) }
                }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(model.text("ابحث في النتايج وأدلة المراجعة…", "Search results and review evidence…"), text: $search)
                .textFieldStyle(.roundedBorder)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(LedgerFilter.allCases) { item in
                        chip(item)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func chip(_ item: LedgerFilter) -> some View {
        let selected = filter == item
        let count = baseEntries.filter { $0.matches(item) }.count
        return Button { filter = item } label: {
            Text("\(item.label(model.arabic)) \(count)")
                .font(.callout)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .foregroundStyle(selected ? Color.black.opacity(0.85) : .primary)
                .background(selected ? Workshop.yellow : Color.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(selected ? 0 : 0.15)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var emptyState: some View {
        WorkshopCard {
            VStack(alignment: .leading, spacing: 6) {
                if baseEntries.isEmpty {
                    Label(model.text("السجل فاضي لسه", "The ledger is empty"), systemImage: "tray")
                        .font(.headline)
                    Text(model.text("نفّذ معاينة محلية أو اطلب من الأساسي يفوّض شغل، وهتلاقي تقرير العامل ومراجعة الأساسي هنا.",
                                    "Run a local preview or ask your primary to delegate work; the worker report and primary review will appear here."))
                        .foregroundStyle(.secondary)
                } else if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label(model.text("مفيش عناصر تحت الفلتر ده", "Nothing under this filter yet"), systemImage: "line.3.horizontal.decrease.circle")
                        .font(.headline)
                    Text(model.text("جرّب فلتر تاني أو امسح البحث.", "Try another filter or clear the search."))
                        .foregroundStyle(.secondary)
                } else {
                    Label(model.text("مفيش نتايج بتطابق البحث ده", "No results match this search"), systemImage: "magnifyingglass")
                        .font(.headline)
                    Text(model.text("غيّر كلمة البحث أو الفلتر.", "Try a different search word or filter."))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct LedgerEntryRow: View {
    let entry: LedgerEntry
    @EnvironmentObject private var model: AppModel

    var body: some View {
        WorkshopCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                        Text(timestampLine).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    statusBadge
                }
                if case .job(let job) = entry, job.status == "running" { RunningWorkerControls(job: job) }
                if !entry.detail.isEmpty {
                    Text(entry.detail).font(.callout).foregroundStyle(.secondary)
                }
                if let worker = entry.workerLabel {
                    Text(workerLine(worker)).font(.caption).foregroundStyle(.secondary)
                }
                if let result = entry.resultText, !result.isEmpty {
                    resultSection(result)
                }
                if entry.isTeamJob {
                    reviewSection
                }
            }
        }
    }

    private var timestampLine: String {
        let when = entry.sortDate.formatted(date: .abbreviated, time: .shortened)
        return entry.sourceLabel(model.arabic) + " · " + when
    }

    private func workerLine(_ worker: String) -> String {
        var line = model.text("العامل: ", "Worker: ") + worker
        if let primary = entry.primaryLabel {
            line += " · " + model.text("الأساسي: ", "Primary: ") + primary
        }
        return line
    }

    private var statusBadge: some View {
        Text(entry.status.label(model.arabic))
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(statusColor.opacity(0.15), in: Capsule())
            .foregroundStyle(statusColor)
    }

    private var statusColor: Color {
        switch entry.status {
        case .running: .blue
        case .needsReview, .changesRequested: .orange
        case .completed, .accepted: .green
        case .rejected, .failed: .red
        case .queued, .cancelled: .secondary
        }
    }

    private func resultSection(_ result: String) -> some View {
        DisclosureGroup(entry.isTeamJob ? model.text("تقرير العامل", "Worker report") : model.text("النتيجة", "Result")) {
            Text((try? AttributedString(markdown: result, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(result))
                .font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
        }
    }

    @ViewBuilder private var reviewSection: some View {
        if entry.reviews.isEmpty {
            if entry.finished != nil {
                Label(model.text("لسه مفيش مراجعة أساسي مستقلة متسجلة للمهمة دي.", "No independent primary review recorded for this job yet."),
                      systemImage: "questionmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.text("مراجعة الأساسي المستقلة", "Independent primary review"))
                    .font(.caption.weight(.semibold))
                ForEach(Array(entry.reviews.enumerated()), id: \.offset) { index, review in
                    reviewRow(review, index: index, total: entry.reviews.count)
                }
            }
            .padding(.top, 2)
        }
    }

    private func reviewRow(_ review: TeamReview, index: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(decisionLabel(review.decision))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(decisionColor(review.decision).opacity(0.16), in: Capsule())
                    .foregroundStyle(decisionColor(review.decision))
                Text(review.primary.label).font(.caption).foregroundStyle(.secondary)
                Text("·").foregroundStyle(.secondary)
                Text(review.created.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                if let score = review.score {
                    Text("·").foregroundStyle(.secondary)
                    Text(model.text("التقييم ", "Score ") + "\(score)/5").font(.caption).foregroundStyle(.secondary)
                }
                if total > 1 {
                    Spacer(minLength: 4)
                    Text(model.text("مراجعة \(index + 1) من \(total)", "Review \(index + 1) of \(total)"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if !review.summary.isEmpty {
                Text(review.summary).font(.callout).textSelection(.enabled)
            }
            DisclosureGroup(model.text("أدلة التحقق", "Verification evidence")) {
                Text(review.verification).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func decisionLabel(_ decision: TeamReview.Decision) -> String {
        switch decision {
        case .accepted: model.text("مقبول", "Accepted")
        case .changesRequested: model.text("طلب تعديل", "Changes requested")
        case .rejected: model.text("مرفوض", "Rejected")
        }
    }

    private func decisionColor(_ decision: TeamReview.Decision) -> Color {
        switch decision {
        case .accepted: .green
        case .changesRequested: .orange
        case .rejected: .red
        }
    }
}
