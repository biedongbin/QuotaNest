import Foundation
import Testing
@testable import QuotaNest

@Suite(.serialized)
@MainActor
struct ProviderCatalogFailureIsolationTests {
    @Test func sameAuthSourceFailureKeepsLastGoodSnapshot() throws {
        try checkFailure(changedSource: false)
    }

    @Test func changedAuthSourceFailureCannotRestorePreviousAccount() throws {
        try checkFailure(changedSource: true)
    }

    private func checkFailure(changedSource: Bool) throws {
        for error in ["auth", "network", "process"] {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("catalog-failure-\(UUID())")
            let hud = root.appendingPathComponent("hud")
            let providers = root.appendingPathComponent("providers")
            let pluginDir = providers.appendingPathComponent("catalog-account")
            try fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: hud, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: root) }
            let source = root.appendingPathComponent("external-auth.json")
            try Data("{\"access_token\":\"account-A\"}".utf8).write(to: source)
            let capturedAt = Date().timeIntervalSince1970 * 1000
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: capturedAt / 1000 - 60)],
                                 ofItemAtPath: source.path)
            let auth = hud.appendingPathComponent(".catalog-account-usage-auth.json")
            let manifest = ProviderManifest(name: "Catalog", label: "Catalog", authFile: auth.path,
                queryUrl: "https://quota.invalid/usage", queryAuth: "bearer", authMode: "auth", quotaMode: "script",
                quotaAuthModes: ["auth"], credentialSource: ProviderCredentialSource(file: source.path, tokenPath: "access_token"))
            try JSONEncoder().encode(manifest).write(to: pluginDir.appendingPathComponent("manifest.json"))
            var config = ProviderConfig()
            config.authMode = "auth"
            config.quotaMode = "script"
            try ProviderConfigStore.write(config, manifest: manifest, to: auth)
            let cache = hud.appendingPathComponent(".catalog-account-usage-cache.json")
            let old = UsageCache(generatedAt: capturedAt, windows: [WindowBucket(label: "Account A", amount: 17, unit: "credits", period: "balance")])
            try JSONEncoder().encode(old).write(to: cache)
            let suite = "catalog-failure-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let engine = DataEngine(hudDir: hud, bundleProvidersDir: nil, userProvidersDir: providers,
                runner: ProviderRunner(nodePath: nil, logDir: hud), defaults: defaults)
            engine.reloadRegistry()
            #expect(engine.states.first?.cache?.windows?.first?.amount == 17)
            if changedSource {
                try Data("{\"access_token\":\"account-B\"}".utf8).write(to: source)
                try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: capturedAt / 1000 + 1)],
                                     ofItemAtPath: source.path)
            }
            let sourceBytes = try Data(contentsOf: source)
            let failure: UsageCache? = error == "process" ? nil
                : UsageCache(error: error, stale: true, lastAttemptAt: capturedAt + 2000)
            // Direct apply models manual forceRefresh, which does not run refreshNow's preflight invalidation.
            engine.applyForTest(slug: "catalog-account", fetched: failure, now: capturedAt + 2000, checkRevision: true)
            let result = try #require(engine.states.first?.cache)
            let disk = try JSONDecoder().decode(UsageCache.self, from: Data(contentsOf: cache))
            #expect(result.error == (error == "process" ? "fetch" : error))
            #expect(result.stale == true)
            #expect(result.lastAttemptAt == capturedAt + 2000)
            if changedSource {
                #expect(result.windows == nil)
                #expect(result.generatedAt == nil)
                #expect(disk.windows == nil)
            } else {
                #expect(result.windows == old.windows)
                #expect(result.generatedAt == capturedAt)
                #expect(disk.windows == old.windows)
            }
            #expect(try Data(contentsOf: source) == sourceBytes)
        }
    }
}
