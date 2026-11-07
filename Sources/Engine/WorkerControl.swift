import Foundation

enum WorkerContext {
    @TaskLocal static var stopFile: URL?
    @TaskLocal static var modelPreference: WorkerModelPreference?
}

struct WorkerStopped: LocalizedError {
    var errorDescription: String? { "The worker was stopped by the user. Review any partial file changes." }
}

extension EngineConfiguration {
    func stopFile(_ id: UUID) -> URL { root.appendingPathComponent("stop-requests/" + id.uuidString + ".stop") }

    func requestStop(_ id: UUID, primary: EngineAgent? = nil) throws {
        guard let job = try TeamJobLog(root: root).recent(limit: nil).first(where: { $0.id == id }),
              job.status == "running", primary == nil || job.primary == primary else {
            throw FawalyError.invalid("This task is already finished or belongs to a different primary.")
        }
        let file = stopFile(id)
        try Paths.ensurePrivateDirectory(file.deletingLastPathComponent())
        try Data("stop".utf8).write(to: file, options: .atomic)
    }
}
