import Foundation
import Darwin

struct LoginCommand: Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let directory: URL
    var input: String? = nil
}

struct LoginReply: Sendable {
    let exitCode: Int32
    let output: String
    var errorOutput = ""
}

enum LoginProcess {
    private final class ActiveGroups: @unchecked Sendable {
        private let lock = NSLock()
        private var groups = Set<pid_t>()
        func insert(_ pid: pid_t) { lock.lock(); groups.insert(pid); lock.unlock() }
        func remove(_ pid: pid_t) { lock.lock(); groups.remove(pid); lock.unlock() }
        func terminate() {
            lock.lock(); let current = groups; lock.unlock()
            for pid in current { kill(-pid, SIGKILL) }
        }
    }
    private static let active = ActiveGroups()
    static func cancelAll() { active.terminate() }
    private static let outputLimit = 131_072

    static func run(
        _ command: LoginCommand, timeout: TimeInterval,
        onURL: @escaping @Sendable (URL) -> Void = { _ in }
    ) async throws -> LoginReply {
        // Keep auth output in bounded memory. Nonblocking pipes and a private
        // process group prevent an orphaned child from holding setup open.
        var input = [Int32](repeating: -1, count: 2)
        var output = [Int32](repeating: -1, count: 2)
        var diagnostic = [Int32](repeating: -1, count: 2)
        defer { for fd in input + output + diagnostic where fd >= 0 { close(fd) } }
        guard pipe(&input) == 0, pipe(&output) == 0, pipe(&diagnostic) == 0 else { throw launchError }
        for fd in input + output + diagnostic { guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw launchError } }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw launchError }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw launchError }
        defer { posix_spawnattr_destroy(&attributes) }
        for (source, target) in [(input[0], STDIN_FILENO), (output[1], STDOUT_FILENO), (diagnostic[1], STDERR_FILENO)] {
            guard posix_spawn_file_actions_adddup2(&actions, source, target) == 0 else { throw launchError }
        }
        for fd in input + output + diagnostic { guard posix_spawn_file_actions_addclose(&actions, fd) == 0 else { throw launchError } }
        guard posix_spawn_file_actions_addchdir_np(&actions, command.directory.path) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else { throw launchError }
        var argv = ([command.executable.path] + command.arguments).map { strdup($0) }
        var envp = command.environment.sorted(by: { $0.key < $1.key }).map { strdup($0.key + "=" + $0.value) }
        argv.append(nil); envp.append(nil)
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        try Task.checkCancellation()
        var pid: pid_t = 0
        guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil }),
              posix_spawn(&pid, command.executable.path, &actions, &attributes, &argv, &envp) == 0 else { throw launchError }
        active.insert(pid)
        defer { active.remove(pid) }
        for (which, fd) in [(0, input[0]), (1, output[1]), (2, diagnostic[1])] {
            close(fd)
            if which == 0 { input[0] = -1 } else if which == 1 { output[1] = -1 } else { diagnostic[1] = -1 }
        }
        var status: Int32 = 0
        var reaped = false
        defer {
            kill(-pid, SIGKILL)
            if !reaped { while waitpid(pid, &status, 0) == -1 && errno == EINTR {} }
        }
        for fd in [input[1], output[0], diagnostic[0]] {
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw launchError }
        }
        guard fcntl(input[1], F_SETNOSIGPIPE, 1) == 0 else { throw launchError }
        let payload = Data((command.input ?? "").utf8)
        var sent = 0
        var out = Data(), err = Data()
        var delivered = Set<URL>()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(Int64(max(0.01, min(timeout, 3_600)) * 1_000)))
        while true {
            try Task.checkCancellation()
            drain(output[0], into: &out)
            drain(diagnostic[0], into: &err)
            for url in browserURLs(in: String(decoding: out, as: UTF8.self) + "\n" + String(decoding: err, as: UTF8.self)) where delivered.insert(url).inserted { onURL(url) }
            if input[1] >= 0, command.input != nil {
                if sent < payload.count {
                    let written = payload.withUnsafeBytes { bytes in
                        Darwin.write(input[1], bytes.baseAddress!.advanced(by: sent), min(payload.count - sent, 16_384))
                    }
                    if written > 0 { sent += written }
                    else if written < 0 && errno != EAGAIN && errno != EINTR { close(input[1]); input[1] = -1 }
                }
                if sent == payload.count { close(input[1]); input[1] = -1 }
            }
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid {
                reaped = true
                kill(-pid, SIGKILL)
                drain(output[0], into: &out); drain(diagnostic[0], into: &err)
                let exitCode = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
                return LoginReply(exitCode: exitCode, output: String(decoding: out, as: UTF8.self), errorOutput: String(decoding: err, as: UTF8.self))
            }
            if waited == -1 && errno != EINTR { reaped = errno == ECHILD; throw launchError }
            guard clock.now < deadline else { throw FawalyError.invalid("Sign-in timed out. Please try again.") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private static func drain(_ fd: Int32, into data: inout Data) {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        // A noisy process cannot keep this loop running past cancellation/deadline checks.
        for _ in 0..<16 {
            let count = Darwin.read(fd, &bytes, bytes.count)
            guard count > 0 else { return }
            if data.count < outputLimit { data.append(contentsOf: bytes.prefix(min(count, outputLimit - data.count))) }
        }
    }
    private static var launchError: FawalyError { .invalid("The sign-in process could not be started or monitored.") }

    static func browserURLs(in text: String) -> [URL] {
        let expression = try? NSRegularExpression(pattern: #"https://[^\s\x1b<>"]+"#)
        let range = NSRange(text.startIndex..., in: text)
        return expression?.matches(in: text, range: range).compactMap { match in
            guard let span = Range(match.range, in: text), let url = URL(string: String(text[span])),
                  let host = url.host?.lowercased(),
                  ["auth.openai.com", "chatgpt.com", "claude.ai", "console.anthropic.com", "platform.claude.com", "auth.kimi.com", "auth.kimi.ai", "www.kimi.com", "www.kimi.ai", "kimi.com", "kimi.ai"].contains(host),
                  url.user == nil, url.password == nil else { return nil }
            return url
        } ?? []
    }
}
