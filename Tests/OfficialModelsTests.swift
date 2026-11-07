import Foundation
import Testing
@testable import FawalyApp

private func cache(_ models: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["fetched_at": "2026-10-31T00:00:00Z", "client_version": "0.165.0", "models": models])
}
private func signedInRoot() throws -> (URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fawaly-official-models-" + UUID().uuidString)
    let folder = Paths.officialSignIn(.codex, root: root)
    try Paths.ensurePrivateDirectory(folder)
    return (root, folder)
}

@Test func codexListsOnlyPickerModelsInCodexOrder() throws {
    let data = try cache([["slug": "gpt-6.1-sol", "visibility": "list"], ["slug": "gpt-reserve", "visibility": "hide"],
                          ["slug": "gpt-5.6-luna", "visibility": "list"], ["slug": "gpt-6.1-sol", "visibility": "list"],
                          ["slug": "bad slug; rm", "visibility": "list"], ["slug": String(repeating: "x", count: 200), "visibility": "list"],
                          ["visibility": "list"], ["slug": "codex-auto-review", "visibility": "hide"]])
    #expect(OfficialModels.codexSlugs(data) == ["gpt-6.1-sol", "gpt-5.6-luna"])
    #expect(OfficialModels.codexSlugs(Data("not json".utf8)).isEmpty)
    #expect(OfficialModels.codexSlugs(Data(#"{"models":"nope"}"#.utf8)).isEmpty)
}

@Test func codexModelsComeOnlyFromFawalysOwnSignInFolder() throws {
    let (root, folder) = try signedInRoot(); defer { try? FileManager.default.removeItem(at: root) }
    #expect(OfficialModels.codex(root: root).isEmpty)
    try cache([["slug": "gpt-6.1-sol", "visibility": "list"], ["slug": "gpt-6-luna", "visibility": "list"]])
        .write(to: folder.appendingPathComponent("models_cache.json"))
    #expect(OfficialModels.codex(root: root) == ["gpt-6.1-sol", "gpt-6-luna"])
    let other = FileManager.default.temporaryDirectory.appendingPathComponent("fawaly-other-root-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: other) }
    #expect(OfficialModels.codex(root: other).isEmpty)
}

@Test func codexCacheThatIsALinkOrOversizedIsIgnored() throws {
    let (root, folder) = try signedInRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let elsewhere = root.appendingPathComponent("elsewhere.json")
    try cache([["slug": "gpt-6.1-sol", "visibility": "list"]]).write(to: elsewhere)
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("models_cache.json"), withDestinationURL: elsewhere)
    #expect(OfficialModels.codex(root: root).isEmpty)
    try FileManager.default.removeItem(at: folder.appendingPathComponent("models_cache.json"))
    var huge = try cache([["slug": "gpt-6.1-sol", "visibility": "list"]]); huge.append(Data(repeating: 0x20, count: OfficialModels.maximumCacheBytes))
    try huge.write(to: folder.appendingPathComponent("models_cache.json"))
    #expect(OfficialModels.codex(root: root).isEmpty)
}

@Test func codexLinkedSignInFolderIsNotTrusted() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fawaly-official-link-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("real-codex"); try Paths.ensurePrivateDirectory(real)
    try cache([["slug": "gpt-6.1-sol", "visibility": "list"]]).write(to: real.appendingPathComponent("models_cache.json"))
    try Paths.ensurePrivateDirectory(root.appendingPathComponent("official"))
    try FileManager.default.createSymbolicLink(at: Paths.officialSignIn(.codex, root: root), withDestinationURL: real)
    #expect(OfficialModels.codex(root: root).isEmpty)
}

@Test func swappingTheCacheForALinkMidReadCannotRedirectIt() throws {
    let (root, folder) = try signedInRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let leaf = folder.appendingPathComponent("models_cache.json"), outside = root.appendingPathComponent("outside.json")
    try cache([["slug": "gpt-6.1-sol", "visibility": "list"]]).write(to: leaf)
    try cache([["slug": "external-sentinel", "visibility": "list"]]).write(to: outside)
    let models = OfficialModels.codex(root: root) {
        try? FileManager.default.removeItem(at: leaf); try? FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: outside)
    }
    #expect(models == ["gpt-6.1-sol"])
    #expect(OfficialModels.codex(root: root).isEmpty)
}

@Test func swappingTheSignInFolderMidReadCannotRedirectIt() throws {
    let (root, folder) = try signedInRoot(); defer { try? FileManager.default.removeItem(at: root) }
    try cache([["slug": "gpt-6.1-sol", "visibility": "list"]]).write(to: folder.appendingPathComponent("models_cache.json"))
    let decoy = root.appendingPathComponent("decoy"); try Paths.ensurePrivateDirectory(decoy)
    try cache([["slug": "external-sentinel", "visibility": "list"]]).write(to: decoy.appendingPathComponent("models_cache.json"))
    let models = OfficialModels.codex(root: root) {
        try? FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("moved"))
        try? FileManager.default.createSymbolicLink(at: folder, withDestinationURL: decoy)
    }
    #expect(models == ["gpt-6.1-sol"])
    #expect(OfficialModels.codex(root: root).isEmpty)
}

@Test func aCacheThatGrowsPastTheLimitMidReadIsRejected() throws {
    let (root, folder) = try signedInRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let leaf = folder.appendingPathComponent("models_cache.json")
    try cache([["slug": "gpt-6.1-sol", "visibility": "list"]]).write(to: leaf)
    let models = OfficialModels.codex(root: root) {
        guard let handle = try? FileHandle(forWritingTo: leaf) else { return }
        handle.seekToEndOfFile(); handle.write(Data(repeating: 0x20, count: OfficialModels.maximumCacheBytes)); try? handle.close()
    }
    #expect(models.isEmpty)
}

@Test func readingTheCacheChangesNothing() throws {
    let (root, folder) = try signedInRoot(); defer { try? FileManager.default.removeItem(at: root) }
    try cache([["slug": "gpt-6.1-sol", "visibility": "list"]]).write(to: folder.appendingPathComponent("models_cache.json"))
    chmod(folder.path, 0o750)
    #expect(OfficialModels.codex(root: root) == ["gpt-6.1-sol"])
    var info = stat(); #expect(lstat(folder.path, &info) == 0); #expect(info.st_mode & 0o777 == 0o750)
}
