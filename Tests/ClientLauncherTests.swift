import Foundation
import Testing
@testable import FawalyApp

@Test func stableLauncherQuotesPathsAndRefusesForeignFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let launcher = ClientLauncher(root: root)
    try launcher.prepare(application: URL(fileURLWithPath: "/usr/bin/true"))
    let text = try String(contentsOf: launcher.url)
    #expect(text.contains("exec '/usr/bin/true' \"$@\""))
    #expect(try FileManager.default.attributesOfItem(atPath: launcher.url.path)[.posixPermissions] as? Int == 0o700)
    try launcher.prepare(application: URL(fileURLWithPath: "/usr/bin/false"))
    #expect(try String(contentsOf: launcher.url).contains("'/usr/bin/false'"))
    try Data("#!/bin/sh\necho custom\n".utf8).write(to: launcher.url)
    #expect(throws: FawalyError.self) { try launcher.prepare(application: URL(fileURLWithPath: "/usr/bin/true")) }
    try FileManager.default.removeItem(at: launcher.url)
    try FileManager.default.createSymbolicLink(atPath: launcher.url.path, withDestinationPath: "/usr/bin/true")
    #expect(throws: FawalyError.self) { try launcher.prepare(application: URL(fileURLWithPath: "/usr/bin/true")) }
}

@Test func clientMigrationRecognizesItsOwnBundleThroughARelocationLink() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Paths.ensurePrivateDirectory(root)
    defer { try? FileManager.default.removeItem(at: root) }
    let alias = root.appendingPathComponent("Previous location.app")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: Bundle.main.bundleURL)
    let executable = try #require(Bundle.main.executableURL?.lastPathComponent)
    #expect(ClientLink.ownsApplicationExecutable(alias.appendingPathComponent("Contents/MacOS/" + executable).path))
    #expect(!ClientLink.ownsApplicationExecutable("/usr/bin/true"))
    #expect(!ClientLink.ownsApplicationExecutable(root.appendingPathComponent("Other.app/Contents/MacOS/Other").path))
}

@Test func desktopCodeOverrideMigratesOnlyItsOwnRegistrationAndPreservesOtherSettings() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home"), application = try #require(Bundle.main.executableURL)
    let file = home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    try Paths.ensurePrivateDirectory(file.deletingLastPathComponent())
    let other: [String: Any] = ["command": "/usr/bin/true", "env": ["fixture": "preserve this value"]]
    try JSONSerialization.data(withJSONObject: ["fixtureSetting": 42, "mcpServers": ["another_server": other, ClientLink.serverName: ["command": application.path, "args": ["mcp", "--client", "claude"]]]]).write(to: file)
    let link = ClientLink(root: root, application: application, home: home)
    try link.migrateOwnedDesktopOverride()
    let settings = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    let servers = try #require(settings["mcpServers"] as? [String: Any])
    #expect(settings["fixtureSetting"] as? Int == 42)
    #expect((servers["another_server"] as? NSDictionary) == (other as NSDictionary))
    #expect((servers[ClientLink.serverName] as? [String: Any])?["command"] as? String == ClientLauncher(root: root).url.path)
    try JSONSerialization.data(withJSONObject: ["mcpServers": [ClientLink.serverName: ["command": "/usr/bin/true", "args": ["mcp", "--client", "claude"]]]]).write(to: file)
    let foreign = try Data(contentsOf: file)
    #expect(throws: FawalyError.self) { try link.migrateOwnedDesktopOverride() }
    #expect(try Data(contentsOf: file) == foreign)
}
