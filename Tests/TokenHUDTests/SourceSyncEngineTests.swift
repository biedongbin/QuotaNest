import Foundation
import Testing
@testable import TokenHUD

@Suite @MainActor
struct SourceSyncEngineTests {
    @MainActor private struct Fixture {
        let root: URL
        let hud: URL
        let providers: URL
        let source: URL
        let manifest: URL
        let auth: URL
        let defaults: UserDefaults
        let engine: DataEngine

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("source-sync-\(UUID())")
            hud = root.appendingPathComponent("hud")
            providers = root.appendingPathComponent("accounts")
            source = root.appendingPathComponent("source/providers.json")
            manifest = providers.appendingPathComponent("same-slug/manifest.json")
            auth = hud.appendingPathComponent(".same-slug-usage-auth.json")
            for directory in [hud, manifest.deletingLastPathComponent(), source.deletingLastPathComponent()] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try Data(#"{"env":{"ACCOUNT_ENVS":""}}"#.utf8)
                .write(to: root.appendingPathComponent("settings.json"))
            try Data("{}".utf8).write(to: hud.appendingPathComponent("envs.json"))
            defaults = try #require(UserDefaults(suiteName: "source-sync-\(UUID())"))
            engine = DataEngine(hudDir: hud, bundleProvidersDir: nil, userProvidersDir: providers,
                runner: ProviderRunner(nodePath: nil, logDir: hud), defaults: defaults,
                settingsURL: root.appendingPathComponent("settings.json"))
        }

        func writeSource(ids: [String]) throws {
            let records = ids.map { ["id": $0, "key": "fixture-key", "chat": "https://fixture.invalid/v1/chat/completions"] }
            try JSONSerialization.data(withJSONObject: ["providers": records]).write(to: source, options: .atomic)
        }

        func install() throws {
            try writeSource(ids: ["old"])
            let ref = ProviderSourceReference(source: "magpie", path: source.path, recordId: "old",
                providerId: "old", collection: "providers")
            let model = ProviderManifest(name: "Local name", label: "L", displayName: "Keep local name",
                authFile: auth.path, refreshProtocol: "openai", enabled: false, authMode: "apikey",
                origin: "magpie:old", quotaMode: "none", sourceReference: ref)
            try JSONEncoder().encode(model).write(to: manifest)
            try ProviderConfigStore.write(ProviderConfig(), manifest: model, to: auth)
            engine.reloadRegistry()
        }

        func installCPA() throws -> URL {
            let old = source.deletingLastPathComponent().appendingPathComponent("old.json")
            try cpaBytes(key: "fixture-cpa-key").write(to: old)
            let ref = ProviderSourceReference(source: "cpamp", path: old.path, recordId: "old.json",
                providerId: "claude")
            let model = ProviderManifest(name: "Local CPA", label: "CPA", authFile: auth.path,
                refreshProtocol: "anthropic", enabled: false, authMode: "apikey",
                origin: "cpamp:old.json", quotaMode: "none", sourceReference: ref)
            try JSONEncoder().encode(model).write(to: manifest)
            try ProviderConfigStore.write(ProviderConfig(), manifest: model, to: auth)
            engine.reloadRegistry()
            return old
        }

        func cpaBytes(key: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": "claude", "api_key": key,
                "base_url": "https://fixture.invalid/v1/messages"])
        }

        func savedManifest() throws -> ProviderManifest {
            try JSONDecoder().decode(ProviderManifest.self, from: Data(contentsOf: manifest))
        }

        func clean() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func dueUsesLastAttemptAndExactHourBoundary() {
        let start = Date(timeIntervalSince1970: 10000)
        #expect(DataEngine.sourceSyncDue(lastAttempt: nil, now: start))
        #expect(!DataEngine.sourceSyncDue(lastAttempt: start, now: start.addingTimeInterval(3599.999)))
        #expect(DataEngine.sourceSyncDue(lastAttempt: start, now: start.addingTimeInterval(3600)))
        #expect(!DataEngine.sourceSyncDue(lastAttempt: start, now: start.addingTimeInterval(-1)))
    }

    @Test func enabledDefaultsToTrueAndPersistsWithoutStartingTimer() throws {
        let f = try Fixture()
        defer { f.clean() }
        #expect(f.engine.sourceAutoSyncEnabled)
        f.engine.setSourceAutoSyncEnabled(false)
        #expect(!f.defaults.bool(forKey: DataEngine.defaultsSourceAutoSyncKey))
        let other = DataEngine(hudDir: f.hud, bundleProvidersDir: nil, userProvidersDir: f.providers,
            runner: ProviderRunner(nodePath: nil, logDir: f.hud), defaults: f.defaults,
            settingsURL: f.root.appendingPathComponent("settings.json"))
        #expect(!other.sourceAutoSyncEnabled)
    }

    @Test func noReferencesIsClearFeedbackWithoutFailure() async throws {
        let f = try Fixture()
        defer { f.clean() }
        await f.engine.syncImportedSources()
        #expect(f.engine.sourceSyncMessage.contains("没有"))
        #expect(f.engine.sourceSyncIssues.isEmpty)
        #expect(!f.engine.sourceSyncing)
        #expect(f.engine.sourceSyncLastSuccess == nil)
    }

    @Test func disabledAutomaticSkipsScanButManualRegistersAnchorOnce() async throws {
        let f = try Fixture()
        defer { f.clean() }
        try f.install()
        let original = try Data(contentsOf: f.manifest)
        f.engine.setSourceAutoSyncEnabled(false)
        await f.engine.syncImportedSources(force: false)
        #expect(f.engine.sourceSyncLastAttempt == nil)
        #expect(try Data(contentsOf: f.manifest) == original)
        await f.engine.syncImportedSources()
        #expect(try f.savedManifest().sourceReference?.identityAnchor != nil)
        #expect(f.engine.sourceSyncIssues.isEmpty)
        let registered = try Data(contentsOf: f.manifest)
        let auth = try Data(contentsOf: f.auth)
        await f.engine.syncImportedSources()
        #expect(try Data(contentsOf: f.manifest) == registered)
        #expect(try Data(contentsOf: f.auth) == auth)
        #expect(f.engine.sourceSyncMessage.contains("未变 1"))
    }

    @Test func missingSourceIsVisibleAndFailedAttemptThrottles() async throws {
        let f = try Fixture()
        defer { f.clean() }
        try f.install()
        // Keep this test entirely inside its temporary fixture.
        try FileManager.default.removeItem(at: f.source)
        let now = Date(timeIntervalSince1970: 5000)
        await f.engine.syncImportedSources(force: false, now: now)
        #expect(f.engine.sourceSyncIssues["same-slug"] != nil)
        #expect(f.engine.sourceSyncLastSuccess == nil)
        await f.engine.syncImportedSources(force: false, now: now.addingTimeInterval(3599))
        #expect(f.engine.sourceSyncLastAttempt == now)
        await f.engine.syncImportedSources(force: false, now: now.addingTimeInterval(3600))
        #expect(f.engine.sourceSyncLastAttempt == now.addingTimeInterval(3600))
    }

    @Test func correctsCurrentIDsKeepingLocalIdentityFlagsAndSourceBytes() async throws {
        let f = try Fixture()
        defer { f.clean() }
        try f.install()
        await f.engine.syncImportedSources()
        f.engine.setTracking("same-slug", enabled: false)
        f.engine.setFloatingHidden("same-slug", hidden: true)
        let cache = f.hud.appendingPathComponent(".same-slug-usage-cache.json")
        try Data("{}".utf8).write(to: cache)
        try f.writeSource(ids: ["new"])
        let sourceBytes = try Data(contentsOf: f.source)
        await f.engine.syncImportedSources()
        let saved = try f.savedManifest()
        #expect(saved.sourceReference?.recordId == "new")
        #expect(saved.sourceReference?.originalRecordId == "old")
        #expect(saved.origin == "magpie:new")
        #expect(saved.name == "Local name")
        #expect(saved.displayName == "Keep local name")
        #expect(saved.enabled == false)
        #expect(f.engine.disabledSlugs.contains("same-slug"))
        #expect(f.engine.floatingHiddenSlugs.contains("same-slug"))
        #expect(try Data(contentsOf: f.source) == sourceBytes)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        let auth = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: f.auth)) as? [String: Any])
        #expect(Set(auth.keys) == Set(["schemaVersion", "sourceReference"]))
        #expect(!String(decoding: try Data(contentsOf: f.auth), as: UTF8.self).contains("fixture-key"))
    }

    @Test func ambiguousIdentityDoesNotWriteAndIsVisible() async throws {
        let f = try Fixture()
        defer { f.clean() }
        try f.install()
        await f.engine.syncImportedSources()
        let original = try Data(contentsOf: f.manifest)
        try f.writeSource(ids: ["new-one", "new-two"])
        await f.engine.syncImportedSources()
        #expect(f.engine.sourceSyncIssues["same-slug"] != nil)
        #expect(try Data(contentsOf: f.manifest) == original)
    }

    @Test func manifestWriteFailureRollsBackAuthAndManifest() async throws {
        let f = try Fixture()
        defer { f.clean() }
        try f.install()
        let manifest = try Data(contentsOf: f.manifest)
        let auth = try Data(contentsOf: f.auth)
        f.engine.sourceSyncWriteManifest = { data, url in
            try data.write(to: url, options: .atomic)
            throw CocoaError(.fileWriteUnknown)
        }
        await f.engine.syncImportedSources()
        #expect(f.engine.sourceSyncIssues["same-slug"] != nil)
        #expect(try Data(contentsOf: f.manifest) == manifest)
        #expect(try Data(contentsOf: f.auth) == auth)
        #expect(f.engine.sourceSyncLastSuccess == nil)
    }

    @Test func userDeletingAccountDuringScanCannotResurrectIt() async throws {
        let f = try Fixture()
        defer { f.clean() }
        try f.install()
        f.engine.sourceSyncBeforeCommit = {
            try? FileManager.default.removeItem(at: f.manifest.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: f.auth)
            f.engine.reloadRegistry()
        }
        await f.engine.syncImportedSources()
        #expect(f.engine.allPlugins.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.manifest.path))
        #expect(!FileManager.default.fileExists(atPath: f.auth.path))
        #expect(f.engine.sourceSyncIssues["same-slug"] != nil)
    }

    @Test func sourceChangingAfterScanIsSkipped() async throws {
        let f = try Fixture()
        defer { f.clean() }
        try f.install()
        let original = try Data(contentsOf: f.manifest)
        f.engine.sourceSyncBeforeCommit = { try? f.writeSource(ids: ["changed-during-scan"]) }
        await f.engine.syncImportedSources()
        #expect(f.engine.sourceSyncIssues["same-slug"] != nil)
        #expect(try Data(contentsOf: f.manifest) == original)
    }

    @Test(arguments: ["restore-original", "add-candidate", "change-existing-candidate"])
    func cpaCandidatePoolChangingAfterScanSkipsCommit(change: String) async throws {
        let f = try Fixture()
        defer { f.clean() }
        let old = try f.installCPA()
        await f.engine.syncImportedSources()
        #expect(f.engine.sourceSyncIssues.isEmpty)
        let directory = old.deletingLastPathComponent()
        let new = directory.appendingPathComponent("new.json")
        let third = directory.appendingPathComponent("third.json")
        let fourth = directory.appendingPathComponent("fourth.json")
        let candidate = try Data(contentsOf: old)
        try f.cpaBytes(key: "different-long-fixture-key").write(to: third)
        try FileManager.default.moveItem(at: old, to: new)
        let originalManifest = try Data(contentsOf: f.manifest)
        let originalAuth = try Data(contentsOf: f.auth)
        var expectedSources: [URL: Data] = [:]
        var mutationError: Error?
        f.engine.sourceSyncBeforeCommit = {
            do {
                switch change {
                case "restore-original": try candidate.write(to: old)
                case "add-candidate": try candidate.write(to: fourth)
                default:
                    // In-place replacement changes a candidate without changing the directory entries.
                    try candidate.write(to: third)
                }
                for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                    expectedSources[file] = try Data(contentsOf: file)
                }
            } catch { mutationError = error }
        }
        await f.engine.syncImportedSources()
        #expect(mutationError == nil)
        #expect(f.engine.sourceSyncIssues["same-slug"] != nil)
        #expect(try Data(contentsOf: f.manifest) == originalManifest)
        #expect(try Data(contentsOf: f.auth) == originalAuth)
        #expect(try f.savedManifest().sourceReference?.recordId == "old.json")
        #expect(try Data(contentsOf: new) == candidate)
        for (file, bytes) in expectedSources { #expect(try Data(contentsOf: file) == bytes) }
    }

    @Test func overlappingCallsCoalesce() async throws {
        let f = try Fixture()
        defer { f.clean() }
        try f.install()
        var commits = 0
        var secondEntered = false
        var second: Task<Void, Never>?
        f.engine.sourceSyncBeforeCommit = {
            commits += 1
            second = Task {
                secondEntered = true
                await f.engine.syncImportedSources()
            }
            while !secondEntered { await Task.yield() }
        }
        await f.engine.syncImportedSources()
        await second?.value
        #expect(commits == 1)
        #expect(!f.engine.sourceSyncing)
        #expect(f.engine.sourceSyncIssues.isEmpty)
    }
}
