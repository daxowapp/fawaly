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
        return try read(parent: parent, name: name)
    }
    private func read(parent: Int32, name: String) throws -> (text: String, digest: String) {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failure }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size <= Self.limit, info.st_flags & UInt32(SF_DATALESS) == 0 else { throw failure }
        let data = try handle.read(upToCount: Self.limit + 1) ?? Data()
        guard data.count <= Self.limit, let text = String(data: data, encoding: .utf8) else { throw failure }
        return (text, Self.digest(data))
    }
    func write(_ path: String, content: String, expectedDigest: String) throws {
        guard expectedDigest.isEmpty || (expectedDigest.count == 64 && expectedDigest.allSatisfy { $0.isHexDigit }) else { throw failure }
        let (parent, _) = try parent(path, create: expectedDigest.isEmpty)
        close(parent)
        var coordinationError: NSError?, bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: folder.appendingPathComponent(path), options: .forReplacing, error: &coordinationError) { _ in
            do { try writeAnchored(path, content: content, expectedDigest: expectedDigest) }
            catch { bodyError = error }
        }
        if let bodyError { throw bodyError }
        if let coordinationError { throw coordinationError }
    }
    private func writeAnchored(_ path: String, content: String, expectedDigest: String) throws {
        let data = Data(content.utf8)
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
