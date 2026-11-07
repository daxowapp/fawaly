import Foundation

struct EndpointSettings: Codable, Equatable, Sendable {
    let url: URL
    let model: String
    
    private enum CodingKeys: String, CodingKey { case url, model }
    
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let url = try values.decode(URL.self, forKey: .url)
        try self.init(endpoint: url.absoluteString, model: values.decode(String.self, forKey: .model))
    }
    
    init(endpoint: String, model: String) throws {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: trimmed),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil, parts.query == nil,
              !parts.path.isEmpty, parts.path != "/", let url = parts.url else {
            throw FawalyError.invalid("Enter a full HTTPS chat-completions endpoint without a query or credentials.")
        }
        guard !identifier.isEmpty, identifier.utf8.count <= 128 else {
            throw FawalyError.invalid("Enter a model ID of at most 128 bytes.")
        }
        self.url = url
        self.model = identifier
    }
}

struct TextAdvisor: Sendable {
    static let questionLimit = 16 * 1_024
    static let contextLimit = 64 * 1_024
    static let responseLimit = 512 * 1_024

    enum Purpose { case consultation, task }

    static func validate(question: String, context: String) throws {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              question.utf8.count <= questionLimit else {
            throw FawalyError.invalid("Enter a question or task of up to 16 KB.")
        }
        guard context.utf8.count <= contextLimit else {
            throw FawalyError.invalid("Context can contain up to 64 KB.")
        }
    }

    static func demo(question: String, context: String, arabic: Bool) -> String {
        let headline = String(question.prefix(180))
        if arabic {
            let contextNote = context.isEmpty ? "أضف السياق أو القيود المهمة." : "راجع السياق اللي كتبته وحدّد القيود المهمة."
            return """
                معاينة محلية · قائمة مراجعة جاهزة

                \(headline)

                1. حدّد النتيجة المطلوبة ومعيار نجاحها.
                2. \(contextNote)
                3. جرّب أصغر خطوة ممكنة وراجع النتيجة قبل ما تكمّل.
                """
        }
        let contextNote = context.isEmpty ? "Write down the relevant context and constraints." : "Review the context you entered and identify the relevant constraints."
        return """
            Local preview · checklist

            \(headline)

            1. Define the desired outcome and how to check it.
            2. \(contextNote)
            3. Try the smallest useful step and review the result before continuing.
            """
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }

    private struct Body: Encodable {
        let model: String
        let messages: [Message]
    }

    private struct Reply: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
        ) async -> URLRequest? { nil }
    }

    static func request(endpoint: EndpointSettings, key: String, messages: [Message], timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: endpoint.url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(Body(model: endpoint.model, messages: messages))
        return request
    }

    static func send(
        endpoint: EndpointSettings, key: String, question: String, context: String,
        previous: [ConsultRound], purpose: Purpose, timeout: TimeInterval
    ) async throws -> String {
        try validate(question: question, context: context)
        let instruction = purpose == .consultation
            ? "Give concise second-opinion advice based only on the text provided. Identify risks and a verification step. Do not claim to have changed files or run tools."
            : "Respond to the task with a concise textual result using only the provided text. Do not claim to have changed files or run tools."
        var messages = [Message(role: "system", content: instruction)]
        for round in previous {
            messages.append(Message(role: "user", content: round.prompt))
            messages.append(Message(role: "assistant", content: round.advice))
        }
        messages.append(Message(role: "user", content: context.isEmpty ? question : question + "\n\nContext:\n" + context))
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = timeout
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let request = try request(endpoint: endpoint, key: key, messages: messages, timeout: timeout)
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FawalyError.invalid("The service returned an invalid response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw FawalyError.invalid("The service returned HTTP \(http.statusCode).")
        }
        var data = Data()
        for try await byte in stream {
            guard data.count < responseLimit else { throw FawalyError.invalid("The response exceeded the size limit.") }
            data.append(byte)
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
              let content = reply.choices.first?.message.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FawalyError.invalid("The service did not return a chat message.")
        }
        return content
    }
}
