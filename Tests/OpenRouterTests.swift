import Foundation
import CryptoKit
import Testing
@testable import FawalyApp

@Test func openRouterRejectsCallbackInjectionAndUsesPKCE() throws {
    let flow = try OpenRouterPKCE(), other = try OpenRouterPKCE()
    #expect(flow.verifier.count == 43 && flow.state.count == 43)
    #expect(flow.verifier != other.verifier && flow.state != other.state)
    let callback = URL(string: "http://localhost:54321" + flow.path)!
    let auth = URLComponents(url: flow.authorizationURL(callback: callback), resolvingAgainstBaseURL: false)!
    #expect(auth.host == "openrouter.ai" && auth.path == "/auth")
    #expect(auth.queryItems?.first(where: { $0.name == "code_challenge_method" })?.value == "S256")
    #expect(auth.queryItems?.contains(where: { $0.name == "code_verifier" }) == false)
    let valid = flow.path + "?code=fixture-code&state=" + flow.state
    #expect(try flow.code(from: valid) == "fixture-code")
    for target in ["/wrong?code=fixture-code&state=" + flow.state,
                   flow.path + "?code=fixture-code&state=wrong", valid + "&code=second", valid + "&state=second",
                   flow.path + "?code=%0A&state=" + flow.state] {
        #expect(throws: FawalyError.self) { try flow.code(from: target) }
    }
}

@Test @MainActor func openRouterLoopbackExchangesOnceWithoutOpeningARealAccount() async throws {
    let key = try await OpenRouterSignIn().signIn(timeout: 5, open: { authorization in
        let items = URLComponents(url: authorization, resolvingAgainstBaseURL: false)!.queryItems!
        var callback = URLComponents(string: items.first { $0.name == "callback_url" }!.value!)!
        #expect(callback.host == "localhost")
        callback.queryItems = [URLQueryItem(name: "code", value: "fixture-code"), URLQueryItem(name: "state", value: items.first { $0.name == "state" }!.value!)]
        let url = callback.url!
        Task { _ = try await URLSession.shared.data(from: url) }
        return true
    }, exchange: { request in
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/auth/keys")
        #expect(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String])
        #expect(body["code"] == "fixture-code" && body["code_challenge_method"] == "S256")
        #expect(body["code_verifier"]?.count == 43)
        return (Data(#"{"key":"fixture-derived-key"}"#.utf8), 200)
    })
    #expect(key == "fixture-derived-key")
}

@Test @MainActor func openRouterSignInCanBeCancelledAndTimesOutWithoutExchanging() async {
    await #expect(throws: FawalyError.self) {
        try await OpenRouterSignIn().signIn(timeout: 1, open: { _ in true }, exchange: { _ in
            Issue.record("A timed-out flow attempted key exchange"); return (Data(), 500)
        })
    }
    let task = Task { try await OpenRouterSignIn().signIn(open: { _ in true }, exchange: { _ in
        Issue.record("A cancelled flow attempted key exchange"); return (Data(), 500)
    }) }
    try? await Task.sleep(for: .milliseconds(50))
    task.cancel()
    do { _ = try await task.value; Issue.record("Cancelled flow succeeded") }
    catch { #expect(error is CancellationError) }
}

@Test func openRouterListsOnlyTextToolModelsWithoutGenerationOrAuthentication() async throws {
    var profile = APIAssistant.preset(.openrouter); profile.model = "catalog-fixture"
    var worker = APIWorker(root: FileManager.default.temporaryDirectory)
    worker.credential = { _ in "" }
    worker.transport = { request in
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/models")
        #expect(request.httpBody == nil && request.value(forHTTPHeaderField: "Authorization") == nil)
        let data: [[String: Any]] = [
            ["id": "vendor/tool-model", "supported_parameters": ["tools"], "architecture": ["output_modalities": ["text"]]],
            ["id": "vendor/chat-only", "supported_parameters": [], "architecture": ["output_modalities": ["text"]]],
            ["id": "vendor/async-only:batch", "supported_parameters": ["tools"], "architecture": ["output_modalities": ["text"]]],
            ["id": "vendor/image-only", "supported_parameters": ["tools"], "architecture": ["output_modalities": ["image"]]]]
        return (try JSONSerialization.data(withJSONObject: ["data": data]), 200)
    }
    #expect(try await worker.models(profile) == ["vendor/tool-model"])
    profile.endpoint = URL(string: "https://attacker.invalid/api/v1/chat/completions")!
    #expect(throws: FawalyError.self) { try profile.validate() }
}

@Test func openRouterKeepsSelectedModelAndDisablesProviderFallback() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var profile = APIAssistant.preset(.openrouter); profile.model = "vendor/selected-model"
    var worker = APIWorker(root: root)
    worker.credential = { _ in "fixture-key" }
    worker.transport = { request in
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(body["model"] as? String == "vendor/selected-model" && body["models"] == nil)
        let provider = try #require(body["provider"] as? [String: Bool])
        #expect(provider["allow_fallbacks"] == false && provider["require_parameters"] == true)
        return (Data(#"{"choices":[{"message":{"content":"fixture-result"}}]}"#.utf8), 200)
    }
    #expect(try await worker.run(profile, prompt: "fixture", workspace: nil, timeout: 3) == "fixture-result")
}
