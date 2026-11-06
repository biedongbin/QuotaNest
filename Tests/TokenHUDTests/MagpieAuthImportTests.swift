import Foundation
import Testing
@testable import QuotaNest

@Suite struct MagpieAuthImportTests {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("magpie-auth-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func write(_ object: Any, _ file: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: file)
    }
    private var jwt: String {
        let header = Data(#"{"alg":"none"}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let payload = Data(#"{"sub":"fixture-user","exp":4102444800}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return header + "." + payload + ".fixture-signature"
    }
    private func config(_ row: ImportCandidate, directory: URL) throws -> ProviderConfig {
        let template = try #require(ProviderImporter.bundledTemplates().first { $0.slug == row.template })
        var config = ProviderConfigStore.read(authFile: directory.appendingPathComponent("not-created.json"), manifest: template.manifest)
        config.authMode = "auth"
        config.sourceReference = row.sourceReference
        config.sourceTemplate = template.slug
        config.sourceEndpointIsFixed = true
        return config
    }

    @Test func nativeCodexInlineSnapshotIsImportableAndNeverUsesRoutingOnAsEnabled() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("logins.json")
        func save(token: String, account: String = "workspace-A") throws {
            try write([["id": "login-A", "agent": "codex", "user": "fixture@example.test", "on": false,
                        "auth": ["auth_mode": "chatgpt", "tokens": ["access_token": token, "account_id": account]]]], file)
        }
        try save(token: "fixture-token-A")
        let row = try #require(ProviderImporter.fromMagpie(home: dir.path, sourceDirectory: dir.path).first)
        #expect(row.template == "gpt" && row.unsupportedReason == nil && row.enabled)
        #expect(row.apiKey.isEmpty && row.sourceRecordId == "login-A")
        let original = try Data(contentsOf: file)
        let cfg = try config(row, directory: dir)
        #expect(try ProviderAuthentication.resolveQuota(cfg).refreshKey == "fixture-token-A")
        #expect(try Data(contentsOf: file) == original)
        try save(token: "fixture-token-B")
        #expect(try ProviderAuthentication.resolveQuota(cfg).refreshKey == "fixture-token-B")
        #expect(try ImportedSource.references(in: try #require(row.sourceReference)).count == 1)
        try save(token: "fixture-token-C", account: "workspace-B")
        #expect(throws: (any Error).self) { try ProviderAuthentication.resolveQuota(cfg) }
    }

    @Test func nativeRecordMustRemainUniqueAndKeepTheSameAgent() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("logins.json")
        let item: [String: Any] = ["id": "login-A", "agent": "codex", "auth": ["auth_mode": "chatgpt", "tokens": ["access_token": "fixture-token", "account_id": "A"]]]
        try write([item], file)
        let row = try #require(ProviderImporter.fromMagpie(home: dir.path, sourceDirectory: dir.path).first)
        let reference = try #require(row.sourceReference)
        try write([item, item], file)
        #expect(throws: (any Error).self) { try ImportedSource.read(reference) }
        var changed = item; changed["agent"] = "other"
        try write([changed], file)
        #expect(throws: (any Error).self) { try ImportedSource.read(reference) }
    }

    @Test func zcodeStartPrefersNestedJWTOverPlanKeyAndKeepsTheExactSlot() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let refresh = String(decoding: try JSONSerialization.data(withJSONObject: ["jwt": jwt, "key": "fixture-plan-key", "device": "fixture-device", "source": "zcode"]), as: UTF8.self)
        try write(["providers": [["id": "zcode-plugin", "off": false]]], dir.appendingPathComponent("providers.json"))
        let auth: [String: Any] = ["type": "oauth", "access": "fixture-plan-key", "refresh": refresh, "accountId": "fixture-account", "expires": 0]
        try write(["zcode": auth], dir.appendingPathComponent("plugin-auth.json"))
        try write([["id": "zcode", "name": "ZCode", "accounts": [["key": "zcode", "type": "oauth", "accountId": "fixture-account"]]]], dir.appendingPathComponent("plugin-providers.json"))
        let row = try #require(ProviderImporter.fromMagpie(home: dir.path, sourceDirectory: dir.path).first)
        #expect(row.template == "zcode-start" && row.unsupportedReason == nil)
        #expect(row.sourceReference?.providerId == "zcode-plugin")
        #expect(row.sourceReference?.credentialProviderId == "zcode" && row.sourceRecordId == "zcode")
        let resolved = try ProviderAuthentication.resolveQuota(config(row, directory: dir))
        #expect(resolved.queryKey == jwt && resolved.refreshKey == jwt)
        #expect(resolved.authContext["device"] == "fixture-device" && resolved.authContext["expiresAt"] == "0")
        #expect(resolved.queryUrl.hasPrefix("https://zcode.z.ai/"))
        let providers = dir.appendingPathComponent("accounts"), hud = dir.appendingPathComponent("hud")
        try ProviderImporter.apply(row, templates: ProviderImporter.bundledTemplates(), userDir: providers, hudDir: hud)
        for root in [providers, hud] {
            for file in (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []) where file.pathExtension == "json" {
                let text = try String(contentsOf: file, encoding: .utf8)
                #expect(!text.contains(jwt) && !text.contains("fixture-plan-key") && !text.contains("fixture-device"))
            }
        }
        var changed = auth; changed["accountId"] = "another-account"
        try write(["zcode": changed], dir.appendingPathComponent("plugin-auth.json"))
        #expect(throws: (any Error).self) { try ImportedSource.read(try #require(row.sourceReference)) }
    }

    @Test func pluginWithoutAccountIDPinsTheJWTSubjectAndRejectsUnidentifiableAuth() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try write(["providers": [["id": "zcode"]]], dir.appendingPathComponent("providers.json"))
        try write([["id": "zcode", "accounts": [["key": "zcode", "type": "oauth"]]]], dir.appendingPathComponent("plugin-providers.json"))
        func save(_ token: String) throws {
            let refresh = String(decoding: try JSONSerialization.data(withJSONObject: ["jwt": token, "device": "device"]), as: UTF8.self)
            try write(["zcode": ["type": "oauth", "refresh": refresh]], dir.appendingPathComponent("plugin-auth.json"))
        }
        try save(jwt)
        let row = try #require(ProviderImporter.fromMagpie(home: dir.path, sourceDirectory: dir.path).first)
        #expect(row.unsupportedReason == nil && row.sourceReference?.identityAccount != nil)
        let header = jwt.split(separator: ".")[0]
        let changedPayload = Data(#"{"sub":"different-user","exp":4102444800}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        try save(String(header) + "." + changedPayload + ".fixture-signature")
        #expect(throws: (any Error).self) { try ImportedSource.read(try #require(row.sourceReference)) }
        let noSubject = Data(#"{"exp":4102444800}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        try save(String(header) + "." + noSubject + ".fixture-signature")
        #expect(ProviderImporter.fromMagpie(home: dir.path, sourceDirectory: dir.path).first?.unsupportedReason != nil)
    }

    @Test func anOpaquePlanKeyDoesNotBecomeAStartJWT() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try write(["providers": [["id": "zcode"]]], dir.appendingPathComponent("providers.json"))
        try write(["zcode": ["type": "oauth", "access": "fixture-plan-key", "accountId": "fixture-account", "device": "device"]], dir.appendingPathComponent("plugin-auth.json"))
        try write([["id": "zcode", "accounts": [["key": "zcode", "type": "oauth", "accountId": "fixture-account"]]]], dir.appendingPathComponent("plugin-providers.json"))
        let row = try #require(ProviderImporter.fromMagpie(home: dir.path, sourceDirectory: dir.path).first)
        #expect(row.unsupportedReason != nil)
    }
}
