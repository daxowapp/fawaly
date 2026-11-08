import Foundation
import AppKit
import CryptoKit
import Network
import Security

/// Only the challenge and a loopback callback leave this process. No password,
/// authorization code or API key is written to a URL log or a configuration file.
struct OpenRouterPKCE: Sendable {
    let verifier: String
    let state: String
    let path: String
    init() throws {
        func random() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw FawalyError.invalid("Secure sign-in could not be prepared.")
            }
            return Self.base64(Data(bytes))
        }
        verifier = try random(); state = try random(); path = "/callback/" + (try random())
    }
    var challenge: String { Self.base64(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    private static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    func authorizationURL(callback: URL, arabic: Bool = false) -> URL {
        var url = URLComponents(string: "https://openrouter.ai/auth")!
        url.queryItems = [URLQueryItem(name: "callback_url", value: callback.absoluteString),
                          URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "code_challenge_method", value: "S256"),
                          URLQueryItem(name: "state", value: state), URLQueryItem(name: "key_label", value: WorkshopCopy.integrationName(arabic: arabic) + " on Mac")]
        return url.url!
    }
    func code(from target: String) throws -> String {
        guard target.utf8.count <= 8192, target.hasPrefix(path + "?"),
              let url = URLComponents(string: "http://localhost" + target), url.path == path,
              let items = url.queryItems, items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == state,
              items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value,
              !code.isEmpty, code.utf8.count <= 4096,
              !code.contains(where: { $0.isWhitespace || $0.isNewline || $0.asciiValue.map { $0 < 32 || $0 == 127 } == true }) else {
            throw FawalyError.invalid("Invalid sign-in callback. No account was connected.")
        }
        return code
    }
    func exchangeRequest(code: String) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!, timeoutInterval: 20)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "code_verifier": verifier, "code_challenge_method": "S256"])
        return request
    }
}

@MainActor
final class OpenRouterSignIn {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var continuation: CheckedContinuation<String, Error>?
    private var deadline: Task<Void, Never>?
    private var started = false
    private var arabic = false

    func signIn(arabic: Bool = false, timeout: TimeInterval = 180,
                open: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
                exchange: @escaping @Sendable (URLRequest) async throws -> (Data, Int) = { try await APIHTTP.send($0) }) async throws -> String {
        self.arabic = arabic
        let pkce = try OpenRouterPKCE()
        defer { stop() }
        let code = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { waiting in
                continuation = waiting
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let server = try NWListener(using: parameters)
                    listener = server
                    server.stateUpdateHandler = { [weak self] state in
                      Task { @MainActor in
                        guard let self else { return }
                        if case .ready = state, !self.started, let port = self.listener?.port {
                            self.started = true
                            let callback = URL(string: "http://localhost:\(port.rawValue)\(pkce.path)")!
                            guard open(pkce.authorizationURL(callback: callback, arabic: arabic)) else {
                                self.finish(.failure(FawalyError.invalid("Open your browser to connect OpenRouter."))); return
                            }
                        } else if case .failed = state {
                            self.finish(.failure(FawalyError.invalid("The local sign-in callback could not start.")))
                        }
                      }
                    }
                    server.newConnectionHandler = { [weak self] connection in
                      Task { @MainActor in
                        guard let self, self.connections.count < 8 else { connection.cancel(); return }
                        self.connections.append(connection); connection.start(queue: .main)
                        self.receive(connection, bytes: Data(), pkce: pkce)
                      }
                    }
                    server.start(queue: .main)
                    deadline = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(max(1, min(timeout, 600)))) }
                        catch { return }
                        self?.finish(.failure(FawalyError.invalid("OpenRouter sign-in timed out. Try again.")))
                    }
                } catch { finish(.failure(FawalyError.invalid("The local sign-in callback could not start."))) }
            }
        } onCancel: { Task { @MainActor in self.finish(.failure(CancellationError())) } }
        try Task.checkCancellation()
        let (bytes, status) = try await exchange(pkce.exchangeRequest(code: code))
        try Task.checkCancellation()
        guard status == 200, bytes.count <= 65536,
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let key = object["key"] as? String, !key.isEmpty, key.utf8.count <= 16384,
              !key.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw FawalyError.invalid("OpenRouter authorization could not be completed. Try again or use an API key.")
        }
        return key
    }
    private func receive(_ connection: NWConnection, bytes: Data, pkce: OpenRouterPKCE) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: max(1, 8192 - bytes.count)) { [weak self] data, _, done, error in
          Task { @MainActor in
            guard let self else { connection.cancel(); return }
            var bytes = bytes; bytes.append(data ?? Data())
            guard bytes.count < 8192, error == nil else { self.close(connection); return }
            guard bytes.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if done { self.close(connection) } else { self.receive(connection, bytes: bytes, pkce: pkce) }; return
            }
            let first = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n")[0].split(separator: " ")
            let code = first.count == 3 && first[0] == "GET" && first[2] == "HTTP/1.1" ? try? pkce.code(from: String(first[1])) : nil
            let body = self.arabic
                ? (code == nil ? "رابط الرجوع غير صالح. ارجع للفواعلي وجرّب تاني." : "وصل تفويض OpenRouter. ارجع للفواعلي واختار الموديل واحفظ الاتصال.")
                : (code == nil ? "Invalid callback. Return to Sudo Interns (Fawaly) to try again." : "OpenRouter authorization received. Return to Sudo Interns (Fawaly) to choose your model and save the connection.")
            let header = "HTTP/1.1 \(code == nil ? "400 Bad Request" : "200 OK")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'\r\n\r\n"
            connection.send(content: Data((header + body).utf8), completion: .contentProcessed { [weak self] _ in
              Task { @MainActor in
                self?.close(connection)
                if let code { self?.finish(.success(code)) }
              }
            })
          }
        }
    }
    private func close(_ connection: NWConnection) {
        connection.cancel(); connections.removeAll { $0 === connection }
    }
    private func finish(_ result: Result<String, Error>) {
        let pending = continuation; continuation = nil
        stop(); pending?.resume(with: result)
    }
    private func stop() {
        deadline?.cancel(); deadline = nil; listener?.cancel(); listener = nil
        for connection in connections { connection.cancel() }; connections = []
    }
}
