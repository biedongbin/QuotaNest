import Foundation
import Testing
@testable import QuotaNest

@Suite struct AccountIdentityDedupTests {
    private func template() throws -> PluginProvider {
        try #require(ProviderImporter.bundledTemplates().first { $0.slug == "gpt" })
    }
    private func token(subject: String = "fixture-user", workspace: String = "workspace-A",
                       issuer: String = "https://auth.openai.com", rotation: Int = 1) throws -> String {
        func encode(_ object: [String: Any]) throws -> String {
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return try encode(["alg": "RS256"]) + "." + encode(["sub": subject, "iss": issuer, "iat": rotation,
            "https://api.openai.com/auth": ["chatgpt_account_id": workspace]]) + ".fixture-signature-\(rotation)"
    }
    private func record(_ object: [String: Any], mode: String = "auth") -> SourceRecord {
        SourceRecord(object: object, authMode: mode, key: "", baseURL: "", protocolName: "responses", model: "", revision: "fixture")
    }
    private func save(_ object: Any, at file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: file)
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quota-dedup-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func nativeCPAAndRouterFormatsMatchAfterTokenRotation() throws {
        let type = try template()
        let native = record(["auth_mode": "chatgpt", "tokens": ["access_token": try token(rotation: 1), "account_id": "workspace-A"]])
        let cpa = record(["type": "codex", "access_token": try token(rotation: 2), "account_id": "workspace-A"])
        let router = record(["provider": "codex", "accessToken": try token(rotation: 3), "providerSpecificData": ["accountId": "workspace-A"]])
        let first = try #require(ProviderAccountIdentity.fingerprint(record: native, template: type))
        #expect(ProviderAccountIdentity.fingerprint(record: cpa, template: type) == first)
        #expect(ProviderAccountIdentity.fingerprint(record: router, template: type) == first)
        #expect(!first.contains("fixture-user") && !first.contains("workspace-A"))
    }

    @Test func differentUserOrWorkspaceAndMissingEvidenceNeverMerge() throws {
        let type = try template()
        func fingerprint(subject: String = "fixture-user", workspace: String = "workspace-A", header: String? = nil) throws -> String? {
            ProviderAccountIdentity.fingerprint(record: record(["type": "codex", "access_token": try token(subject: subject, workspace: workspace),
                "account_id": header ?? workspace]), template: type)
        }
        let first = try #require(try fingerprint())
        #expect(try fingerprint(subject: "another-user") != first)
        #expect(try fingerprint(workspace: "workspace-B") != first)
        #expect(try fingerprint(header: "conflicting-workspace") == nil)
        #expect(ProviderAccountIdentity.fingerprint(record: record(["type": "codex", "access_token": "opaque", "account_id": "workspace-A"]), template: type) == nil)
        #expect(ProviderAccountIdentity.fingerprint(record: record(["type": "codex", "access_token": try token()]), template: type) == first)
        let noWorkspacePayload = Data(#"{"sub":"fixture-user","iss":"https://auth.openai.com"}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        #expect(ProviderAccountIdentity.fingerprint(record: record(["type": "codex", "access_token": "e30." + noWorkspacePayload + ".fixture"]), template: type) == nil)
        #expect(ProviderAccountIdentity.fingerprint(record: record(["type": "codex", "access_token": try token(issuer: "https://untrusted.invalid"), "account_id": "workspace-A"]), template: type) == nil)
        #expect(ProviderAccountIdentity.fingerprint(record: record([:], mode: "apikey"), template: type) == nil)
    }

    @Test func previewAndCommitRejectTheSameAccountFromAnotherSource() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let type = try template()
        let cpa = root.appendingPathComponent(".cli-proxy-api/first.json")
        try save(["type": "codex", "access_token": try token(), "account_id": "workspace-A"], at: cpa)
        let first = try #require(ProviderImporter.fromCPAMP(home: root.path, templates: [type]).first)
        let providers = root.appendingPathComponent("accounts"), hud = root.appendingPathComponent("hud")
        let slug = try ProviderImporter.apply(first, templates: [type], userDir: providers, hudDir: hud)
        let magpie = root.appendingPathComponent("magpie/logins.json")
        try save([["id": "different-source-id", "agent": "codex", "user": "Different display name",
                   "auth": ["auth_mode": "chatgpt", "tokens": ["access_token": try token(rotation: 2), "account_id": "workspace-A"]]]], at: magpie)
        let second = try #require(ProviderImporter.fromMagpie(home: root.path, sourceDirectory: magpie.deletingLastPathComponent().path, templates: [type]).first)
        let beforeSource = try Data(contentsOf: magpie)
        let beforeManifest = try Data(contentsOf: providers.appendingPathComponent(slug + "/manifest.json"))
        let saved = try #require(ProviderRegistry.scan(dir: providers).first)
        var oldManifest = saved.manifest
        oldManifest.credentialSource?.accountIdentity = nil // Already installed accounts predate the new declaration.
        let old = PluginProvider(slug: saved.slug, manifest: oldManifest, dir: saved.dir)
        let index = ProviderAccountIdentity.index(providers: [old], templates: [type])
        #expect(index[slug] == second.accountIdentity)
        #expect(ImportCenterModel.stateOf(second, existing: [old], accountIdentities: index,
            templateLookup: { _ in type.manifest }) == .duplicate)
        #expect(!ImportCenterModel.RowState.duplicate.pickable)
        #expect(throws: (any Error).self) {
            try ProviderImporter.apply(second, templates: [type], userDir: providers, hudDir: hud)
        }
        #expect(ProviderRegistry.scan(dir: providers).count == 1)
        #expect(try Data(contentsOf: magpie) == beforeSource)
        #expect(try Data(contentsOf: providers.appendingPathComponent(slug + "/manifest.json")) == beforeManifest)
    }

    @Test func concurrentDifferentRecordsCreateOnlyOneAccount() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let type = try template()
        for index in 1...2 {
            try save(["type": "codex", "access_token": try token(rotation: index), "account_id": "workspace-A"],
                     at: root.appendingPathComponent(".cli-proxy-api/\(index).json"))
        }
        let candidates = ProviderImporter.fromCPAMP(home: root.path, templates: [type])
        #expect(candidates.count == 2)
        let providers = root.appendingPathComponent("accounts"), hud = root.appendingPathComponent("hud")
        let successes = await withTaskGroup(of: Bool.self) { group in
            for candidate in candidates {
                group.addTask {
                    (try? ProviderImporter.apply(candidate, templates: [type], userDir: providers, hudDir: hud)) != nil
                }
            }
            var count = 0
            for await success in group { if success { count += 1 } }
            return count
        }
        #expect(successes == 1)
        #expect(ProviderRegistry.scan(dir: providers).count == 1)
    }
}
