import Foundation
import Testing
@testable import FawalyApp

private func skillRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("skills-fixture-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
private func skillFixture(_ id: String = "fixture-skill", kind: String = "skill", tags: [String] = ["testing"]) -> (SkillPackage, [String: String]) {
    let path = kind == "skill" ? "SKILL.md" : "SOURCE.md"
    let body = kind == "skill" ? "---\nname: \(id)\ndescription: Fixture guidance\n---\nOnly test fixture instructions.\n" : "# Fixture project template\nPreserve existing project rules.\n"
    return (SkillPackage(id: id, name: id, nameAR: id, description: "fixture", descriptionAR: "fixture", kind: kind, repo: "fixture/skills", revision: String(repeating: "a", count: 40), author: "Fixture upstream author", license: "MIT", stars: 1, checked: "2026-11-08", skillName: id, tags: tags, requirements: [], hasScripts: false, hasHooks: false,
        files: [.init(source: "skills/" + path, path: path, sha256: SkillPackage.digest(Data(body.utf8)), bytes: body.utf8.count, executable: false)]), [path: body])
}

@Test func bundledSkillCatalogUsesPinnedRevisionsAndPreservesAttribution() throws {
    let entries = try SkillPackage.catalog()
    #expect(entries.count >= 9)
    #expect(entries.contains { $0.id == "planning-files" && $0.hasHooks })
    #expect(entries.filter { $0.kind == "template" }.count >= 2)
    for item in entries {
        try item.validate()
        #expect(!item.author.isEmpty && !item.license.isEmpty && item.revision.count == 40)
    }
}

@Test func skillInstallationPreservesUserInstructionsSettingsAndCredit() async throws {
    let root = try skillRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let original = "# قواعد المستخدم\r\nKeep my Fawaly rules.\r\n<!-- another-skill -->\r\n"
    try Data(original.utf8).write(to: root.appendingPathComponent("CLAUDE.md"))
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    let settings = Data(#"{"mcpServers":{"fawaly_team":{"keep":true}},"hooks":{"custom":"preserve"}}"#.utf8)
    try settings.write(to: root.appendingPathComponent(".claude/settings.json"))
    let (item, contents) = skillFixture(), store = ProjectSkills(directory: root)
    let plan = try store.plan(item, contents: contents, catalog: [item])
    try await store.install(plan)
    #expect(store.status(item) == .installed)
    #expect(try Data(contentsOf: root.appendingPathComponent("CLAUDE.md")).starts(with: Data(original.utf8)))
    #expect(try Data(contentsOf: root.appendingPathComponent(".claude/settings.json")) == settings)
    #expect(try String(contentsOf: root.appendingPathComponent(".agents/skills/fixture-skill/Fawaly-CREDITS.md")).contains(item.author))
    #expect(try String(contentsOf: root.appendingPathComponent(".fawaly/skills/backups/fixture-skill/CLAUDE.md.before")) == original)
    let (other, otherContents) = skillFixture("second-skill")
    let second = try store.plan(other, contents: otherContents, catalog: [item, other])
    #expect(second.warnings.contains { $0.contains("May overlap with") })
    try await store.install(second)
    #expect(store.status(item) == .installed && store.status(other) == .installed)
    #expect(try String(contentsOf: root.appendingPathComponent("CLAUDE.md")).contains("another-skill"))
}

@Test func skillInstallerRefusesExternalCollisionsLinksAndUserModifiedFiles() async throws {
    let root = try skillRoot(), outside = try skillRoot()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    let (item, contents) = skillFixture(), store = ProjectSkills(directory: root)
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".claude/skills"), withDestinationURL: outside)
    #expect(throws: FawalyError.self) { try store.plan(item, contents: contents, catalog: [item]) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    try FileManager.default.removeItem(at: root.appendingPathComponent(".claude/skills"))
    let target = root.appendingPathComponent(".agents/skills/fixture-skill")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try Data("User-owned skill".utf8).write(to: target.appendingPathComponent("SKILL.md"))
    #expect(store.status(item) == .external)
    #expect(throws: FawalyError.self) { try store.plan(item, contents: contents, catalog: [item]) }
    #expect(try String(contentsOf: target.appendingPathComponent("SKILL.md")) == "User-owned skill")
}

@Test func interruptedSkillInstallResumesWithoutOverwritingConcurrentInstructionEdits() async throws {
    let root = try skillRoot(); defer { try? FileManager.default.removeItem(at: root) }
    try Data("Original rules".utf8).write(to: root.appendingPathComponent("CLAUDE.md"))
    let (item, contents) = skillFixture(), store = ProjectSkills(directory: root)
    let plan = try store.plan(item, contents: contents, catalog: [item])
    try Data("Concurrent user change".utf8).write(to: root.appendingPathComponent("CLAUDE.md"))
    await #expect(throws: FawalyError.self) { try await store.install(plan) }
    #expect(store.status(item) == .incomplete)
    #expect(try String(contentsOf: root.appendingPathComponent("CLAUDE.md")) == "Concurrent user change")
    try await store.install(store.plan(item, contents: contents, catalog: [item]))
    #expect(store.status(item) == .installed)
    #expect(try String(contentsOf: root.appendingPathComponent("CLAUDE.md")).hasPrefix("Concurrent user change"))
    try Data("User customized the skill".utf8).write(to: root.appendingPathComponent(".agents/skills/fixture-skill/SKILL.md"))
    #expect(store.status(item) == .modified)
    #expect(throws: FawalyError.self) { try store.plan(item, contents: contents, catalog: [item]) }
}

@Test func templateAppendsAndNeverReplacesExistingFawalyOrOtherSkillSections() async throws {
    let root = try skillRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let original = "# Keep\nFawaly team instructions\nOther installed skill instructions\n"
    for name in ["CLAUDE.md", "AGENTS.md"] { try Data(original.utf8).write(to: root.appendingPathComponent(name)) }
    let (item, contents) = skillFixture("fixture-template", kind: "template")
    let store = ProjectSkills(directory: root), plan = try store.plan(item, contents: contents, catalog: [item])
    #expect(plan.warnings.count == 2)
    try await store.install(plan)
    for name in ["CLAUDE.md", "AGENTS.md"] {
        let result = try Data(contentsOf: root.appendingPathComponent(name))
        #expect(result.starts(with: Data(original.utf8)))
        #expect(String(decoding: result, as: UTF8.self).contains("Fixture project template"))
    }
}

@Test func skillDownloadsFailClosedOnBadHashesAndNeverRunPayloads() async throws {
    let (item, _) = skillFixture()
    await #expect(throws: FawalyError.self) {
        try await item.download { request in
            #expect(request.url?.host == "raw.githubusercontent.com")
            #expect(request.url?.path.contains(item.revision) == true)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return (Data("tampered".utf8), 200)
        }
    }
}

@Test func sharedProjectMemoryIsOptInBoundedAndNeverFollowsLinks() async throws {
    let root = try skillRoot(), outside = try skillRoot()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    let (item, contents) = skillFixture("memory-fixture", tags: ["memory"])
    try Data("Known project decision".utf8).write(to: root.appendingPathComponent("findings.md"))
    #expect(ProjectSkillsContext.enrich("Brief", workspace: root, catalog: [item]) == "Brief")
    let store = ProjectSkills(directory: root)
    try await store.install(store.plan(item, contents: contents, catalog: [item]))
    try Data("Outside secret fixture".utf8).write(to: outside.appendingPathComponent("outside.md"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("progress.md"), withDestinationURL: outside.appendingPathComponent("outside.md"))
    let prompt = ProjectSkillsContext.enrich("Brief", workspace: root, catalog: [item])
    #expect(prompt.contains("Known project decision") && prompt.contains("memory-fixture/SKILL.md"))
    #expect(!prompt.contains("Outside secret fixture"))
    #expect(ProjectSkillsContext.enrich("Brief", workspace: nil, catalog: [item]) == "Brief")
}

@Test func skillDetectionUsesFrontmatterEvenWhenFolderHasAnotherName() throws {
    let root = try skillRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (item, contents) = skillFixture()
    let folder = root.appendingPathComponent(".agents/skills/user-renamed-folder")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(contents["SKILL.md"]!.utf8).write(to: folder.appendingPathComponent("SKILL.md"))
    let store = ProjectSkills(directory: root)
    #expect(store.status(item) == .external)
    #expect(throws: FawalyError.self) { try store.plan(item, contents: contents, catalog: [item]) }
}

@Test func skillHelperPermissionRequiresTheExpectedDigestAndNeverExecutes() throws {
    let root = try skillRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try APIWorkspace(root)
    try workspace.write("helper.sh", content: "#!/bin/sh\nexit 99\n", expectedDigest: "")
    #expect(throws: FawalyError.self) { try workspace.markExecutable("helper.sh", expectedDigest: String(repeating: "0", count: 64)) }
    try workspace.markExecutable("helper.sh", expectedDigest: workspace.read("helper.sh").digest)
    let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("helper.sh").path)[.posixPermissions] as? Int
    #expect(permissions == 0o700)
}

@Test func cancelledSkillInstallDoesNotCreateAReceiptOrFiles() async throws {
    let root = try skillRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let (item, contents) = skillFixture(), store = ProjectSkills(directory: root)
    let plan = try store.plan(item, contents: contents, catalog: [item])
    let task = Task { try await store.install(plan) }
    task.cancel()
    do { try await task.value; Issue.record("Cancelled install succeeded") }
    catch { #expect(error is CancellationError) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}
