import Darwin
import Foundation

enum WorkerProcess {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var groups = Set<pid_t>()
        func insert(_ pid: pid_t) { lock.lock(); groups.insert(pid); lock.unlock() }
        func remove(_ pid: pid_t) { lock.lock(); groups.remove(pid); lock.unlock() }
        func cancelAll() {
            lock.lock(); let current = groups; lock.unlock()
            for pid in current { kill(-pid, SIGKILL) }
        }
    }
    private static let registry = Registry()
    static func cancelAll() { registry.cancelAll() }
    static let outputLimit = 1_048_576

    static func run(
        program: String, arguments: [String], environment: [String: String], directory: URL,
        workingDirectory: URL, prompt: String, timeout: Int, stopFile: URL? = nil
    ) async throws -> Data {
        let input = directory.appendingPathComponent("brief.txt")
        let output = directory.appendingPathComponent("stdout")
        let diagnostics = directory.appendingPathComponent("stderr")
        try Data(prompt.utf8).write(to: input, options: .withoutOverwriting)
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw launchError }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw launchError }
        defer { posix_spawnattr_destroy(&attributes) }

        let streams = [(STDIN_FILENO, input, O_RDONLY), (STDOUT_FILENO, output, O_WRONLY | O_CREAT | O_EXCL),
                       (STDERR_FILENO, diagnostics, O_WRONLY | O_CREAT | O_EXCL)]
        for (fd, url, flags) in streams {
            guard posix_spawn_file_actions_addopen(&actions, fd, url.path, flags, 0o600) == 0 else { throw launchError }
        }
        guard posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else { throw launchError }

        var pid: pid_t = 0
        var argv = ([program] + arguments).map { strdup($0) }
        var envp = environment.sorted(by: { $0.key < $1.key }).map { strdup($0.key + "=" + $0.value) }
        argv.append(nil)
        envp.append(nil)
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        try Task.checkCancellation()
        if let stopFile, FileManager.default.fileExists(atPath: stopFile.path) { throw WorkerStopped() }
        guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil }),
              posix_spawn(&pid, program, &actions, &attributes, &argv, &envp) == 0 else { throw launchError }

        registry.insert(pid)
        defer { registry.remove(pid) }
        var status: Int32 = 0
        var reaped = false
        defer {
            if !reaped {
                kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(max(1, min(timeout, 3_600))))
        while true {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid {
                reaped = true
                // A worker may have left children in its process group.
                kill(-pid, SIGKILL)
                break
            }
            if waited == -1 && errno != EINTR {
                reaped = errno == ECHILD
                throw FawalyError.invalid("Fawaly lost the worker process.")
            }
            try Task.checkCancellation()
            if let stopFile, FileManager.default.fileExists(atPath: stopFile.path) { throw WorkerStopped() }
            guard clock.now < deadline else { throw FawalyError.invalid("The worker exceeded its time limit.") }
            guard size(of: output) <= outputLimit, size(of: diagnostics) <= outputLimit else {
                throw FawalyError.invalid("The worker exceeded its output limit.")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard (status & 0x7f) == 0, ((status >> 8) & 0xff) == 0 else {
            let detail = size(of: diagnostics) <= outputLimit ? (try? String(contentsOf: diagnostics, encoding: .utf8)) ?? "" : ""
            if detail.contains("sandbox_apply") || detail.contains("sandbox-exec:") {
                throw FawalyError.invalid("The worker sandbox could not start. The request was stopped.")
            }
            let response = size(of: output) <= outputLimit ? (try? String(contentsOf: output, encoding: .utf8)) ?? "" : ""
            let authenticationDetail = detail + response
            if authenticationDetail.localizedCaseInsensitiveContains("not logged in") || authenticationDetail.localizedCaseInsensitiveContains("invalid api key")
                || authenticationDetail.localizedCaseInsensitiveContains("authentication") || authenticationDetail.localizedCaseInsensitiveContains("401") {
                throw FawalyError.invalid("The worker rejected its isolated sign-in. Reconnect it in Services.")
            }
            throw FawalyError.invalid("The worker exited before returning a result. Check its isolated sign-in and CLI version.")
        }
        guard size(of: output) <= outputLimit else { throw FawalyError.invalid("The worker exceeded its output limit.") }
        return try Data(contentsOf: output)
    }

    private static var launchError: FawalyError { .invalid("Fawaly could not start the worker process.") }

    private static func size(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
