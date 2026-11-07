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
    private final class ActiveProcesses: @unchecked Sendable {
        private let lock = NSLock()
        private var processes: [UUID: Process] = [:]

        func insert(_ process: Process, id: UUID) {
            lock.lock()
            defer { lock.unlock() }
            processes[id] = process
        }

        func remove(_ id: UUID) {
            lock.lock()
            defer { lock.unlock() }
            processes.removeValue(forKey: id)
        }

        func terminate() {
            lock.lock()
            let active = Array(processes.values)
            lock.unlock()
            for process in active where process.isRunning { process.terminate() }
        }
    }

    private static let active = ActiveProcesses()
    static func cancelAll() { active.terminate() }

    private final class Buffer: @unchecked Sendable {
        let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            if data.count < 131_072 { data.append(chunk.prefix(131_072 - data.count)) }
        }
        func text() -> String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    static func run(
        _ command: LoginCommand, timeout: TimeInterval,
        onURL: @escaping @Sendable (URL) -> Void = { _ in }
    ) async throws -> LoginReply {
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = command.environment
        process.currentDirectoryURL = command.directory
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        let buffer = Buffer()
        let errorBuffer = Buffer()
        output.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil }
            else { buffer.append(bytes) }
        }
        error.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil }
            else { errorBuffer.append(bytes) }
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            error.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
        }
        try Task.checkCancellation()
        try process.run()
        let processID = UUID()
        active.insert(process, id: processID)
        defer { active.remove(processID) }
        let deadline = Date().addingTimeInterval(timeout)
        var delivered = Set<URL>()
        do {
            if let text = command.input {
                try input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
                try input.fileHandleForWriting.close()
            }
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else { throw FawalyError.invalid("Sign-in timed out. Please try again.") }
                for url in browserURLs(in: buffer.text() + "\n" + errorBuffer.text()) where delivered.insert(url).inserted { onURL(url) }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            if process.isRunning {
                process.terminate()
                let stop = Date().addingTimeInterval(2)
                while process.isRunning && Date() < stop { try? await Task.sleep(for: .milliseconds(50)) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            throw error
        }
        // isRunning is already false. Pumping a second run loop with
        // waitUntilExit can hang while EOF notifications are being drained.
        output.fileHandleForReading.readabilityHandler = nil
        error.fileHandleForReading.readabilityHandler = nil
        buffer.append(output.fileHandleForReading.readDataToEndOfFile())
        errorBuffer.append(error.fileHandleForReading.readDataToEndOfFile())
        return LoginReply(exitCode: process.terminationStatus, output: buffer.text(), errorOutput: errorBuffer.text())
    }

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
