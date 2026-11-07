import Foundation

struct ClientLauncher {
    let root: URL
    var url: URL { root.appendingPathComponent("launchers/fawaly-team") }
    private static let marker = "#!/bin/sh\n# Fawaly managed MCP launcher v1\n"

    func prepare(application: URL) throws {
        let path = application.standardizedFileURL.path
        guard !path.contains("/AppTranslocation/"), !path.hasPrefix("/Volumes/"),
              !path.hasPrefix("/private/var/folders/"), !path.hasPrefix("/tmp/"),
              !path.contains("\n"), !path.contains("\r"),
              FileManager.default.isExecutableFile(atPath: path) else {
            throw FawalyError.invalid("Move Fawaly to Applications and open it there before connecting your team.")
        }
        try Paths.ensurePrivateDirectory(url.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: url.path) {
            let info = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard info.isSymbolicLink != true, info.isRegularFile == true,
                  try String(contentsOf: url, encoding: .utf8).hasPrefix(Self.marker) else {
                throw FawalyError.invalid("The team launcher was changed outside Fawaly. Review it before reconnecting.")
            }
        }
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        try (Self.marker + "exec " + quoted + " \"$@\"\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
