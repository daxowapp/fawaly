import Foundation
import Darwin

struct ComparisonSnapshots: Sendable {
    struct Prepared: Sendable { let id: UUID; let commit: String; let directory: URL; let snapshots: [EngineAgent: URL] }
    let root: URL
    static let maximumArchiveBytes = 128 * 1_024 * 1_024

    func prepare(project: URL, agents: [EngineAgent]) async throws -> Prepared {
        guard agents.count == 2, Set(agents).count == 2 else { throw FawalyError.invalid("Choose two different assistants.") }
        let id = UUID()
        let directory = root.appendingPathComponent("comparisons/" + id.uuidString, isDirectory: true)
        try Paths.ensurePrivateDirectory(directory)
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: directory) } }
        let environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                           "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"]
        let top = try await git(["rev-parse", "--show-toplevel"], project: project, directory: directory, environment: environment)
        guard URL(fileURLWithPath: top).resolvingSymlinksInPath() == project.resolvingSymlinksInPath() else {
            throw FawalyError.invalid("Choose the Git repository’s root folder.")
        }
        let commit = try await git(["rev-parse", "--verify", "HEAD^{commit}"], project: project, directory: directory, environment: environment)
        guard commit.range(of: #"^[0-9a-f]{40}([0-9a-f]{24})?$"#, options: .regularExpression) != nil else { throw FawalyError.invalid("Commit the project before comparing assistants.") }
        let archive = directory.appendingPathComponent("source.tar")
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                let command = directory.appendingPathComponent("archive-command")
                try Paths.ensurePrivateDirectory(command)
                return try await WorkerProcess.run(program: "/usr/bin/git", arguments: ["--no-optional-locks", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-C", project.path, "archive", "--format=tar", "--output=" + archive.path, commit],
                    environment: environment, directory: command, workingDirectory: command, prompt: "", timeout: 60)
            }
            group.addTask {
                while true {
                    try Task.checkCancellation()
                    let size = (try? WorkerFiles.size(archive)) ?? 0
                    guard size <= Self.maximumArchiveBytes else { throw FawalyError.invalid("The committed project is too large for a comparison snapshot (128 MB maximum).") }
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
        guard (try WorkerFiles.size(archive)) <= Self.maximumArchiveBytes else { throw FawalyError.invalid("The comparison snapshot exceeds 128 MB.") }
        var snapshots: [EngineAgent: URL] = [:]
        for agent in agents {
            let snapshot = directory.appendingPathComponent(agent.rawValue + "/snapshot")
            try Paths.ensurePrivateDirectory(snapshot)
            let command = directory.appendingPathComponent(agent.rawValue + "/extract-command")
            try Paths.ensurePrivateDirectory(command)
            let invocation = AgentWorker.Invocation(program: URL(fileURLWithPath: "/usr/bin/tar"), arguments: [], environment: [:])
            let policy = command.appendingPathComponent("extract.sb")
            try AgentWorker.sandboxProfile(invocation: invocation, directory: directory, workspace: nil, codexHome: nil)
                .write(to: policy, atomically: true, encoding: .utf8)
            _ = try await WorkerProcess.run(program: "/usr/bin/sandbox-exec", arguments: ["-f", policy.path, "/usr/bin/tar", "-xf", archive.path, "-C", snapshot.path, "--no-same-owner"],
                environment: environment, directory: command, workingDirectory: command, prompt: "", timeout: 30)
            // Refuse links that could make a snapshot depend on files outside it.
            if let files = FileManager.default.enumerator(at: snapshot, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
                for case let file as URL in files {
                    if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                        guard file.resolvingSymlinksInPath().path.hasPrefix(snapshot.resolvingSymlinksInPath().path + "/") else {
                            throw FawalyError.invalid("This project contains a link outside its committed snapshot.")
                        }
                    }
                }
            }
            var reserved = stat()
            guard lstat(snapshot.appendingPathComponent(".git").path, &reserved) != 0, errno == ENOENT else {
                throw FawalyError.invalid("The snapshot archive contains reserved Git metadata.")
            }
            let metadata = snapshot.deletingLastPathComponent().appendingPathComponent("baseline.git")
            _ = try await git(["init", "--quiet", "--separate-git-dir=" + metadata.path], project: snapshot, directory: directory, environment: environment)
            _ = try await git(["add", "--force", "."], project: snapshot, directory: directory, environment: environment)
            _ = try await git(["-c", "user.name=Fawaly Comparison", "-c", "user.email=fawaly@localhost", "commit", "--quiet", "--no-gpg-sign", "--allow-empty", "-m", "Isolated comparison baseline"], project: snapshot, directory: directory, environment: environment)
            let identity = try SnapshotIdentity(snapshot)
            try JSONEncoder().encode(identity).write(to: snapshot.deletingLastPathComponent().appendingPathComponent("snapshot-identity.json"), options: .atomic)
            snapshots[agent] = snapshot
        }
        try FileManager.default.removeItem(at: archive)
        keep = true
        return Prepared(id: id, commit: commit, directory: directory, snapshots: snapshots)
    }

    struct SnapshotIdentity: Codable, Equatable {
        let device: Int64
        let inode: UInt64
        init(_ url: URL) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                throw FawalyError.invalid("The comparison snapshot was replaced or linked. Its result was not accepted.")
            }
            device = Int64(info.st_dev); inode = UInt64(info.st_ino)
        }
    }

    func changedFiles(in snapshot: URL, directory: URL) async throws -> [String] {
        let parent = snapshot.deletingLastPathComponent()
        let identity = try JSONDecoder().decode(SnapshotIdentity.self, from: WorkerFiles.read(parent.appendingPathComponent("snapshot-identity.json"), limit: 1024))
        guard try SnapshotIdentity(snapshot) == identity else { throw FawalyError.invalid("The comparison snapshot was replaced. Review the result manually.") }
        let metadata = parent.appendingPathComponent("baseline.git")
        let environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                           "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"]
        let changed = try await git(["diff", "--no-ext-diff", "--no-textconv", "--name-only", "-z", "HEAD"], project: snapshot, directory: directory, environment: environment, metadata: metadata)
        let added = try await git(["ls-files", "--others", "--exclude-standard", "-z"], project: snapshot, directory: directory, environment: environment, metadata: metadata)
        guard try SnapshotIdentity(snapshot) == identity else { throw FawalyError.invalid("The comparison snapshot changed during inspection. Review it manually.") }
        return Array(Set((changed + "\0" + added).split(separator: "\0").map(String.init))).sorted()
    }

    private func git(_ arguments: [String], project: URL, directory: URL, environment: [String: String], metadata: URL? = nil) async throws -> String {
        let command = directory.appendingPathComponent("git-" + UUID().uuidString)
        try Paths.ensurePrivateDirectory(command)
        var args = ["--no-optional-locks", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-C", project.path]
        var program = "/usr/bin/git"
        if let metadata {
            args += ["--git-dir=" + metadata.path, "--work-tree=" + project.path]
            let policy = command.appendingPathComponent("inspect.sb")
            let invocation = AgentWorker.Invocation(program: URL(fileURLWithPath: program), arguments: [], environment: [:])
            try AgentWorker.sandboxProfile(invocation: invocation, directory: command, workspace: project, codexHome: nil, readOnly: [metadata]).write(to: policy, atomically: true, encoding: .utf8)
            args = ["-f", policy.path, program] + args
            program = "/usr/bin/sandbox-exec"
        }
        let data = try await WorkerProcess.run(program: program, arguments: args + arguments,
            environment: environment, directory: command, workingDirectory: command, prompt: "", timeout: 15)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
