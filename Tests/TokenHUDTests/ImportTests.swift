import Foundation
import CryptoKit
import Testing
@testable import QuotaNest

/// Every source, database, registry and HUD used here is an isolated temporary fixture.
@Suite
struct ImportTests {
    private func tmpHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("th-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func write(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }

    private func database(_ url: URL, sql: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProviderImporter.sqlite)
        process.arguments = [url.path, sql]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func keyTemplate(_ slug: String, home: URL, endpoint: String = "https://official.invalid/v1/chat/completions") throws -> PluginProvider {
        let dir = home.appendingPathComponent("templates/" + slug)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: dir.appendingPathComponent("fetch.sh"), atomically: true, encoding: .utf8)
        return PluginProvider(slug: slug, manifest: ProviderManifest(name: slug, label: slug,
            cacheFile: "unused", queryAuth: "bearer", refreshUrl: endpoint, refreshProtocol: "openai",
            quotaMode: "script", quotaAuthModes: ["apikey"]), dir: dir)
    }

    private func authTemplate(_ slug: String, provider: String, home: URL) throws -> PluginProvider {
        let dir = home.appendingPathComponent("templates/" + slug)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: dir.appendingPathComponent("fetch.sh"), atomically: true, encoding: .utf8)
        let source = ProviderCredentialSource(file: "/unused", tokenPath: "accessToken",
            requiredValues: ["provider": provider], alternatives: [ProviderCredentialFormat(tokenPath: "access_token", requiredValues: ["type": provider])])
        return PluginProvider(slug: slug, manifest: ProviderManifest(name: slug, label: slug,
            cacheFile: "unused", queryAuth: "header", authMode: "auth", quotaMode: "script",
            quotaAuthModes: ["auth"], credentialSource: source), dir: dir)
    }

    private func magpie(_ home: URL, key: String = "FAKE_SOURCE_KEY") throws -> URL {
        let root = home.appendingPathComponent("magpie-data")
        try write(["providers": [["id": "b.ai", "name": "Demo relay", "key": key,
            "chat": "https://relay.invalid/v1", "anthropic": "https://relay.invalid", "baseAPI": "chat"]]],
            to: root.appendingPathComponent("providers.json"))
        return root
    }

    private func applyFixture(_ home: URL) throws -> (ImportCandidate, URL, URL) {
        let root = try magpie(home)
        let c = try #require(ProviderImporter.fromMagpie(home: home.path, sourceDirectory: root.path, templates: []).first)
        return (c, home.appendingPathComponent("accounts"), home.appendingPathComponent("hud"))
    }

    @Test func nineRouterRetainsPrimaryIDsAndInactiveRowsWithoutSecrets() throws {
        let home = try tmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let db = home.appendingPathComponent(".9router/db/data.sqlite")
        try database(db, sql: """
        CREATE TABLE providerConnections (id TEXT, provider TEXT, authType TEXT, name TEXT, isActive INT, data TEXT);
        INSERT INTO providerConnections VALUES ('conn-1','glm','apikey','Demo',1,'{"apiKey":"FAKE_GLM"}');
        INSERT INTO providerConnections VALUES ('conn-2','anthropic-compatible-x','apikey','Relay',0,'{"apiKey":"FAKE_RELAY","providerSpecificData":{"baseUrl":"https://relay.invalid"}}');
        INSERT INTO providerConnections VALUES ('conn-3','unknown-vendor','apikey','Unknown',1,'{"apiKey":"FAKE_OTHER","baseUrl":"https://other.invalid"}');
        """)
        let template = try keyTemplate("glm", home: home)
        let rows = ProviderImporter.from9Router(home: home.path, templates: [template])
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.apiKey.isEmpty })
        let glm = try #require(rows.first { $0.sourceRecordId == "conn-1" })
        #expect(glm.template == "glm")
        #expect(glm.sourceReference?.providerId == "glm")
        #expect(glm.unsupportedReason == nil)
        let relay = try #require(rows.first { $0.sourceRecordId == "conn-2" })
        #expect(!relay.enabled)
        #expect(relay.proto == "anthropic")
        #expect(relay.unsupportedReason == nil)
        #expect(rows.first { $0.sourceRecordId == "conn-3" }?.unsupportedReason != nil)
        let bytes = try Data(contentsOf: db)
        #expect(bytes.count > 0)
    }

    @Test func nineRouterOAuthUsesDeclaredFormatsAndMasksAccount() throws {
        let home = try tmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try database(home.appendingPathComponent(".9router/db/data.sqlite"), sql: """
        CREATE TABLE providerConnections (id TEXT, provider TEXT, authType TEXT, name TEXT, isActive INT, data TEXT);
        INSERT INTO providerConnections VALUES ('original-pk','codex','oauth','demo@example.invalid',1,'{"accessToken":"FAKE_ACCESS"}');
        """)
        let template = try authTemplate("gpt", provider: "codex", home: home)
        let row = try #require(ProviderImporter.from9Router(home: home.path, templates: [template]).first)
        #expect(row.template == "gpt")
        #expect(row.unsupportedReason == nil)
        #expect(row.sourceRecordId == "original-pk")
        #expect(!row.name.contains("demo@example.invalid"))
        #expect(row.apiKey.isEmpty)
        #expect(row.authLabel == "Auth")
    }

    @Test func ccSwitchNamespacesSamePrimaryKeyAndKeepsUnsupportedVisible() throws {
        let home = try tmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try database(home.appendingPathComponent(".cc-switch/cc-switch.db"), sql: """
        CREATE TABLE providers (id TEXT, app_type TEXT, name TEXT, settings_config TEXT);
        INSERT INTO providers VALUES ('same','claude','Relay','{"env":{"ANTHROPIC_BASE_URL":"https://relay.invalid","ANTHROPIC_AUTH_TOKEN":"FAKE_CC_KEY"}}');
        INSERT INTO providers VALUES ('same','codex','Codex','{"auth":{}}');
        """)
        let rows = ProviderImporter.fromCCSwitch(home: home.path, templates: [])
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.origin)).count == 2)
        #expect(rows.allSatisfy { $0.sourceRecordId == "same" && $0.apiKey.isEmpty })
        #expect(rows.first { $0.sourceReference?.collection == "claude" }?.unsupportedReason == nil)
        #expect(rows.first { $0.sourceReference?.collection == "codex" }?.unsupportedReason != nil)
    }

    @Test func cpampUsesDeclaredTypesAndAuthFormatsIncludingDisabled() throws {
        let home = try tmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent(".cli-proxy-api")
        try write(["type": "codex", "access_token": "FAKE_ACCESS", "disabled": true], to: dir.appendingPathComponent("original.json"))
        try write(["type": "not-supported", "api_key": "FAKE_OTHER"], to: dir.appendingPathComponent("other.json"))
        let template = try authTemplate("gpt", provider: "codex", home: home)
        let rows = ProviderImporter.fromCPAMP(home: home.path, templates: [template])
        #expect(rows.count == 2)
        let row = try #require(rows.first { $0.sourceRecordId == "original.json" })
        #expect(row.template == "gpt")
        #expect(row.unsupportedReason == nil)
        #expect(!row.enabled)
        #expect(row.apiKey.isEmpty)
        #expect(rows.first { $0.sourceRecordId == "other.json" }?.unsupportedReason != nil)
    }

    @Test func magpieDefaultsRespectOnlyAbsoluteXDG() {
        #expect(ProviderImporter.magpieRoot(home: "/fixture", environment: [:]) == "/fixture/.config/magpie")
        #expect(ProviderImporter.magpieRoot(home: "/fixture", environment: ["XDG_CONFIG_HOME": "/xdg"]) == "/xdg/magpie")
        #expect(ProviderImporter.magpieRoot(home: "/fixture", environment: ["XDG_CONFIG_HOME": "relative"]) == "/fixture/.config/magpie")
    }

    @Test func magpieKeepsExactProviderAndKeyAccountIDs() throws {
        let home = try tmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("portable/data")
        try write(["providers": [["id": "b.ai", "name": "Relay", "key": "FAKE_MAIN", "chat": "https://relay.invalid/v1",
            "keys": [["key": "FAKE_EXTRA", "name": "Other", "off": true]]]]], to: root.appendingPathComponent("providers.json"))
        let rows = ProviderImporter.fromMagpie(home: home.path, sourceDirectory: root.path, templates: [])
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.sourceRecordId == "b.ai" && $0.sourceReference?.providerId == "b.ai" && $0.apiKey.isEmpty })
        let hash = SHA256.hash(data: Data("FAKE_EXTRA".utf8)).prefix(5).map { String(format: "%02x", $0) }.joined()
        let extra = try #require(rows.first { $0.sourceReference?.collection == "providers:key:" + hash })
        #expect(!extra.enabled)
        #expect(extra.unsupportedReason == nil)
    }

    @Test func magpiePluginRequiresExactCachedSlotAndStoredActualID() throws {
        let home = try tmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("portable")
        try write(["providers": [["id": "codex-plugin", "name": "Codex plugin"]]], to: root.appendingPathComponent("providers.json"))
        try write(["codex#slot01": ["type": "oauth", "access_token": "FAKE_PLUGIN_ACCESS", "typeMarker": "unused", "provider": "codex"]],
                  to: root.appendingPathComponent("plugin-auth.json"))
        // A declared Auth format can consume this plugin's access_token/provider layout.
        let dir = home.appendingPathComponent("template")
        let source = ProviderCredentialSource(file: "/unused", tokenPath: "access_token", requiredValues: ["provider": "codex"])
        let template = PluginProvider(slug: "gpt", manifest: ProviderManifest(name: "GPT", label: "GPT", cacheFile: "unused",
            authMode: "auth", quotaMode: "script", quotaAuthModes: ["auth"], credentialSource: source), dir: dir)
        let cache: [[String: Any]] = [["id": "codex", "spec": "fake-plugin", "name": "Codex plugin",
            "accounts": [["key": "codex#slot01", "type": "oauth", "accountId": "demo"]]]]
        try write(cache, to: root.appendingPathComponent("plugin-providers.json"))
        let row = try #require(ProviderImporter.fromMagpie(home: home.path, sourceDirectory: root.path, templates: [template]).first)
        #expect(row.sourceReference?.providerId == "codex-plugin")
        #expect(row.sourceReference?.credentialProviderId == "codex")
        #expect(row.sourceRecordId == "codex#slot01")
        #expect(row.unsupportedReason == nil)
        try write([["id": "codex", "accounts": [["key": "codex#other"]]]], to: root.appendingPathComponent("plugin-providers.json"))
        #expect(ProviderImporter.fromMagpie(home: home.path, sourceDirectory: root.path, templates: [template]).first?.unsupportedReason != nil)
    }

    @Test func magpieNativeLoginIsVisibleButNeverCopiesAuth() throws {
        let home = try tmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("source")
        try write([["id": "stable-login", "agent": "codex", "user": "demo@example.invalid", "auth": ["access_token": "FAKE_NATIVE"]]],
                  to: root.appendingPathComponent("logins.json"))
        let row = try #require(ProviderImporter.fromMagpie(home: home.path, sourceDirectory: root.path, templates: []).first)
        #expect(row.sourceRecordId == "stable-login")
        #expect(row.unsupportedReason?.contains("Keychain") == true)
        #expect(row.apiKey.isEmpty)
    }

    @Test func templateMatchingUsesIdentityAndEndpointNeverDisplayName() throws {
        let home = try tmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let glm = try keyTemplate("glm", home: home, endpoint: "https://glm.invalid/v1/chat/completions")
        let zai = try keyTemplate("zai-coding", home: home, endpoint: "https://zai.invalid/v1/messages")
        #expect(ProviderImporter.matchingTemplate(provider: "glm", base: "https://zai.invalid/v1", templates: [glm, zai])?.slug == "glm")
        #expect(ProviderImporter.matchingTemplate(provider: "glm-cn", base: "", templates: [glm, zai])?.slug == "glm")
        #expect(ProviderImporter.matchingTemplate(provider: "custom", base: "https://GLM.invalid/v1/", templates: [glm, zai])?.slug == "glm")
        #expect(ProviderImporter.matchingTemplate(provider: "Friendly GLM", base: "", templates: [glm, zai]) == nil)
    }

    @Test func nestedV1EndpointMatchingPreservesHostSchemeAndOtherPaths() throws {
        let home = try tmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let glm = try keyTemplate("glm", home: home,
            endpoint: "https://open.bigmodel.cn/api/anthropic/v1/messages")
        #expect(ProviderImporter.matchingTemplate(provider: "custom", base: "https://open.bigmodel.cn/api/anthropic", templates: [glm])?.slug == "glm")
        #expect(ProviderImporter.matchingTemplate(provider: "custom", base: "https://open.bigmodel.cn/api/anthropic/v1/messages", templates: [glm])?.slug == "glm")
        #expect(ProviderImporter.matchingTemplate(provider: "custom", base: "https://other.invalid/api/anthropic", templates: [glm]) == nil)
        #expect(ProviderImporter.matchingTemplate(provider: "custom", base: "http://open.bigmodel.cn/api/anthropic", templates: [glm]) == nil)
        #expect(ProviderImporter.matchingTemplate(provider: "custom", base: "https://open.bigmodel.cn/other/anthropic", templates: [glm]) == nil)
        #expect(ProviderImporter.matchingTemplate(provider: "custom", base: "https://open.bigmodel.cn/api/anthropic/v2", templates: [glm]) == nil)
    }

    @Test func knownExcludedTemplateDoesNotBecomeGeneric() throws {
        let home = try tmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let root = try magpie(home)
        let unsupported = PluginProvider(slug: "b.ai", manifest: ProviderManifest(name: "Excluded", label: "Excluded", quotaMode: "none"), dir: home)
        let row = try #require(ProviderImporter.fromMagpie(home: home.path, sourceDirectory: root.path, templates: [unsupported]).first)
        #expect(row.template == "b.ai")
        #expect(row.unsupportedReason != nil)
    }

    @Test func applyWritesReferenceOnlyAndFollowsRotatedSourceKey() throws {
        let home = try tmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let (candidate, userDir, hudDir) = try applyFixture(home)
        let source = try #require(candidate.sourceReference)
        let before = try Data(contentsOf: URL(fileURLWithPath: source.path))
        let slug = try ProviderImporter.apply(candidate, templates: [], userDir: userDir, hudDir: hudDir)
        #expect(try Data(contentsOf: URL(fileURLWithPath: source.path)) == before)
        let manifestURL = userDir.appendingPathComponent(slug + "/manifest.json")
        let authURL = hudDir.appendingPathComponent(".\(slug)-usage-auth.json")
        let manifest = try JSONDecoder().decode(ProviderManifest.self, from: Data(contentsOf: manifestURL))
        #expect(manifest.sourceReference == source)
        #expect(manifest.isSourceConfigurationReadOnly)
        #expect(manifest.origin == "magpie:b.ai")
        for file in [manifestURL, authURL] {
            #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("FAKE_SOURCE_KEY"))
        }
        let config = ProviderConfigStore.read(authFile: authURL, manifest: manifest)
        #expect(config.refreshKey.isEmpty)
        #expect(try ProviderAuthentication.resolveBase(config).refreshKey == "FAKE_SOURCE_KEY")
        _ = try magpie(home, key: "FAKE_ROTATED_KEY")
        #expect(try ProviderAuthentication.resolveBase(config).refreshKey == "FAKE_ROTATED_KEY")
        #expect(throws: (any Error).self) {
            _ = try ProviderImporter.apply(candidate, templates: [], userDir: userDir, hudDir: hudDir)
        }
    }

    @Test func applyRejectsMissingOrChangedReferenceBeforeWriting() throws {
        let home = try tmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let (candidate, userDir, hudDir) = try applyFixture(home)
        let noReference = ImportCandidate(source: "legacy", name: "Unsafe", template: nil, apiKey: "FAKE_KEY", baseURL: "https://relay.invalid", proto: "openai", note: "")
        #expect(throws: (any Error).self) { _ = try ProviderImporter.apply(noReference, templates: [], userDir: userDir, hudDir: hudDir) }
        let source = try #require(candidate.sourceReference)
        try write(["providers": []], to: URL(fileURLWithPath: source.path))
        #expect(throws: (any Error).self) { _ = try ProviderImporter.apply(candidate, templates: [], userDir: userDir, hudDir: hudDir) }
        #expect(!FileManager.default.fileExists(atPath: userDir.path))
    }

    @Test func applyConflictLeavesNoStagingAndPreservesExistingFile() throws {
        let home = try tmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let (candidate, userDir, hudDir) = try applyFixture(home)
        try FileManager.default.createDirectory(at: hudDir, withIntermediateDirectories: true)
        let original = hudDir.appendingPathComponent(".b-ai-usage-auth.json")
        try Data("{}".utf8).write(to: original)
        #expect(throws: (any Error).self) { _ = try ProviderImporter.apply(candidate, templates: [], userDir: userDir, hudDir: hudDir) }
        #expect(try String(contentsOf: original, encoding: .utf8) == "{}")
        #expect((try FileManager.default.contentsOfDirectory(atPath: userDir.path)).isEmpty)
    }

    @Test func dedupUsesFullSourceIdentityAndLegacyOrigin() throws {
        let home = try tmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let (candidate, _, _) = try applyFixture(home)
        var manifest = ProviderManifest(name: "Existing", label: "Existing", sourceReference: candidate.sourceReference)
        #expect(ProviderImporter.matchesExisting(candidate, manifest: manifest))
        var other = try #require(candidate.sourceReference)
        other = ProviderSourceReference(source: other.source, path: other.path + ".other", recordId: other.recordId,
            providerId: other.providerId, collection: other.collection)
        manifest.sourceReference = other
        #expect(!ProviderImporter.matchesExisting(candidate, manifest: manifest))
        manifest.sourceReference = nil
        manifest.origin = candidate.origin
        #expect(ProviderImporter.matchesExisting(candidate, manifest: manifest))
        #expect(ImportCenterModel.stateOf(candidate, existing: [], templateLookup: { _ in nil }) == .unadapted)
    }

    @Test func genericAnthropicUsesAPIKeyHeader() throws {
        let home = try tmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("source")
        try write(["providers": [["id": "relay", "name": "Relay", "key": "FAKE_KEY", "anthropic": "https://relay.invalid"]]],
                  to: root.appendingPathComponent("providers.json"))
        let row = try #require(ProviderImporter.fromMagpie(home: home.path, sourceDirectory: root.path, templates: []).first)
        let userDir = home.appendingPathComponent("accounts")
        let slug = try ProviderImporter.apply(row, templates: [], userDir: userDir, hudDir: home.appendingPathComponent("hud"))
        let manifest = try JSONDecoder().decode(ProviderManifest.self, from: Data(contentsOf: userDir.appendingPathComponent(slug + "/manifest.json")))
        #expect(manifest.refreshHeader?.contains("x-api-key: <key>") == true)
        #expect(manifest.refreshHeader?.contains("Authorization: Bearer") == false)
    }

    @Test func legacyOriginConvertsInPlaceAndRemovesCopiedSecrets() throws {
        let home = try tmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let (candidate, userDir, hudDir) = try applyFixture(home)
        let slug = try ProviderImporter.apply(candidate, templates: [], userDir: userDir, hudDir: hudDir)
        let manifestURL = userDir.appendingPathComponent(slug + "/manifest.json")
        let authURL = hudDir.appendingPathComponent(".\(slug)-usage-auth.json")
        let cacheURL = hudDir.appendingPathComponent(".\(slug)-usage-cache.json")
        var manifest = try JSONDecoder().decode(ProviderManifest.self, from: Data(contentsOf: manifestURL))
        manifest.sourceReference = nil
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        try write(["refreshApiKey": "FAKE_OLD_COPY", "headers": ["Authorization": "Bearer FAKE_OLD_COPY"]], to: authURL)
        try write(["buckets": ["old": 1]], to: cacheURL)
        let source = try #require(candidate.sourceReference)
        let sourceBefore = try Data(contentsOf: URL(fileURLWithPath: source.path))
        #expect(ImportCenterModel.stateOf(candidate, existing: ProviderRegistry.scan(dir: userDir), templateLookup: { _ in nil }) == .unadapted)
        let converted = try ProviderImporter.apply(candidate, templates: [], userDir: userDir, hudDir: hudDir)
        #expect(converted == slug)
        #expect(ProviderRegistry.scan(dir: userDir).count == 1)
        #expect(!(try String(contentsOf: authURL, encoding: .utf8)).contains("FAKE_OLD_COPY"))
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path))
        #expect(try Data(contentsOf: URL(fileURLWithPath: source.path)) == sourceBefore)
        let convertedManifest = try JSONDecoder().decode(ProviderManifest.self, from: Data(contentsOf: manifestURL))
        #expect(convertedManifest.sourceReference == source)
        #expect(ImportCenterModel.stateOf(candidate, existing: ProviderRegistry.scan(dir: userDir), templateLookup: { _ in nil }) == .exists)
        _ = try magpie(home, key: "FAKE_UPDATED_AFTER_CONVERSION")
        let config = ProviderConfigStore.read(authFile: authURL, manifest: convertedManifest)
        #expect(try ProviderAuthentication.resolveBase(config).refreshKey == "FAKE_UPDATED_AFTER_CONVERSION")
    }

    @Test func legacyConversionRejectsChangedSupplierOrProtocolWithoutWriting() throws {
        let cases: [(oldTemplate: String?, provider: String, oldProtocol: String)] = [
            ("glm", "ollama", "openai"),
            (nil, "ollama", "openai"),
            ("glm", "openai-compatible-relay", "openai"),
            (nil, "openai-compatible-relay", "anthropic")
        ]
        for scenario in cases {
            let home = try tmpHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let db = home.appendingPathComponent(".9router/db/data.sqlite")
            try database(db, sql: """
            CREATE TABLE providerConnections (id TEXT, provider TEXT, authType TEXT, name TEXT, isActive INT, data TEXT);
            INSERT INTO providerConnections VALUES ('row1','\(scenario.provider)','apikey','Current source',1,'{"apiKey":"FAKE_OLLAMA_KEY","providerSpecificData":{"baseUrl":"https://source.invalid/v1"}}');
            """)
            let templates = [try keyTemplate("ollama", home: home)]
            let candidate = try #require(ProviderImporter.from9Router(home: home.path, templates: templates).first)
            #expect(candidate.unsupportedReason == nil)
            let userDir = home.appendingPathComponent("accounts")
            let hudDir = home.appendingPathComponent("hud")
            let slug = "legacy-account"
            let authURL = PluginGenerator.expandPath(PluginGenerator.authPath(slug: slug, hudDir: hudDir))
            let cacheURL = PluginGenerator.expandPath(PluginGenerator.cachePath(slug: slug, hudDir: hudDir))
            let manifestURL = userDir.appendingPathComponent(slug + "/manifest.json")
            let manifest = ProviderManifest(name: "Old supplier", label: "Old supplier",
                cacheFile: cacheURL.path, authFile: authURL.path,
                refreshUrl: "https://old-glm.invalid/v1/chat/completions", refreshProtocol: scenario.oldProtocol,
                refreshHeader: "Authorization: Bearer <key>", template: scenario.oldTemplate, origin: "9router:row1")
            try PluginGenerator.writePlugin(slug: slug, manifest: manifest, script: "#!/bin/sh\nexit 0\n", into: userDir)
            try write(["refreshApiKey": "FAKE_OLD_GLM_COPY"], to: authURL)
            try write(["old": "cache"], to: cacheURL)
            let files = [manifestURL, authURL, cacheURL, db]
            let before = try files.map { try Data(contentsOf: $0) }
            #expect(throws: (any Error).self) {
                _ = try ProviderImporter.apply(candidate, templates: templates, userDir: userDir, hudDir: hudDir)
            }
            #expect(try files.map { try Data(contentsOf: $0) } == before)
            #expect(try JSONDecoder().decode(ProviderManifest.self, from: Data(contentsOf: manifestURL)).sourceReference == nil)
            #expect(ProviderRegistry.scan(dir: userDir).count == 1)
        }
    }

    @Test func failedLegacySourceValidationPreservesOriginalFiles() throws {
        let home = try tmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let (candidate, userDir, hudDir) = try applyFixture(home)
        let slug = try ProviderImporter.apply(candidate, templates: [], userDir: userDir, hudDir: hudDir)
        let manifestURL = userDir.appendingPathComponent(slug + "/manifest.json")
        let authURL = hudDir.appendingPathComponent(".\(slug)-usage-auth.json")
        var manifest = try JSONDecoder().decode(ProviderManifest.self, from: Data(contentsOf: manifestURL))
        manifest.sourceReference = nil
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        try write(["refreshApiKey": "FAKE_LEGACY_COPY"], to: authURL)
        let oldManifest = try Data(contentsOf: manifestURL)
        let oldAuth = try Data(contentsOf: authURL)
        let reference = try #require(candidate.sourceReference)
        try write(["providers": []], to: URL(fileURLWithPath: reference.path))
        #expect(throws: (any Error).self) {
            _ = try ProviderImporter.apply(candidate, templates: [], userDir: userDir, hudDir: hudDir)
        }
        #expect(try Data(contentsOf: manifestURL) == oldManifest)
        #expect(try Data(contentsOf: authURL) == oldAuth)
    }

    @Test @MainActor func cancelImportLeavesUnstartedRowsAndRetrySucceeds() async throws {
        let home = try tmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let (first, userDir, hudDir) = try applyFixture(home)
        let (second, _, _) = try applyFixture(home.appendingPathComponent("other-source"))
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hudDir, withIntermediateDirectories: true)
        let suite = "th-import-cancel-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = DataEngine(hudDir: hudDir, bundleProvidersDir: nil, userProvidersDir: userDir,
            runner: ProviderRunner(nodePath: nil, logDir: hudDir), defaults: defaults,
            settingsURL: home.appendingPathComponent("settings.json"))
        let model = ImportCenterModel(engine: engine, hudDir: hudDir, userDir: userDir)
        // Exercise cancellation after eligibility has already admitted the fixture rows.
        model.rows = [ImportCenterModel.Row(candidate: first, state: .addable, note: ""),
                      ImportCenterModel.Row(candidate: second, state: .addable, note: "")]
        model.picked = Set(model.rows.map(\.id))
        model.importSelected()
        model.cancelImport()
        var deadline = Date().addingTimeInterval(5)
        while model.importing && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(!model.importing)
        #expect(model.rows.allSatisfy { !$0.imported })
        #expect(try FileManager.default.contentsOfDirectory(atPath: userDir.path).isEmpty)
        model.importSelected()
        deadline = Date().addingTimeInterval(5)
        while model.importing && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(!model.importing)
        #expect(model.rows.allSatisfy { $0.imported })
        #expect(ProviderRegistry.scan(dir: userDir).count == 2)
    }

    @Test func triggerURLJoinsOnce() {
        #expect(ProviderImporter.triggerURLForTest("https://a.invalid", "openai") == "https://a.invalid/v1/chat/completions")
        #expect(ProviderImporter.triggerURLForTest("https://a.invalid/v1", "anthropic") == "https://a.invalid/v1/messages")
    }
}
