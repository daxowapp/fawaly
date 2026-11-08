import Darwin
import Foundation

struct WorkerAuthenticationError: LocalizedError {
    var errorDescription: String? { "The worker rejected its isolated sign-in. Reconnect it in Services." }
}

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
        let inputFD = try WorkerFiles.create(input)
        defer { close(inputFD) }
        try FileHandle(fileDescriptor: inputFD, closeOnDealloc: false).write(contentsOf: Data(prompt.utf8))
        guard lseek(inputFD, 0, SEEK_SET) == 0 else { throw launchError }
        let outputFD = try WorkerFiles.create(output)
        defer { close(outputFD) }
        let diagnosticFD = try WorkerFiles.create(diagnostics)
        defer { close(diagnosticFD) }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw launchError }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw launchError }
        defer { posix_spawnattr_destroy(&attributes) }

        for (source, target) in [(inputFD, STDIN_FILENO), (outputFD, STDOUT_FILENO), (diagnosticFD, STDERR_FILENO)] {
            guard posix_spawn_file_actions_adddup2(&actions, source, target) == 0 else { throw launchError }
        }
        guard posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
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
            guard try WorkerFiles.size(outputFD) <= outputLimit, try WorkerFiles.size(diagnosticFD) <= outputLimit else {
                throw FawalyError.invalid("The worker exceeded its output limit.")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard (status & 0x7f) == 0, ((status >> 8) & 0xff) == 0 else {
            let detail = (try? WorkerFiles.read(diagnosticFD, limit: outputLimit)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            if detail.contains("sandbox_apply") || detail.contains("sandbox-exec:") {
                throw FawalyError.invalid("The worker sandbox could not start. The request was stopped.")
            }
            let response = (try? WorkerFiles.read(outputFD, limit: outputLimit)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            let authenticationDetail = detail + response
            let event = (try? JSONSerialization.jsonObject(with: Data(response.utf8))) as? [String: Any]
            if event?["api_error_status"] as? Int == 401 || ["not logged in", "invalid api key", "failed to authenticate", "authentication failed", "401 unauthorized"].contains(where: { authenticationDetail.localizedCaseInsensitiveContains($0) }) {
                throw WorkerAuthenticationError()
            }
            throw FawalyError.invalid("The worker exited before returning a result. Check its isolated sign-in and CLI version.")
        }
        // Recheck both streams after reaping: a fast, successful child can finish
        // between polls with oversized diagnostics as well as oversized stdout.
        guard try WorkerFiles.size(outputFD) <= outputLimit, try WorkerFiles.size(diagnosticFD) <= outputLimit else {
            throw FawalyError.invalid("The worker exceeded its output limit.")
        }
        return try WorkerFiles.read(outputFD, limit: outputLimit)
    }

    private static var launchError: FawalyError { .invalid("Fawaly could not start the worker process.") }

}
