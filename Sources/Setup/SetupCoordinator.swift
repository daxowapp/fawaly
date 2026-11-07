import Foundation

@MainActor
final class SetupCoordinator: ObservableObject {
    enum Step: Int, CaseIterable { case welcome, team, prepare, accounts, finish }
    enum Phase: Equatable {
        case missing, available, preparing, signingIn, verifying, connected
        case failed(String)
    }

    struct Dependencies: Sendable {
        var executable: @Sendable (EngineAgent) -> URL?
        var install: @Sendable (EngineAgent) async throws -> URL
        var signIn: @Sendable (EngineAgent, KimiRegion, @escaping @Sendable (URL) -> Void) async throws -> Void
        var verify: @Sendable (EngineAgent) async throws -> Bool
        var signOut: @Sendable (EngineAgent) async throws -> Void
        var integrate: @Sendable (EngineAgent) async throws -> Void = { _ in }

        static func live(root: URL) -> Self {
            let service = NativeSignIn(configuration: EngineConfiguration(root: root))
            return Self(executable: { $0.executable(root: root) },
                        install: { try await RuntimeInstaller(root: root).install($0) },
                        signIn: { try await service.signIn($0, region: $1, onURL: $2) },
                        verify: { try await service.verify($0) },
                        signOut: { try await service.signOut($0) },
                        integrate: { primary in
                            guard let executable = Bundle.main.executableURL else { throw FawalyError.invalid("The Fawaly application could not be located.") }
                            try await ClientLink(root: root, application: executable).connect(primary)
                        })
        }
    }

    @Published var step = Step.welcome
    @Published var editingTeam = false
    @Published var selected = Set(EngineAgent.allCases)
    @Published var team = TeamSettings()
    @Published var advisorMode = AdvisorMode.important
    @Published var kimiRegion = KimiRegion.global
    @Published private(set) var integrationReady = false
    @Published private(set) var integrationIssue: String?
    @Published private(set) var phases: [EngineAgent: Phase] = [:]
    @Published private(set) var activeAgent: EngineAgent?
    @Published private(set) var browserURL: URL?
    @Published private(set) var busy = false
    private let dependencies: Dependencies
    private var operation: Task<Void, Never>?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        scan()
    }

    var connected: [EngineAgent] { EngineAgent.allCases.filter { phases[$0] == .connected } }
    var teamReady: Bool { team.supporters.allSatisfy { phases[$0] == .connected } && dependencies.executable(team.primary) != nil }
    var selectedConnected: [EngineAgent] { connected.filter { selected.contains($0) } }

    func scan() {
        guard !busy else { return }
        for agent in EngineAgent.allCases {
            if dependencies.executable(agent) == nil { phases[agent] = .missing }
            else if phases[agent] != .connected { phases[agent] = .available }
        }
    }

    func prepare() {
        guard !busy, !selected.isEmpty else { return }
        begin()
        operation = Task { [weak self] in
            guard let self else { return }
            defer { finishOperation() }
            for agent in EngineAgent.allCases where selected.contains(agent) {
                activeAgent = agent
                do {
                    if dependencies.executable(agent) == nil {
                        phases[agent] = .preparing
                        _ = try await dependencies.install(agent)
                    }
                    try Task.checkCancellation()
                    guard dependencies.executable(agent) != nil else { throw FawalyError.invalid("The service could not be located after preparation.") }
                    phases[agent] = .verifying
                    phases[agent] = try await dependencies.verify(agent) ? .connected : .available
                } catch is CancellationError {
                    phases[agent] = .available
                    scanAfterCancellation()
                    return
                } catch {
                    phases[agent] = .failed(error.localizedDescription)
                    return
                }
            }
            step = .accounts
        }
    }

    func connect(_ agent: EngineAgent) {
        guard !busy, dependencies.executable(agent) != nil else { return }
        begin()
        activeAgent = agent
        phases[agent] = .signingIn
        operation = Task { [weak self] in
            guard let self else { return }
            defer { finishOperation() }
            do {
                try await dependencies.signIn(agent, kimiRegion) { [weak self] url in
                    Task { @MainActor in
                        guard let self, self.activeAgent == agent, self.busy else { return }
                        self.browserURL = url
                    }
                }
                phases[agent] = .verifying
                guard try await dependencies.verify(agent) else { throw FawalyError.invalid("Sign-in has not been confirmed. Please retry.") }
                try Task.checkCancellation()
                phases[agent] = .connected
            } catch is CancellationError {
                phases[agent] = .available
            } catch {
                phases[agent] = .failed(error.localizedDescription)
            }
        }
    }

    func verifyConnections() {
        guard !busy else { return }
        begin()
        operation = Task { [weak self] in
            guard let self else { return }
            defer { finishOperation() }
            for agent in EngineAgent.allCases where dependencies.executable(agent) != nil {
                activeAgent = agent
                phases[agent] = .verifying
                do { phases[agent] = try await dependencies.verify(agent) ? .connected : .available }
                catch is CancellationError { phases[agent] = .available; return }
                catch { phases[agent] = .failed(error.localizedDescription) }
            }
        }
    }

    func disconnect(_ agent: EngineAgent) {
        guard !busy else { return }
        begin()
        activeAgent = agent
        operation = Task { [weak self] in
            guard let self else { return }
            defer { finishOperation() }
            do { try await dependencies.signOut(agent); phases[agent] = .available }
            catch { phases[agent] = .failed(error.localizedDescription) }
        }
    }

    func resetIntegration() {
        guard !busy else { return }
        integrationReady = false
        integrationIssue = nil
    }

    func integrateTeam() {
        guard !busy, teamReady else { return }
        begin()
        integrationIssue = nil
        integrationReady = false
        operation = Task { [weak self] in
            guard let self else { return }
            defer { finishOperation() }
            do {
                try team.validate()
                try await dependencies.integrate(team.primary)
                integrationReady = true
            } catch is CancellationError { integrationIssue = "Connection cancelled. You can retry." }
            catch { integrationIssue = error.localizedDescription }
        }
    }

    func cancel() {
        operation?.cancel()
        browserURL = nil
    }

    private func begin() { busy = true; browserURL = nil }
    private func finishOperation() { busy = false; activeAgent = nil; operation = nil; browserURL = nil }
    private func scanAfterCancellation() {
        for agent in EngineAgent.allCases where phases[agent] != .connected {
            phases[agent] = dependencies.executable(agent) == nil ? .missing : .available
        }
    }
}
