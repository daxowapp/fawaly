import Foundation
import Darwin

struct ComparisonSession: Codable, Identifiable, Equatable, Sendable {
    struct Run: Codable, Equatable, Sendable {
        let agent: EngineAgent
        var status = "waiting"
        var succeeded: Bool?
        var answer: String?
        var started: Date?
        var finished: Date?
        var changedFiles: [String]?
    }
    let id: UUID
    let project: String
    let commit: String
    let brief: String
    var created = Date()
    var runs: [Run]
    var winner: EngineAgent?
    var review: String?

    func snapshot(root: URL, agent: EngineAgent) -> URL {
        root.appendingPathComponent("comparisons/" + id.uuidString + "/" + agent.rawValue + "/snapshot", isDirectory: true)
    }
}

struct ComparisonStore: Sendable {
    let root: URL
    func save(_ session: ComparisonSession) throws {
        let folder = root.appendingPathComponent("comparisons/" + session.id.uuidString)
        try Paths.ensurePrivateDirectory(folder)
        try JSONEncoder().encode(session).write(to: folder.appendingPathComponent("result.json"), options: .atomic)
    }
    func recent() throws -> [ComparisonSession] {
        let folder = root.appendingPathComponent("comparisons")
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .compactMap { directory in
                guard let data = try? Data(contentsOf: directory.appendingPathComponent("result.json")), data.count <= 1_048_576,
                      let item = try? JSONDecoder().decode(ComparisonSession.self, from: data), item.id.uuidString == directory.lastPathComponent else { return nil }
                return item
            }.sorted { $0.created > $1.created }
    }
    private func read(_ id: UUID) throws -> ComparisonSession? {
        let file = root.appendingPathComponent("comparisons/" + id.uuidString + "/result.json")
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw FawalyError.invalid("The comparison record is too large.") }
        let session = try JSONDecoder().decode(ComparisonSession.self, from: data)
        return session.id == id ? session : nil
    }

    func recoverInterrupted(beforeLock: (UUID) throws -> Void = { _ in }) throws {
        for candidate in try recent() where candidate.runs.contains(where: { $0.status == "running" || $0.status == "waiting" }) {
            try beforeLock(candidate.id)
            let lockURL = root.appendingPathComponent("comparisons/" + candidate.id.uuidString + "/owner.lock")
            let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { continue }
            // The previous owner may have finished after the discovery read.
            guard var session = try read(candidate.id), session.runs.contains(where: { $0.status == "running" || $0.status == "waiting" }) else { continue }
            for index in session.runs.indices {
                if session.runs[index].status == "running" {
                    session.runs[index].status = "needs_review"
                    session.runs[index].answer = "Interrupted. Review the saved snapshot for partial edits."
                    session.runs[index].succeeded = false
                    session.runs[index].finished = Date()
                } else if session.runs[index].status == "waiting" { session.runs[index].status = "cancelled" }
            }
            try save(session)
        }
    }

    func requestStop(_ id: UUID) throws {
        guard try recent().contains(where: { $0.id == id && $0.runs.contains(where: { $0.status == "running" || $0.status == "waiting" }) }) else {
            throw FawalyError.invalid("This comparison has already finished.")
        }
        try Data("stop".utf8).write(to: root.appendingPathComponent("comparisons/" + id.uuidString + "/stop"), options: .atomic)
    }

    func chooseWinner(id: UUID, agent: EngineAgent, note: String) throws {
        guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, note.utf8.count <= 4_096,
              var session = try recent().first(where: { $0.id == id }),
              session.runs.allSatisfy({ $0.status != "running" && $0.status != "waiting" }),
              session.runs.contains(where: { $0.agent == agent && $0.status == "needs_review" && $0.succeeded == true }) else {
            throw FawalyError.invalid("Choose a finished result and describe what you reviewed before choosing a winner.")
        }
        session.winner = agent
        session.review = note
        try save(session)
    }
}

struct ComparisonRunner: Sendable {
    let configuration: EngineConfiguration
    var execute: (@Sendable (EngineAgent, String, URL) async throws -> String)?

    func run(project: URL, agents: [EngineAgent], brief: String,
             progress: @escaping @Sendable (ComparisonSession) async -> Void) async throws -> ComparisonSession {
        guard !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, brief.utf8.count <= 30_720 else {
            throw FawalyError.invalid("Describe the comparison task in no more than 30 KB.")
        }
        let copies = try await ComparisonSnapshots(root: configuration.root).prepare(project: project, agents: agents)
        let owner = open(copies.directory.appendingPathComponent("owner.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard owner >= 0, flock(owner, LOCK_EX | LOCK_NB) == 0 else {
            if owner >= 0 { close(owner) }
            throw FawalyError.invalid("The comparison could not acquire its session lock.")
        }
        defer { close(owner) }
        var session = ComparisonSession(id: copies.id, project: project.path, commit: copies.commit, brief: brief, runs: agents.map { .init(agent: $0) })
        let store = ComparisonStore(root: configuration.root)
        try store.save(session)
        await progress(session)
        let stopFile = copies.directory.appendingPathComponent("stop")
        for index in session.runs.indices {
            if Task.isCancelled || FileManager.default.fileExists(atPath: stopFile.path) {
                session.runs[index].status = "cancelled"
                continue
            }
            let agent = session.runs[index].agent
            let snapshot = copies.snapshots[agent]!
            session.runs[index].status = "running"
            session.runs[index].started = Date()
            try store.save(session)
            await progress(session)
            do {
                let assignment = "Work only in this isolated Git snapshot: " + snapshot.path + ". The original project is not writable. Complete the task below, report changes and checks honestly.\n\n" + brief
                let result: String
                if let execute { result = try await execute(agent, assignment, snapshot) }
                else {
                    result = try await WorkerContext.$stopFile.withValue(stopFile) {
                        try await AgentWorker(configuration: configuration).runManagedSnapshot(agent, prompt: assignment, workspace: snapshot, timeout: 900)
                    }
                }
                session.runs[index].succeeded = true
                session.runs[index].answer = result
                session.runs[index].status = "needs_review"
            } catch is WorkerStopped {
                session.runs[index].succeeded = false
                session.runs[index].answer = "Stopped by the user. Review this snapshot for partial edits."
                session.runs[index].status = "needs_review"
            } catch is CancellationError {
                session.runs[index].succeeded = false
                session.runs[index].answer = "Stopped. Review this snapshot for partial edits."
                session.runs[index].status = "needs_review"
            } catch {
                session.runs[index].succeeded = false
                session.runs[index].answer = error.localizedDescription + " Review this snapshot for partial edits."
                session.runs[index].status = "needs_review"
            }
            let inventory = Task.detached {
                try? await ComparisonSnapshots(root: configuration.root).changedFiles(in: snapshot, directory: copies.directory)
            }
            session.runs[index].changedFiles = await inventory.value
            session.runs[index].finished = Date()
            try store.save(session)
            await progress(session)
        }
        try store.save(session)
        await progress(session)
        return session
    }
}

extension AgentWorker {
    func runManagedSnapshot(_ agent: EngineAgent, prompt: String, workspace: URL, timeout: Int) async throws -> String {
        try validateManagedSnapshot(workspace, agent: agent)
        return try await run(agent, prompt: prompt, workspace: workspace, timeout: timeout, managedSnapshot: true)
    }

    func validateManagedSnapshot(_ url: URL, agent: EngineAgent) throws {
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= 4, components.last == "snapshot", components[components.count - 2] == agent.rawValue,
              let id = UUID(uuidString: components[components.count - 3]) else { throw FawalyError.invalid("Invalid managed comparison snapshot.") }
        let expected = configuration.root.appendingPathComponent("comparisons/" + id.uuidString + "/" + agent.rawValue + "/snapshot")
        guard url.standardizedFileURL.path == expected.standardizedFileURL.path,
              url.resolvingSymlinksInPath().path == expected.standardizedFileURL.path,
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw FawalyError.invalid("The comparison snapshot is unavailable or linked outside its managed folder.")
        }
    }
}
