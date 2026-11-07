import Foundation

public struct ConsultRequest: Sendable {
    public var by: Rater
    public var reason: ConsultReason
    /// The question for round 1, or the usta's follow-up for later rounds.
    public var question: String
    public var context: String?
    public var repo: URL?
    public var advisor: String?
    public var consultId: UUID?
    public var allowMetered: Bool
    public init(by: Rater, reason: ConsultReason, question: String, context: String?, repo: URL?, advisor: String?, consultId: UUID?, allowMetered: Bool) {
        self.by = by; self.reason = reason; self.question = question; self.context = context; self.repo = repo; self.advisor = advisor; self.consultId = consultId; self.allowMetered = allowMetered
    }
}

public struct ConsultResponse: Codable, Equatable, Sendable {
    public var consultId: UUID
    public var round: Int
    public var maxRounds: Int
    public var provider: String
    public var model: String
    public var advice: String
    public var truncated: Bool
    public var status: String
}

/// Runs bounded, read-only consultation rounds. Each round replays the whole transcript; no CLI session state.
public struct Advisor: Sendable {
    public static let questionLimit = 16 * 1024, contextLimit = 64 * 1024, summaryLimit = 2 * 1024
    public var root: URL
    public var runtime: any Runtime
    public var resolver: CredentialResolver
    public var clock: any Clock
    public var environment: [String: String]
    public init(root: URL = Paths.root(), runtime: any Runtime = NativeRuntime(), resolver: CredentialResolver = CredentialResolver(), clock: any Clock = SystemClock(), environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.root = root; self.runtime = runtime; self.resolver = resolver; self.clock = clock; self.environment = environment
    }

    public func consult(_ request: ConsultRequest) async throws -> ConsultResponse {
        guard environment["DELEGATE_WORKER_DEPTH"]?.isEmpty != false else { throw AdvisorError.recursive }
        guard request.by != .human else { throw AdvisorError.invalid("by must be claude or codex") }
        guard !request.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, request.question.utf8.count <= Self.questionLimit else { throw AdvisorError.invalid("question must be 1 byte to 16 KB") }
        guard (request.context?.utf8.count ?? 0) <= Self.contextLimit else { throw AdvisorError.invalid("context must be at most 64 KB") }
        let roster = try await RosterStore(root: root).load(), settings = roster.advisors, log = ConsultLog(root: root), now = clock.now()
        try log.expireOpen(now: now)
        let availability = try await AvailabilityStore(root: root).read()

        guard let id = request.consultId else {
            try AdvisorPolicy.check(mode: settings.mode, reason: request.reason)
            let candidates = try AdvisorSelection.candidates(roster: roster, availability: availability, caller: request.by, pinned: request.advisor, allowMetered: request.allowMetered, now: now, resolver: resolver)
            let consultId = UUID()
            var reasons: [String] = []
            for (index, candidate) in candidates.enumerated() {
                let (round, problem) = try await run(candidate, consultId: consultId, index: 1, prompt: request.question, brief: Self.brief(question: request.question, context: request.context, rounds: [], followUp: request.question), repo: request.repo, settings: settings)
                // Only the first round may move to the next seat, and only for availability problems.
                if let problem, round.status == "failed", Self.fallsThrough(problem.kind) {
                    reasons.append(Self.reason(candidate, problem.kind)); if index < candidates.count - 1 { continue }
                    throw AdvisorError.noAdvisorAvailable(reasons)
                }
                var record = ConsultRecord(id: consultId, caller: request.by, reason: request.reason, provider: candidate.entry.provider, model: candidate.entry.model, modeAtStart: settings.mode, question: request.question, context: request.context, rounds: [round], created: now)
                record.updated = clock.now(); try log.insert(record)
                return response(record, round, settings)
            }
            throw AdvisorError.noAdvisorAvailable(reasons)
        }

        let lock: FileLock
        do { lock = try await FileLock.acquire(root: root, name: "consult-" + id.uuidString) } catch { throw AdvisorError.invalid("Another round of this consultation is still running.") }
        defer { lock.release() }
        guard var record = try log.get(id) else { throw AdvisorError.unknownConsultation }
        guard record.status == .open else { throw AdvisorError.consultationClosed }
        guard record.caller == request.by else { throw AdvisorError.mismatch("caller") }
        if let pinned = request.advisor, pinned != record.provider { throw AdvisorError.mismatch("advisor") }
        try AdvisorPolicy.check(mode: settings.mode, reason: record.reason)
        guard record.rounds.count < settings.maxRounds else { throw AdvisorError.roundLimit(settings.maxRounds) }
        let candidate: RouteCandidate
        do {
            candidate = try AdvisorSelection.candidates(roster: roster, availability: [:], caller: request.by, pinned: record.provider, allowMetered: request.allowMetered, now: now, resolver: resolver)[0]
        } catch let error as AdvisorError { throw AdvisorError.advisorUnavailable(error.description) }
        var seat = candidate; seat.entry.model = record.model
        let index = record.rounds.count + 1
        let (round, _) = try await run(seat, consultId: id, index: index, prompt: request.question, brief: Self.brief(question: record.question, context: request.context, rounds: record.rounds, followUp: request.question), repo: request.repo, settings: settings)
        record.rounds.append(round); record.updated = clock.now(); try log.update(record)
        return response(record, round, settings)
    }

    public func decide(id: UUID, by: Rater, decision: ConsultDecision, summary: String) throws -> ConsultRecord {
        guard summary.utf8.count <= Self.summaryLimit else { throw AdvisorError.invalid("summary must be at most 2 KB") }
        let log = ConsultLog(root: root)
        try log.expireOpen(now: clock.now())
        guard var record = try log.get(id) else { throw AdvisorError.unknownConsultation }
        guard record.status == .open else { throw AdvisorError.consultationClosed }
        guard record.caller == by else { throw AdvisorError.mismatch("caller") }
        record.status = .closed; record.decision = decision; record.summary = summary; record.updated = clock.now()
        try log.update(record); return record
    }

    static func brief(question: String, context: String?, rounds: [ConsultRound], followUp: String) -> String {
        var parts = ["Question from the usta:\n" + question]
        if let context, !context.isEmpty { parts.append("Context shared by the usta:\n" + context) }
        for round in rounds {
            if round.index > 1 { parts.append("Follow-up \(round.index):\n" + round.prompt) }
            parts.append("Advice \(round.index):\n" + (round.advice.isEmpty ? "(no advice — round \(round.status))" : round.advice))
        }
        if !rounds.isEmpty { parts.append("Follow-up \(rounds.count + 1):\n" + followUp) }
        return parts.joined(separator: "\n\n")
    }
    static func fallsThrough(_ kind: ProblemKind) -> Bool {
        [.authentication, .quotaExhausted, .subscriptionExpired, .temporaryRateLimit, .networkOrServer, .unavailable, .resourceUnavailable, .modelUnavailable].contains(kind)
    }
    static func reason(_ candidate: RouteCandidate, _ kind: ProblemKind) -> String {
        if kind == .authentication, let client = candidate.template.runtime.officialClient { return "\(candidate.entry.provider): Sign in to \(client == .claude ? "Claude Code" : "Codex") for Fawaly" }
        return "\(candidate.entry.provider): \(kind.rawValue)"
    }

    private func response(_ record: ConsultRecord, _ round: ConsultRound, _ settings: AdvisorSettings) -> ConsultResponse {
        ConsultResponse(consultId: record.id, round: round.index, maxRounds: settings.maxRounds, provider: record.provider, model: record.model, advice: round.advice, truncated: round.truncated, status: round.status)
    }

    private func run(_ candidate: RouteCandidate, consultId: UUID, index: Int, prompt: String, brief: String, repo: URL?, settings: AdvisorSettings) async throws -> (ConsultRound, Problem?) {
        let started = clock.now(), jobId = UUID().uuidString
        // Like worker jobs, round files live outside the state root, which the sandbox denies entirely.
        let artifact = FileManager.default.temporaryDirectory.appendingPathComponent("fawaly-consults/\(consultId.uuidString)/round-\(index)-\(jobId)", isDirectory: true)
        try Paths.ensurePrivateDirectory(artifact)
        let workdir: URL
        if let repo { workdir = Paths.canonical(repo) } else { workdir = artifact.appendingPathComponent("empty", isDirectory: true); try Paths.ensurePrivateDirectory(workdir) }
        var request = WorkerRequest(providerID: candidate.entry.provider, template: candidate.template, config: candidate.config, model: candidate.entry.model, effort: candidate.entry.effort, brief: brief, workdir: workdir, addDirs: [], artifactDir: artifact, key: candidate.key, timeout: TimeInterval(settings.timeoutMinutes * 60), parentEnv: environment)
        request.advisor = true; request.stateRoot = root; request.jobTag = jobId
        let live = ActiveJobWriter(root: root, job: ActiveJob(jobId: jobId, provider: candidate.entry.provider, model: candidate.entry.model, lane: "advisor", kind: .general, startedAt: started), workdir: workdir, clock: clock)
        try await live.start()
        let stop = StopSignal(); request.stop = stop
        request.onEvent = { Task { await live.event() } }
        let watcher = Task {
            while !Task.isCancelled {
                if FileManager.default.fileExists(atPath: StopRequest.file(root: root, jobId: jobId).path) { stop.set(); await live.phase(.stopping); return }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        defer { watcher.cancel(); Task { await live.finish() } }
        let outcome = try await runtime.run(request, onStart: { _ in })
        if outcome.error.map({ ProblemKind(rawValue: $0.layers.first?["kind"]?.string ?? "") == .sandboxUnavailable }) == true || outcome.status == "delegation_unavailable" {
            throw AdvisorError.invalid("The advisor sandbox is unavailable on this Mac, so the consultation was refused (sandbox_unavailable).")
        }
        let problem = outcome.success ? nil : Classifier.classify(provider: candidate.entry.provider, family: candidate.template.family, error: outcome.error ?? ProviderError(["code": .string("unknown_worker_failure")]), now: clock.now())
        let status = outcome.success ? "completed" : stop.isSet || outcome.status == "aborted" ? "stopped" : outcome.status == "timeout" || problem?.kind == .timeout ? "timeout" : "failed"
        // A stopped or timed-out round says nothing about the service's availability.
        let store = AvailabilityStore(root: root)
        if let problem, status == "failed", Self.fallsThrough(problem.kind) { try? await store.update(candidate.entry.provider, Schedule.record(for: problem, now: clock.now())) }
        else if problem == nil { try? await store.update(candidate.entry.provider, Schedule.available(now: clock.now())) }
        return (ConsultRound(index: index, prompt: prompt, advice: outcome.success ? outcome.finalMessage : "", status: status, startedAt: started, finishedAt: clock.now()), problem)
    }
}
