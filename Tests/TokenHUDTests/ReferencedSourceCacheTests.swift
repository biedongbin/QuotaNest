import Foundation
import Testing
@testable import TokenHUD

@Suite(.serialized)
struct ReferencedSourceCacheTests {
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

    private func saveJSON(_ file: URL, key: String = "fixture-A", base: String = "https://first.example.test/v1") throws {
        try JSONSerialization.data(withJSONObject: ["type": "clinepass", "api_key": key, "base_url": base])
            .write(to: file, options: .atomic)
    }

    @MainActor
    private func fixture(_ root: URL, source: URL, sqlite: Bool = false) throws -> (DataEngine, ProviderManifest, URL) {
        let hud = root.appendingPathComponent("hud"), plugins = root.appendingPathComponent("providers")
        let plugin = plugins.appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: hud, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        let reference = ProviderSourceReference(source: sqlite ? "9router" : "cpamp", path: source.path,
            recordId: sqlite ? "same-pk" : source.lastPathComponent,
            providerId: sqlite ? "openai-compatible-chat" : "clinepass")
        let auth = hud.appendingPathComponent(".fixture-usage-auth.json")
        let cache = hud.appendingPathComponent(".fixture-usage-cache.json")
        let manifest = ProviderManifest(name: "fixture", label: "Fixture", cacheFile: cache.path, authFile: auth.path,
            queryUrl: "https://quota.example.test/usage", sourceReference: reference)
        try JSONEncoder().encode(manifest).write(to: plugin.appendingPathComponent("manifest.json"))
        try Data("{}".utf8).write(to: auth)
        let defaults = try #require(UserDefaults(suiteName: "tokenhud-ref-cache-\(UUID())"))
        let engine = DataEngine(hudDir: hud, bundleProvidersDir: nil, userProvidersDir: plugins,
            runner: ProviderRunner(nodePath: nil, logDir: hud), defaults: defaults)
        engine.reloadRegistry()
        return (engine, manifest, cache)
    }

    private func cached(_ revision: String?) -> UsageCache {
        UsageCache(generatedAt: Date().timeIntervalSince1970 * 1000, fiveHour: nil,
            sevenDay: Bucket(usedPercentage: 73, resetsAt: nil), monthly: nil, sourceRevision: revision)
    }

    @Test @MainActor func jsonRotationRejectsDiskAndLateResultsAndFailedQueryCannotInheritOldIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenhud-ref-cache-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.json")
        try saveJSON(source)
        let (engine, manifest, cacheFile) = try fixture(root, source: source)
        let reference = try #require(manifest.sourceReference)
        let revisionA = try ImportedSource.read(reference).revision
        let cacheA = cached(revisionA)
        try JSONEncoder().encode(cacheA).write(to: cacheFile)
        engine.reloadRegistry()
        #expect(engine.states.first?.cache?.sevenDay?.usedPercentage == 73)
        let gateA = DataEngine.configRevision(slug: "fixture", manifest: manifest)
        #expect(gateA == gateA.rounded())
        #expect(gateA < 4_503_599_627_370_496)
        engine.applyForTest(slug: "fixture", fetched: nil, now: 1, checkRevision: true)
        #expect(engine.states.first?.cache?.sevenDay?.usedPercentage == 73)
        #expect(engine.states.first?.cache?.sourceRevision == revisionA)
        // A URL-only change at the same primary key is an identity revision too.
        try saveJSON(source, base: "https://second.example.test/v1")
        #expect(DataEngine.configRevision(slug: "fixture", manifest: manifest) != gateA)
        #expect(engine.readCache(slug: "fixture", manifest: manifest) == nil)
        engine.applyForTest(slug: "fixture", fetched: cacheA, now: 2, checkRevision: true)
        #expect(engine.states.first?.cache == nil)
        engine.applyForTest(slug: "fixture", fetched: nil, now: 3, checkRevision: true)
        #expect(engine.states.first?.cache?.sevenDay == nil)
        #expect(engine.readCache(slug: "fixture", manifest: manifest) == nil)
        // Unstamped legacy cache is never accepted, even with the current source present.
        try JSONEncoder().encode(cached(nil)).write(to: cacheFile)
        #expect(engine.readCache(slug: "fixture", manifest: manifest) == nil)
        try FileManager.default.removeItem(at: source)
        engine.applyForTest(slug: "fixture", fetched: cacheA, now: 4, checkRevision: true)
        #expect(engine.states.first?.cache == nil)
        #expect(engine.readCache(slug: "fixture", manifest: manifest) == nil)
    }

    @Test @MainActor func sqliteSamePrimaryKeyRotationChangesGateWithoutFileMtimeGuessing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenhud-ref-db-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.sqlite")
        try sql(source, "CREATE TABLE providerConnections(id TEXT PRIMARY KEY, provider TEXT, authType TEXT, data TEXT); INSERT INTO providerConnections VALUES('same-pk','openai-compatible-chat','apikey','{\"apiKey\":\"fixture-A\",\"baseUrl\":\"https://first.example.test/v1\"}')")
        let (engine, manifest, cacheFile) = try fixture(root, source: source, sqlite: true)
        let reference = try #require(manifest.sourceReference)
        let first = cached(try ImportedSource.read(reference).revision)
        try JSONEncoder().encode(first).write(to: cacheFile)
        engine.reloadRegistry()
        let revision = DataEngine.configRevision(slug: "fixture", manifest: manifest)
        let modified = try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try sql(source, "UPDATE providerConnections SET data='{\"apiKey\":\"fixture-B\",\"baseUrl\":\"https://first.example.test/v1\"}' WHERE id='same-pk'")
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: source.path) }
        #expect(DataEngine.configRevision(slug: "fixture", manifest: manifest) != revision)
        #expect(engine.readCache(slug: "fixture", manifest: manifest) == nil)
        engine.applyForTest(slug: "fixture", fetched: nil, now: 1, checkRevision: true)
        #expect(engine.states.first?.cache?.sevenDay == nil)
        engine.applyForTest(slug: "fixture", fetched: first, now: 2, checkRevision: true)
        #expect(engine.states.first?.cache == nil)
        try sql(source, "DELETE FROM providerConnections")
        #expect(engine.readCache(slug: "fixture", manifest: manifest) == nil)
    }

    @Test @MainActor func acceptedNewCacheRefreshesOnlyExistingHUDDependencyProjection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenhud-ref-export-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.json")
        try saveJSON(source)
        let (engine, manifest, _) = try fixture(root, source: source)
        let reference = try #require(manifest.sourceReference)
        let hud = root.appendingPathComponent("hud")
        let plugin = try #require(engine.allPlugins.first)
        let entry = try #require(HUDSync.envsDict(plugins: [plugin], hudDir: hud, builtinNames: [])["fixture"])
        #expect(entry.sourceReferenceDependencies?[source.path] != nil)
        let envs = hud.appendingPathComponent("envs.json")
        try HUDSync.writeEnvs(["fixture": entry], to: envs)
        let exported = String(decoding: try Data(contentsOf: envs), as: UTF8.self)
        #expect(!exported.contains("fixture-A"))
        try saveJSON(source, key: "fixture-rotated-key")
        let oldDate = Date(timeIntervalSinceNow: -2)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: source.path)
        engine.applyForTest(slug: "fixture", fetched: cached(try ImportedSource.read(reference).revision), now: 1, checkRevision: true)
        let entries = try JSONDecoder().decode([String: EnvsEntry].self, from: Data(contentsOf: envs))
        let deps = try #require(entries["fixture"]?.sourceReferenceDependencies)
        #expect(abs((deps[source.path] ?? 0) - oldDate.timeIntervalSince1970 * 1000) < 1)
        #expect(engine.states.first?.cache?.sevenDay?.usedPercentage == 73)
        let safe = String(decoding: try Data(contentsOf: envs), as: UTF8.self)
        #expect(!safe.contains("fixture-rotated-key"))
    }

    @Test @MainActor func snapshotAndRunnerStampFrozenRevisionWithoutChangingSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenhud-ref-snapshot-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.json")
        try saveJSON(source)
        let (_, manifest, _) = try fixture(root, source: source)
        let reference = try #require(manifest.sourceReference)
        let auth = PluginGenerator.expandPath(try #require(manifest.authFile))
        let bytes = try Data(contentsOf: source)
        let config = ProviderConfigStore.read(authFile: auth, manifest: manifest)
        let snapshot = try ProviderQuerySnapshot.make(config: config, manifest: manifest, originalAuth: auth)
        defer { snapshot.cleanup() }
        let revisionA = try ImportedSource.read(reference).revision
        #expect(snapshot.sourceRevision == revisionA)
        try saveJSON(source, key: "fixture-B")
        #expect(snapshot.sourceRevision == revisionA)
        #expect(try Data(contentsOf: auth) == Data("{}".utf8))
        try bytes.write(to: source)
        let pluginDir = root.appendingPathComponent("providers/fixture")
        // The fixture rotates its own temporary source after the request snapshot exists.
        let script = """
        /bin/cp '\(root.appendingPathComponent("replacement.json").path)' '\(source.path)'
        print -r -- '{"generatedAt":1,"seven_day":{"used_percentage":73},"error":"fetch"}'
        """
        try JSONSerialization.data(withJSONObject: ["type": "clinepass", "api_key": "fixture-C", "base_url": "https://third.example.test/v1"])
            .write(to: root.appendingPathComponent("replacement.json"))
        try script.write(to: pluginDir.appendingPathComponent("fetch.sh"), atomically: true, encoding: .utf8)
        let runner = ProviderRunner(nodePath: nil, logDir: auth.deletingLastPathComponent())
        let result = await runner.run(PluginProvider(slug: "fixture", manifest: manifest, dir: pluginDir))
        #expect(result?.sourceRevision == revisionA)
        #expect(result?.sourceRevision != (try ImportedSource.read(reference).revision))
        #expect(result?.error == "fetch")
    }
}
