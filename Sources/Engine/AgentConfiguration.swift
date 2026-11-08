import Darwin
import Foundation
import CryptoKit
import LocalAuthentication
import Security

enum EngineAgent: String, CaseIterable, Codable, Sendable {
    case codex, claude, kimi
    case zai, minimax, deepseek, openrouter, anthropicAPI, openAIAPI, ollama, lmstudio

    static let nativeAgents: [EngineAgent] = [.codex, .claude, .kimi]
    var isNative: Bool { Self.nativeAgents.contains(self) }
    var billingLabel: String { isNative ? "subscription" : [.ollama, .lmstudio].contains(self) ? "local_endpoint" : "provider_account" }

    static let primaryAgents: [EngineAgent] = [.codex, .claude]

    var providerID: String { rawValue + "-official" }
    var label: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .kimi: "Kimi"
        case .zai: "Z.AI (GLM)"
        case .minimax: "MiniMax"
        case .deepseek: "DeepSeek"
        case .openrouter: "OpenRouter"
        case .anthropicAPI: "Anthropic-compatible API"
        case .openAIAPI: "OpenAI-compatible API"
        case .ollama: "Ollama"
        case .lmstudio: "LM Studio"
        }
    }
    var caller: Rater {
        Rater(rawValue: rawValue)!
    }
    var modelLabel: String { "default" }

    init?(provider: String) {
        guard let agent = Self.allCases.first(where: { $0.providerID == provider || $0.rawValue == provider }) else { return nil }
        self = agent
    }

    func executable(home: URL = FileManager.default.homeDirectoryForCurrentUser, root: URL = Paths.rebuiltRoot()) -> URL? {
        guard isNative else { return nil }
        if self == .kimi {
            let managed = root.appendingPathComponent("runtimes/kimi")
            return FileManager.default.isExecutableFile(atPath: managed.path) ? managed.resolvingSymlinksInPath() : nil
        }
        let paths = [home.appendingPathComponent(".local/bin/" + rawValue).path, "/opt/homebrew/bin/" + rawValue,
                     "/usr/local/bin/" + rawValue]
        var candidates = [root.appendingPathComponent("runtimes/" + rawValue)] + paths.map { URL(fileURLWithPath: $0) }
        if self == .codex {
            candidates.append(URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"))
        } else {
            let directory = home.appendingPathComponent("Library/Application Support/Claude/claude-code")
            let children = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            let bundled = (children?.allObjects as? [URL] ?? []).filter { $0.path.hasSuffix("/claude.app/Contents/MacOS/claude") }
            candidates += bundled.sorted { $0.path.compare($1.path, options: .numeric) == .orderedDescending }
        }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })?.resolvingSymlinksInPath()
    }
}

struct EngineConfiguration: Sendable {
    let root: URL

    var codexHome: URL { Paths.officialSignIn(.codex, root: root).standardizedFileURL }
    private var workspaces: URL { root.appendingPathComponent("engine-workspaces.json") }

    func prepareCodexHome() throws {
        try Paths.ensurePrivateDirectory(codexHome)
        guard codexHome.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().appendingPathComponent("official/codex").path else {
            throw FawalyError.invalid("The Fawaly Codex sign-in folder must not be a link.")
        }
        let auth = codexHome.appendingPathComponent("auth.json")
        if (try? auth.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw FawalyError.invalid("The Fawaly Codex sign-in file must not be a link.")
        }
    }

    func isReady(_ agent: EngineAgent) -> Bool {
        if !agent.isNative { return (try? APIAssistantStore(root: root).load(agent)).map { $0.enabled && ($0.local || APIAssistantKeychain.contains($0)) } ?? false }
        guard agent.executable(root: root) != nil else { return false }
        switch agent {
        case .codex:
            let auth = codexHome.appendingPathComponent("auth.json")
            let real = auth.resolvingSymlinksInPath()
            guard real.path == root.resolvingSymlinksInPath().appendingPathComponent("official/codex/auth.json").path,
                  let values = try? auth.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
            return values.isRegularFile == true && (values.fileSize ?? 0) > 0
        case .claude:
            return hasNativeSignIn(.claude) || (try? EngineKeychain.claudeToken()) != nil
        case .kimi:
            return hasNativeSignIn(.kimi) && KimiWorker.hasCredentials(nativeAuthDirectory(.kimi))
        default: return false
        }
    }

    func approvedWorkspace(_ path: String) throws -> URL {
        let directory = try canonicalWorkspace(path)
        guard try readWorkspaces().contains(directory.path) else {
            throw FawalyError.invalid("Workspace access is off. Choose and approve this project folder from the Fawaly home screen first.")
        }
        return directory
    }

    func allowWorkspace(_ path: String) throws -> URL {
        let directory = try canonicalWorkspace(path)
        try withJobLock {
            var current = try readWorkspaces()
            current.insert(directory.path)
            try JSONEncoder().encode(current.sorted()).write(to: workspaces, options: .atomic)
        }
        return directory
    }

    func denyWorkspace(_ path: String) throws {
        guard path.hasPrefix("/") else { throw FawalyError.invalid("Pass the absolute path of one project directory.") }
        let directory = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        try withJobLock {
            var current = try readWorkspaces()
            current.remove(directory.path)
            try JSONEncoder().encode(current.sorted()).write(to: workspaces, options: .atomic)
        }
    }
    
    private func canonicalWorkspace(_ path: String) throws -> URL {
        let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let ownState = root.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        let broad = ["/", "/Users", home, home + "/Documents", home + "/Desktop", home + "/Downloads", home + "/Library"]
        let sensitive = [home + "/.codex", home + "/.claude", home + "/.ssh", home + "/Library", ownState]
        guard path.hasPrefix("/"), !broad.contains(directory.path),
              directory.path.hasPrefix(home + "/") || directory.path.hasPrefix("/Volumes/"),
              !ownState.hasPrefix(directory.path + "/"),
              !sensitive.contains(where: { directory.path == $0 || directory.path.hasPrefix($0 + "/") }),
              (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw FawalyError.invalid("Choose a specific, existing project folder.")
        }
        return directory
    }

    private func readWorkspaces() throws -> Set<String> {
        do {
            return Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: workspaces)))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
    }

    func lockWorkerAccess() throws -> Int32 {
        try Paths.ensurePrivateDirectory(root)
        let fd = open(root.appendingPathComponent("engine.lock").path, O_CREAT | O_NOFOLLOW | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FawalyError.invalid("The engine access lock could not be opened.") }
        guard flock(fd, LOCK_SH | LOCK_NB) == 0 else {
            close(fd)
            throw FawalyError.invalid("Fawaly is changing its configuration. Retry after setup finishes.")
        }
        return fd
    }

    func lockWorker(_ agent: EngineAgent, workspace: URL?) throws -> [Int32] {
        let folder = root.appendingPathComponent("work-locks")
        try Paths.ensurePrivateDirectory(folder)
        var names = ["agent-" + agent.rawValue]
        if let workspace {
            var info = stat()
            guard stat(workspace.path, &info) == 0 else { throw FawalyError.invalid("The project folder is unavailable.") }
            let identity = "\(info.st_dev):\(info.st_ino)"
            let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            names.append("project-" + digest)
        }
        var descriptors: [Int32] = []
        do {
            for name in names {
                let fd = open(folder.appendingPathComponent(name + ".lock").path, O_CREAT | O_NOFOLLOW | O_RDWR | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw FawalyError.invalid("The worker lock could not be opened.") }
                guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                    close(fd)
                    throw FawalyError.invalid("This assistant or project is already in use. Retry when its current task finishes.")
                }
                descriptors.append(fd)
            }
            return descriptors
        } catch {
            descriptors.forEach { close($0) }
            throw error
        }
    }

    func isWorking(_ agent: EngineAgent) -> Bool {
        let fd = open(root.appendingPathComponent("work-locks/agent-" + agent.rawValue + ".lock").path, O_NOFOLLOW | O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return flock(fd, LOCK_EX | LOCK_NB) != 0
    }

    func lockJob() throws -> Int32 {
        try Paths.ensurePrivateDirectory(root)
        let fd = open(root.appendingPathComponent("engine.lock").path, O_CREAT | O_NOFOLLOW | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FawalyError.invalid("The engine job lock could not be opened.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw FawalyError.invalid("The engine is already running a job. Retry after it finishes.")
        }
        return fd
    }

    private func withJobLock(_ action: () throws -> Void) throws {
        let fd = try lockJob()
        defer { close(fd) }
        try action()
    }
}

enum EngineKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.daxow.fawaly.rebuilt.engine",
         kSecAttrAccount as String: "claude-setup-token"]
    }

    static func defaultKeychainFile() -> URL? {
        var keychain: SecKeychain?
        guard SecKeychainCopyDefault(&keychain) == errSecSuccess, let keychain else { return nil }
        var length: UInt32 = 4096
        var path = [CChar](repeating: 0, count: Int(length))
        guard SecKeychainGetPath(keychain, &length, &path) == errSecSuccess else { return nil }
        return URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
    }

    static func claudeToken() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = item as? Data, let token = String(data: bytes, encoding: .utf8) else {
            throw FawalyError.invalid("Fawaly could not read its Claude Code token from Keychain.")
        }
        return token
    }

    static func saveClaudeToken(_ value: String) throws {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.utf8.count <= 8_192, !token.contains(where: \.isWhitespace) else {
            throw FawalyError.invalid("Paste the single token printed by Claude Code’s setup-token command.")
        }
        let changes = [kSecValueData as String: Data(token.utf8)]
        var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(changes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw FawalyError.invalid("Fawaly could not save the token in Keychain.") }
    }

    static func forgetClaudeToken() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw FawalyError.invalid("Fawaly could not remove its token from Keychain.")
        }
    }
}
