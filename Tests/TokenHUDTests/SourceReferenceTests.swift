import Foundation
import CryptoKit
import Testing
@testable import QuotaNest

@Suite(.serialized)
struct SourceReferenceTests {
    private func root() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tokenhud-source-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
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

    private func record(_ key: String, base: String = "https://first.example.test/v1") throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["apiKey": key, "providerSpecificData": ["baseUrl": base]])
        return String(decoding: data, as: UTF8.self)
    }

    @Test func sqliteRotationIsLiveButResolvedSnapshotIsFrozenAndMissingFailsClosed() throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let db = directory.appendingPathComponent("fake.sqlite")
        let pk = "row' OR 1=1 --"
        try sql(db, "CREATE TABLE providerConnections(id TEXT PRIMARY KEY, provider TEXT, authType TEXT, data TEXT); INSERT INTO providerConnections VALUES(\(ReadonlySQLite.literal(pk)), 'openai-compatible-chat', 'apikey', \(ReadonlySQLite.literal(try record("fixture-first"))));")
        let reference = ProviderSourceReference(source: "9router", path: db.path, recordId: pk, providerId: "openai-compatible-chat")
        var config = ProviderConfig()
        config.sourceReference = reference
        config.refreshKey = "old-copied-key"
        let before = try Data(contentsOf: db)
        let first = try ProviderAuthentication.resolveBase(config)
        #expect(first.refreshKey == "fixture-first")
        #expect(try Data(contentsOf: db) == before)
        try sql(db, "UPDATE providerConnections SET data = \(ReadonlySQLite.literal(try record("fixture-second", base: "https://second.example.test/v1")))")
        let second = try ProviderAuthentication.resolveBase(config)
        #expect(second.refreshKey == "fixture-second")
        #expect(second.apiBaseURL == "https://second.example.test/v1")
        #expect(first.sourceRevision != second.sourceRevision)
        #expect(try ProviderAuthentication.resolveBase(first).refreshKey == "fixture-first")
        try sql(db, "UPDATE providerConnections SET provider='different-provider'")
        #expect(throws: ProviderAuthenticationError.self) { try ProviderAuthentication.resolveBase(config) }
        try sql(db, "DELETE FROM providerConnections")
        #expect(throws: ProviderAuthenticationError.self) { try ProviderAuthentication.resolveBase(config) }
    }

    @Test func fileReferenceNeverPersistsKeysOrWritesSourceAndRejectsChangedType() throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.json")
        let bytes = try JSONSerialization.data(withJSONObject: ["type": "clinepass", "api_key": "fixture-source-key"])
        try bytes.write(to: file)
        let reference = ProviderSourceReference(source: "cpamp", path: file.path, recordId: file.lastPathComponent, providerId: "clinepass")
        let manifest = ProviderManifest(name: "fixture", label: "Fixture", template: "cline", sourceReference: reference)
        var config = ProviderConfigStore.applyingManifest(manifest, to: ProviderConfig())
        config.refreshKey = "fixture-copy"
        config.queryKey = "fixture-query-copy"
        config.authContext = ["secret": "fixture-context-copy"]
        let account = directory.appendingPathComponent("account.json")
        try ProviderConfigStore.write(config, manifest: manifest, to: account)
        let saved = String(decoding: try Data(contentsOf: account), as: UTF8.self)
        #expect(!saved.contains("fixture-source-key"))
        #expect(!saved.contains("fixture-copy"))
        #expect(!saved.contains("fixture-query-copy"))
        #expect(!saved.contains("fixture-context-copy"))
        let draft = ProviderConfigStore.read(authFile: account, manifest: manifest)
        #expect(draft.refreshKey.isEmpty)
        let snapshot = try ProviderAuthentication.resolveBase(draft)
        #expect(snapshot.refreshKey == "fixture-source-key")
        #expect(throws: ProviderAuthenticationError.self) { try ProviderConfigStore.write(snapshot, manifest: manifest, to: account) }
        #expect(throws: ProviderAuthenticationError.self) { try ProviderConfigStore.write(config, manifest: manifest, to: file) }
        #expect(try Data(contentsOf: file) == bytes)
        try JSONSerialization.data(withJSONObject: ["type": "codex", "api_key": "fixture-wrong-type"]).write(to: file)
        #expect(throws: ProviderAuthenticationError.self) { try ImportedSource.read(reference) }
    }

    @Test func databaseOAuthUsesCompleteGenericLayoutAndTrustedColumnIdentity() throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let db = directory.appendingPathComponent("fake.sqlite")
        let raw = "{\"provider\":\"spoofed\",\"accessToken\":\"fixture-oauth-access\",\"account\":{\"id\":\"fixture-account\"}}"
        try sql(db, "CREATE TABLE providerConnections(id TEXT PRIMARY KEY, provider TEXT, authType TEXT, data TEXT); INSERT INTO providerConnections VALUES('oauth-row','fixture-provider','oauth',\(ReadonlySQLite.literal(raw)))")
        let reference = ProviderSourceReference(source: "9router", path: db.path, recordId: "oauth-row", providerId: "fixture-provider")
        let layout = ProviderCredentialSource(file: "", tokenPath: "accessToken", headerPaths: ["account-id": "account.id"], requiredValues: ["provider": "fixture-provider"], contextPaths: ["accountId": "account.id"])
        let manifest = ProviderManifest(name: "fixture", label: "Fixture", template: "fixture", authMode: "auth", credentialSource: layout,
            authCallUrl: "https://oauth.example.test/responses", authCallProtocol: "responses", sourceReference: reference)
        let config = ProviderConfigStore.applyingManifest(manifest, to: ProviderConfig())
        let snapshot = try ProviderAuthentication.resolveCall(config)
        #expect(snapshot.refreshKey == "fixture-oauth-access")
        #expect(snapshot.authContext["accountId"] == "fixture-account")
        #expect(snapshot.refreshHeader.contains("account-id: fixture-account"))
        #expect(snapshot.refreshUrl == "https://oauth.example.test/responses")
    }

    @Test func ccSwitchUsesExactAppTypeAndCurrentSettings() throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let db = directory.appendingPathComponent("fake.sqlite")
        let settings = "{\"env\":{\"ANTHROPIC_API_KEY\":\"fixture-claude-key\",\"ANTHROPIC_BASE_URL\":\"https://claude.example.test\"}}"
        try sql(db, "CREATE TABLE providers(id TEXT, app_type TEXT, settings_config TEXT, PRIMARY KEY(id,app_type)); INSERT INTO providers VALUES('same','claude',\(ReadonlySQLite.literal(settings))); INSERT INTO providers VALUES('same','codex','{}')")
        let reference = ProviderSourceReference(source: "cc-switch", path: db.path, recordId: "same", providerId: "claude")
        let record = try ImportedSource.read(reference)
        #expect(record.key == "fixture-claude-key")
        #expect(record.protocolName == "anthropic")
        try sql(db, "DELETE FROM providers WHERE app_type='claude'")
        #expect(throws: ProviderAuthenticationError.self) { try ImportedSource.read(reference) }
    }

    @Test func magpiePluginSlotMustStillBelongToOriginalProvider() throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("plugin-auth.json")
        try JSONSerialization.data(withJSONObject: ["google#abc123": ["type": "oauth", "access": "fixture-plugin-access"]]).write(to: file)
        try JSONSerialization.data(withJSONObject: ["providers": [["id": "google-plugin"]]]).write(to: directory.appendingPathComponent("providers.json"))
        let cache = directory.appendingPathComponent("plugin-providers.json")
        try JSONSerialization.data(withJSONObject: [["id": "google", "accounts": [["key": "google#abc123"]]]]).write(to: cache)
        let reference = ProviderSourceReference(source: "magpie", path: file.path, recordId: "google#abc123", providerId: "google-plugin", collection: "plugin-auth", credentialProviderId: "google")
        #expect(try ImportedSource.read(reference).object["access"] as? String == "fixture-plugin-access")
        try JSONSerialization.data(withJSONObject: [["id": "different", "accounts": [["key": "google#abc123"]]]]).write(to: cache)
        #expect(throws: ProviderAuthenticationError.self) { try ImportedSource.read(reference) }
    }

    @Test func magpieSelectorAndPrimaryKeyRotationReadCurrentSource() throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("providers.json")
        func save(_ key: String, selector: String = "responses") throws {
            try JSONSerialization.data(withJSONObject: ["providers": [["id": "b.ai", "key": key,
                "baseAPI": selector, "chat": "https://chat.example.test/v1", "responses": "https://responses.example.test/v1"]]])
                .write(to: file)
        }
        try save("fixture-magpie-first")
        let reference = ProviderSourceReference(source: "magpie", path: file.path, recordId: "b.ai", providerId: "b.ai", collection: "providers")
        let first = try ImportedSource.read(reference)
        #expect(first.protocolName == "responses")
        #expect(first.baseURL == "https://responses.example.test/v1")
        try save("fixture-magpie-second")
        #expect(try ImportedSource.read(reference).key == "fixture-magpie-second")
        try save("fixture-magpie-second", selector: "gemini")
        #expect(throws: ProviderAuthenticationError.self) { try ImportedSource.read(reference) }
    }

    @Test func magpieKeyProtocolsOverrideSelectorsAndUnrestrictedExtraKeysInherit() throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("providers.json")
        let key = "fixture-extra-key"
        let fingerprint = SHA256.hash(data: Data(key.utf8)).prefix(5).map { String(format: "%02x", $0) }.joined()
        let primary = ProviderSourceReference(source: "magpie", path: file.path, recordId: "fixture", providerId: "fixture", collection: "providers")
        let extra = ProviderSourceReference(source: "magpie", path: file.path, recordId: "fixture", providerId: "fixture", collection: "providers:key:" + fingerprint)
        func save(_ record: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: ["providers": [record]]).write(to: file)
        }
        try save(["id": "fixture", "key": "fixture-primary-key", "keyProtocol": "anthropic", "baseAPI": "chat",
                  "chat": "https://chat.example.test/v1", "anthropic": "https://anthropic.example.test"])
        #expect(try ImportedSource.read(primary).protocolName == "anthropic")
        #expect(try ImportedSource.read(primary).baseURL == "https://anthropic.example.test")
        for protocolValue in [nil, ""] as [String?] {
            var item: [String: Any] = ["key": key]
            item["protocol"] = protocolValue
            try save(["id": "fixture", "key": "fixture-primary-key", "anthropic": "https://anthropic.example.test", "keys": [item]])
            #expect(try ImportedSource.read(extra).key == key)
            #expect(try ImportedSource.read(extra).protocolName == "anthropic")
            try save(["id": "fixture", "baseAPI": "responses", "chat": "https://chat.example.test/v1",
                      "responses": "https://responses.example.test/v1", "keys": [item]])
            #expect(try ImportedSource.read(extra).protocolName == "responses")
        }
        try save(["id": "fixture", "keyProtocol": "anthropic", "chat": "https://chat.example.test/v1", "key": "fixture-primary-key"])
        #expect(throws: ProviderAuthenticationError.self) { try ImportedSource.read(primary) }
        try save(["id": "fixture", "chat": "https://chat.example.test/v1", "keys": [["key": key, "protocol": "anthropic"]]])
        #expect(throws: ProviderAuthenticationError.self) { try ImportedSource.read(extra) }
    }

    @Test func fixedMagpieTemplateRejectsRetypedRecordBeforeCallOrQuota() throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("providers.json")
        let templates = ProviderImporter.bundledTemplates()
        let glm = try #require(templates.first { $0.slug == "glm" })
        let ollama = try #require(templates.first { $0.slug == "ollama" })
        let glmURL = try #require(glm.manifest.refreshUrl)
        let ollamaURL = try #require(ollama.manifest.refreshUrl)
        func save(_ preset: String, url: String, key: String) throws {
            try JSONSerialization.data(withJSONObject: ["providers": [["id": "foo", "preset": preset,
                "key": key, "baseAPI": "anthropic", "anthropic": url]]]).write(to: file)
        }
        let reference = ProviderSourceReference(source: "magpie", path: file.path, recordId: "foo", providerId: "foo", collection: "providers")
        var manifest = glm.manifest
        manifest.template = "glm"
        manifest.sourceReference = reference
        try save("glm", url: glmURL, key: "fixture-glm-first")
        let config = ProviderConfigStore.read(authFile: directory.appendingPathComponent("account.json"), manifest: manifest)
        #expect(config.sourceTemplate == "glm")
        #expect(try ProviderAuthentication.resolveCall(config).refreshKey == "fixture-glm-first")
        try save("glm", url: glmURL, key: "fixture-glm-second")
        #expect(try ProviderAuthentication.resolveCall(config).refreshKey == "fixture-glm-second")
        #expect(try ProviderAuthentication.resolveQuota(config).queryKey == "fixture-glm-second")
        // An explicit conflicting identity must fail even when its URL still resembles GLM.
        try save("ollama", url: glmURL, key: "fixture-other-vendor")
        #expect(throws: ProviderAuthenticationError.self) { try ProviderAuthentication.resolveCall(config) }
        try save("ollama", url: ollamaURL, key: "fixture-ollama")
        let original = try Data(contentsOf: file)
        #expect(throws: ProviderAuthenticationError.self) { try ProviderAuthentication.resolveCall(config) }
        #expect(throws: ProviderAuthenticationError.self) { try ProviderAuthentication.resolveQuota(config) }
        #expect(try Data(contentsOf: file) == original)
        // A generic reference follows the same record's current URL and key.
        var generic = manifest
        generic.template = nil
        let custom = ProviderConfigStore.read(authFile: directory.appendingPathComponent("generic.json"), manifest: generic)
        let snapshot = try ProviderAuthentication.resolveCall(custom)
        #expect(snapshot.refreshKey == "fixture-ollama")
        #expect(snapshot.apiBaseURL == ollamaURL)
    }

    @Test func readonlySQLiteRejectsWritesAndTimesOutWithoutReturningRows() throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let db = directory.appendingPathComponent("fake.sqlite")
        try sql(db, "CREATE TABLE fixture(id TEXT PRIMARY KEY)")
        #expect(throws: ProviderAuthenticationError.self) {
            try ReadonlySQLite.query(path: db.path, sql: "INSERT INTO fixture VALUES('forbidden')")
        }
        #expect(throws: ProviderAuthenticationError.self) {
            try ReadonlySQLite.query(path: db.path, sql: "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n) SELECT sum(x) FROM n", timeout: 0.05)
        }
        #expect(try ReadonlySQLite.query(path: db.path, sql: "SELECT * FROM fixture").isEmpty)
    }
}
