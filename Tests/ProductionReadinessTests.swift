import Foundation
import Darwin
import CryptoKit
import Testing
@testable import FawalyApp

private final class MetadataFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let headers = path == "/declared-large" ? ["Content-Length": "99999"] : [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: path == "/unavailable" ? 503 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 65, count: path == "/stream-large" ? 257 : 128))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func installerBoundsDeclaredAndStreamingMetadataBeforeParsing() async throws {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MetadataFixture.self]
    let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
    #expect(try await RuntimeInstaller.metadata(URL(string: "https://fixture.invalid/valid")!, session: session, limit: 128).count == 128)
    for path in ["declared-large", "stream-large", "unavailable"] {
        await #expect(throws: FawalyError.self) {
            try await RuntimeInstaller.metadata(URL(string: "https://fixture.invalid/" + path)!, session: session, limit: 256)
        }
    }
}

@Test func everyScreenBundlesItsOwnDistinctCharacterScene() throws {
    #expect(Set(AppPage.allCases.map(\.artwork)).count == AppPage.allCases.count)
    var hashes = Set<Data>()
    for page in AppPage.allCases {
        let url = try #require(AppResources.bundle.url(forResource: "crew-" + page.artwork, withExtension: "png"))
        let data = try Data(contentsOf: url)
        #expect(data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))
        #expect(data.count > 1024)
        #expect(hashes.insert(Data(SHA256.hash(data: data))).inserted, "Repeated image content for \(page)")
    }
}

@Test @MainActor func skillInstallationSurvivesPageNavigationButPreviewDownloadCancels() async {
    let activity = SkillActivity()
    activity.installing = true; activity.active = "Fixture installation"
    activity.operation = Task { try? await Task.sleep(for: .milliseconds(20)) }
    activity.leavePage()
    #expect(activity.operation?.isCancelled == false)
    await activity.operation?.value
    activity.installing = false
    activity.operation = Task { try? await Task.sleep(for: .seconds(5)) }
    activity.leavePage()
    #expect(activity.operation?.isCancelled == true)
    await activity.operation?.value
}

@Test func installerRejectsUnsignedWrongVendorAndSymlinkedRuntimesWithoutExecutingThem() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-integrity-" + UUID().uuidString)
    try Paths.ensurePrivateDirectory(root)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("fixture-runtime"), marker = root.appendingPathComponent("executed")
    try Data(("#!/bin/sh\n/usr/bin/touch '" + marker.path + "'\n").utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let linked = root.appendingPathComponent("linked-runtime")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: executable)
    let installer = RuntimeInstaller(root: root)
    for file in [executable, linked, URL(fileURLWithPath: "/bin/echo")] {
        await #expect(throws: FawalyError.self) { try await installer.verifyExecutable(file, agent: .codex, directory: root) }
    }
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}

@Test func workerRejectsOversizedDiagnosticsEvenWhenChildExitsSuccessfully() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("worker-output-" + UUID().uuidString)
    try Paths.ensurePrivateDirectory(root)
    defer { try? FileManager.default.removeItem(at: root) }
    await #expect(throws: FawalyError.self) {
        try await WorkerProcess.run(program: "/bin/sh", arguments: ["-c", "/bin/dd if=/dev/zero bs=2097152 count=1 1>&2 2>/dev/null"], environment: ["PATH": "/usr/bin:/bin"], directory: root, workingDirectory: root, prompt: "Fixture", timeout: 5)
    }
    let count = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("stderr").path)[.size] as? Int
    #expect((count ?? 0) > WorkerProcess.outputLimit)
}

@Test func nativeWorkerCannotMakeTheHostReadAnOutsideFileThroughItsOutputPath() async throws {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".fawaly-output-fixture-" + UUID().uuidString)
    let job = root.appendingPathComponent("job"), outside = root.appendingPathComponent("private-fixture.txt")
    try Paths.ensurePrivateDirectory(job)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("PRIVATE-OUTSIDE-FIXTURE".utf8).write(to: outside)
    let invocation = AgentWorker.Invocation(program: URL(fileURLWithPath: "/bin/sh"), arguments: [], environment: [:])
    let profile = job.appendingPathComponent("worker.sb")
    try AgentWorker.sandboxProfile(invocation: invocation, directory: job, workspace: nil, codexHome: nil).write(to: profile, atomically: true, encoding: .utf8)
    let script = "if /bin/cat \"$1\" >/dev/null 2>/dev/null; then exit 7; fi; /bin/rm \"$2/stdout\"; /bin/ln -s \"$1\" \"$2/stdout\""
    do {
        let data = try await WorkerProcess.run(program: "/usr/bin/sandbox-exec", arguments: ["-f", profile.path, "/bin/sh", "-c", script, "fixture", outside.path, job.path], environment: ["PATH": "/usr/bin:/bin"], directory: job, workingDirectory: job, prompt: "Fixture", timeout: 5)
        #expect(!String(decoding: data, as: UTF8.self).contains("PRIVATE-OUTSIDE-FIXTURE"))
    } catch { #expect(error.localizedDescription.contains("worker result")) }
}

@Test func codexFinalAnswerNeverFollowsAnOutsideSymlink() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-final-fixture-" + UUID().uuidString)
    let job = root.appendingPathComponent("job"), outside = root.appendingPathComponent("private-fixture")
    try Paths.ensurePrivateDirectory(job); defer { try? FileManager.default.removeItem(at: root) }
    try Data("PRIVATE-OUTSIDE-FIXTURE".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: job.appendingPathComponent("final.txt"), withDestinationURL: outside)
    #expect(throws: FawalyError.self) { try AgentWorker.answer(.codex, directory: job, output: Data()) }
}

@Test func boundedWorkerFilesUseLiveSizesAndRejectHardlinksSymlinksAndPipes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bounded-worker-files-" + UUID().uuidString)
    try Paths.ensurePrivateDirectory(root); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("result"), symlink = root.appendingPathComponent("symlink"), hardlink = root.appendingPathComponent("hardlink"), pipeURL = root.appendingPathComponent("pipe")
    let fd = try WorkerFiles.create(file); defer { close(fd) }
    #expect(try WorkerFiles.size(fd) == 0)
    try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: Data(repeating: 65, count: 257))
    #expect(try WorkerFiles.size(fd) == 257)
    #expect(throws: FawalyError.self) { try WorkerFiles.read(fd, limit: 256) }
    #expect(try WorkerFiles.read(fd, limit: 257).count == 257)
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file)
    #expect(throws: FawalyError.self) { try WorkerFiles.read(symlink, limit: 1024) }
    try FileManager.default.linkItem(at: file, to: hardlink)
    #expect(throws: FawalyError.self) { try WorkerFiles.read(hardlink, limit: 1024) }
    #expect(mkfifo(pipeURL.path, 0o600) == 0)
    #expect(throws: FawalyError.self) { try WorkerFiles.read(pipeURL, limit: 1024) }
}

@Test func workerDoesNotInheritAnUnrelatedOpenDescriptor() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("worker-descriptors-" + UUID().uuidString)
    try Paths.ensurePrivateDirectory(root); defer { try? FileManager.default.removeItem(at: root) }
    let secret = root.appendingPathComponent("private-fixture")
    try Data("PRIVATE-DESCRIPTOR-FIXTURE".utf8).write(to: secret)
    let fd = open(secret.path, O_RDONLY); #expect(fd >= 0); defer { close(fd) }
    let output = try await WorkerProcess.run(program: "/bin/sh", arguments: ["-c", "if /bin/cat /dev/fd/\"$1\" 2>/dev/null; then exit 7; fi; printf CLOSED", "fixture", String(fd)], environment: ["PATH": "/usr/bin:/bin"], directory: root, workingDirectory: root, prompt: "Fixture", timeout: 5)
    #expect(String(decoding: output, as: UTF8.self) == "CLOSED")
}

@Test @MainActor func failedReadingStateLoadNeverOverwritesSavedBookmarks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reading-preservation-" + UUID().uuidString)
    try Paths.ensurePrivateDirectory(root); defer { try? FileManager.default.removeItem(at: root) }
    var snapshot = DailySnapshot(); snapshot.checkedAt = Date()
    try DailyStore(root: root).save(snapshot)
    let reading = root.appendingPathComponent("developer-daily-reading.json"), original = Data("broken fixture preserves bytes".utf8)
    try original.write(to: reading)
    let model = DailyViewModel(); await model.update(root: root, force: false)
    #expect(!model.readingAvailable)
    let article = DailyArticle(sourceID: "github", title: "Fixture", url: URL(string: "https://github.blog/changelog/fixture")!, published: Date(), topic: .coding)
    model.toggle(article, saved: true, root: root)
    #expect(try Data(contentsOf: reading) == original)
    try DailyStore(root: root).save(DailyReadingState(), reading: true)
    await model.update(root: root, force: false)
    #expect(model.readingAvailable)
    model.toggle(article, saved: true, root: root)
    #expect(try DailyStore(root: root).reading().saved.contains(article.id))
}

@Test func largeComparisonInventoriesStayVisibleWithAnExplicitTruncationFlag() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("comparison-inventory-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var session = ComparisonSession(id: UUID(), project: "/fixture", commit: "fixture", brief: "Fixture", runs: [.init(agent: .kimi), .init(agent: .claude)])
    for index in session.runs.indices {
        session.runs[index].changedFiles = (0..<10000).map { String(repeating: "path/", count: 20) + String($0) }
        session.runs[index].status = "needs_review"
    }
    let store = ComparisonStore(root: root); try store.save(session)
    let saved = try #require(store.recent().first)
    #expect(saved.runs.allSatisfy { $0.inventoryTruncated == true && ($0.changedFiles?.count ?? 10001) <= 1000 })
    #expect(try WorkerFiles.size(root.appendingPathComponent("comparisons/" + session.id.uuidString + "/result.json")) <= 1_048_576)
}

@Test func rejectedNativeSignInCannotBeRevivedByALocalStatusCheck() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-reauth-" + UUID().uuidString)
    try Paths.ensurePrivateDirectory(root.appendingPathComponent("runtimes")); defer { try? FileManager.default.removeItem(at: root) }
    let runtime = root.appendingPathComponent("runtimes/claude")
    try Data("fixture".utf8).write(to: runtime)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.path)
    let configuration = EngineConfiguration(root: root)
    try configuration.recordNativeSignIn(.claude, connected: true)
    try configuration.requireNativeSignIn(.claude, required: true)
    #expect(!configuration.isReady(.claude))
    let service = NativeSignIn(configuration: configuration, execute: { _, _, _ in LoginReply(exitCode: 0, output: #"{"loggedIn":true}"#) })
    #expect(try await !service.verify(.claude))
    #expect(configuration.requiresNativeSignIn(.claude))
    try await service.signIn(.claude, onURL: { _ in })
    #expect(!configuration.requiresNativeSignIn(.claude))
    #expect(configuration.isReady(.claude))
    let marker = configuration.nativeAuthDirectory(.claude).appendingPathComponent("fawaly-reauth-required.json")
    try FileManager.default.removeItem(at: marker)
    try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: root.appendingPathComponent("missing"))
    #expect(configuration.requiresNativeSignIn(.claude))
}

@Test func nativeProvider401IsAnAuthenticationFailureRatherThanAUsableResult() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-401-" + UUID().uuidString)
    try Paths.ensurePrivateDirectory(root); defer { try? FileManager.default.removeItem(at: root) }
    await #expect(throws: WorkerAuthenticationError.self) {
        try await WorkerProcess.run(program: "/bin/sh", arguments: ["-c", "printf '%s' '{\"api_error_status\":401,\"is_error\":true,\"result\":\"Failed to authenticate\"}'; exit 1"], environment: ["PATH": "/usr/bin:/bin"], directory: root, workingDirectory: root, prompt: "Fixture", timeout: 5)
    }
}
