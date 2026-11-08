import Foundation
import UserNotifications

struct WorkshopPreferences: Codable, Equatable, Sendable {
    var notifications = false
    var morningCheck = false
    var morningHour = 9
    var appearance: String?

    func checkIsDue(now: Date, last: Date?, calendar: Calendar = .current) -> Bool {
        guard morningCheck, (0...23).contains(morningHour), calendar.component(.hour, from: now) >= morningHour else { return false }
        return last.map { $0 < calendar.startOfDay(for: now) } ?? true
    }
}

struct PreferencesBackup: Codable {
    let schema: String
    let created: Date
    let arabic: Bool
    let advisorMode: AdvisorMode
    let advisorRounds: Int
    let advisorMinutes: Int
    let policy: DelegationPolicy
    let morningCheck: Bool
    let morningHour: Int
    let workerModels: [String: String]?
    let appearance: String?

    init(state: WorkshopState, now: Date = Date()) {
        schema = "fawaly.preferences.v1"; created = now; arabic = state.arabic
        advisorMode = state.advisors.mode; advisorRounds = state.advisors.maxRounds; advisorMinutes = state.advisors.timeoutMinutes
        policy = state.delegationPolicy ?? DelegationPolicy()
        workerModels = state.workerModels
        appearance = state.preferences?.appearance
        morningCheck = state.preferences?.morningCheck ?? false; morningHour = state.preferences?.morningHour ?? 9
    }
    static func read(_ file: URL) throws -> Self {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 65_537) ?? Data()
        guard data.count <= 65_536 else { throw FawalyError.invalid("The settings file is too large.") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schema == "fawaly.preferences.v1", AdvisorSettings.rounds.contains(value.advisorRounds),
              AdvisorSettings.minutes.contains(value.advisorMinutes), (0...23).contains(value.morningHour),
              (1...3600).contains(value.policy.timeoutSeconds) else { throw FawalyError.invalid("The settings backup is invalid or uses a newer format.") }
        guard value.appearance.map({ ["light", "dark"].contains($0) }) ?? true else { throw FawalyError.invalid("Invalid workshop appearance.") }
        guard value.workerModels?.allSatisfy({ EngineAgent(rawValue: $0.key) != nil && OfficialModels.valid($0.value) }) ?? true else { throw FawalyError.invalid("Invalid assistant model preferences.") }
        return value
    }
    func write(to file: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: file, options: .atomic)
    }
}

enum WorkshopNotifications {
    static func authorize() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    /// Confirm delivery through the public OS API. Focus settings can still hide a banner.
    static func sendTest(arabic: Bool) async throws -> Bool {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = arabic ? "الفواعلي" : WorkshopCopy.englishName
        content.body = arabic ? "تنبيه تجريبي — تنبيهات الورشة جاهزة." : "Test notification — your workshop notifications are ready."
        content.sound = .default
        let identifier = "fawaly-test-" + UUID().uuidString
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        for _ in 0..<20 {
            if await center.deliveredNotifications().contains(where: { $0.request.identifier == identifier }) { return true }
            try await Task.sleep(for: .milliseconds(250))
        }
        return false
    }
    static func completed(agent: EngineAgent, needsReview: Bool, failed: Bool = false, arabic: Bool) async {
        let content = UNMutableNotificationContent()
        content.title = arabic ? "الفواعلي" : WorkshopCopy.englishName
        content.sound = .default
        // Keep task text and source paths out of lock-screen notifications.
        content.body = failed ? agent.label + (arabic ? " اتوقفت مهمته — افتح الورشة للتفاصيل." : " task stopped — open Sudo Interns for details.") : agent.label + (arabic ? (needsReview ? " خلص — افتح الورشة للمراجعة." : " خلص المهمة. افتح الورشة للنتيجة.") : (needsReview ? " finished — open Sudo Interns to review." : " finished — open Sudo Interns for the result."))
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
