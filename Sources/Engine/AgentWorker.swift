import Darwin
import Foundation

struct AgentWorker: Sendable {
    let configuration: EngineConfiguration

    struct Invocation {
        let program: URL
        let arguments: [String]
        let environment: [String: String]
    }

    static func invocation(
        _ agent: EngineAgent, executable: URL, directory: URL, workspace: URL?,
        codexHome: URL, token: String?, claudeHome: URL? = nil, kimiHome: URL? = nil, model: String? = nil
    ) throws -> Invocation {
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "TMPDIR": directory.path,
            "DELEGATE_WORKER_DEPTH": "1",
            "TERM": "dumb"
        ]
        var arguments: [String]
        switch agent {
        case .codex:
            environment["CODEX_HOME"] = codexHome.path
            arguments = ["-a", "never", "exec", "--ignore-user-config", "--ephemeral", "--skip-git-repo-check",
                         "--sandbox", workspace == nil ? "read-only" : "workspace-write", "--json",
                         "--disable", "hooks", "--disable", "plugins", "--disable", "multi_agent", "--disable", "skill_search",
                         "-c", "cli_auth_credentials_store=\"file\"", "-c", "web_search=\"disabled\"",
                         "--output-last-message", directory.appendingPathComponent("final.txt").path]
            if workspace == nil { arguments += ["--disable", "shell_tool", "--disable", "unified_exec"] }
            if let workspace { arguments += ["--add-dir", workspace.path] }
            arguments.append("-")
        case .kimi:
            guard kimiHome != nil else { throw FawalyError.invalid("Open Fawaly Services and connect Kimi.") }
            // Kimi watches HOME for user settings. Keep that watcher inside the
            // private assignment folder; never grant it the real home directory.
            environment["HOME"] = directory.path
            environment["KIMI_CODE_HOME"] = directory.appendingPathComponent("kimi-config").path
            environment["KIMI_DISABLE_TELEMETRY"] = "1"
            arguments = ["--agent-file", directory.appendingPathComponent("fawaly-worker.md").path,
                         "--skills-dir", directory.appendingPathComponent("empty-skills").path,
                         "--output-format", "stream-json", "--prompt", "Read brief.txt in the current directory and complete that assignment for the primary agent."]
            if let workspace { arguments += ["--add-dir", workspace.path] }
        case .claude:
            guard token != nil || claudeHome != nil else {
                throw FawalyError.invalid("Open Fawaly Services and connect Claude Code.")
            }
            if let token { environment["CLAUDE_CODE_OAUTH_TOKEN"] = token }
            environment["CLAUDE_CONFIG_DIR"] = (claudeHome ?? directory.appendingPathComponent("claude-config")).path
            arguments = ["--print", "--safe-mode", "--setting-sources", "", "--strict-mcp-config",
                         "--mcp-config", "{\"mcpServers\":{}}", "--no-session-persistence", "--output-format", "json",
                         "--tools", workspace == nil ? "" : "Read,Glob,Grep,Edit,Write",
                         "--permission-mode", workspace == nil ? "default" : "acceptEdits"]
            if let workspace { arguments += ["--add-dir", workspace.path] }
        default: throw FawalyError.invalid("API assistants do not launch a native CLI.")
        }
        if let model {
            guard OfficialModels.valid(model) else { throw FawalyError.invalid("Invalid worker model identifier.") }
            if agent == .codex { arguments.insert(contentsOf: ["--model", model], at: arguments.count - 1) }
            else { arguments += ["--model", model] }
        }
        return Invocation(program: executable, arguments: arguments, environment: environment)
    }

    func run(_ agent: EngineAgent, prompt: String, workspace: URL? = nil, timeout: Int = 120, managedSnapshot: Bool = false) async throws -> String {
        guard !prompt.isEmpty, prompt.utf8.count <= 120 * 1_024 else { throw FawalyError.invalid("The worker brief must be 1 byte to 120 KB.") }
        guard ProcessInfo.processInfo.environment["DELEGATE_WORKER_DEPTH"]?.isEmpty != false else {
            throw FawalyError.invalid("Nested Fawaly delegation is disabled.")
        }
        let lock = try configuration.lockWorkerAccess()
        defer { close(lock) }
        let authorizedWorkspace = try workspace.map { directory in
            if managedSnapshot { try validateManagedSnapshot(directory, agent: agent); return directory }
            return try configuration.approvedWorkspace(directory.path)
        }
        let workerLocks = try configuration.lockWorker(agent, workspace: authorizedWorkspace)
        defer { workerLocks.forEach { close($0) } }
        let prompt = ProjectSkillsContext.enrich(prompt, workspace: authorizedWorkspace)
        if !agent.isNative {
            guard let assistant = try APIAssistantStore(root: configuration.root).load(agent), assistant.enabled else { throw FawalyError.invalid("Connect this assistant in Fawaly first.") }
            let preference = WorkerContext.modelPreference
            let selectedModel = preference?.agent == agent ? preference?.model : try WorkshopStore(root: configuration.root).load().workerModels?[agent.rawValue]
            var selected = assistant
            if let selectedModel { selected.model = selectedModel }
            return try await APIWorker(root: configuration.root).run(selected, prompt: prompt, workspace: authorizedWorkspace, timeout: timeout)
        }
        guard let executable = agent.executable(root: configuration.root) else { throw FawalyError.invalid(agent.label + " CLI is not installed.") }
        if agent == .codex {
            try configuration.prepareCodexHome()
            guard configuration.isReady(.codex) else {
                throw FawalyError.invalid("Open Fawaly Services and connect Codex.")
            }
        }
        let claudeHome = configuration.hasNativeSignIn(.claude) ? configuration.nativeAuthDirectory(.claude) : nil
        let token = agent == .claude && claudeHome == nil ? try EngineKeychain.claudeToken() : nil
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fawaly-worker-" + UUID().uuidString, isDirectory: true).resolvingSymlinksInPath()
        try Paths.ensurePrivateDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let kimiHome = agent == .kimi ? configuration.nativeAuthDirectory(.kimi) : nil
        if let kimiHome { try KimiWorker.prepare(directory: directory, authentication: kimiHome, workspace: authorizedWorkspace) }
        let requestedModel: String?
        if let preference = WorkerContext.modelPreference, preference.agent == agent { requestedModel = preference.model }
        else { requestedModel = try WorkshopStore(root: configuration.root).load().workerModels?[agent.rawValue] }
        let invocation = try Self.invocation(agent, executable: executable, directory: directory,
                                             workspace: authorizedWorkspace, codexHome: configuration.codexHome, token: token, claudeHome: claudeHome, kimiHome: kimiHome, model: requestedModel)
        let profile = directory.appendingPathComponent("worker.sb")
        let comparisonMetadata = managedSnapshot ? authorizedWorkspace.map { [$0.deletingLastPathComponent().appendingPathComponent("baseline.git")] } ?? [] : []
        try Self.sandboxProfile(invocation: invocation, directory: directory, workspace: authorizedWorkspace,
                                codexHome: agent == .codex ? configuration.codexHome : agent == .kimi ? kimiHome : claudeHome,
                                authKeychain: agent == .claude && claudeHome != nil ? EngineKeychain.defaultKeychainFile() : nil, protectGitMetadata: true, readOnly: comparisonMetadata).write(to: profile, atomically: true, encoding: .utf8)
        let workerPrompt = authorizedWorkspace.map { "The only approved project directory is " + $0.path + ". Use absolute paths under that directory.\n\n" + prompt } ?? prompt
        let output: Data
        do { output = try await WorkerProcess.run(program: "/usr/bin/sandbox-exec", arguments: ["-f", profile.path, executable.path] + invocation.arguments,
                                                  environment: invocation.environment, directory: directory,
                                                  workingDirectory: directory, prompt: workerPrompt, timeout: timeout, stopFile: WorkerContext.stopFile) }
        catch let error as WorkerAuthenticationError {
            try? configuration.requireNativeSignIn(agent, required: true)
            throw FawalyError.invalid(error.localizedDescription)
        }
        return try Self.answer(agent, directory: directory, output: output)
    }

    static func sandboxProfile(invocation: Invocation, directory: URL, workspace: URL?, codexHome: URL?, authKeychain: URL? = nil, protectGitMetadata: Bool = true, readOnly: [URL] = []) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        let program = invocation.program
        let programPath = program.pathComponents
        let package = programPath.lastIndex(where: { $0.hasSuffix(".app") }).map {
            NSString.path(withComponents: Array(programPath.prefix($0 + 1)))
        } ?? program.path
        // Seatbelt compares resolved filesystem paths. Foundation preserves the
        // macOS /var alias, while native runtimes may access it as /private/var.
        func filesystemPath(_ url: URL) -> String {
            guard let path = realpath(url.path, nil) else { return url.resolvingSymlinksInPath().path }
            defer { free(path) }
            return String(cString: path)
        }
        let writable = ([directory] + [workspace, codexHome].compactMap { $0 }).map(filesystemPath)
        let readable = writable + [package] + [authKeychain?.path].compactMap { $0 } + readOnly.map(filesystemPath)
        func filters(_ paths: [String]) -> String {
            paths.map { path in
                let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
                return "(subpath \"\(escaped)\")"
            }.joined(separator: " ")
        }
        let protectedGit = protectGitMetadata ? workspace.map { "(deny file-write* " + filters([filesystemPath($0.appendingPathComponent(".git"))]) + ")" } ?? "" : ""
        return """
        (version 1)
        (allow default)
        (deny file-write*)
        (deny file-read-data \(filters([home.path])))
        (allow file-read-data \(filters(readable)))
        (allow file-write* \(filters(writable)))
        (allow file-write-data (literal "/dev/null"))
        \(protectedGit)
        """
    }

    static func answer(_ agent: EngineAgent, directory: URL, output: Data) throws -> String {
        let text: String?
        switch agent {
        case .codex:
            let final = directory.appendingPathComponent("final.txt")
            var info = stat()
            let exists = lstat(final.path, &info) == 0
            if !exists && errno != ENOENT { throw FawalyError.invalid("The final answer could not be inspected safely.") }
            let fileText = exists ? String(data: try WorkerFiles.read(final, limit: WorkerProcess.outputLimit), encoding: .utf8) : nil
            if let fileText, !fileText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = fileText
            } else {
                let events = output.split(separator: 10).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
                let completed = events.contains { $0["type"] as? String == "turn.completed" }
                text = completed ? events.reversed().compactMap { event -> String? in
                    guard event["type"] as? String == "item.completed", let item = event["item"] as? [String: Any],
                          item["type"] as? String == "agent_message" else { return nil }
                    return item["text"] as? String
                }.first : nil
            }
        case .kimi:
            text = KimiWorker.answer(output)
        case .claude:
            let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any]
            text = object?["is_error"] as? Bool == true ? nil : object?["result"] as? String
        default: text = nil
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FawalyError.invalid(agent.label + " did not return a usable answer. Check the isolated sign-in.")
        }
        return ConsultRound.cap(text).0
    }
}
