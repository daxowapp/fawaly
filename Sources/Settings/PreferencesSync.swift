import Darwin
import Foundation

/// A revisioned wrapper around `PreferencesBackup` for folder-based sync, e.g. a folder the user
/// picked inside iCloud Drive. The store only ever opens one fixed document name inside that
/// folder; it never reads paths taken from document contents and the document carries no accounts,
/// keys, roles, grants or history. Turning sync on or off, polling, confirming remote changes,
/// preventing apply-loops and resolving conflicts stay with the caller.
struct PreferencesSyncEnvelope: Codable {
    static let schema = "fawaly.preferences-sync.v1"
    /// Envelope documents larger than this (96 KB) are rejected on read and on publish.
    static let maximumBytes = 96 * 1024

    let schema: String
    /// Identifies one published revision; fresh for every publish.
    let id: UUID
    /// The device that published this revision.
    let deviceID: UUID
    let updatedAt: Date
    let preferences: PreferencesBackup

    init(schema: String = PreferencesSyncEnvelope.schema, id: UUID = UUID(), deviceID: UUID, updatedAt: Date, preferences: PreferencesBackup) {
        self.schema = schema
        self.id = id
        self.deviceID = deviceID
        self.updatedAt = updatedAt
        self.preferences = preferences
    }
}

struct PreferencesSyncStore {
    static let fileName = "Fawaly-preferences.sync.json"

    let folder: URL
    private var file: URL { folder.appendingPathComponent(Self.fileName) }

    /// Reads the current revision, or nil when no document exists yet. Links and non-regular
    /// files are refused, oversized or malformed documents throw, and the nested backup must
    /// satisfy the same validation as a hand-carried preferences backup.
    func read() throws -> PreferencesSyncEnvelope? {
        let file = self.file
        if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw FawalyError.invalid("The preferences sync document must not be a link.")
        }
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try coordinating(reading: file) { url in
            try Self.boundedRegularRead(url, limit: PreferencesSyncEnvelope.maximumBytes)
        }
        let envelope = try JSONDecoder().decode(PreferencesSyncEnvelope.self, from: data)
        try Self.validate(envelope)
        return envelope
    }

    /// Validates the backup, then replaces the document with a fresh revision in one atomic,
    /// coordinated write. Refuses to replace a link or a non-regular file.
    @discardableResult
    func publish(_ backup: PreferencesBackup, deviceID: UUID, now: Date = Date()) throws -> PreferencesSyncEnvelope {
        try publish(backup, deviceID: deviceID, now: now, checkRevision: false, revision: nil)
    }

    /// Compare the revision inside the coordinated write, so a remote change
    /// discovered after polling is never silently overwritten.
    func publish(_ backup: PreferencesBackup, deviceID: UUID, now: Date = Date(), replacing revision: UUID?) throws -> PreferencesSyncEnvelope {
        try publish(backup, deviceID: deviceID, now: now, checkRevision: true, revision: revision)
    }

    private func publish(_ backup: PreferencesBackup, deviceID: UUID, now: Date, checkRevision: Bool, revision: UUID?) throws -> PreferencesSyncEnvelope {
        try Self.validate(backup)
        let envelope = PreferencesSyncEnvelope(deviceID: deviceID, updatedAt: now, preferences: backup)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        guard data.count <= PreferencesSyncEnvelope.maximumBytes else {
            throw FawalyError.invalid("The preferences sync document is too large.")
        }
        let file = self.file
        if FileManager.default.fileExists(atPath: file.path) {
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true else {
                throw FawalyError.invalid("The preferences sync document must not be a link.")
            }
            guard values.isRegularFile == true else {
                throw FawalyError.invalid("The preferences sync document is not a regular file.")
            }
        }
        try coordinating(writing: file) { url in
            var info = stat()
            let exists = lstat(url.path, &info) == 0
            if exists {
                guard info.st_mode & S_IFMT == S_IFREG else { throw FawalyError.invalid("The sync document must be a regular file, not a link.") }
                if checkRevision {
                    let data = try Self.boundedRegularRead(url, limit: PreferencesSyncEnvelope.maximumBytes)
                    let current = try JSONDecoder().decode(PreferencesSyncEnvelope.self, from: data)
                    try Self.validate(current)
                    guard current.id == revision else { throw FawalyError.invalid("Preferences changed on another Mac. Review the incoming revision before sharing yours.") }
                }
            } else {
                guard errno == ENOENT else { throw FawalyError.invalid("The shared preferences could not be inspected safely.") }
                if checkRevision && revision != nil { throw FawalyError.invalid("The shared revision was removed. Choose the sync folder again to share your preferences.") }
            }
            try data.write(to: url, options: .atomic)
        }
        return envelope
    }

    /// Mirrors the field validation in `PreferencesBackup.read` so a synced document is exactly as
    /// trustworthy as a backup file the user imported by hand.
    static func validate(_ envelope: PreferencesSyncEnvelope) throws {
        guard envelope.schema == PreferencesSyncEnvelope.schema else {
            throw FawalyError.invalid("The preferences sync document uses an unknown format.")
        }
        try validate(envelope.preferences)
    }

    static func validate(_ backup: PreferencesBackup) throws {
        guard backup.schema == "fawaly.preferences.v1", AdvisorSettings.rounds.contains(backup.advisorRounds),
              AdvisorSettings.minutes.contains(backup.advisorMinutes), (0...23).contains(backup.morningHour),
              (1...3600).contains(backup.policy.timeoutSeconds) else {
            throw FawalyError.invalid("The settings backup is invalid or uses a newer format.")
        }
        guard backup.appearance.map({ ["light", "dark"].contains($0) }) ?? true else {
            throw FawalyError.invalid("Invalid workshop appearance.")
        }
        guard backup.workerModels?.allSatisfy({ EngineAgent(rawValue: $0.key) != nil && OfficialModels.valid($0.value) }) ?? true else {
            throw FawalyError.invalid("Invalid assistant model preferences.")
        }
        guard backup.policy.orders.allSatisfy({ key, order in DelegationPolicy.Kind(rawValue: key) != nil && Set(order).count == order.count }) else {
            throw FawalyError.invalid("Invalid worker routing preferences.")
        }
    }

    /// Reads at most `limit` bytes and only from a regular file, so a document swapped for a link,
    /// device or directory mid-read cannot redirect the read; the descriptor is checked after
    /// opening, like the anchored reads used for the model cache.
    private static func boundedRegularRead(_ file: URL, limit: Int) throws -> Data {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw FawalyError.invalid("The preferences sync document could not be opened safely.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw FawalyError.invalid("The preferences sync document is not a regular file.")
        }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else {
            throw FawalyError.invalid("The preferences sync document is too large.")
        }
        return data
    }

    private func coordinating<T>(reading file: URL, _ body: (URL) throws -> T) throws -> T {
        guard NSFileVersion.unresolvedConflictVersionsOfItem(at: file)?.isEmpty != false else { throw FawalyError.invalid("iCloud has conflicting preference versions. Resolve the document conflict before syncing.") }
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: file, options: [], error: &coordinationError) { url in
            result = Result { try body(url) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw FawalyError.invalid("The preferences sync document could not be read.") }
        return try result.get()
    }

    private func coordinating(writing file: URL, _ body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: file, options: [], error: &coordinationError) { url in
            do { try body(url) } catch { bodyError = error }
        }
        if let bodyError { throw bodyError }
        if let coordinationError { throw coordinationError }
    }
}
