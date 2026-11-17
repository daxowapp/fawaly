import Foundation
import Darwin
import CryptoKit

/// Provider tools operate relative to an already approved project descriptor.
/// Every component is opened without following links; no shell or Git tools.
final class APIWorkspace {
    private let descriptor: Int32
    private let folder: URL
    static let limit = 128 * 1024
    init(_ folder: URL) throws {
        self.folder = folder
        descriptor = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw FawalyError.invalid("The approved project is unavailable.") }
    }
    deinit { close(descriptor) }
    private func components(_ path: String) throws -> [String] {
        let values = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 4096,
              !values.isEmpty, values.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !Self.gitName($0) && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }) else {
            throw FawalyError.invalid("Use a project-relative path without links, .git or parent traversal.")
        }
        return values
    }
    private func parent(_ path: String, create: Bool = false) throws -> (Int32, String) {
        let values = try components(path)
        var fd = dup(descriptor)
        guard fd >= 0 else { throw failure }
        do {
            for component in values.dropLast() {
                var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT && create {
                    guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else { throw failure }
                    next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw failure }
                close(fd); fd = next
            }
            return (fd, values.last!)
        } catch { close(fd); throw error }
    }
    func read(_ path: String) throws -> (text: String, digest: String) {
        let (parent, name) = try parent(path)
        defer { close(parent) }
        let value = try read(parent: parent, name: name)
        return (value.text, value.digest)
    }
    struct Edit { let old: String; let new: String }
    /// Replace exact passages of an existing file and return its new digest.
    /// Each passage must occur exactly once, byte for byte, in the result of
    /// the edits before it. Nothing is written unless every edit applies, and
    /// the commit is the same anchored compare-and-swap as `write`.
    func edit(_ path: String, edits: [Edit], expectedDigest: String) throws -> String {
        guard (1...32).contains(edits.count) else { throw FawalyError.invalid("Provide 1 to 32 edits.") }
        let (parent, name) = try parent(path)
        let current: (data: Data, text: String, digest: String)
        do { defer { close(parent) }; current = try read(parent: parent, name: name) }
        guard current.digest == expectedDigest else {
            throw FawalyError.invalid("The file changed or was not read. Read it again before editing.")
        }
        var bytes = current.data
        for (index, edit) in edits.enumerated() {
            let old = Data(edit.old.utf8)
            guard !old.isEmpty else { throw FawalyError.invalid("Edit \(index + 1): old_text is empty.") }
            guard let match = bytes.range(of: old) else {
                throw FawalyError.invalid("Edit \(index + 1): old_text was not found. Copy it exactly from the file, including spaces and line breaks. Nothing was written.")
            }
            guard bytes.range(of: old, in: (match.lowerBound + 1)..<bytes.endIndex) == nil else {
                throw FawalyError.invalid("Edit \(index + 1): old_text occurs more than once. Include more of the surrounding text. Nothing was written.")
            }
            bytes.replaceSubrange(match, with: Data(edit.new.utf8))
            guard bytes.count <= Self.limit else { throw FawalyError.invalid("Edit \(index + 1) makes the file larger than 128 KB. Nothing was written.") }
        }
        guard String(data: bytes, encoding: .utf8) != nil else { throw failure }
        return try write(path, data: bytes, expectedDigest: expectedDigest)
    }
    private func read(parent: Int32, name: String) throws -> (data: Data, text: String, digest: String) {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failure }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size <= Self.limit, info.st_flags & UInt32(SF_DATALESS) == 0 else { throw failure }
        let data = try handle.read(upToCount: Self.limit + 1) ?? Data()
        guard data.count <= Self.limit, let text = String(data: data, encoding: .utf8) else { throw failure }
        return (data, text, Self.digest(data))
    }
    /// Returns the digest of the written file, for a later write or edit.
    @discardableResult
    func write(_ path: String, content: String, expectedDigest: String) throws -> String {
        try write(path, data: Data(content.utf8), expectedDigest: expectedDigest)
    }
    private func write(_ path: String, data: Data, expectedDigest: String) throws -> String {
        guard expectedDigest.isEmpty || (expectedDigest.count == 64 && expectedDigest.allSatisfy { $0.isHexDigit }) else { throw failure }
        let (parent, _) = try parent(path, create: expectedDigest.isEmpty)
        close(parent)
        var coordinationError: NSError?, bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: folder.appendingPathComponent(path), options: .forReplacing, error: &coordinationError) { _ in
            do { try writeAnchored(path, data: data, expectedDigest: expectedDigest) }
            catch { bodyError = error }
        }
        if let bodyError { throw bodyError }
        if let coordinationError { throw coordinationError }
        return Self.digest(data)
    }
    /// Preserve executable helpers from a verified skill manifest without executing them.
    func markExecutable(_ path: String, expectedDigest: String) throws {
        let (parent, name) = try parent(path)
        defer { close(parent) }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failure }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size <= Self.limit, info.st_flags & UInt32(SF_DATALESS) == 0 else { throw failure }
        let bytes = try handle.read(upToCount: Self.limit + 1) ?? Data()
        guard bytes.count <= Self.limit, Self.digest(bytes) == expectedDigest, fchmod(fd, 0o700) == 0 else { throw failure }
    }
    private func writeAnchored(_ path: String, data: Data, expectedDigest: String) throws {
        guard data.count <= Self.limit else { throw failure }
        let (parent, name) = try parent(path, create: true)
        defer { close(parent) }
        var original = stat()
        let exists = fstatat(parent, name, &original, AT_SYMLINK_NOFOLLOW) == 0
        let expected = exists ? try read(parent: parent, name: name).digest : ""
        guard (exists || errno == ENOENT), expected == expectedDigest else {
            throw FawalyError.invalid("The file changed or was not read. Read it again before writing.")
        }
        let temporary = ".fawaly-" + UUID().uuidString + ".nosync"
        let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, exists ? original.st_mode & 0o777 : 0o600)
        guard fd >= 0 else { throw failure }
        defer { unlinkat(parent, temporary, 0) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data); try handle.synchronize()
        // Recheck immediately before the atomic replacement. RENAME_EXCL protects
        // creation from overwriting a concurrently created destination.
        if exists {
            guard try read(parent: parent, name: name).digest == expectedDigest else { throw failure }
            guard renameat(parent, temporary, parent, name) == 0 else { throw failure }
        } else {
            guard renameatx_np(parent, temporary, parent, name, UInt32(RENAME_EXCL)) == 0 else { throw failure }
        }
    }
    func list() throws -> [String] {
        var results: [String] = []
        func visit(_ fd: Int32, prefix: String, depth: Int) throws {
            guard depth < 12, results.count < 2000 else { return }
            let duplicate = dup(fd)
            guard duplicate >= 0 else { throw failure }
            guard let directory = fdopendir(duplicate) else { close(duplicate); throw failure }
            defer { closedir(directory) }
            while let entry = readdir(directory) {
                if results.count >= 2000 { break }
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                guard ![".", "..", "node_modules", "build", ".build"].contains(name.lowercased()), !Self.gitName(name) else { continue }
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_flags & UInt32(SF_DATALESS) == 0 else { continue }
                let path = prefix + name
                if info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 { results.append(path) }
                else if info.st_mode & S_IFMT == S_IFDIR {
                    let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    if next >= 0 { defer { close(next) }; try visit(next, prefix: path + "/", depth: depth + 1) }
                }
            }
        }
        try visit(descriptor, prefix: "", depth: 0)
        return results.sorted()
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func gitName(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")) == ".git"
    }
    private var failure: FawalyError { .invalid("The project file is unavailable, linked, binary, too large or changed. Use ordinary UTF-8 files within the approved project.") }
}
