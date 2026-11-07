import CryptoKit
import Foundation

struct RuntimeInstaller: Sendable {
    let root: URL

    #if arch(arm64)
    static let codexPlatform = "aarch64-apple-darwin"
    static let claudePlatform = "darwin-arm64"
    #else
    static let codexPlatform = "x86_64-apple-darwin"
    static let claudePlatform = "darwin-x64"
    #endif

    private struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
        let digest: String?
        let size: Int
    }
    private struct Release: Decodable { let assets: [Asset] }
    private struct ClaudeManifest: Decodable {
        struct Platform: Decodable {
            let checksum: String
            let size: Int
        }
        let platforms: [String: Platform]
    }

    private final class DownloadGuard: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesWritten > 400_000_000 { downloadTask.cancel() }
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let url = request.url, url.scheme == "https",
                  ["api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com",
                   "downloads.claude.ai"].contains(url.host?.lowercased() ?? "") else { return nil }
            return request
        }
    }

    func install(_ agent: EngineAgent) async throws -> URL {
        let runtimes = root.appendingPathComponent("runtimes", isDirectory: true)
        try Paths.ensurePrivateDirectory(runtimes)
        guard runtimes.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().appendingPathComponent("runtimes").path else {
            throw FawalyError.invalid("The service folder could not be prepared.")
        }
        let target = runtimes.appendingPathComponent(agent.rawValue)
        if FileManager.default.fileExists(atPath: target.path) {
            try await verifyExecutable(target, agent: agent, directory: runtimes)
            return target
        }
        let staging = runtimes.appendingPathComponent(".install-" + UUID().uuidString, isDirectory: true)
        try Paths.ensurePrivateDirectory(staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 300
        let guardrail = DownloadGuard()
        let session = URLSession(configuration: config, delegate: guardrail, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let candidate: URL
        if agent == .codex || agent == .kimi {
            let repository = agent == .codex ? "openai/codex" : "MoonshotAI/kimi-code"
            let request = URLRequest(url: URL(string: "https://api.github.com/repos/" + repository + "/releases/latest")!)
            let (data, response) = try await session.data(for: request)
            try Self.requireSuccess(response)
            let release = try JSONDecoder().decode(Release.self, from: data)
            let name = agent == .codex ? "codex-" + Self.codexPlatform : "kimi"
            let archiveName = agent == .codex ? name + ".tar.gz" : "kimi-code-" + Self.claudePlatform + ".tar.gz"
            guard let asset = release.assets.first(where: { $0.name == archiveName }),
                  asset.browser_download_url.scheme == "https", asset.browser_download_url.host == "github.com",
                  asset.browser_download_url.path.hasPrefix("/" + repository + "/releases/download/"),
                  let digest = asset.digest, digest.hasPrefix("sha256:"), asset.size <= 400_000_000 else {
                throw FawalyError.invalid("The official service download could not be verified.")
            }
            let archive = try await download(asset.browser_download_url, session: session, size: asset.size,
                                             checksum: String(digest.dropFirst(7)), destination: staging.appendingPathComponent("runtime.tar.gz"))
            let listing = try await run("/usr/bin/tar", ["-tzf", archive.path], at: staging)
            guard listing.output.split(whereSeparator: \.isNewline).map(String.init) == [name] else {
                throw FawalyError.invalid("The service archive has an unexpected layout.")
            }
            let verbose = try await run("/usr/bin/tar", ["-tvzf", archive.path], at: staging)
            guard verbose.output.hasPrefix("-") else { throw FawalyError.invalid("The service archive contains an unsupported entry.") }
            _ = try await run("/usr/bin/tar", ["-xzf", archive.path, "-C", staging.path], at: staging)
            candidate = staging.appendingPathComponent(name)
        } else {
            let base = "https://downloads.claude.ai/claude-code-releases"
            let (versionData, versionReply) = try await session.data(from: URL(string: base + "/stable")!)
            try Self.requireSuccess(versionReply)
            let version = String(decoding: versionData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else {
                throw FawalyError.invalid("The official Claude Code version could not be read.")
            }
            let (data, response) = try await session.data(from: URL(string: base + "/" + version + "/manifest.json")!)
            try Self.requireSuccess(response)
            let manifest = try JSONDecoder().decode(ClaudeManifest.self, from: data)
            guard let platform = manifest.platforms[Self.claudePlatform], platform.size <= 400_000_000 else {
                throw FawalyError.invalid("Claude Code is unavailable for this Mac.")
            }
            candidate = try await download(URL(string: base + "/" + version + "/" + Self.claudePlatform + "/claude")!,
                                           session: session, size: platform.size, checksum: platform.checksum,
                                           destination: staging.appendingPathComponent("claude"))
        }
        guard (try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).isRegularFile == true,
              candidate.resolvingSymlinksInPath().path == candidate.path else {
            throw FawalyError.invalid("The downloaded service is not a regular executable.")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: candidate.path)
        try await verifyExecutable(candidate, agent: agent, directory: staging)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: target.path) {
            try await verifyExecutable(target, agent: agent, directory: runtimes)
            return target
        }
        try FileManager.default.moveItem(at: candidate, to: target)
        return target
    }

    func verifyExecutable(_ file: URL, agent: EngineAgent, directory: URL) async throws {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              file.resolvingSymlinksInPath().path == file.path else {
            throw FawalyError.invalid("The service executable must be a regular file.")
        }
        let team: String
        switch agent {
        case .codex: team = "2DC432GLL2" // OpenAI OpCo, LLC
        case .claude: team = "Q6L2SF6YDW" // Anthropic PBC
        case .kimi: team = "2J9472RW75" // Beijing Moonshot Technology Co., Ltd
        }
        _ = try await run("/usr/bin/codesign", ["--verify", "--strict",
            "-R=anchor apple generic and certificate leaf[subject.OU] = \"" + team + "\"", file.path], at: directory)
    }

    private func download(_ url: URL, session: URLSession, size: Int, checksum: String, destination: URL) async throws -> URL {
        guard size > 0, checksum.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
            throw FawalyError.invalid("The official service manifest is incomplete.")
        }
        let (file, response) = try await session.download(from: url)
        try Self.requireSuccess(response)
        guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == size,
              try Self.sha256(file) == checksum else {
            throw FawalyError.invalid("The download did not pass its integrity check. Please retry.")
        }
        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }

    static func sha256(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { digest.update(data: chunk) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FawalyError.invalid("The official download service is unavailable. Please retry.")
        }
    }

    private func run(_ program: String, _ arguments: [String], at directory: URL) async throws -> LoginReply {
        let result = try await LoginProcess.run(
            LoginCommand(executable: URL(fileURLWithPath: program), arguments: arguments,
                         environment: ["PATH": "/usr/bin:/bin"], directory: directory), timeout: 30)
        guard result.exitCode == 0 else { throw FawalyError.invalid("The downloaded service could not be verified or prepared.") }
        return result
    }
}
