import Foundation
import Testing
@testable import FawalyApp

private func isolatedRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("fawaly-rebuilt-test-" + UUID().uuidString, isDirectory: true)
}

@Test @MainActor func previewTaskCompletesAndSurvivesReload() async throws {
    let root = isolatedRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(root: root)
    #expect(model.loaded)
    try model.addTask(title: "Check launch", details: "Use a clean state.")
    let item = try #require(model.state.work.first)
    try await model.runTask(item.id, provider: AppModel.preview)

    let restored = AppModel(root: root)
    let completed = try #require(restored.state.work.first)
    #expect(completed.id == item.id)
    #expect(completed.completed != nil)
    #expect(completed.result?.contains("Check launch") == true)
}

@Test @MainActor func previewConsultationRecordsRoundsAndDecision() async throws {
    let root = isolatedRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(root: root)
    try await model.consult(provider: AppModel.preview, by: .human, reason: .userRequest,
                            question: "Review the plan", context: "Private fixture")
    let first = try #require(model.consults.first)
    #expect(first.contextBytes == "Private fixture".utf8.count)
    #expect(first.contextSHA256 != nil)
    #expect(first.rounds.count == 1)

    try await model.consult(provider: AppModel.preview, by: .human, reason: .userRequest,
                            question: "What should I verify?", context: "", continuing: first.id)
    try model.decide(first.id, decision: .adopted, summary: "Start with a launch check.")

    let restored = AppModel(root: root)
    let finished = try #require(restored.consults.first)
    #expect(finished.rounds.map(\.index) == [1, 2])
    #expect(finished.status == .closed)
    #expect(finished.decision == .adopted)
}

@Test @MainActor func disabledAdvisorAndRoundLimitAreEnforced() async throws {
    let root = isolatedRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(root: root)
    try await model.updateAdvisors { $0.mode = .off }
    await #expect(throws: FawalyError.self) {
        try await model.consult(provider: AppModel.preview, by: .human, reason: .userRequest,
                                question: "Check", context: "")
    }
    try await model.updateAdvisors { $0.mode = .onRequest; $0.maxRounds = 1 }
    try await model.consult(provider: AppModel.preview, by: .human, reason: .userRequest,
                            question: "First", context: "")
    let first = try #require(model.consults.first)
    await #expect(throws: FawalyError.self) {
        try await model.consult(provider: AppModel.preview, by: .human, reason: .userRequest,
                                question: "Second", context: "", continuing: first.id)
    }
}

@Test func endpointValidationAndPayload() throws {
    #expect(throws: FawalyError.self) {
        try EndpointSettings(endpoint: "http://example.test/chat/completions", model: "fixture")
    }
    #expect(throws: FawalyError.self) {
        try EndpointSettings(endpoint: "https://user@example.test/chat/completions", model: "fixture")
    }
    let endpoint = try EndpointSettings(endpoint: "https://example.test/v1/chat/completions", model: "fixture")
    let request = try TextAdvisor.request(endpoint: endpoint, key: "fixture",
                                         messages: [.init(role: "user", content: "Check the queue")], timeout: 2)
    #expect(request.url == endpoint.url)
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
    let payload = try #require(request.httpBody)
    #expect(String(decoding: payload, as: UTF8.self).contains("Check the queue"))
}
