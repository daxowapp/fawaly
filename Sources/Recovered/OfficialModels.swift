import Foundation

/// Models offered by the user's own Fawaly sign-in to an official CLI. Codex refreshes its list in
/// `models_cache.json` inside Fawaly's sign-in folder whenever it runs there; this only reads that file
/// and never the main session's `~/.codex`.
public enum OfficialModels {
    public static let maximumCacheBytes = 4_000_000
    /// Picker-visible Codex model slugs in Codex's order; empty until Codex has run once with Fawaly's sign-in.
    public static func codex(root: URL) -> [String] { codex(root: root, beforeRead: {}) }
    /// Every step is anchored to the descriptor checked before it, so swapping the folders or the file for
    /// links mid-read cannot redirect it. Nothing is created or changed.
    static func codex(root: URL, beforeRead: () -> Void) -> [String] {
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC); guard rootFD >= 0 else { return [] }
        defer { close(rootFD) }
        guard let officialFD = ownedDirectory(rootFD, "official") else { return [] }
        defer { close(officialFD) }
        guard let codexFD = ownedDirectory(officialFD, OfficialClient.codex.rawValue) else { return [] }
        defer { close(codexFD) }
        let fd = openat(codexFD, "models_cache.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC); guard fd >= 0 else { return [] }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_size >= 0, info.st_size <= maximumCacheBytes else { return [] }
        beforeRead()
        guard let data = boundedRead(fd, limit: maximumCacheBytes) else { return [] }
        return codexSlugs(data)
    }
    /// Parses Codex's model cache. Hidden, malformed and duplicate entries are dropped.
    public static func codexSlugs(_ data: Data) -> [String] {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = body["models"] as? [Any] else { return [] }
        var seen = Set<String>()
        return models.compactMap { $0 as? [String: Any] }
            .filter { $0["visibility"] as? String == "list" }
            .compactMap { $0["slug"] as? String }
            .filter { valid($0) && seen.insert($0).inserted }
    }
    static func valid(_ slug: String) -> Bool {
        slug.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:/\[\]-]{0,127}$"#, options: .regularExpression) != nil
    }
    private static func ownedDirectory(_ parent: Int32, _ name: String) -> Int32? {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { close(fd); return nil }
        return fd
    }
    /// At most `limit` bytes; nil when the file holds more (it may have grown after `fstat`).
    private static func boundedRead(_ fd: Int32, limit: Int) -> Data? {
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; return nil }
            if count == 0 { return data }
            data.append(buffer, count: count)
            if data.count > limit { return nil }
        }
    }
}
