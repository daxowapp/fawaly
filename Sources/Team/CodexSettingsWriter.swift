import Darwin
import Foundation

// Use Codex's atomic config writer so an edit stays confined to this server's setting.
struct CodexSettingsWriter {
    private final class Responses: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ bytes: Data) {
            lock.lock()
            defer { lock.unlock() }
            if data.count < 1_048_576 { data.append(bytes.prefix(1_048_576 - data.count)) }
        }

        func response(_ id: Int) -> [String: Any]? {
            lock.lock()
            let snapshot = data
            lock.unlock()
            return snapshot.split(separator: 10).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
                .first { $0["id"] as? Int == id }
        }
    }

    static func setTeamTimeout(executable: URL, home: URL, directory: URL, environment: [String: String]) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.environment = environment
        process.currentDirectoryURL = directory
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let responses = Responses()
        output.fileHandleForReading.readabilityHandler = { responses.append($0.availableData) }
        try Task.checkCancellation()
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            output.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
        }
        func send(_ request: [String: Any]) throws {
            var bytes = try JSONSerialization.data(withJSONObject: request)
            bytes.append(10)
            try input.fileHandleForWriting.write(contentsOf: bytes)
        }
        func waitFor(_ id: Int) async throws -> [String: Any] {
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                if let response = responses.response(id) {
                    guard response["error"] == nil, let result = response["result"] as? [String: Any] else {
                        throw FawalyError.invalid("Codex could not save the team’s task duration. Please retry setup.")
                    }
                    return result
                }
                guard process.isRunning else { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw FawalyError.invalid("Codex did not finish saving the team’s task duration. Please retry setup.")
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "fawaly-setup", "version": "0.6.0"], "capabilities": [:]]])
        _ = try await waitFor(1)
        try send(["method": "initialized"])
        try send(["id": 2, "method": "config/value/write", "params": [
            "keyPath": "mcp_servers." + ClientLink.serverName + ".tool_timeout_sec", "value": 3610,
            "mergeStrategy": "replace", "filePath": home.appendingPathComponent(".codex/config.toml").path]])
        _ = try await waitFor(2)
    }
}
