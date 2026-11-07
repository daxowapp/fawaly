import Foundation

struct DelegationPolicy: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable { case general, code, research, review }
    var timeoutSeconds = 900
    /// Only assigned workers may appear here. An empty order uses the saved team order.
    var orders: [String: [EngineAgent]] = [:]

    func validate(team: TeamSettings?) throws {
        guard (1...3600).contains(timeoutSeconds), orders.allSatisfy({ key, order in
            Kind(rawValue: key) != nil && Set(order).count == order.count && order.allSatisfy { team?.workers.contains($0) == true }
        }) else { throw FawalyError.invalid("Choose a timeout from 1 to 3600 seconds and an order of assigned workers.") }
    }

    func workers(kind: String?, team: TeamSettings) -> [EngineAgent] {
        let order = orders[kind ?? Kind.general.rawValue] ?? []
        return order.isEmpty ? team.workers : order.filter { team.workers.contains($0) }
    }
}
