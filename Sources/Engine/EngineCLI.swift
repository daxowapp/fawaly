import CoreFoundation
import Darwin
import Foundation
import Security

enum EngineCLI {
    private static let outputLock = NSLock()
    static func run(_ arguments: [String]) async -> Int32 {
        var root = Paths.rebuiltRoot()
        #if DEBUG
        if let testRoot = ProcessInfo.processInfo.environment["FAWALY_ENGINE_TEST_ROOT"], testRoot.hasPrefix("/") {
            root = URL(fileURLWithPath: testRoot, isDirectory: true)
        }
        #endif
        let configuration = EngineConfiguration(root: root)
        do {
            switch arguments.first {
            case "mcp":
                // SecItem's LAContext flag does not suppress prompts for legacy
                // file-based Mac keychains. This headless process must fail
                // closed; approvals belong in the account editor's GUI action.
                var previousInteraction: DarwinBoolean = true
                guard SecKeychainGetUserInteractionAllowed(&previousInteraction) == errSecSuccess,
                      SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
                    throw FawalyError.invalid("Background Keychain access could not be prepared. Open Fawaly and retry from the account editor.")
                }
                defer { SecKeychainSetUserInteractionAllowed(previousInteraction.boolValue) }
                let client: EngineAgent?
                if arguments.count == 1 { client = nil }
                else if arguments.count == 3, arguments[1] == "--client", let value = EngineAgent(rawValue: arguments[2]), EngineAgent.primaryAgents.contains(value) { client = value }
                else { throw FawalyError.invalid("Use: fawaly mcp --client codex|claude") }
                let server = EngineMCP(bridge: EngineBridge(configuration: configuration, client: client))
                signal(SIGPIPE, SIG_IGN)
                signal(SIGTERM, SIG_IGN)
                signal(SIGINT, SIG_IGN)
                let runner = Task.detached { try await server.serve() }
                let sources = [SIGTERM, SIGINT].map { value in
                    let source = DispatchSource.makeSignalSource(signal: value, queue: .global())
                    source.setEventHandler { runner.cancel() }
                    source.resume()
                    return source
                }
                defer { sources.forEach { $0.cancel() } }
                try await runner.value
            case "status":
                let result = try EngineBridge(configuration: configuration, client: nil).status()
                try writeJSON(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)))
            case "codex-login":
                try configuration.prepareCodexHome()
                guard let executable = EngineAgent.codex.executable() else { throw FawalyError.invalid("Install the Codex CLI first.") }
                let process = Process()
                process.executableURL = executable
                process.currentDirectoryURL = configuration.codexHome
                process.arguments = ["login", "-c", "cli_auth_credentials_store=\"file\""]
                process.environment = [
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                    "CODEX_HOME": configuration.codexHome.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color"
                ]
                process.standardInput = FileHandle.standardInput
                process.standardOutput = FileHandle.standardOutput
                process.standardError = FileHandle.standardError
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus
            case "claude-setup-token":
                guard let executable = EngineAgent.claude.executable() else { throw FawalyError.invalid("Install the Claude Code CLI first.") }
                let setup = configuration.root.appendingPathComponent("claude-setup")
                try Paths.ensurePrivateDirectory(setup)
                let process = Process()
                process.executableURL = executable
                process.currentDirectoryURL = setup
                process.arguments = ["setup-token"]
                process.environment = [
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                    "CLAUDE_CONFIG_DIR": setup.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color"
                ]
                process.standardInput = FileHandle.standardInput
                process.standardOutput = FileHandle.standardOutput
                process.standardError = FileHandle.standardError
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus
            case "allow-workspace", "deny-workspace":
                guard arguments.count == 2 else { throw FawalyError.invalid("Pass the absolute path of one project directory.") }
                if arguments[0] == "allow-workspace" {
                    let directory = try configuration.allowWorkspace(arguments[1])
                    print("Allowed workspace: \(directory.path)")
                } else {
                    try configuration.denyWorkspace(arguments[1])
                    print("Workspace removed from Fawaly’s allowlist.")
                }
            default:
                print("Usage: fawaly mcp --client codex|claude, status, codex-login, claude-setup-token, allow-workspace PATH, deny-workspace PATH")
                return arguments.first == "--help" ? 0 : 64
            }
            return 0
        } catch is CancellationError {
            return 0
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            return 1
        }
    }

    static func writeJSON(_ value: Any) throws {
        outputLock.lock()
        defer { outputLock.unlock() }
        var bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        bytes.append(10)
        try FileHandle.standardOutput.write(contentsOf: bytes)
    }
}

struct EngineMCP: Sendable {
    let bridge: EngineBridge

    // Tool requests run independently so status and stop remain usable during a
    // long delegation. Bound concurrency and serialize stdout JSON frames.
    private final class Slots: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func acquire() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard count < 8 else { return false }
            count += 1
            return true
        }
        func release() { lock.lock(); count -= 1; lock.unlock() }
    }

    func serve() async throws {
        let slots = Slots()
        try await withThrowingTaskGroup(of: Void.self) { requests in
            defer { requests.cancelAll() }
            var pending = Data()
            var initialized = false
            var input = [UInt8](repeating: 0, count: 8_192)
            while true {
                try Task.checkCancellation()
                await Task.yield()
                var fd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                let ready = poll(&fd, 1, 100)
                if ready == 0 { continue }
                if ready < 0 {
                    if errno == EINTR { continue }
                    return
                }
                let count = input.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count) }
                if count <= 0 { return }
                pending.append(contentsOf: input.prefix(count))
                while let newline = pending.firstIndex(of: 10) {
                    let frame = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    let message = try? JSONSerialization.jsonObject(with: frame) as? [String: Any]
                    if initialized, message?["method"] as? String == "tools/call", let id = message?["id"] {
                        guard slots.acquire() else {
                            try EngineCLI.writeJSON(rpcError(id, -32000, "Too many concurrent team requests. Please retry."))
                            continue
                        }
                        requests.addTask {
                            defer { slots.release() }
                            var ready = true
                            if let response = await handle(frame, initialized: &ready) { try EngineCLI.writeJSON(response) }
                        }
                    } else if let response = await handle(frame, initialized: &initialized) {
                        try EngineCLI.writeJSON(response)
                    }
                }
                guard pending.count < 512 * 1_024 else { return }
            }
        }
    }

    func handle(_ frame: Data, initialized: inout Bool) async -> [String: Any]? {
        guard frame.count < 512 * 1_024,
              let request = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
            return rpcError(NSNull(), -32700, "Invalid JSON")
        }
        guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
            return rpcError(NSNull(), -32600, "Invalid request")
        }
        guard let id = request["id"] else { return nil }
        guard id is String || (id is NSNumber && CFGetTypeID(id as CFTypeRef) != CFBooleanGetTypeID()) else {
            return rpcError(NSNull(), -32600, "Invalid request ID")
        }
        let params = request["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch method {
        case "initialize":
            let versions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
            let requested = params["protocolVersion"] as? String ?? ""
            initialized = true
            result = ["protocolVersion": versions.contains(requested) ? requested : versions[0],
                      "capabilities": ["tools": ["listChanged": false]],
                      "serverInfo": ["name": "fawaly-rebuilt", "version": "0.7.0"],
                      "instructions": "Fawaly manages your team. For a nontrivial user task, proactively read roster_get and use the configured team without requiring the user to direct each step. Use the saved delegation timeout and ordered workers for the task kind (general, code, research, review); no implicit paid fallback. You remain the primary and own the plan, integration, verification, and final decision. Follow advisor.mode: important means consult the assigned advisor before committing to a plan or important decision; on_request means consult only when the user requests advice; off means do not consult. Send relevant user-authorized context with a concise proposed plan and record your decision using consult_decide. Delegate a suitable bounded implementation or investigation to a configured worker when available; send a precise deliverable, allowed files, constraints, and acceptance checks. Supply a short user-facing title in the roster language so the workshop shows a readable task name. Do not delegate the whole task or your final review. A cwd permits edits only in the project the user approved in Fawaly. After the worker returns, independently inspect actual changed files and run appropriate verification, repair findings, then call review with the jobId, decision, your own observed evidence, and optional score. A worker report is a claim, not proof. Never claim a review you did not perform. Use changes_requested or rejected when checks fail. Keep working until the user’s goal is complete. Text-only advice requires no workspace access; workers cannot delegate again."]
        case "ping":
            result = [:]
        case "tools/list" where initialized:
            result = ["tools": Self.tools]
        case "tools/call" where initialized:
            guard let name = params["name"] as? String else { return rpcError(id, -32602, "Expected a tool name") }
            do {
                let args = params["arguments"] as? [String: Any] ?? [:]
                guard params["arguments"] == nil || params["arguments"] is [String: Any] else {
                    return rpcError(id, -32602, "Tool arguments must be an object")
                }
                let value = try await tool(name, args)
                let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                result = ["isError": false, "content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]],
                          "structuredContent": value]
            } catch {
                result = ["isError": true, "content": [["type": "text", "text": error.localizedDescription]]]
            }
        case "tools/list", "tools/call":
            return rpcError(id, -32002, "Initialize the Fawaly session first")
        default:
            return rpcError(id, -32601, "Method not found")
        }
        return ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func tool(_ name: String, _ args: [String: Any]) async throws -> [String: Any] {
        guard let spec = Self.tools.first(where: { $0["name"] as? String == name }),
              let schema = spec["inputSchema"] as? [String: Any],
              let fields = schema["properties"] as? [String: [String: Any]] else {
            throw FawalyError.invalid("Unknown Fawaly tool.")
        }
        for (key, value) in args {
            guard let type = fields[key]?["type"] as? String,
                  type == "string" ? value is String : (value is NSNumber && CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()) else {
                throw FawalyError.invalid("Unsupported argument or argument type for \(key).")
            }
            if let allowed = fields[key]?["enum"] as? [String], let supplied = value as? String, !allowed.contains(supplied) {
                throw FawalyError.invalid("Use one of these values for \(key): " + allowed.joined(separator: ", "))
            }
        }
        for key in schema["required"] as? [String] ?? [] where args[key] == nil {
            throw FawalyError.invalid("Missing \(key).")
        }
        switch name {
        case "status", "roster_get":
            return try object(bridge.status())
        case "delegate":
            guard let brief = args["brief"] as? String, !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  brief.utf8.count <= 120 * 1_024 else { throw FawalyError.invalid("Enter a brief of up to 120 KB.") }
            return try await object(bridge.delegate(brief: brief, cwd: args["cwd"] as? String,
                                                    provider: args["provider"] as? String, timeout: try (args["timeout"] as? String).map { try Self.seconds($0) }, kind: args["kind"] as? String, title: args["title"] as? String))
        case "consult":
            let reasonValue = args["reason"] as? String ?? ConsultReason.userRequest.rawValue
            guard let reason = ConsultReason(rawValue: reasonValue), let question = args["question"] as? String else {
                throw FawalyError.invalid("Use a question and a valid consultation reason.")
            }
            let id = try Self.id(args["consultId"] as? String)
            return try await object(bridge.consult(question: question, context: args["context"] as? String ?? "",
                                                   reason: reason, provider: args["advisor"] as? String, continuing: id))
        case "stop":
            guard let id = try Self.id(args["jobId"] as? String), let client = bridge.client else {
                throw FawalyError.invalid("Choose a running job from this primary.")
            }
            try bridge.configuration.requestStop(id, primary: client)
            return ["jobId": id.uuidString, "status": "stop_requested"]
        case "review":
            guard let id = try Self.id(args["jobId"] as? String),
                  let decision = TeamReview.Decision(rawValue: args["decision"] as? String ?? ""),
                  let summary = args["summary"] as? String, let verification = args["verification"] as? String else {
                throw FawalyError.invalid("Use a jobId, decision, summary, and independent verification evidence.")
            }
            let score: Int?
            if let value = args["score"] as? String {
                guard let number = Int(value), (1...5).contains(number) else { throw FawalyError.invalid("Review scores range from 1 to 5.") }
                score = number
            } else { score = nil }
            return try object(bridge.review(id: id, decision: decision, summary: summary, verification: verification, score: score))
        case "consult_decide":
            guard let id = try Self.id(args["consultId"] as? String),
                  let decision = ConsultDecision(rawValue: args["decision"] as? String ?? "") else {
                throw FawalyError.invalid("Use a consultation ID and adopted, partly, or rejected.")
            }
            return try object(bridge.decide(id: id, decision: decision, summary: args["summary"] as? String ?? ""))
        default:
            throw FawalyError.invalid("Unknown Fawaly tool.")
        }
    }

    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        guard let fields = object as? [String: Any] else { throw FawalyError.invalid("Invalid engine result.") }
        return fields
    }

    private func rpcError(_ id: Any, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    static func seconds(_ value: String?) throws -> Int {
        guard let value else { return 120 }
        if value.utf8.allSatisfy({ (48...57).contains($0) }), let seconds = Int(value), (1...3_600).contains(seconds) { return seconds }
        let units: [Character: Int] = ["s": 1, "m": 60, "h": 3_600]
        guard let unit = value.last, let multiplier = units[unit], let amount = Int(value.dropLast()),
              (1...(3_600 / multiplier)).contains(amount) else {
            throw FawalyError.invalid("Set a timeout between 1s and 1h, such as 2m.")
        }
        return amount * multiplier
    }

    private static func id(_ value: String?) throws -> UUID? {
        guard let value else { return nil }
        guard let id = UUID(uuidString: value) else { throw FawalyError.invalid("Invalid record ID.") }
        return id
    }

    static let tools: [[String: Any]] = {
        func tool(_ name: String, _ description: String, fields: [String: String] = [:],
                  required: [String] = [], readOnly: Bool = false, openWorld: Bool = false) -> [String: Any] {
            var properties = fields.mapValues { ["type": $0] as [String: Any] }
            if name == "delegate" {
                properties["timeout"]?["description"] = "Duration from 1 second to 1 hour, e.g. 90s or 15m. A numeric string is seconds. Omit to use the saved worker timeout."
                properties["timeout"]?["examples"] = ["90s", "15m", "900"]
            }
            if name == "consult" { properties["reason"]?["enum"] = ConsultReason.allCases.map(\.rawValue) }
            if name == "review" { properties["decision"]?["enum"] = TeamReview.Decision.allCases.map(\.rawValue) }
            if name == "consult_decide" { properties["decision"]?["enum"] = ["adopted", "partly", "rejected"] }
            return ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": properties,
                             "required": required, "additionalProperties": false],
             "annotations": ["readOnlyHint": readOnly, "openWorldHint": openWorld]]
        }
        return [
            tool("status", "Read native connection status, team roles, advisor policy, and approved project access.", readOnly: true),
            tool("roster_get", "Read the configured primary, advisor, workers, advisor policy, and approved project. Use this at the start of substantial work, then proactively consult and delegate according to those roles.", readOnly: true),
            tool("delegate", "Send a task brief to a configured Fawaly worker. A cwd allows edits only in a project approved by the user. Independently inspect changes and verify the result, then record your decision with review and the returned jobId.",
                 fields: ["brief": "string", "cwd": "string", "provider": "string", "timeout": "string",
                          "lane": "string", "kind": "string", "title": "string", "allowMetered": "boolean"], required: ["brief"], openWorld: true),
            tool("consult", "Ask the configured Fawaly advisor for a text-only second opinion. Send only context approved by the user.",
                 fields: ["question": "string", "context": "string", "reason": "string", "advisor": "string", "consultId": "string"],
                 required: ["question"], openWorld: true),
            tool("stop", "Request a stop for this primary’s running worker job. File edits may be partial and must be reviewed. Other processes are not stopped.", fields: ["jobId": "string"], required: ["jobId"]),
            tool("review", "Record the primary’s independent review of a finished worker job. Inspect actual files and run appropriate checks first. Decisions: accepted, changes_requested, rejected. Evidence must describe your observations, not repeat the worker’s claims.",
                 fields: ["jobId": "string", "decision": "string", "summary": "string", "verification": "string", "score": "string"], required: ["jobId", "decision", "summary", "verification"]),
            tool("consult_decide", "Record the primary agent’s decision for an open consultation.",
                 fields: ["consultId": "string", "decision": "string", "summary": "string"], required: ["consultId", "decision"])
        ]
    }()
}
