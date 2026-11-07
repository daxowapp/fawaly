import CryptoKit
import Foundation

struct SignedCatalog: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let name: String
        let template: String
        let billing: String
        let models: [String]
        let docsURL: URL?
        let baseURL: URL?
        let modelsURL: URL?
        let authMode: String?
    }
    let schema: String
    let publishedAt: String
    let providers: [Entry]

    static let pinnedKey = "86iVoJtVL5TrOeR+aUQoz8b3KW8CwL/M/VPi+uD6fdE="
    static let maximumBytes = 1_048_576

    static func verify(_ data: Data) throws -> Self {
        struct Envelope: Decodable { let payload: String; let signature: String }
        guard data.count <= maximumBytes else { throw CatalogError.invalid }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard let payload = Data(base64Encoded: envelope.payload), payload.count <= maximumBytes,
              let signature = Data(base64Encoded: envelope.signature),
              let keyData = Data(base64Encoded: pinnedKey),
              try Curve25519.Signing.PublicKey(rawRepresentation: keyData).isValidSignature(signature, for: payload) else {
            throw CatalogError.invalid
        }
        let catalog = try JSONDecoder().decode(Self.self, from: payload)
        guard catalog.schema == "fawaly.catalog.v1", ISO8601DateFormatter().date(from: catalog.publishedAt) != nil,
              catalog.providers.count <= 100, Set(catalog.providers.map(\.id)).count == catalog.providers.count,
              catalog.providers.allSatisfy({ entry in
                  validIdentifier(entry.id) && !entry.name.isEmpty && entry.name.count <= 160 &&
                  entry.models.count <= 200 && entry.models.allSatisfy(validIdentifier) &&
                  ["subscription", "metered", "local"].contains(entry.billing) &&
                  [entry.docsURL, entry.baseURL, entry.modelsURL].compactMap { $0 }.allSatisfy(validURL)
              }) else { throw CatalogError.invalid }
        return catalog
    }

    static func publishedDate(_ value: String) throws -> Date {
        guard let date = ISO8601DateFormatter().date(from: value) else { throw CatalogError.invalid }
        return date
    }

    static func load(root: URL, bundle: Bundle = .main) throws -> Self {
        var candidates: [Self] = []
        if let file = bundle.url(forResource: "catalog.signed", withExtension: "json"),
           let bundled = try? verify(boundedRead(file)) { candidates.append(bundled) }
        let saved = root.appendingPathComponent("catalog.signed.json")
        if let downloaded = try? verify(boundedRead(saved)) { candidates.append(downloaded) }
        guard let newest = candidates.max(by: { (try? publishedDate($0.publishedAt)) ?? .distantPast < (try? publishedDate($1.publishedAt)) ?? .distantPast }) else { throw CatalogError.unavailable }
        return newest
    }

    static func importFile(_ file: URL, root: URL) throws -> Self {
        let data = try boundedRead(file)
        let incoming = try verify(data)
        if let current = try? load(root: root), try publishedDate(incoming.publishedAt) < publishedDate(current.publishedAt) { throw CatalogError.older }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: root.appendingPathComponent("catalog.signed.json"), options: .atomic)
        return incoming
    }

    private static func boundedRead(_ file: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw CatalogError.invalid }
        return data
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 160 && !value.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 } == true })
    }

    private static func validURL(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, url.fragment == nil, let host = url.host else { return false }
        return url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host))
    }

    enum CatalogError: LocalizedError {
        case invalid, unavailable, older
        var errorDescription: String? {
            switch self {
            case .invalid: "The catalog is invalid or its publisher signature does not match."
            case .unavailable: "The signed catalog is unavailable."
            case .older: "A newer signed catalog is already installed."
            }
        }
    }
}
