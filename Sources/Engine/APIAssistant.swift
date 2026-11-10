import Foundation
import Security
import CryptoKit
import LocalAuthentication

struct APIAssistant: Codable, Equatable, Sendable {
    enum Format: String, Codable, CaseIterable { case openAI, anthropic }
    let agent: EngineAgent
    var endpoint: URL
    var model: String
    var format: Format
    var enabled = true
    var dailyRequestLimit = 100
    var maxRounds = 12
    /// Reply size requested from the service for each round. Nil keeps the
    /// default, which every supported service accepts; a larger value must be
    /// one the chosen model allows, or the service rejects the request.
    var maxOutputTokens: Int?
    static let defaultOutputTokens = 4096
    static let outputTokenRange = 1024...65536
    var local: Bool { ["localhost", "127.0.0.1", "[::1]", "::1"].contains(endpoint.host?.lowercased() ?? "") }
    var keyAccount: String { agent.rawValue + ":" + SHA256.hash(data: Data(endpoint.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() }

    func validate() throws {
        guard !agent.isNative, OfficialModels.valid(model), (1...10000).contains(dailyRequestLimit), (1...32).contains(maxRounds),
              maxOutputTokens.map(Self.outputTokenRange.contains) ?? true,
              let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (parts.scheme == "http" && local),
              parts.path.hasSuffix(format == .anthropic ? "/messages" : "/chat/completions") else {
            throw FawalyError.invalid("Choose a valid HTTPS service endpoint, model and request limits. HTTP is allowed only on this Mac.")
        }
        if [.ollama, .lmstudio].contains(agent) && !local { throw FawalyError.invalid("Local assistants must use a loopback address on this Mac.") }
        let fixedHosts: [EngineAgent: String] = [.zai: "api.z.ai", .minimax: "api.minimax.io", .deepseek: "api.deepseek.com", .openrouter: "openrouter.ai"]
        if let expected = fixedHosts[agent], host != expected { throw FawalyError.invalid("This provider must use its official API host. Choose a custom service for another host.") }
        if agent == .openrouter && (format != .openAI || endpoint.absoluteString != "https://openrouter.ai/api/v1/chat/completions") {
            throw FawalyError.invalid("OpenRouter must use its official chat endpoint.")
        }
    }
    static func preset(_ agent: EngineAgent) -> Self {
        switch agent {
        case .zai: .init(agent: agent, endpoint: URL(string: "https://api.z.ai/api/paas/v4/chat/completions")!, model: "glm-5.3", format: .openAI)
        case .minimax: .init(agent: agent, endpoint: URL(string: "https://api.minimax.io/anthropic/v1/messages")!, model: "MiniMax-M3.1-Flash", format: .anthropic)
        case .deepseek: .init(agent: agent, endpoint: URL(string: "https://api.deepseek.com/chat/completions")!, model: "deepseek-flash", format: .openAI)
        case .openrouter: .init(agent: agent, endpoint: URL(string: "https://openrouter.ai/api/v1/chat/completions")!, model: "", format: .openAI)
        case .ollama: .init(agent: agent, endpoint: URL(string: "http://localhost:11434/v1/chat/completions")!, model: "", format: .openAI)
        case .lmstudio: .init(agent: agent, endpoint: URL(string: "http://localhost:1234/v1/chat/completions")!, model: "", format: .openAI)
        case .anthropicAPI: .init(agent: agent, endpoint: URL(string: "https://api.anthropic.com/v1/messages")!, model: "", format: .anthropic)
        default: .init(agent: agent, endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!, model: "", format: .openAI)
        }
    }
}

struct APIAssistantStore: Sendable {
    let root: URL
    private var file: URL { root.appendingPathComponent("api-assistants.json") }
    func all() throws -> [APIAssistant] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let info = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 65536 else { throw FawalyError.invalid("Invalid assistant configuration file.") }
        let values = try JSONDecoder().decode([APIAssistant].self, from: Data(contentsOf: file))
        for value in values { try value.validate() }
        guard Set(values.map(\.agent)).count == values.count else { throw FawalyError.invalid("Duplicate assistant configuration.") }
        return values
    }
    func load(_ agent: EngineAgent) throws -> APIAssistant? { try all().first { $0.agent == agent } }
    func save(_ value: APIAssistant) throws {
        try value.validate()
        var values = try all(); values.removeAll { $0.agent == value.agent }; values.append(value)
        try write(values)
    }
    func remove(_ agent: EngineAgent) throws { try write(all().filter { $0.agent != agent }) }
    private func write(_ values: [APIAssistant]) throws {
        try Paths.ensurePrivateDirectory(root)
        try JSONEncoder().encode(values).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

enum APIAssistantKeychain {
    private static func query(_ assistant: APIAssistant) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.daxow.fawaly.rebuilt.api", kSecAttrAccount as String: assistant.keyAccount]
    }
    static func contains(_ assistant: APIAssistant) -> Bool { SecItemCopyMatching(query(assistant) as CFDictionary, nil) == errSecSuccess }
    static func read(_ assistant: APIAssistant, allowInteraction: Bool = false) throws -> String {
        var value = query(assistant); value[kSecReturnData as String] = true
        // A headless MCP worker cannot surface a Keychain approval reliably.
        // MCP also disables legacy file-keychain interaction at process entry;
        // LAContext alone covers only the modern authentication path.
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        value[kSecUseAuthenticationContext as String] = context
        var data: CFTypeRef?
        let result = SecItemCopyMatching(value as CFDictionary, &data)
        if result == errSecItemNotFound { return "" }
        guard result == errSecSuccess, let bytes = data as? Data, let key = String(data: bytes, encoding: .utf8) else {
            throw FawalyError.invalid("Keychain access is unavailable. In Fawaly, open Assistants & plans, manage this service, and choose Save & test to approve access or enter its key again. No provider request was sent.")
        }
        return key
    }
    static func save(_ key: String, for assistant: APIAssistant) throws {
        guard !key.isEmpty, key.utf8.count <= 16384, !key.contains(where: \.isNewline) else { throw FawalyError.invalid("Enter a valid service key.") }
        let attributes = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(query(assistant) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(assistant); item.merge(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw FawalyError.invalid("The service key could not be saved in Keychain.") }
        } else if status != errSecSuccess { throw FawalyError.invalid("The service key could not be updated in Keychain.") }
    }
    static func remove(_ assistant: APIAssistant) throws {
        let status = SecItemDelete(query(assistant) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw FawalyError.invalid("The service key could not be removed from Keychain.") }
    }
}
