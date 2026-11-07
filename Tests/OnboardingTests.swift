import Foundation
import Testing
@testable import FawalyApp

private func setupRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fawaly-setup-test-" + UUID().uuidString)
    try Paths.ensurePrivateDirectory(root.appendingPathComponent("runtimes"))
    for agent in EngineAgent.allCases {
        let file = root.appendingPathComponent("runtimes/" + agent.rawValue)
        try Data("fixture".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    }
    return root
}

private actor SetupFixture {
    var signedIn = Set<EngineAgent>()
    var failNext = false
    func failOnce() { failNext = true }
    func login(_ agent: EngineAgent) throws {
        if failNext { failNext = false; throw FawalyError.invalid("Fixture unavailable") }
        signedIn.insert(agent)
    }
    func connected(_ agent: EngineAgent) -> Bool { signedIn.contains(agent) }
    func logout(_ agent: EngineAgent) { signedIn.remove(agent) }
    nonisolated func dependencies(root: URL) -> SetupCoordinator.Dependencies {
        .init(executable: { agent in
            let file = root.appendingPathComponent("runtimes/" + agent.rawValue)
            return FileManager.default.isExecutableFile(atPath: file.path) ? file : nil
        }, install: { agent in
            let file = root.appendingPathComponent("runtimes/" + agent.rawValue)
            try Data("fixture".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            return file
        }, signIn: { agent, _, callback in
            callback(URL(string: "https://claude.ai/oauth/authorize?fixture=1")!)
            try await self.login(agent)
        }, verify: { await self.connected($0) }, signOut: { await self.logout($0) })
    }
}

@MainActor private func settle(_ setup: SetupCoordinator) async throws {
    let deadline = Date().addingTimeInterval(5)
    while setup.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!setup.busy)
}

@Test @MainActor func onboardingPreparesConnectsRetriesAndSignsOut() async throws {
    let root = try setupRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.removeItem(at: root.appendingPathComponent("runtimes/claude"))
    let fixture = SetupFixture()
    let setup = SetupCoordinator(dependencies: fixture.dependencies(root: root))
    #expect(setup.step == .welcome)
    #expect(setup.phases[.claude] == .missing)
    setup.prepare()
    try await settle(setup)
    #expect(setup.step == .accounts)
    #expect(setup.connected.isEmpty)
    #expect(setup.phases[.claude] == .available)
    await fixture.failOnce()
    setup.connect(.claude)
    try await settle(setup)
    #expect(setup.phases[.claude] == .failed("Fixture unavailable"))
    setup.connect(.claude)
    try await settle(setup)
    #expect(setup.connected == [.claude])
    setup.selected = [.codex]
    #expect(setup.selectedConnected.isEmpty)
    setup.disconnect(.claude)
    try await settle(setup)
    #expect(setup.connected.isEmpty)
    #expect(setup.browserURL == nil)
}

@Test @MainActor func onboardingCancellationReturnsToRetryableState() async throws {
    let root = try setupRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var dependencies = SetupFixture().dependencies(root: root)
    dependencies.signIn = { _, _, _ in try await Task.sleep(for: .seconds(20)) }
    let setup = SetupCoordinator(dependencies: dependencies)
    setup.connect(.codex)
    #expect(setup.busy)
    setup.connect(.claude)
    #expect(setup.activeAgent == .codex)
    setup.cancel()
    try await settle(setup)
    #expect(setup.phases[.codex] == .available)
    #expect(setup.activeAgent == nil)
    #expect(setup.browserURL == nil)
}

@Test @MainActor func onboardingRequiresVerificationAndPersistsExplicitPreviewChoice() async throws {
    let root = try setupRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = SetupFixture()
    let model = AppModel(root: root, setupDependencies: fixture.dependencies(root: root))
    #expect(model.showOnboarding)
    model.finishOnboarding(previewOnly: false)
    #expect(model.showOnboarding)
    model.finishOnboarding(previewOnly: true)
    #expect(!model.showOnboarding)
    let restored = AppModel(root: root, setupDependencies: fixture.dependencies(root: root))
    #expect(!restored.showOnboarding)
    restored.restartOnboarding()
    #expect(restored.showOnboarding)
}

@Test func workshopBeforeOnboardingVersionStillDecodes() throws {
    let state = WorkshopState()
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
    object.removeValue(forKey: "onboardingVersion")
    let restored = try JSONDecoder().decode(WorkshopState.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(restored.onboardingVersion == nil)
    #expect(restored == state)
}

@Test func nativeSignInUsesIsolatedFoldersAndVerifiedStatus() async throws {
    let root = try setupRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let config = EngineConfiguration(root: root)
    let service = NativeSignIn(configuration: config, execute: { command, _, _ in
        if command.arguments.contains("--json") { return LoginReply(exitCode: 0, output: "{\"loggedIn\":true}", errorOutput: "Diagnostic on stderr") }
        return LoginReply(exitCode: 0, output: "", errorOutput: "Logged in using ChatGPT")
    })
    for agent in EngineAgent.primaryAgents {
        let command = try service.command(agent, login: true)
        #expect(command.directory == config.nativeAuthDirectory(agent))
        #expect(command.environment["ANTHROPIC_API_KEY"] == nil)
        #expect(command.environment["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        #expect(command.environment[agent == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"] == command.directory.path)
        #expect(try await service.verify(agent))
        #expect(config.hasNativeSignIn(agent))
    }
    let invocation = try AgentWorker.invocation(.claude, executable: URL(fileURLWithPath: "/usr/bin/true"), directory: root, workspace: nil,
                                              codexHome: config.codexHome, token: nil, claudeHome: config.nativeAuthDirectory(.claude))
    #expect(invocation.environment["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
    #expect(invocation.environment["CLAUDE_CONFIG_DIR"] == config.nativeAuthDirectory(.claude).path)
}

@Test func nativeSignInRejectsUnconfirmedOrFailedLogin() async throws {
    let root = try setupRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let config = EngineConfiguration(root: root)
    try config.recordNativeSignIn(.claude, connected: true)
    let service = NativeSignIn(configuration: config, execute: { _, _, _ in LoginReply(exitCode: 0, output: "{\"loggedIn\":false}") })
    #expect(try await !service.verify(.claude))
    #expect(!config.hasNativeSignIn(.claude))
    await #expect(throws: FawalyError.self) { try await service.signIn(.claude, onURL: { _ in }) }
}

@Test func browserSignInURLsRequireOfficialHTTPSHosts() {
    let text = "https://auth.openai.com/oauth/authorize?state=fixture https://claude.ai/oauth/authorize https://claude.ai.evil.test/oauth http://claude.ai/oauth https://user@claude.ai/oauth https://example.test https://chatgpt.com/"
    #expect(LoginProcess.browserURLs(in: text).map(\.host) == ["auth.openai.com", "claude.ai", "chatgpt.com"])
}

@Test func loginProcessSeparatesOutputAndStopsOnTimeout() async throws {
    let root = try setupRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let reply = try await LoginProcess.run(LoginCommand(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf 'out'; printf 'err' >&2"], environment: [:], directory: root), timeout: 3)
    #expect(reply.output == "out")
    #expect(reply.errorOutput == "err")
    await #expect(throws: FawalyError.self) {
        _ = try await LoginProcess.run(LoginCommand(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], environment: [:], directory: root), timeout: 0.1)
    }
}

@Test func downloadedRuntimeHashIsVerified() throws {
    let root = try setupRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("payload")
    try Data("abc".utf8).write(to: file)
    #expect(try RuntimeInstaller.sha256(file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

@Test func loginProcessFinishesAfterItsOutputStreamsCloseEarly() async throws {
    let root = try setupRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for _ in 0..<4 {
        let reply = try await LoginProcess.run(LoginCommand(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf out; printf err >&2; exec 1>&- 2>&-; /bin/sleep 0.05"], environment: [:], directory: root), timeout: 3)
        #expect(reply.exitCode == 0)
        #expect(reply.output == "out")
        #expect(reply.errorOutput == "err")
    }
}

@Test @MainActor func connectedSetupCompletesAndUnverifiedSignInCannotComplete() async throws {
    let root = try setupRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = SetupFixture()
    var dependencies = fixture.dependencies(root: root)
    dependencies.signIn = { _, _, _ in }
    let unverified = SetupCoordinator(dependencies: dependencies)
    unverified.connect(.codex)
    try await settle(unverified)
    #expect(unverified.connected.isEmpty)
    #expect(unverified.phases[.codex] == .failed("Sign-in has not been confirmed. Please retry."))

    let model = AppModel(root: root, setupDependencies: fixture.dependencies(root: root))
    model.setup.connect(.claude)
    try await settle(model.setup)
    model.setup.integrateTeam()
    try await settle(model.setup)
    model.finishOnboarding(previewOnly: false)
    #expect(!model.showOnboarding)
    #expect(model.state.onboardingVersion == 2)
    #expect(model.state.team == model.setup.team)
    #expect(model.state.advisors.mode == .important)
    let restored = AppModel(root: root, setupDependencies: fixture.dependencies(root: root))
    #expect(!restored.showOnboarding)
}

@Test @MainActor func editingTeamChecksExistingAccountsAndCanDiscardChanges() async throws {
    let root = try setupRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var state = WorkshopState()
    state.onboardingVersion = 2
    state.team = TeamSettings()
    state.advisors.mode = .important
    try WorkshopStore(root: root).save(state)
    let fixture = SetupFixture()
    try await fixture.login(.claude)
    let model = AppModel(root: root, setupDependencies: fixture.dependencies(root: root))
    model.editTeam()
    try await settle(model.setup)
    #expect(model.setup.teamReady)
    model.setup.team.choosePrimary(.claude)
    model.cancelTeamEdit()
    #expect(!model.showOnboarding)
    #expect(model.state.team?.primary == .codex)
    #expect(model.setup.team.primary == .codex)
    #expect(try WorkshopStore(root: root).load().team?.primary == .codex)
}

@Test func kimiLoginRequiresNativeSuccessAndAnIsolatedCredentialStore() async throws {
    let root = try setupRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = EngineConfiguration(root: root)
    try configuration.prepareAuthDirectory(.kimi)
    let authentication = configuration.nativeAuthDirectory(.kimi)
    try Paths.ensurePrivateDirectory(authentication.appendingPathComponent("credentials"))
    try Data("fixture".utf8).write(to: authentication.appendingPathComponent("credentials/fixture.json"))
    let service = NativeSignIn(configuration: configuration, execute: { command, _, _ in
        if command.arguments.first == "login" { return LoginReply(exitCode: 0, output: "", errorOutput: "Logged in to Kimi Code.") }
        return LoginReply(exitCode: 0, output: #"{"providers":{"kimi-code":{"oauth":{"storage":"file","key":"fixture"}}},"models":{}}"#)
    })
    #expect(try await !service.verify(.kimi))
    let command = try service.command(.kimi, login: true, region: .global)
    #expect(command.arguments == ["login", "--region", "global"])
    #expect(command.environment["KIMI_CODE_HOME"] == authentication.path)
    #expect(command.environment["KIMI_API_KEY"] == nil)
    try await service.signIn(.kimi, region: .global, onURL: { _ in })
    #expect(configuration.isReady(.kimi))
    try await service.signOut(.kimi)
    #expect(!configuration.isReady(.kimi))
    #expect(!KimiWorker.hasCredentials(authentication))
}

@Test func kimiVerificationURLsStayOnOfficialHosts() {
    let urls = LoginProcess.browserURLs(in: "https://auth.kimi.com/device?user_code=fixture https://www.kimi.ai/device https://auth.kimi.ai.evil.test/device http://auth.kimi.com/device")
    #expect(urls.map(\.host) == ["auth.kimi.com", "www.kimi.ai"])
}
