import Foundation
import Testing
@testable import TokenHUD

@Suite(.serialized)
struct SourceSynchronizationTests {
    private let secret = "offline-synchronization-fixture-token"
    private let endpoint = "https://sync.example.test/v1"

    private func root() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tokenhud-sync-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func save(_ object: Any, to file: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: file)
    }

    private func sql(_ file: URL, _ statement: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [file.path, statement]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func fixture(_ source: String, directory: URL, id: String = "old", key: String? = nil) throws -> ProviderSourceReference {
        let token = key ?? secret
        switch source {
        case "9router":
            let file = directory.appendingPathComponent("9router.sqlite")
            let data = String(decoding: try JSONSerialization.data(withJSONObject: ["apiKey": token, "baseUrl": endpoint]), as: UTF8.self)
            try sql(file, "CREATE TABLE IF NOT EXISTS providerConnections(id TEXT, provider TEXT, authType TEXT, data TEXT); DELETE FROM providerConnections; INSERT INTO providerConnections VALUES(\(ReadonlySQLite.literal(id)), 'openai-compatible-chat', 'apikey', \(ReadonlySQLite.literal(data)))")
            return ProviderSourceReference(source: source, path: file.path, recordId: id, providerId: "openai-compatible-chat", collection: "providerConnections")
        case "cc-switch":
            let file = directory.appendingPathComponent("cc.sqlite")
            let data = String(decoding: try JSONSerialization.data(withJSONObject: ["env": ["ANTHROPIC_API_KEY": token, "ANTHROPIC_BASE_URL": endpoint]]), as: UTF8.self)
            try sql(file, "CREATE TABLE IF NOT EXISTS providers(id TEXT, app_type TEXT, settings_config TEXT); DELETE FROM providers; INSERT INTO providers VALUES(\(ReadonlySQLite.literal(id)), 'claude', \(ReadonlySQLite.literal(data)))")
            return ProviderSourceReference(source: source, path: file.path, recordId: id, providerId: "claude", collection: "claude")
        case "cpamp":
            let file = directory.appendingPathComponent(id + ".json")
            try save(["type": "codex", "api_key": token, "base_url": endpoint], to: file)
            return ProviderSourceReference(source: source, path: file.path, recordId: file.lastPathComponent, providerId: "codex", collection: "auth-files")
        default:
            let file = directory.appendingPathComponent("providers.json")
            try save(["providers": [["id": id, "key": token, "chat": endpoint]]], to: file)
            return ProviderSourceReference(source: "magpie", path: file.path, recordId: id, providerId: id, collection: "providers")
        }
    }

    @Test(arguments: ["9router", "cc-switch", "cpamp", "magpie"])
    func exactSecretRenameCorrectsOnlyUniqueCompatibleRecord(_ source: String) throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let old = try fixture(source, directory: directory)
        let registered = try #require(SourceSynchronizer.scan(reference: old, authMode: "apikey").reference)
        #expect(registered.identityAnchor?.count == 71)
        #expect(registered.sameSourceRecord(as: old))
        if source == "cpamp" { try FileManager.default.removeItem(atPath: old.path) }
        let replacement = try fixture(source, directory: directory, id: "new")
        let before = try Data(contentsOf: URL(fileURLWithPath: replacement.path))
        let result = SourceSynchronizer.scan(reference: registered, authMode: "apikey")
        guard case .correctedRef(let corrected) = result else {
            Issue.record("Expected corrected reference, received \(result)"); return
        }
        #expect(corrected.recordId == replacement.recordId)
        #expect(corrected.providerId == replacement.providerId)
        #expect(corrected.originalRecordId == old.recordId)
        #expect(corrected.originalProviderId == old.providerId)
        #expect(try Data(contentsOf: URL(fileURLWithPath: replacement.path)) == before)
        let encoded = String(decoding: try JSONEncoder().encode(corrected), as: UTF8.self)
        #expect(!encoded.contains(secret))
        #expect(!encoded.contains(endpoint))
        #expect(!encoded.contains("refreshToken"))
    }

    @Test(arguments: ["9router", "cc-switch", "cpamp", "magpie"])
    func originalPrimaryKeyMayRotateCredential(_ source: String) throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let old = try fixture(source, directory: directory)
        let registered = try #require(SourceSynchronizer.scan(reference: old, authMode: "apikey").reference)
        _ = try fixture(source, directory: directory, key: "rotated-offline-token")
        let result = SourceSynchronizer.scan(reference: registered, authMode: "apikey")
        guard case .unchanged(let updated) = result else { Issue.record("Rotation rejected: \(result)"); return }
        #expect(updated.identityAnchor != registered.identityAnchor)
        #expect(updated.sameSourceRecord(as: registered))
    }

    @Test func legacyMissingReferenceDoesNotBindIdenticalVendorOrName() throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let old = try fixture("magpie", directory: directory)
        _ = try fixture("magpie", directory: directory, id: "new")
        guard case .unavailable(let message) = SourceSynchronizer.scan(reference: old, authMode: "apikey") else {
            Issue.record("Legacy reference incorrectly bound"); return
        }
        #expect(message.contains("重新扫描"))
    }

    @Test func providerTypeAndProtocolChangesRejectOriginalPK() throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let old = try fixture("9router", directory: directory)
        let registered = try #require(SourceSynchronizer.scan(reference: old, authMode: "apikey").reference)
        try sql(URL(fileURLWithPath: old.path), "UPDATE providerConnections SET provider='other-vendor'")
        guard case .unavailable = SourceSynchronizer.scan(reference: registered, authMode: "apikey") else {
            Issue.record("Provider change accepted"); return
        }
        let magpie = try fixture("magpie", directory: directory)
        let anchored = try #require(SourceSynchronizer.scan(reference: magpie, authMode: "apikey").reference)
        try save(["providers": [["id": "old", "key": secret, "anthropic": endpoint]]], to: URL(fileURLWithPath: magpie.path))
        guard case .unavailable = SourceSynchronizer.scan(reference: anchored, authMode: "apikey") else {
            Issue.record("Protocol change accepted"); return
        }
        guard case .unavailable = SourceSynchronizer.scan(reference: anchored, authMode: "apikey", protocolName: "anthropic") else {
            Issue.record("Caller protocol replaced saved protocol evidence"); return
        }
    }

    @Test(arguments: ["9router", "cc-switch", "cpamp", "magpie"])
    func duplicateSecretCandidatesAreAmbiguous(_ source: String) throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let old = try fixture(source, directory: directory)
        let anchored = try #require(SourceSynchronizer.scan(reference: old, authMode: "apikey").reference)
        if source == "cpamp" { try FileManager.default.removeItem(atPath: old.path) }
        let next = try fixture(source, directory: directory, id: "new")
        let file = URL(fileURLWithPath: next.path)
        switch source {
        case "9router": try sql(file, "INSERT INTO providerConnections SELECT 'another', provider, authType, data FROM providerConnections")
        case "cc-switch": try sql(file, "INSERT INTO providers SELECT 'another', app_type, settings_config FROM providers")
        case "cpamp": _ = try fixture(source, directory: directory, id: "another")
        default: try save(["providers": [["id": "new", "key": secret, "chat": endpoint], ["id": "another", "key": secret, "chat": endpoint]]], to: file)
        }
        guard case .ambiguous = SourceSynchronizer.scan(reference: anchored, authMode: "apikey") else {
            Issue.record("Duplicate identity accepted"); return
        }
    }

    @Test func magpieWasRequiresUniqueCompatibleSourceEvidenceAndPreservesOriginalTrace() throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let old = try fixture("magpie", directory: directory)
        let anchored = try #require(SourceSynchronizer.scan(reference: old, authMode: "apikey").reference)
        let file = URL(fileURLWithPath: old.path)
        try save(["providers": [["id": "new", "was": ["old"], "key": "rotated-token", "chat": endpoint]]], to: file)
        let corrected = try #require(SourceSynchronizer.scan(reference: anchored, authMode: "apikey").reference)
        #expect(corrected.providerId == "new")
        #expect(corrected.originalProviderId == "old")
        try save(["providers": [["id": "latest", "was": ["new"], "key": "third-token", "chat": endpoint]]], to: file)
        let latest = try #require(SourceSynchronizer.scan(reference: corrected, authMode: "apikey").reference)
        #expect(latest.originalProviderId == "old")
        #expect(latest.originalRecordId == "old")
        try save(["providers": [["id": "a", "was": ["old"], "key": secret, "chat": endpoint], ["id": "b", "was": ["old"], "key": "other-token", "chat": endpoint]]], to: file)
        guard case .ambiguous = SourceSynchronizer.scan(reference: anchored, authMode: "apikey") else {
            Issue.record("Multiple was candidates accepted"); return
        }
        try save(["providers": [["id": "a", "was": ["old"], "key": secret, "chat": "https://other.example.test"]]], to: file)
        guard case .unavailable = SourceSynchronizer.scan(reference: anchored, authMode: "apikey") else {
            Issue.record("Changed was endpoint accepted"); return
        }
    }

    @Test func magpiePluginSlotRenameUsesExactCredentialAndValidatedOwnerMapping() throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("plugin-auth.json")
        let cache = directory.appendingPathComponent("plugin-providers.json")
        try save(["providers": [["id": "fixture-plugin"]]], to: directory.appendingPathComponent("providers.json"))
        try save(["fixture#old": ["type": "oauth", "access": secret]], to: file)
        try save([["id": "fixture", "accounts": [["key": "fixture#old"]]]], to: cache)
        let reference = ProviderSourceReference(source: "magpie", path: file.path, recordId: "fixture#old",
            providerId: "fixture-plugin", collection: "plugin-auth", credentialProviderId: "fixture")
        let layout = ProviderCredentialSource(file: "", tokenPath: "access", requiredValues: ["type": "oauth"])
        let template = PluginProvider(slug: "fixture", manifest: ProviderManifest(name: "Fixture", label: "Fixture",
            authMode: "auth", credentialSource: layout), dir: directory)
        let anchored = try #require(SourceSynchronizer.scan(reference: reference, template: template, authMode: "auth").reference)
        try save(["fixture#new": ["type": "oauth", "access": secret, "email": "same-display@example.test"]], to: file)
        try save([["id": "fixture", "accounts": [["key": "fixture#new"]]]], to: cache)
        let corrected = try #require(SourceSynchronizer.scan(reference: anchored, template: template, authMode: "auth").reference)
        #expect(corrected.recordId == "fixture#new")
        #expect(corrected.originalRecordId == "fixture#old")
        try save([["id": "other", "accounts": [["key": "fixture#new"]]]], to: cache)
        guard case .unavailable = SourceSynchronizer.scan(reference: anchored, template: template, authMode: "auth") else {
            Issue.record("Unvalidated plugin owner accepted"); return
        }
    }

    @Test func changedIDAndRotatedTokenWithoutStableAccountRequiresRescan() throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let old = try fixture("9router", directory: directory)
        let anchored = try #require(SourceSynchronizer.scan(reference: old, authMode: "apikey").reference)
        _ = try fixture("9router", directory: directory, id: "new", key: "rotated-offline-token")
        guard case .unavailable = SourceSynchronizer.scan(reference: anchored, authMode: "apikey") else {
            Issue.record("Unproven identity accepted"); return
        }
    }
}
