import Foundation
import Testing
@testable import QuotaNest

@Suite(.serialized)
@MainActor
struct ProviderCatalogIntegrationTests {
    private struct Fixture {
        let root: URL
        let hud: URL
        let providers: URL
        let templates: [PluginProvider]
        let model: SettingsModel
        let defaults: UserDefaults
        let suite: String
    }

    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TokenHUD")
    }

    private func fixture() throws -> Fixture {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tokenhud-catalog-integration-\(UUID().uuidString)")
        let bundle = root.appendingPathComponent("bundle/providers")
        let hud = root.appendingPathComponent("hud")
        let providers = root.appendingPathComponent("accounts")
        let sourceTemplates = sourceRoot.appendingPathComponent("providers")
        try fm.createDirectory(at: bundle.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: hud, withIntermediateDirectories: true)
        try fm.createDirectory(at: providers, withIntermediateDirectories: true)
        try fm.copyItem(at: sourceTemplates, to: bundle)
        try fm.copyItem(at: sourceRoot.appendingPathComponent("mjs"), to: bundle.deletingLastPathComponent().appendingPathComponent("mjs"))
        let entries = try fm.contentsOfDirectory(at: sourceTemplates, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        for entry in entries {
            var manifest = try JSONDecoder().decode(ProviderManifest.self,
                from: Data(contentsOf: entry.appendingPathComponent("manifest.json")))
            let slug = entry.lastPathComponent
            // Keep capabilities and formats intact; redirect every filesystem reference before the engine sees it.
            manifest.authFile = hud.appendingPathComponent(".\(slug)-usage-auth.json").path
            manifest.cacheFile = hud.appendingPathComponent(".\(slug)-usage-cache.json").path
            if var source = manifest.credentialSource {
                source.file = root.appendingPathComponent("sources/\(slug)-default.json").path
                source.environmentDirectory = nil
                manifest.credentialSource = source
            }
            try JSONEncoder().encode(manifest).write(to: bundle.appendingPathComponent("\(slug)/manifest.json"))
        }
        let templates = ProviderRegistry.scan(dir: bundle)
        #expect(templates.count == entries.count)
        let suite = "tokenhud.catalog.integration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = root.appendingPathComponent("settings.json")
        try Data("{}".utf8).write(to: settings)
        let engine = DataEngine(hudDir: hud, bundleProvidersDir: bundle, userProvidersDir: providers,
                                runner: ProviderRunner(nodePath: nil, logDir: root.appendingPathComponent("logs")),
                                defaults: defaults, settingsURL: settings)
        // Deliberately avoid start(): it installs timers and launches refresh tasks.
        engine.installScripts()
        engine.migrateAccounts()
        engine.reloadRegistry()
        let model = SettingsModel(engine: engine, hudDir: hud, userDir: providers, settingsURL: settings,
                                  bundleDir: bundle, defaults: defaults, confirmDiscardChanges: { true },
                                  confirmResumePlan: { true }, confirmTestCall: { _ in false },
                                  executeTestCall: { _ in Issue.record("Catalog setup must not call a model"); return nil },
                                  executeQuotaQuery: { _ in Issue.record("Catalog setup must not query a provider"); return .failed("unexpected request") })
        return Fixture(root: root, hud: hud, providers: providers, templates: templates, model: model,
                       defaults: defaults, suite: suite)
    }

    private func cleanup(_ f: Fixture) {
        f.defaults.removePersistentDomain(forName: f.suite)
        try? FileManager.default.removeItem(at: f.root)
    }

    private func keys(for path: String) -> [String] {
        if path.hasPrefix("/") {
            return path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map {
                String($0).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            }
        }
        return path.split(separator: ".").map(String.init)
    }

    private func inserting(_ value: String, at keys: ArraySlice<String>, into object: [String: Any]) -> [String: Any] {
        guard let first = keys.first else { return object }
        var result = object
        if keys.count == 1 { result[first] = value }
        else { result[first] = inserting(value, at: keys.dropFirst(), into: object[first] as? [String: Any] ?? [:]) }
        return result
    }

    private func fakeAuthorization(_ format: ProviderCredentialFormat, token: String) throws -> Data {
        var object: [String: Any] = [:]
        for (name, path) in format.contextPaths ?? [:] {
            object = inserting("offline-\(name)", at: keys(for: path)[...], into: object)
        }
        for (name, path) in format.headerPaths ?? [:] {
            object = inserting("offline-\(name)", at: keys(for: path)[...], into: object)
        }
        for (path, value) in format.requiredValues ?? [:] {
            object = inserting(value, at: keys(for: path)[...], into: object)
        }
        object = inserting(token, at: keys(for: format.tokenPath)[...], into: object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func formats(for source: ProviderCredentialSource) -> [ProviderCredentialFormat] {
        [ProviderCredentialFormat(tokenPath: source.tokenPath, headerPaths: source.headerPaths,
                                  requiredValues: source.requiredValues, contextPaths: source.contextPaths, tokenEncoding: source.tokenEncoding)]
            + (source.alternatives ?? [])
    }

    @discardableResult
    private func create(_ template: PluginProvider, in f: Fixture, format: ProviderCredentialFormat? = nil,
                        suffix: String = "primary") throws -> AccountRow {
        let choice = try #require(f.model.choices.first { $0.id == template.slug })
        let count = ProviderRegistry.scan(dir: f.providers).count
        f.model.pickTemplate(choice)
        #expect(ProviderRegistry.scan(dir: f.providers).count == count)
        #expect(f.model.draft?.isNew == true)
        #expect(f.model.draft?.values.autoQuery == true)
        #expect(f.model.draft?.values.quotaMode == "script")
        #expect(f.model.draft?.values.autoTrigger == false)
        f.model.draft?.values.name = "catalog-\(template.slug)-\(suffix)"
        var token = "offline-fixture-token-\(template.slug)-\(suffix)"
        var sourceURL: URL?
        var sourceContents: Data?
        var usedFormat: ProviderCredentialFormat?
        let mode = try #require(f.model.draft?.values.authMode)
        if mode == "auth" {
            let source = try #require(template.manifest.credentialSource)
            let selectedFormat = try #require(format ?? formats(for: source).first)
            usedFormat = selectedFormat
            if selectedFormat.tokenEncoding == "jwt" {
                let header = Data(#"{"alg":"none"}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
                let payload = Data(#"{"sub":"offline-fixture","exp":4102444800}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
                token = header + "." + payload + ".offline-signature"
            }
            let file = f.root.appendingPathComponent("selected-auth/\(template.slug)-\(suffix).json")
            let contents = try fakeAuthorization(selectedFormat, token: token)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file)
            f.model.draft?.values.authCredentialFile = file.path
            sourceURL = file
            sourceContents = contents
        } else {
            #expect(mode == "apikey")
            f.model.draft?.values.key = token
        }
        // No URL, protocol, model, query key, or credential-mode edits: the selected type supplies them.
        f.model.save()
        #expect(f.model.topError.isEmpty, "Save failed for \(template.slug): \(f.model.topError)")
        #expect(f.model.draft == nil)
        let row = try #require(f.model.current)
        #expect(row.plugin.manifest.template == template.slug)
        #expect(row.plugin.manifest.credentialSource == template.manifest.credentialSource)
        #expect(row.plugin.manifest.quotaAuthModes == template.manifest.quotaAuthModes)
        #expect(row.plugin.manifest.authCallUrl == template.manifest.authCallUrl)
        #expect(row.plugin.manifest.authCallProtocol == template.manifest.authCallProtocol)
        #expect(row.plugin.manifest.inheritQueryUrl == template.manifest.inheritQueryUrl)
        #expect(row.id != template.slug)
        #expect(ProviderRegistry.scan(dir: f.providers).count == count + 1)
        #expect(row.enabled)
        #expect(row.canQuery)
        #expect(f.model.quotaConfigured(row), "Quota not ready for \(template.slug)")
        #expect(row.isConfigured)
        #expect(f.model.engine.triggerDisabledSlugs.contains(row.id))
        let saved = f.model.readConfig(row.plugin)
        #expect(saved.authMode == mode)
        #expect(saved.queryKey.isEmpty)
        #expect(saved.quotaMode == "script")
        let effective = try ProviderAuthentication.resolveQuota(saved)
        #expect(effective.queryKey == token)
        if mode == "apikey" { #expect(saved.refreshKey == token) }
        else {
            #expect(saved.refreshKey.isEmpty)
            #expect(saved.authCredentialFile == sourceURL?.path)
            #expect(try Data(contentsOf: try #require(sourceURL)) == sourceContents)
            let expected = try JSONSerialization.jsonObject(with: try #require(sourceContents))
            let selectedFormat = try #require(usedFormat)
            for (name, path) in selectedFormat.contextPaths ?? [:] {
                let value = keys(for: path).reduce(expected as Any?) { ($0 as? [String: Any])?[$1] } as? String
                #expect(effective.authContext[name] == value)
            }
            for (header, path) in selectedFormat.headerPaths ?? [:] {
                let value = try #require(keys(for: path).reduce(expected as Any?) { ($0 as? [String: Any])?[$1] } as? String)
                #expect(effective.refreshHeader.contains("\(header): \(value)"))
            }
            let stored = try String(contentsOf: try #require(f.model.authURL(row.plugin)), encoding: .utf8)
            #expect(!stored.contains(token))
        }
        if template.manifest.refreshUrl?.isEmpty != false && template.manifest.authCallUrl?.isEmpty != false {
            #expect(saved.refreshUrl.isEmpty)
            #expect(saved.testModel.isEmpty)
            #expect(!row.canCall)
            #expect(!f.model.callConfigured(row))
        }
        #expect(try #require(f.model.authURL(row.plugin)).path.hasPrefix(f.hud.path + "/"))
        #expect(DataEngine.cachePath(for: row.plugin, hudDir: f.hud).path.hasPrefix(f.hud.path + "/"))
        let sourceScript = try String(contentsOf: template.dir.appendingPathComponent("fetch.sh"), encoding: .utf8)
        let script = try String(contentsOf: row.plugin.dir.appendingPathComponent("fetch.sh"), encoding: .utf8)
        #expect(!script.contains("{SLUG}"))
        if sourceScript.contains("{SLUG}") { #expect(script.contains(row.id)) }
        let expression = try NSRegularExpression(pattern: #"[A-Za-z0-9_-]+\.mjs"#)
        let matches = expression.matches(in: script, range: NSRange(script.startIndex..., in: script))
        #expect(!matches.isEmpty)
        for match in matches {
            let range = try #require(Range(match.range, in: script))
            #expect(FileManager.default.fileExists(atPath: f.hud.appendingPathComponent(String(script[range])).path))
        }
        #expect(f.model.lastRun.isEmpty)
        #expect(f.model.callTestResults.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("logs").path))
        return row
    }

    @Test func everyRepositoryTemplateCanBeSelectedAndSavedWithOnlyBaseCredentials() throws {
        let f = try fixture(); defer { cleanup(f) }
        let slugs = Set(f.templates.map(\.slug))
        let balance: Set<String> = ["deepseek", "moonshot", "moonshot-cn", "openrouter", "aihubmix", "stepfun", "stepfun-cn", "vercel-ai-gateway"]
        let coding: Set<String> = ["zai-coding", "minimax-coding", "minimax-coding-cn", "kimi-code", "kimi-code-cn", "codebuddy", "codebuddy-cn", "commandcode"]
        #expect(balance.count == 8 && balance.isSubset(of: slugs))
        #expect(coding.count == 8 && coding.isSubset(of: slugs))
        #expect(Set(f.model.choices.filter { $0.manifest != nil }.map(\.id)) == slugs)
        #expect(f.model.choices.contains { $0.id == "generic-openai" })
        #expect(f.model.choices.contains { $0.id == "generic-anthropic" })
        for template in f.templates { try create(template, in: f) }
    }

    @Test func optInTemplatesStayInCatalogWithoutCreatingAccounts() throws {
        let f = try fixture(); defer { cleanup(f) }
        let optIn = f.templates.filter { $0.manifest.autoCreateDefault == false }
        #expect(optIn.count >= 16)
        for template in optIn {
            #expect(f.model.choices.contains { $0.id == template.slug })
            #expect(!FileManager.default.fileExists(atPath: f.providers.appendingPathComponent(template.slug).path))
            #expect(!f.model.engine.allPlugins.contains { $0.slug == template.slug })
        }
        #expect(ProviderRegistry.scan(dir: f.providers).count == f.templates.filter { $0.manifest.autoCreateDefault != false }.count)
    }

    @Test func realAuthTemplatesAcceptEveryDeclaredCPAAndCLIFormatWithoutChangingSources() throws {
        let f = try fixture(); defer { cleanup(f) }
        let multipleFormats = f.templates.filter { $0.manifest.credentialSource?.alternatives?.isEmpty == false }
        #expect(multipleFormats.contains { $0.slug == "gpt" })
        #expect(multipleFormats.contains { $0.slug == "claude-code" })
        #expect(multipleFormats.contains { $0.slug == "kiro" })
        for template in multipleFormats {
            let source = try #require(template.manifest.credentialSource)
            for (index, format) in formats(for: source).enumerated() {
                try create(template, in: f, format: format, suffix: "format-\(index)")
            }
        }
    }
}
