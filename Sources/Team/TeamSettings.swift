import Foundation

struct TeamSettings: Codable, Equatable, Sendable {
    var primary = EngineAgent.codex
    var advisor: EngineAgent? = .claude
    var workers: [EngineAgent] = []

    var supporters: [EngineAgent] {
        EngineAgent.allCases.filter { $0 == advisor || workers.contains($0) }
    }

    func validate() throws {
        guard EngineAgent.primaryAgents.contains(primary), advisor != primary, !workers.contains(primary),
              advisor.map({ !workers.contains($0) }) ?? true,
              Set(workers).count == workers.count else {
            throw FawalyError.invalid("Choose a different agent for each team role.")
        }
    }

    mutating func choosePrimary(_ agent: EngineAgent) {
        primary = agent
        workers.removeAll { $0 == agent }
        if advisor == agent { advisor = EngineAgent.allCases.first { $0 != agent } }
        workers.removeAll { $0 == advisor }
    }
}
