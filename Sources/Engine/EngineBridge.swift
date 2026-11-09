import Darwin
import Foundation
import os

struct EngineBridge: Sendable {
    let configuration: EngineConfiguration
    let client: EngineAgent?
    private let worker: @Sendable (EngineAgent, String, URL?, Int) async throws -> String
    private let ready: @Sendable (EngineAgent) -> Bool
    /// Whether this engine session has tried to consult the advisor. Every copy of
    /// the bridge shares it.
    private let consulted = OSAllocatedUnfairLock(initialState: false)

    init(configuration: EngineConfiguration, client: EngineAgent?,
         worker: (@Sendable (EngineAgent, String, URL?, Int) async throws -> String)? = nil,
         ready: (@Sendable (EngineAgent) -> Bool)? = nil) {
        self.configuration = configuration
        self.client = client
        self.worker = worker ?? { agent, prompt, directory, timeout in
            try await AgentWorker(configuration: configuration).run(agent, prompt: prompt, workspace: directory, timeout: timeout)
        }
        self.ready = ready ?? { configuration.isReady($0) }
    }

    struct Result: Encodable {
        let status: String
        let provider: String
        let model: String
        let finalMessage: String
        let reviewRequired: Bool
        let changedFiles: [String]?
        let schema = "delegate-relay.result.v1"
        var jobId = UUID()
        var billing = "subscription"
    }

    struct Status: Encodable {
        struct Availability: Encodable {
            let provider: String
            let status: String
            let workerModel: String?
            var billing = "subscription"
        }
        let providers: [String: Availability]
        let advisor: AdvisorSettings
        let team: TeamSettings?
        let delegation: DelegationPolicy
        let projectDirectory: String?
        let active: [String]
        let language: String
        let schema = "delegate-relay.availability.v1"
        let version = "rebuilt-0.7.1"
    }

    func status() throws -> Status {
        let state = try WorkshopStore(root: configuration.root).load()
        let providers = try Dictionary(uniqueKeysWithValues: EngineAgent.allCases.map { agent in
            let configured = agent.isNative ? nil : try APIAssistantStore(root: configuration.root).load(agent)
            let available = ready(agent)
            let status = available ? (try hasCapacity(agent) ? (configuration.isWorking(agent) ? "busy" : "available") : "local_limit_reached") : configured?.enabled == false ? "paused" : "authentication_required"
            return (agent.providerID, Status.Availability(provider: agent.providerID, status: status, workerModel: state.workerModels?[agent.rawValue] ?? configured?.model, billing: agent.billingLabel))
        })
        var advisor = state.advisors
        if let team = state.team {
            // Manual preview seats are separate from the advisor a native
            // primary actually calls. Project that effective assignment only.
            advisor.seats = team.advisor.map { agent in
                [AdvisorSeat(provider: agent.providerID,
                             model: providers[agent.providerID]?.workerModel ?? agent.modelLabel,
                             enabled: ready(agent))]
            } ?? []
        }
        return Status(providers: providers, advisor: advisor, team: state.team, delegation: state.delegationPolicy ?? DelegationPolicy(), projectDirectory: state.projectDirectory?.path,
                      active: try TeamJobLog(root: configuration.root).recent().filter { $0.status == "running" }.map { $0.id.uuidString }, language: state.arabic ? "ar" : "en")
    }

    func delegate(brief: String, cwd: String?, provider: String?, timeout: Int?, kind: String? = nil, title: String? = nil) async throws -> Result {
        let state = try WorkshopStore(root: configuration.root).load()
        try requireConsultation(state, editsProject: cwd != nil)
        let policy = state.delegationPolicy ?? DelegationPolicy()
        let effectiveTimeout = timeout ?? policy.timeoutSeconds
        guard (1...3600).contains(effectiveTimeout) else { throw FawalyError.invalid("Invalid worker timeout.") }
        let agent = try select(provider, kind: kind)
        let workspace = try cwd.map(configuration.approvedWorkspace)
        let log = TeamJobLog(root: configuration.root)
        let shortTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard shortTitle.map({ $0.utf8.count <= 240 && !$0.contains(where: \.isNewline) }) ?? true else { throw FawalyError.invalid("Use a short, single-line task title.") }
        var job = TeamJob(primary: client, worker: agent, title: shortTitle.flatMap { $0.isEmpty ? nil : $0 } ?? String(brief.prefix(180)))
        let selectedModel = try state.workerModels?[agent.rawValue] ?? (agent.isNative ? nil : APIAssistantStore(root: configuration.root).load(agent)?.model)
        try log.save(job)
        let stopFile = configuration.stopFile(job.id)
        defer { try? FileManager.default.removeItem(at: stopFile) }
        let result: Result
        do {
            let answer = try await WorkerContext.$modelPreference.withValue(WorkerModelPreference(agent: agent, model: selectedModel)) {
                try await WorkerContext.$stopFile.withValue(stopFile) {
                    try await worker(agent, brief, workspace, effectiveTimeout)
                }
            }
            result = Result(status: workspace == nil ? "completed" : "needs_handoff",
                            provider: agent.providerID, model: selectedModel ?? agent.modelLabel, finalMessage: answer,
                            reviewRequired: workspace != nil, changedFiles: workspace == nil ? [] : nil, jobId: job.id, billing: agent.billingLabel)
        } catch is WorkerStopped {
            job.status = workspace == nil ? "cancelled" : "needs_handoff"
            job.finished = Date()
            job.result = "Stopped by the user. Review any partial changes before continuing."
            job.reviewRequired = workspace != nil
            try log.save(job)
            return Result(status: job.status, provider: agent.providerID, model: selectedModel ?? agent.modelLabel,
                          finalMessage: job.result!, reviewRequired: job.reviewRequired, changedFiles: nil, jobId: job.id, billing: agent.billingLabel)
        } catch is CancellationError {
            job.status = workspace == nil ? "cancelled" : "needs_handoff"
            job.reviewRequired = workspace != nil
            job.result = "Request stopped. Review any partial workspace changes."
            job.finished = Date()
            try log.save(job)
            throw CancellationError()
        } catch {
            job.status = workspace == nil ? "failed" : "needs_handoff"
            job.finished = Date()
            job.result = error.localizedDescription
            job.reviewRequired = workspace != nil
            try log.save(job)
            guard workspace != nil else { throw error }
            return Result(status: "needs_handoff", provider: agent.providerID, model: selectedModel ?? agent.modelLabel,
                          finalMessage: error.localizedDescription + " Review the workspace for partial edits.",
                          reviewRequired: true, changedFiles: nil, jobId: job.id, billing: agent.billingLabel)
        }
        job.status = result.status
        job.finished = Date()
        job.result = result.finalMessage
        job.reviewRequired = result.reviewRequired
        try log.save(job)
        return result
    }

    func consult(question: String, context: String, reason: ConsultReason, provider: String?, continuing id: UUID? = nil) async throws -> ConsultRecord {
        try TextAdvisor.validate(question: question, context: context)
        guard let client else { throw FawalyError.invalid("Set the MCP client with --client codex or --client claude.") }
        let state = try WorkshopStore(root: configuration.root).load()
        let settings = state.advisors
        let log = ConsultLog(root: configuration.root)
        let started = Date()
        try log.expireOpen(now: started)
        let previous: ConsultRecord?
        if let id {
            guard let record = try log.get(id), record.caller == client.caller, record.status == .open,
                  record.rounds.count < settings.maxRounds,
                  provider.map({ EngineAgent(provider: $0)?.providerID == record.provider }) ?? true else {
                throw FawalyError.invalid("This consultation is unavailable for another round.")
            }
            previous = record
        } else {
            previous = nil
        }
        let effectiveReason = previous?.reason ?? reason
        guard settings.mode != .off, settings.mode == .important || effectiveReason == .userRequest else {
            throw FawalyError.invalid("The current advisor mode does not allow this request.")
        }
        consulted.withLock { $0 = true }
        let agent = try select(previous?.provider ?? provider, consultation: true)
        let prompt = Self.consultationPrompt(question: question, context: context, previous: previous?.rounds ?? [])
        let configuredModel = try state.workerModels?[agent.rawValue] ?? (agent.isNative ? nil : APIAssistantStore(root: configuration.root).load(agent)?.model)
        let selectedModel = previous?.modelPinned == true ? previous?.requestedModel : configuredModel
        let answer = try await WorkerContext.$modelPreference.withValue(WorkerModelPreference(agent: agent, model: selectedModel)) {
            try await worker(agent, prompt, nil, settings.timeoutMinutes * 60)
        }
        let finished = Date()
        var record = previous ?? ConsultRecord(caller: client.caller, reason: reason, provider: agent.providerID,
            model: selectedModel ?? agent.modelLabel, modeAtStart: settings.mode, question: question, context: context, rounds: [], created: started)
        record.model = selectedModel ?? agent.modelLabel
        record.requestedModel = selectedModel
        record.modelPinned = true
        record.rounds.append(ConsultRound(index: record.rounds.count + 1, prompt: question, advice: answer,
                                         status: "completed", startedAt: started, finishedAt: finished))
        record.updated = finished
        if let previous { try log.update(record, replacing: previous) } else { try log.insert(record) }
        return record
    }
    
    func decide(id: UUID, decision: ConsultDecision, summary: String) throws -> ConsultRecord {
        let log = ConsultLog(root: configuration.root)
        try log.expireOpen(now: Date())
        guard let client, let previous = try log.get(id), previous.caller == client.caller,
              previous.status == .open, summary.utf8.count <= 2_048 else {
            throw FawalyError.invalid("Choose an open consultation and a summary of at most 2 KB.")
        }
        var record = previous
        record.status = .closed
        record.decision = decision
        record.summary = summary
        record.updated = Date()
        try log.update(record, replacing: previous)
        return record
    }

    func review(id: UUID, decision: TeamReview.Decision, summary: String, verification: String, score: Int?) throws -> TeamJob {
        guard let client, try WorkshopStore(root: configuration.root).load().team?.primary == client else {
            throw FawalyError.invalid("Only the configured primary can record a worker review.")
        }
        return try TeamJobLog(root: configuration.root).recordReview(id: id,
            review: TeamReview(decision: decision, primary: client, summary: summary, verification: verification, score: score))
    }
    
    static func consultationPrompt(question: String, context: String, previous: [ConsultRound]) -> String {
        var parts = ["Give an independent, text-only second opinion. Identify risks and a concrete verification step. Use only the supplied text."]
        parts += previous.map { "Prior question:\n\($0.prompt)\nPrior advice:\n\($0.advice)" }
        parts.append("Question:\n" + question)
        if !context.isEmpty { parts.append("Context supplied by the caller:\n" + context) }
        var text = parts.joined(separator: "\n\n")
        if text.utf8.count > 120 * 1_024 {
            // Keep the current question and context. Previous rounds remain in the consultation log.
            text = ([parts[0], "Question:\n" + question] + (context.isEmpty ? [] : ["Context supplied by the caller:\n" + context]))
                .joined(separator: "\n\n")
        }
        return text
    }

    /// A model can skip a step of its instructions, so the user's advisor policy is
    /// enforced here. One attempt per session is enough, because an advisor that is
    /// busy or failing must not block the work.
    private func requireConsultation(_ state: WorkshopState, editsProject: Bool) throws {
        let required = editsProject && state.advisors.mode == .important && state.team?.advisor != nil
        if required && !consulted.withLock({ $0 }) {
            throw FawalyError.invalid("The user's advisor policy requires a consultation before project work. Call consult with your proposed plan, record your decision with consult_decide, then delegate again.")
        }
    }

    private func select(_ pinned: String?, consultation: Bool = false, kind: String? = nil) throws -> EngineAgent {
        if let team = try WorkshopStore(root: configuration.root).load().team {
            try team.validate()
            guard client == team.primary else { throw FawalyError.invalid("Open this team from its configured primary agent.") }
            let policy = try WorkshopStore(root: configuration.root).load().delegationPolicy ?? DelegationPolicy()
            let allowed = consultation ? team.advisor.map { [$0] } ?? [] : policy.workers(kind: kind, team: team)
            let candidate: EngineAgent?
            if let pinned { candidate = EngineAgent(provider: pinned) }
            else { candidate = try allowed.first(where: { try ready($0) && !configuration.isWorking($0) && hasCapacity($0) }) }
            if pinned == nil, candidate == nil, allowed.contains(where: ready) {
                if try allowed.contains(where: { try ready($0) && !hasCapacity($0) }) { throw FawalyError.invalid("Assigned workers reached their local daily request cap. Adjust it in Fawaly or wait for the next UTC day.") }
                throw FawalyError.invalid(consultation ? "Your advisor is busy. Retry when its current task finishes." : "Your assigned workers are busy. Retry after a current task finishes.")
            }
            guard let candidate, allowed.contains(candidate) else {
                throw FawalyError.invalid(consultation ? "Choose a connected advisor in Fawaly team setup." : "Choose a worker in Fawaly team setup before delegating.")
            }
            guard ready(candidate) else { throw FawalyError.invalid(candidate.label + " is not connected to Fawaly.") }
            guard try hasCapacity(candidate) else { throw FawalyError.invalid("This assistant reached its local daily request cap. No provider request was sent.") }
            return candidate
        }
        if let pinned {
            guard let agent = EngineAgent(provider: pinned) else {
                throw FawalyError.invalid("Choose a connected provider from the Fawaly team roster.")
            }
            guard agent != client else { throw FawalyError.invalid("Choose the other CLI as the worker to avoid recursion.") }
            guard ready(agent) else { throw FawalyError.invalid(agent.label + " is not connected to Fawaly.") }
            return agent
        }
        guard let agent = EngineAgent.nativeAgents.first(where: { $0 != client && ready($0) }) else {
            throw FawalyError.invalid("Connect the other CLI in Fawaly Services before delegating.")
        }
        return agent
    }

    private func hasCapacity(_ agent: EngineAgent) throws -> Bool {
        guard !agent.isNative, let profile = try APIAssistantStore(root: configuration.root).load(agent) else { return true }
        return try APIUsage(root: configuration.root).totals(agent).requests < profile.dailyRequestLimit
    }
}
