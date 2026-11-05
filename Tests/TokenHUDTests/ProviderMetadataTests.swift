import Foundation
import Testing
@testable import QuotaNest

@Suite(.serialized)
struct ProviderMetadataTests {
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenhud-metadata-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeJSON(_ object: [String: Any], to file: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: file)
    }

    private func config(_ file: URL) -> ProviderConfig {
        var config = ProviderConfig()
        config.authMode = "auth"
        config.queryUrl = "https://fixture.example.test/usage"
        config.credentialSource = ProviderCredentialSource(file: file.path, tokenPath: "tokens.access_token",
            headerPaths: ["native-account": "tokens.account_id"], requiredValues: ["auth_mode": "native"],
            contextPaths: ["projectId": "tokens.project_id"], alternatives: [
                ProviderCredentialFormat(tokenPath: "access_token", headerPaths: ["cpa-account": "account_id"],
                    requiredValues: ["type": "fixture"], contextPaths: ["userId": "user_id"]),
                ProviderCredentialFormat(tokenPath: "accessToken", contextPaths: ["deviceId": "deviceId"])
            ])
        return config
    }

    @Test func formatsAreSelectedAsAWholeAndNeverMixIdentityFields() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("login.json")
        let object: [String: Any] = ["auth_mode": "wrong", "tokens": ["access_token": "native-token", "account_id": "native-id", "project_id": "native-project"],
            "type": "fixture", "access_token": "cpa-token", "account_id": "cpa-id", "user_id": "cpa-user", "accessToken": "router-token", "deviceId": "router-device"]
        try writeJSON(object, to: file)
        let c = config(file)
        let cpa = try ProviderAuthentication.resolveQuota(c)
        #expect(cpa.queryKey == "cpa-token")
        #expect(cpa.authContext == ["userId": "cpa-user"])
        #expect(cpa.queryHeader.contains("cpa-account: cpa-id"))
        #expect(!cpa.queryHeader.contains("native-id"))
        var native = object; native["auth_mode"] = "native"
        try writeJSON(native, to: file)
        let first = try ProviderAuthentication.resolveQuota(c)
        #expect(first.queryKey == "native-token")
        #expect(first.authContext == ["projectId": "native-project"])
        #expect(!first.queryHeader.contains("cpa-id"))
        var router = object; router["access_token"] = "\ninvalid"
        try writeJSON(router, to: file)
        let last = try ProviderAuthentication.resolveQuota(c)
        #expect(last.queryKey == "router-token")
        #expect(last.authContext == ["deviceId": "router-device"])
        #expect(!last.queryHeader.contains("cpa-account"))
        router["deviceId"] = "bad\ncontext"
        try writeJSON(router, to: file)
        #expect(throws: ProviderAuthenticationError.self) { try ProviderAuthentication.resolveQuota(c) }
    }

    @Test func jsonPointerSelectsAnExplicitURLKeyWithoutMixingProviderRecords() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("opencode-auth.json")
        var object: [String: Any] = [
            "https://provider.example/v1": ["type": "api", "key": "A", "account": "account-A", "project~id": "project-A", "~1": "escaped-A"],
            "https://other.example/v1": ["type": "api", "key": "B", "account": "account-B", "project~id": "project-B"]
        ]
        try writeJSON(object, to: file)
        let pointer = "/https:~1~1provider.example~1v1"
        var c = ProviderConfig()
        c.authMode = "auth"
        c.credentialSource = ProviderCredentialSource(file: file.path, tokenPath: "missing.dot.path", alternatives: [
            ProviderCredentialFormat(tokenPath: pointer + "/key", headerPaths: ["X-Account": pointer + "/account"],
                requiredValues: [pointer + "/type": "api"],
                contextPaths: ["projectId": pointer + "/project~0id", "escaped": pointer + "/~01"])
        ])
        let resolved = try ProviderAuthentication.resolveQuota(c)
        #expect(resolved.queryKey == "A")
        #expect(resolved.queryHeader.contains("X-Account: account-A"))
        #expect(!resolved.queryHeader.contains("account-B"))
        #expect(resolved.authContext == ["projectId": "project-A", "escaped": "escaped-A"])
        object["https://provider.example/v1"] = ["type": "api", "key": "A"]
        try writeJSON(object, to: file)
        let missingIdentity = try ProviderAuthentication.resolveQuota(c)
        #expect(missingIdentity.authContext.isEmpty)
        #expect(!missingIdentity.queryHeader.contains("X-Account"))
        object["https://provider.example/v1"] = ["type": "oauth", "key": "A"]
        try writeJSON(object, to: file)
        #expect(throws: ProviderAuthenticationError.self) { try ProviderAuthentication.resolveQuota(c) }
        object.removeValue(forKey: "https://provider.example/v1")
        try writeJSON(object, to: file)
        #expect(throws: ProviderAuthenticationError.self) { try ProviderAuthentication.resolveQuota(c) }
    }

    @Test func contextIsFrozenPrivateAndNeverWrittenToAccountOrExternalSource() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let login = root.appendingPathComponent("login.json")
        try writeJSON(["accessToken": "fixture-token", "deviceId": "private-device", "unmapped": "must-not-copy"], to: login)
        let original = try Data(contentsOf: login)
        var c = config(login)
        let manifest = ProviderManifest(name: "fixture", label: "Fixture", queryUrl: c.queryUrl,
            authMode: "auth", quotaMode: "script", credentialSource: c.credentialSource)
        let account = root.appendingPathComponent("account.json")
        c.authContext = ["stale": "must-not-persist"]
        try ProviderConfigStore.write(c, manifest: manifest, to: account)
        let saved = try Data(contentsOf: account)
        #expect(!String(decoding: saved, as: UTF8.self).contains("must-not-persist"))
        #expect(ProviderConfigStore.read(authFile: account, manifest: manifest).authContext.isEmpty)
        #expect(throws: ProviderAuthenticationError.self) { try ProviderConfigStore.write(c, manifest: manifest, to: login) }
        let resolved = try ProviderAuthentication.resolveQuota(c)
        try writeJSON(["accessToken": "new-token", "deviceId": "new-device"], to: login)
        #expect(try ProviderAuthentication.resolveQuota(resolved).authContext == ["deviceId": "private-device"])
        try original.write(to: login)
        let snapshot = try ProviderQuerySnapshot.make(config: resolved, manifest: manifest, originalAuth: account)
        defer { snapshot.cleanup() }
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: snapshot.file)) as? [String: Any])
        #expect(object["tokenhudAuthContext"] as? [String: String] == ["deviceId": "private-device"])
        #expect(object["unmapped"] == nil)
        #expect(snapshot.secrets.contains("private-device"))
        #expect(try Data(contentsOf: account) == saved)
        #expect(try Data(contentsOf: login) == original)
        #expect(throws: ProviderAuthenticationError.self) { try ProviderConfigStore.write(resolved, manifest: manifest, to: account) }

        let script = "printf '%s' private-device >&2\nexit 1\n"
        let providers = root.appendingPathComponent("providers")
        var runnable = manifest; runnable.authFile = account.path
        try PluginGenerator.writePlugin(slug: "fixture", manifest: runnable, script: script, into: providers)
        let runner = ProviderRunner(nodePath: nil, logDir: root)
        #expect(await runner.run(PluginProvider(slug: "fixture", manifest: runnable, dir: providers.appendingPathComponent("fixture"))) == nil)
        let log = try String(contentsOf: root.appendingPathComponent(".fixture-usage-stderr.log"), encoding: .utf8)
        #expect(!log.contains("private-device"))
    }

    @Test @MainActor func onlyOptedInTemplatesCreateDefaultsAndExistingAccountsStillUpgrade() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("bundle")
        let user = root.appendingPathComponent("user")
        let hud = root.appendingPathComponent("hud")
        let source = ProviderCredentialSource(file: "", tokenPath: "accessToken", contextPaths: ["deviceId": "deviceId"])
        let modern = ProviderManifest(name: "modern", label: "Modern", authMode: "auth", credentialSource: source, autoCreateDefault: false)
        try PluginGenerator.writePlugin(slug: "modern", manifest: modern, script: "exit 1", into: bundle)
        try PluginGenerator.writePlugin(slug: "legacy", manifest: ProviderManifest(name: "legacy", label: "Legacy"), script: "exit 1", into: bundle)
        let suite = "metadata-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = DataEngine(hudDir: hud, bundleProvidersDir: bundle, userProvidersDir: user,
            runner: ProviderRunner(nodePath: "/usr/bin/true", logDir: hud), defaults: defaults,
            settingsURL: root.appendingPathComponent("settings.json"))
        engine.migrateAccounts()
        #expect(ProviderRegistry.scan(dir: bundle).count == 2)
        #expect(!FileManager.default.fileExists(atPath: user.appendingPathComponent("modern/manifest.json").path))
        #expect(!FileManager.default.fileExists(atPath: hud.appendingPathComponent(".modern-usage-auth.json").path))
        #expect(FileManager.default.fileExists(atPath: user.appendingPathComponent("legacy/manifest.json").path))
        let template = PluginProvider(slug: "modern", manifest: modern, dir: bundle.appendingPathComponent("modern"))
        let instance = try PluginGenerator.instantiate(template: template, slug: "modern", name: "My Account", into: user, hudDir: hud)
        #expect(instance.autoCreateDefault == false)
        #expect(instance.credentialSource == source)
        let encoded = try JSONEncoder().encode(instance)
        let decoded = try JSONDecoder().decode(ProviderManifest.self, from: encoded)
        #expect(decoded.autoCreateDefault == false && decoded.credentialSource == source)
        #expect(ProviderConfigStore.applyingManifest(decoded, to: ProviderConfig()).credentialSource == source)
        engine.migrateAccounts()
        let after = try JSONDecoder().decode(ProviderManifest.self, from: Data(contentsOf: user.appendingPathComponent("modern/manifest.json")))
        #expect(after.displayName == "My Account")
        #expect(after.credentialSource == source)
    }

    @Test func emptyDefaultPathRequiresSelectionAndQuotaDoesNotRequireCallEndpoint() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var c = config(root.appendingPathComponent("unused"))
        c.credentialSource?.file = ""
        c.credentialSource?.environmentDirectory = "FIXTURE_HOME"
        #expect(ProviderAuthentication.credentialFileURL(for: c, environment: ["FIXTURE_HOME": root.path]) == nil)
        #expect(ProviderAuthentication.sourceDescription(c).contains("请选择"))
        do {
            _ = try ProviderAuthentication.resolveQuota(c)
            Issue.record("Missing file should fail")
        } catch { #expect(error.localizedDescription.contains("未指定")) }
        var unsupported = c; unsupported.credentialSource = nil
        do {
            _ = try ProviderAuthentication.resolveQuota(unsupported)
            Issue.record("Unsupported Auth should fail")
        } catch { #expect(error.localizedDescription.contains("未提供本机 Auth 适配")) }
        let selected = root.appendingPathComponent("chosen.json")
        try writeJSON(["accessToken": "selected-token"], to: selected)
        c.authCredentialFile = selected.path
        #expect(try ProviderAuthentication.resolveQuota(c).queryKey == "selected-token")
        #expect(throws: ProviderAuthenticationError.self) { try ProviderAuthentication.resolveCall(c) }
    }
}
