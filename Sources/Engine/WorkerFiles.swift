import Darwin
import Foundation

/// Worker-controlled filenames are untrusted. Keep one descriptor from open to
/// bounded read; never follow a link or trust Foundation's cached file metadata.
enum WorkerFiles {
    static func create(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw invalid }
        return fd
    }

    static func size(_ fd: Int32) throws -> Int {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_size >= 0, info.st_size <= Int.max else { throw invalid }
        return Int(info.st_size)
    }

    static func size(_ url: URL) throws -> Int {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw invalid }
        defer { close(fd) }
        return try size(fd)
    }

    static func read(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw invalid }
        defer { close(fd) }
        return try read(fd, limit: limit)
    }

    static func read(_ fd: Int32, limit: Int) throws -> Data {
        guard limit >= 0, limit < Int.max, try size(fd) <= limit else { throw invalid }
        var data = Data(), buffer = [UInt8](repeating: 0, count: min(16_384, limit + 1))
        while true {
            // Read at most one byte past the limit, even if the file grows after fstat.
            let count = pread(fd, &buffer, min(buffer.count, limit + 1 - data.count), off_t(data.count))
            if count < 0 { if errno == EINTR { continue }; throw invalid }
            if count == 0 { return data }
            guard count <= limit - data.count else { throw invalid }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private static var invalid: FawalyError { .invalid("A worker result is linked, changed, unreadable or exceeds its size limit. The result was not accepted.") }
}
