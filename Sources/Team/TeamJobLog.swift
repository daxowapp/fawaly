import Foundation
import SQLite3

struct TeamReview: Codable, Equatable, Sendable {
    enum Decision: String, Codable, CaseIterable, Sendable {
        case accepted, changesRequested = "changes_requested", rejected
    }
    let decision: Decision
    let primary: EngineAgent
    let summary: String
    let verification: String
    let score: Int?
    var created = Date()
}

struct TeamJob: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    let primary: EngineAgent?
    let worker: EngineAgent
    let title: String
    var status = "running"
    var started = Date()
    var finished: Date?
    var result: String?
    var reviewRequired = false
    var reviews: [TeamReview]?

    var latestReview: TeamReview? { reviews?.last }

    func statusLabel(arabic: Bool) -> String {
        switch status {
        case "running": arabic ? "شغّال" : "Running"
        case "completed": arabic ? "خلصت" : "Completed"
        case "needs_handoff": arabic ? "محتاج مراجعة الأساسي" : "Needs primary review"
        case "cancelled": arabic ? "اتلغت" : "Cancelled"
        case "reviewed": arabic ? "اتراجعت واتقبلت" : "Reviewed and accepted"
        case "changes_requested": arabic ? "محتاجة تعديل" : "Changes requested"
        case "rejected": arabic ? "مرفوضة بعد المراجعة" : "Rejected after review"
        default: arabic ? "ما اكتملتش" : "Failed"
        }
    }
}

struct TeamJobLog: Sendable {
    let root: URL

    func save(_ job: TeamJob) throws {
        let data = try JSONEncoder().encode(job)
        try database { handle in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "INSERT INTO team_jobs(id, started, payload) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw failure }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, job.id.uuidString, -1, transient)
            sqlite3_bind_double(statement, 2, job.started.timeIntervalSince1970)
            _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), transient) }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure }
        }
    }

    func recent(limit: Int? = 50) throws -> [TeamJob] {
        try database { handle in
            var statement: OpaquePointer?
            let query = "SELECT payload FROM team_jobs ORDER BY started DESC" + (limit.map { " LIMIT \(max(1, $0))" } ?? "")
            guard sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw failure }
            defer { sqlite3_finalize(statement) }
            var records: [TeamJob] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                guard let bytes = sqlite3_column_blob(statement, 0) else { throw failure }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
                records.append(try JSONDecoder().decode(TeamJob.self, from: data))
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw failure }
            return records
        }
    }

    func recordReview(id: UUID, review: TeamReview) throws -> TeamJob {
        guard !review.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              review.summary.utf8.count <= 2_048,
              !review.verification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              review.verification.utf8.count <= 12_288,
              review.score.map({ (1...5).contains($0) }) ?? true else {
            throw FawalyError.invalid("Record a review summary, verification evidence, and an optional score from 1 to 5.")
        }
        return try database { handle in
            guard sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw failure }
            defer { sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "SELECT payload FROM team_jobs WHERE id = ?", -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw failure }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, id.uuidString, -1, transient)
            guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else {
                throw FawalyError.invalid("This worker result is no longer available.")
            }
            var job = try JSONDecoder().decode(TeamJob.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
            guard job.primary == review.primary, job.finished != nil, job.status != "running" else {
                throw FawalyError.invalid("Only the job’s primary can review a finished worker result.")
            }
            if job.latestReview.map({ $0.decision == review.decision && $0.summary == review.summary && $0.verification == review.verification && $0.score == review.score }) != true {
                job.reviews = (job.reviews ?? []) + [review]
            }
            job.status = review.decision == .accepted ? "reviewed" : review.decision.rawValue
            job.reviewRequired = review.decision == .changesRequested
            let payload = try JSONEncoder().encode(job)
            var update: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "UPDATE team_jobs SET payload = ? WHERE id = ?", -1, &update, nil) == SQLITE_OK,
                  let update else { throw failure }
            defer { sqlite3_finalize(update) }
            _ = payload.withUnsafeBytes { sqlite3_bind_blob(update, 1, $0.baseAddress, Int32($0.count), transient) }
            sqlite3_bind_text(update, 2, id.uuidString, -1, transient)
            guard sqlite3_step(update) == SQLITE_DONE, sqlite3_exec(handle, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw failure }
            return job
        }
    }

    private func database<T>(_ action: (OpaquePointer) throws -> T) throws -> T {
        try WorkLog(root: root).database { handle in
            guard sqlite3_exec(handle, "CREATE TABLE IF NOT EXISTS team_jobs(id TEXT PRIMARY KEY, started REAL NOT NULL, payload BLOB NOT NULL)", nil, nil, nil) == SQLITE_OK else { throw failure }
            return try action(handle)
        }
    }

    private var failure: FawalyError { .invalid("Team activity could not be saved or loaded.") }
}
