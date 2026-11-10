import Foundation
import SQLite3
import CryptoKit

public enum ConsultReason: String, Codable, Sendable, CaseIterable { case userRequest = "user_request", plan, riskyChange = "risky_change", disputedReview = "disputed_review" }
public enum ConsultDecision: String, Codable, Sendable, CaseIterable { case adopted, partly, rejected }
public enum ConsultStatus: String, Codable, Sendable { case open, closed, noDecision = "no_decision" }

public struct ConsultRound: Codable, Equatable, Sendable {
    public static let adviceLimit = 64 * 1024
    public var index: Int
    /// What the usta asked in this round (round 1: the question itself).
    public var prompt: String
    public var advice: String
    public var truncated: Bool
    public var note: String? = nil
    public var status: String
    public var startedAt: Date
    public var finishedAt: Date?
    public init(index: Int, prompt: String, advice: String, status: String, startedAt: Date, finishedAt: Date?) {
        self.index = index; self.prompt = prompt; self.status = status; self.startedAt = startedAt; self.finishedAt = finishedAt
        (self.advice, self.truncated) = Self.cap(advice)
    }
    static func cap(_ text: String) -> (String, Bool) {
        guard text.utf8.count > adviceLimit else { return (text, false) }
        var result = ""; var bytes = 0
        for c in text { let n = String(c).utf8.count; if bytes + n > adviceLimit { break }; result.append(c); bytes += n }
        return (result, true)
    }
}

public struct ConsultRecord: Codable, Equatable, Sendable, Identifiable {
    public var requestedModel: String?
    public var modelPinned: Bool?
    public var id: UUID
    public var caller: Rater
    public var reason: ConsultReason
    public var provider: String
    public var model: String
    public var modeAtStart: AdvisorMode
    public var question: String
    /// Only a fingerprint and size of the shared context are kept on this Mac.
    public var contextSHA256: String?
    public var contextBytes: Int
    public var rounds: [ConsultRound]
    public var status: ConsultStatus = .open
    public var decision: ConsultDecision?
    public var summary: String?
    public var created: Date
    public var updated: Date
    public init(id: UUID = UUID(), caller: Rater, reason: ConsultReason, provider: String, model: String, modeAtStart: AdvisorMode, question: String, context: String?, rounds: [ConsultRound], created: Date) {
        self.id = id; self.caller = caller; self.reason = reason; self.provider = provider; self.model = model; self.modeAtStart = modeAtStart
        self.question = question; self.rounds = rounds; self.created = created; self.updated = created
        contextBytes = context?.utf8.count ?? 0
        contextSHA256 = context.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
    }
}

/// Consultation records live next to the work log; an additive table, so older engines are unaffected.
public struct ConsultLog: Sendable {
    public static let openLimit: TimeInterval = 24 * 3600
    public let root: URL
    public init(root: URL) { self.root = root }
    private func database<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try WorkLog(root: root).database { db in
            guard sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS consults(id TEXT PRIMARY KEY, created REAL NOT NULL, status TEXT NOT NULL, record TEXT NOT NULL)", nil, nil, nil) == SQLITE_OK else { throw FawalyError.invalid("Cannot initialize consultations") }
            return try body(db)
        }
    }
    private static func encoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; e.outputFormatting = [.sortedKeys]; return e }
    private static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }
    private func write(_ record: ConsultRecord, sql: String, replacing previous: ConsultRecord? = nil) throws {
        let json = String(decoding: try Self.encoder().encode(record), as: UTF8.self)
        try database { db in
            var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw FawalyError.invalid("Cannot prepare consultation write") }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, record.id.uuidString, -1, transient); sqlite3_bind_double(stmt, 2, record.created.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, record.status.rawValue, -1, transient); sqlite3_bind_text(stmt, 4, json, -1, transient)
            if let previous {
                let original = String(decoding: try Self.encoder().encode(previous), as: UTF8.self)
                sqlite3_bind_text(stmt, 5, original, -1, transient)
            }
            guard sqlite3_step(stmt) == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw FawalyError.invalid("Consultation not saved") }
        }
    }
    public func insert(_ record: ConsultRecord) throws { try write(record, sql: "INSERT INTO consults(id, created, status, record) VALUES(?1, ?2, ?3, ?4)") }
    public func update(_ record: ConsultRecord) throws { try write(record, sql: "UPDATE consults SET created = ?2, status = ?3, record = ?4 WHERE id = ?1") }
    func update(_ record: ConsultRecord, replacing previous: ConsultRecord) throws {
        try write(record, sql: "UPDATE consults SET created = ?2, status = ?3, record = ?4 WHERE id = ?1 AND record = ?5", replacing: previous)
    }
    
    /// A record this version cannot decode is skipped and counted instead of
    /// hiding every other consultation. A busy or failing database is an
    /// error, never a silently shorter list. The limit counts readable records.
    private func select(_ sql: String, limit: Int? = nil, _ bind: (OpaquePointer?) -> Void = { _ in }) throws -> (records: [ConsultRecord], unreadable: Int) {
        try database { db in
            var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw FawalyError.invalid("Cannot read consultations") }
            bind(stmt)
            var records: [ConsultRecord] = [], unreadable = 0
            var result = sqlite3_step(stmt)
            while result == SQLITE_ROW {
                if let limit, records.count >= limit { return (records, unreadable) }
                if let text = sqlite3_column_text(stmt, 0),
                   let record = try? Self.decoder().decode(ConsultRecord.self, from: Data(String(cString: text).utf8)) {
                    records.append(record)
                } else { unreadable += 1 }
                result = sqlite3_step(stmt)
            }
            guard result == SQLITE_DONE else { throw FawalyError.invalid("Cannot read consultations") }
            return (records, unreadable)
        }
    }
    public func get(_ id: UUID) throws -> ConsultRecord? {
        try select("SELECT record FROM consults WHERE id = ?1") { sqlite3_bind_text($0, 1, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }.records.first
    }
    public func recent(limit: Int = 100) throws -> [ConsultRecord] { try load(limit: limit).records }
    func load(limit: Int = 100) throws -> (records: [ConsultRecord], unreadable: Int) {
        try select("SELECT record FROM consults ORDER BY created DESC, id DESC", limit: max(1, min(limit, 1000)))
    }
    /// Open consultations older than 24 h become "no decision recorded".
    @discardableResult public func expireOpen(now: Date) throws -> Int {
        var count = 0
        for var record in try select("SELECT record FROM consults WHERE status = 'open'").records where now.timeIntervalSince(record.created) > Self.openLimit {
            record.status = .noDecision; record.updated = now; try update(record); count += 1
        }
        return count
    }
}
