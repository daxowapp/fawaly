import Foundation
import SQLite3

public enum Rater: String, Codable, Sendable, CaseIterable {
    case claude, codex, kimi, human
    case zai, minimax, deepseek, openrouter, anthropicAPI, openAIAPI, ollama, lmstudio
}

public enum AdvisorMode: String, Codable, Sendable, CaseIterable {
    case off, onRequest = "on_request", important
}

public struct AdvisorSeat: Codable, Equatable, Sendable {
    var provider: String
    var model: String
    var enabled = true
}

public struct AdvisorSettings: Codable, Equatable, Sendable {
    static let rounds = 1...5
    static let minutes = 1...10
    var mode: AdvisorMode = .onRequest
    var maxRounds = 3
    var timeoutMinutes = 2
    var seats = [AdvisorSeat(provider: "local-preview", model: "checklist")]
}

enum Billing: Equatable {
    case local, subscription, metered
}

struct Provider {
    let name: String
    let models: [String]
    let billing: Billing
}

enum OfficialClient: String {
    case codex
}

enum FawalyError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

enum Paths {
    static func officialSignIn(_ client: OfficialClient, root: URL) -> URL {
        root.appendingPathComponent("official", isDirectory: true)
            .appendingPathComponent(client.rawValue, isDirectory: true)
    }

    static func ensurePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
    }

    static func rebuiltRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fawaly Rebuilt", isDirectory: true)
    }
}

struct WorkLog {
    let root: URL

    func database<T>(_ action: (OpaquePointer) throws -> T) throws -> T {
        try Paths.ensurePrivateDirectory(root)
        let path = root.appendingPathComponent("worklog.sqlite").path
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        defer { if let handle { sqlite3_close(handle) } }
        guard status == SQLITE_OK, let handle else {
            throw FawalyError.invalid("The local work log could not be opened.")
        }
        sqlite3_busy_timeout(handle, 3_000)
        return try action(handle)
    }

    /// Identity, size and modification time of the database file. Every commit
    /// rewrites part of the file, so an equal value before and after a read
    /// means nothing was committed in between.
    var signature: WorkLogSignature? {
        var info = stat()
        guard stat(root.appendingPathComponent("worklog.sqlite").path, &info) == 0 else { return nil }
        return WorkLogSignature(file: UInt64(info.st_ino), size: Int64(info.st_size),
                                seconds: Int(info.st_mtimespec.tv_sec), nanoseconds: Int(info.st_mtimespec.tv_nsec))
    }
}

struct WorkLogSignature: Equatable, Sendable {
    let file: UInt64
    let size: Int64
    let seconds: Int
    let nanoseconds: Int
}

struct WorkItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let details: String
    let created: Date
    var completed: Date?
    var result: String?

    init(title: String, details: String, created: Date = Date()) {
        id = UUID()
        self.title = title
        self.details = details
        self.created = created
    }
}

struct WorkshopState: Codable, Equatable {
    var arabic = false
    var advisors = AdvisorSettings()
    var work: [WorkItem] = []
    var provider: EndpointSettings?
    var onboardingVersion: Int?
    var team: TeamSettings?
    var projectDirectory: URL?
    var kimiRegion: KimiRegion?
    var preferences: WorkshopPreferences?
    var workerModels: [String: String]?
    var delegationPolicy: DelegationPolicy?
}

struct WorkshopStore {
    let root: URL
    private var file: URL { root.appendingPathComponent("workshop.json") }

    func load() throws -> WorkshopState {
        do {
            return try JSONDecoder().decode(WorkshopState.self, from: Data(contentsOf: file))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return WorkshopState()
        }
    }

    func save(_ state: WorkshopState) throws {
        try Paths.ensurePrivateDirectory(root)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: file, options: .atomic)
    }
}
