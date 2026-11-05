import Foundation
import CryptoKit
import Testing
@testable import QuotaNest

@Suite(.serialized)
struct AppIdentityMigrationTests {
    private final class Fixture {
        let home: URL
        let legacyDomain: String
        let targetDomain: String
        let defaults: UserDefaults
        var support: URL { home.appendingPathComponent("Library/Application Support", isDirectory: true) }
        var legacy: URL { support.appendingPathComponent("TokenHUD", isDirectory: true) }
        var target: URL { support.appendingPathComponent("QuotaNest", isDirectory: true) }
        let now = Date(timeIntervalSince1970: 1_790_000_000)

        init() throws {
            home = FileManager.default.temporaryDirectory.appendingPathComponent("quotanest-migration-fixture-\(UUID())", isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath()
            let identifier = "local.quotanest.migration-fixture.\(UUID().uuidString)"
            legacyDomain = identifier + ".legacy"
            targetDomain = identifier + ".target"
            defaults = try #require(UserDefaults(suiteName: identifier))
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: legacyDomain)
            defaults.removePersistentDomain(forName: targetDomain)
            defaults.synchronize()
            // Only this freshly created, UUID-named fixture home is ever removed.
            try? FileManager.default.removeItem(at: home)
        }

        func migrate(checkpoint: (AppIdentityMigration.Checkpoint) throws -> Void = { _ in }) throws -> AppIdentityMigration.Outcome {
            try AppIdentityMigration.migrate(userHome: home, legacyDomain: legacyDomain, targetDomain: targetDomain,
                                             now: now, defaults: defaults, checkpoint: checkpoint)
        }

        func write(_ bytes: Data, to url: URL, mode: Int = 0o600) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try bytes.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }

        @discardableResult
        func account(_ slug: String = "my-account", manifest: [String: Any] = [:]) throws -> URL {
            var object: [String: Any] = ["name": "Fixture", "label": "Fixture", "fetch": "./fetch.sh", "buckets": [:]]
            for (key, value) in manifest { object[key] = value }
            let directory = legacy.appendingPathComponent("providers/\(slug)", isDirectory: true)
            try write(JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
                      to: directory.appendingPathComponent("manifest.json"))
            try write(Data("#!/bin/sh\nexit 0\n".utf8), to: directory.appendingPathComponent("fetch.sh"), mode: 0o750)
            return directory
        }

        func preferences(_ object: [String: Any], target: Bool = false) {
            defaults.setPersistentDomain(object, forName: target ? targetDomain : legacyDomain)
            defaults.synchronize()
        }

        func snapshot(_ root: URL) throws -> [String: String] {
            var files: [String: String] = [:]
            func visit(_ url: URL, path: String) throws {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                switch attributes[.type] as? FileAttributeType {
                case .typeDirectory:
                    files[path] = "directory:\(mode)"
                    for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                        try visit(child, path: path.isEmpty ? child.lastPathComponent : path + "/" + child.lastPathComponent)
                    }
                case .typeSymbolicLink:
                    files[path] = "link:\(mode):" + (try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
                default:
                    let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
                    files[path] = "file:\(mode):\(digest)"
                }
            }
            try visit(root, path: "")
            return files
        }

        func noStagingDirectories() throws -> Bool {
            guard FileManager.default.fileExists(atPath: support.path) else { return true }
            return try FileManager.default.contentsOfDirectory(atPath: support.path)
                .allSatisfy { !$0.hasPrefix(".QuotaNest-migration-") }
        }
    }

    private struct InjectedFailure: Error {}

    @Test func migratesAccountsAndCompleteApplicationPreferencesWithVerifiedOriginalBackup() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let account = try fixture.account("stable-account-42")
        try fixture.account("second-account")
        let authBytes = Data("{\"refreshApiKey\":\"fixture-only-key\",\"scheduleTimes\":[\"09:00\",\"16:45\"],\"testPrompt\":\"保留 TokenHUD 中文\"}\n".utf8)
        try fixture.write(authBytes, to: account.appendingPathComponent("auth.json"))
        let old: [String: Any] = [
            "tokenhud.appLanguage": "en", "tokenhud.providerOrder": ["second-account", "stable-account-42"],
            "tokenhud.disabledProviders": ["second-account"], "tokenhud.hudHidden.slugs": ["stable-account-42"],
            "tokenhud.floatingHidden.slugs": ["second-account"], "tokenhud.triggerDisabled.slugs": ["second-account"],
            "tokenhud.interval.stable-account-42": 15, "tokenhud.scheduleFired": "fixture:2026-11-05:09:00",
            "tokenhud.sourceAutoSync.enabled": false, "tokenhud.ratelimit.pausedUntil": "fixture-paused",
            "tokenhud.panelStyle": "card", "tokenhud.settings.selected": "stable-account-42",
            "tokenhud.iconProvider": "second-account", "floatingFrame": "{{10, 20}, {300, 400}}",
            "NSWindow Frame TokenHUDSettings": "10 20 600 700", "AppleLanguages": ["en", "zh-Hans"]
        ]
        fixture.preferences(old)
        fixture.preferences(["quotanest.iconProvider": "new-existing-account", "newOnly": true], target: true)
        let before = try fixture.snapshot(fixture.legacy)
        let result = try fixture.migrate()
        #expect(result.migrated)
        #expect(result.providersDir == fixture.target.appendingPathComponent("providers", isDirectory: true))
        #expect(!FileManager.default.fileExists(atPath: fixture.legacy.path))
        let backup = try #require(result.backupDirectory)
        #expect(backup.deletingLastPathComponent().lastPathComponent == "MigrationBackups")
        #expect(backup.lastPathComponent.hasPrefix("TokenHUD-"))
        #expect(try fixture.snapshot(backup) == before)
        #expect(try Data(contentsOf: result.providersDir.appendingPathComponent("stable-account-42/auth.json")) == authBytes)
        let preferences = try #require(fixture.defaults.persistentDomain(forName: fixture.targetDomain))
        for (key, value) in old where key != "tokenhud.iconProvider" {
            let mapped = key.hasPrefix("tokenhud.") ? "quotanest." + key.dropFirst("tokenhud.".count) : key
            let migratedValue = try #require(preferences[mapped])
            #expect(NSDictionary(dictionary: ["value": migratedValue]).isEqual(to: ["value": value]))
        }
        #expect(preferences["quotanest.iconProvider"] as? String == "new-existing-account")
        #expect(preferences["tokenhud.appLanguage"] == nil)
        #expect(NSDictionary(dictionary: fixture.defaults.persistentDomain(forName: fixture.legacyDomain) ?? [:]).isEqual(to: old))
        let report = String(decoding: try Data(contentsOf: #require(result.reportURL)), as: UTF8.self)
        #expect(report.contains("originalTreeHash"))
        #expect(report.contains("schemaVersion"))
        #expect(!report.contains("fixture-only-key"))
        #expect(!report.contains("testPrompt"))
        #expect(!report.contains("09:00"))
        #expect(try fixture.noStagingDirectories())
    }

    @Test func completedMarkerIsIdempotentAndNeverReplaysLegacyPreferencesOrFiles() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.account()
        fixture.preferences(["tokenhud.appLanguage": "en"])
        let first = try fixture.migrate()
        let targetBefore = try fixture.snapshot(fixture.target)
        fixture.preferences(["tokenhud.appLanguage": "zh-Hans", "tokenhud.injectedLater": true])
        fixture.preferences(["quotanest.appLanguage": "zh-Hant", "postMigration": true], target: true)
        // A recreated legacy directory must also remain untouched after the committed marker.
        try fixture.account("legacy-recreated")
        let recreatedBefore = try fixture.snapshot(fixture.legacy)
        let second = try fixture.migrate()
        #expect(!second.migrated)
        #expect(second.backupDirectory == first.backupDirectory)
        #expect(second.reportURL == first.reportURL)
        #expect(try fixture.snapshot(fixture.target) == targetBefore)
        #expect(try fixture.snapshot(fixture.legacy) == recreatedBefore)
        let preferences = fixture.defaults.persistentDomain(forName: fixture.targetDomain) ?? [:]
        #expect(preferences["quotanest.appLanguage"] as? String == "zh-Hant")
        #expect(preferences["quotanest.injectedLater"] == nil)
    }

    @Test func removedBackupAndReportDoNotBlockCompletedMigrationOrReplayHistory() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.account()
        fixture.preferences(["tokenhud.appLanguage": "en"])
        let first = try fixture.migrate()
        let backup = try #require(first.backupDirectory)
        let report = try #require(first.reportURL)
        let backups = fixture.target.appendingPathComponent("MigrationBackups", isDirectory: true)
        try #require(backup.deletingLastPathComponent().standardizedFileURL == backups.standardizedFileURL)
        try #require(backup.lastPathComponent.hasPrefix("TokenHUD-"))
        try #require(report.standardizedFileURL == fixture.target.appendingPathComponent(AppIdentityMigration.reportFilename).standardizedFileURL)
        try FileManager.default.removeItem(at: backup)
        try FileManager.default.removeItem(at: report)
        try #require(FileManager.default.contentsOfDirectory(atPath: backups.path).isEmpty)
        try FileManager.default.removeItem(at: backups)
        try fixture.write(Data("current-account-state\n".utf8), to: first.providersDir.appendingPathComponent("my-account/current-state.txt"))
        fixture.preferences(["quotanest.appLanguage": "zh-Hant", "postMigration": true], target: true)
        fixture.preferences(["tokenhud.appLanguage": "zh-Hans", "tokenhud.injectedLater": true])
        try fixture.account("recreated-legacy-account")
        let currentTarget = try fixture.snapshot(fixture.target)
        let recreatedLegacy = try fixture.snapshot(fixture.legacy)
        let currentPreferences = fixture.defaults.persistentDomain(forName: fixture.targetDomain) ?? [:]
        let second = try fixture.migrate()
        #expect(!second.migrated)
        #expect(second.providersDir == first.providersDir)
        #expect(second.backupDirectory == nil)
        #expect(second.reportURL == nil)
        #expect(try fixture.snapshot(fixture.target) == currentTarget)
        #expect(try fixture.snapshot(fixture.legacy) == recreatedLegacy)
        #expect(NSDictionary(dictionary: fixture.defaults.persistentDomain(forName: fixture.targetDomain) ?? [:]).isEqual(to: currentPreferences))
        #expect(try fixture.noStagingDirectories())
    }

    @Test func everyTransactionFailureRestoresOriginalDirectoryAndTargetPreferences() throws {
        for failurePoint in AppIdentityMigration.Checkpoint.allCases {
            let fixture = try Fixture(); defer { fixture.cleanup() }
            try fixture.account()
            fixture.preferences(["tokenhud.appLanguage": "en", "tokenhud.providerOrder": ["my-account"]])
            let targetPreferences: [String: Any] = ["quotanest.appLanguage": "zh-Hant", "unchanged": [1, 2, 3]]
            fixture.preferences(targetPreferences, target: true)
            let original = try fixture.snapshot(fixture.legacy)
            #expect(throws: AppIdentityMigration.MigrationError.self) {
                try fixture.migrate { point in if point == failurePoint { throw InjectedFailure() } }
            }
            #expect(try fixture.snapshot(fixture.legacy) == original)
            #expect(!FileManager.default.fileExists(atPath: fixture.target.path))
            #expect(NSDictionary(dictionary: fixture.defaults.persistentDomain(forName: fixture.targetDomain) ?? [:]).isEqual(to: targetPreferences))
            #expect(try fixture.noStagingDirectories())
        }
    }

    @Test func rollbackRemovesNewTargetPreferenceDomainWhenNoneExisted() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.account()
        fixture.preferences(["tokenhud.appLanguage": "en"])
        #expect(throws: AppIdentityMigration.MigrationError.self) {
            try fixture.migrate { point in if point == .preferencesWritten { throw InjectedFailure() } }
        }
        #expect((fixture.defaults.persistentDomain(forName: fixture.targetDomain) ?? [:]).isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.legacy.path))
        #expect(try fixture.noStagingDirectories())
    }

    @Test func nonemptyUnmarkedTargetAndFilenameConflictsAreNeverOverwritten() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.account()
        try fixture.write(Data("existing-user-file".utf8), to: fixture.target.appendingPathComponent("providers/my-account/manifest.json"))
        let old = try fixture.snapshot(fixture.legacy), new = try fixture.snapshot(fixture.target)
        #expect(throws: AppIdentityMigration.MigrationError.self) { try fixture.migrate() }
        #expect(try fixture.snapshot(fixture.legacy) == old)
        #expect(try fixture.snapshot(fixture.target) == new)
        #expect(try fixture.noStagingDirectories())
    }

    @Test func existingEmptyTargetCanBeAtomicallyReplacedAndRestoredOnFailure() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.account()
        try FileManager.default.createDirectory(at: fixture.target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o750])
        #expect(throws: AppIdentityMigration.MigrationError.self) {
            try fixture.migrate { point in if point == .activated { throw InjectedFailure() } }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.target.path).isEmpty)
        #expect((try FileManager.default.attributesOfItem(atPath: fixture.target.path)[.posixPermissions] as? NSNumber)?.intValue == 0o750)
        let result = try fixture.migrate()
        #expect(result.migrated)
    }

    @Test func rebasesOnlyOwnedExplicitPathsWithoutChangingAnyOtherJSONByte() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let old = fixture.legacy.path, new = fixture.target.path
        let prompt = "TokenHUD 原文 \(old)/providers/user text"
        let manifest = """
        { "name":"TokenHUD", "label":"TokenHUD 中文", "fetch":"\(old)/providers/my-account/fetch.sh",
          "authFile":"~/Library/Application Support/TokenHUD/providers/my-account/auth.json",
          "cacheFile":"\(old)-other/cache.json", "testPrompt":"\(prompt)",
          "queryUrl":"https://fixture.example/TokenHUD", "token":"\(old)/fixture-secret",
          "credentialSource":{"file":"\(old)/credentials.json","path":"\(old)/credentials.json","tokenPath":"tokenhud.secret"},
          "sourceReference":{"source":"tokenhud","path":"\(old)/own.json","recordId":"TokenHUD 原始PK","providerId":"TokenHUD-original-id"},
          "largeIdentifier":123456789012345678901234567890 }
        """
        let account = try fixture.account()
        try fixture.write(Data(manifest.utf8), to: account.appendingPathComponent("manifest.json"))
        let auth = "{ \"authCredentialFile\":\"\(old)/own.json\", \"token\":\"\(old)/unchanged-secret\", \"testPrompt\":\"TokenHUD\" }\n"
        try fixture.write(Data(auth.utf8), to: account.appendingPathComponent("auth.json"))
        let result = try fixture.migrate()
        let migrated = String(decoding: try Data(contentsOf: result.providersDir.appendingPathComponent("my-account/manifest.json")), as: UTF8.self)
        // Independent, explicit expected fragments: arbitrary strings sharing the same old-root text remain exact.
        let expected = manifest
            .replacingOccurrences(of: "\"fetch\":\"\(old)/providers/my-account/fetch.sh\"", with: "\"fetch\":\"\(new)/providers/my-account/fetch.sh\"")
            .replacingOccurrences(of: "\"authFile\":\"~/Library/Application Support/TokenHUD/providers/my-account/auth.json\"", with: "\"authFile\":\"~/Library/Application Support/QuotaNest/providers/my-account/auth.json\"")
            .replacingOccurrences(of: "\"file\":\"\(old)/credentials.json\"", with: "\"file\":\"\(new)/credentials.json\"")
            .replacingOccurrences(of: "\"path\":\"\(old)/credentials.json\"", with: "\"path\":\"\(new)/credentials.json\"")
            .replacingOccurrences(of: "\"path\":\"\(old)/own.json\"", with: "\"path\":\"\(new)/own.json\"")
        #expect(migrated == expected)
        let migratedAuth = String(decoding: try Data(contentsOf: result.providersDir.appendingPathComponent("my-account/auth.json")), as: UTF8.self)
        #expect(migratedAuth == auth.replacingOccurrences(of: "\"authCredentialFile\":\"\(old)/own.json\"", with: "\"authCredentialFile\":\"\(new)/own.json\""))
        #expect(try Data(contentsOf: #require(result.backupDirectory).appendingPathComponent("providers/my-account/manifest.json")) == Data(manifest.utf8))
    }

    @Test func sourceReferencesExternalHUDAndStableAuthCacheNamesRemainExact() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        for source in ["9router", "cc-switch", "cpamp", "magpie"] {
            let slug = "source-" + source
            let path = fixture.home.appendingPathComponent("external/\(source)/TokenHUD-auth.json").path
            let directory = try fixture.account(slug, manifest: [
                "authFile": "~/.claude/hud/.cline-usage-auth.json", "cacheFile": "~/.claude/hud/.cline-usage-cache.json",
                "fetch": fixture.home.appendingPathComponent(".claude/hud/fetch-TokenHUD.sh").path,
                "sourceReference": ["source": source, "path": path, "recordId": "TokenHUD 原始PK", "providerId": "TokenHUD-original-id"],
                "testPrompt": "TokenHUD 中文", "refreshHeader": "Bearer fixture-TokenHUD-key"
            ])
            try fixture.write(Data("{\"sourceReference\":{\"source\":\"\(source)\",\"path\":\"\(path)\",\"recordId\":\"TokenHUD-PK\",\"providerId\":\"TokenHUD-id\"}}".utf8),
                              to: directory.appendingPathComponent("auth.json"))
        }
        let before = try fixture.snapshot(fixture.legacy.appendingPathComponent("providers"))
        let result = try fixture.migrate()
        #expect(try fixture.snapshot(result.providersDir) == before)
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".claude").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("external").path))
    }

    @Test func externalToolReferenceWithOldRootTextIsNotRebranded() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let directory = try fixture.account(manifest: [
            "sourceReference": ["source": "9router", "path": fixture.legacy.appendingPathComponent("source.db").path,
                                "recordId": "unchanged-primary-key", "providerId": "unchanged-provider-id"]
        ])
        let bytes = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let result = try fixture.migrate()
        #expect(try Data(contentsOf: result.providersDir.appendingPathComponent("my-account/manifest.json")) == bytes)
    }

    @Test func defaultsOnlyRebaseExplicitOwnedDirectoryOrNodeFields() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let externalNode = fixture.home.appendingPathComponent(".nvm/TokenHUD/bin/node").path
        fixture.preferences([
            "tokenhud.providersDir": fixture.legacy.appendingPathComponent("providers").path,
            "tokenhud.appSupportDirectory": "~/Library/Application Support/TokenHUD",
            "tokenhud.nodePath": externalNode,
            "tokenhud.testPrompt": fixture.legacy.path + "/unchanged text", "tokenhud.source": ["path": fixture.legacy.path],
            "tokenhud.userProvidersDir": fixture.legacy.path + "-other/providers"
        ])
        _ = try fixture.migrate()
        let values = fixture.defaults.persistentDomain(forName: fixture.targetDomain) ?? [:]
        #expect(values["quotanest.providersDir"] as? String == fixture.target.appendingPathComponent("providers").path)
        #expect(values["quotanest.appSupportDirectory"] as? String == "~/Library/Application Support/QuotaNest")
        #expect(values["quotanest.nodePath"] as? String == externalNode)
        #expect(values["quotanest.testPrompt"] as? String == fixture.legacy.path + "/unchanged text")
        #expect((values["quotanest.source"] as? [String: String])?["path"] == fixture.legacy.path)
        #expect(values["quotanest.userProvidersDir"] as? String == fixture.legacy.path + "-other/providers")
    }

    @Test func ownedNodePathRebasesButDotDotAndSiblingPrefixesDoNot() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        fixture.preferences(["tokenhud.nodePath": fixture.legacy.appendingPathComponent("runtime/bin/node").path,
                             "tokenhud.providersDir": fixture.legacy.path + "/../TokenHUD-other/providers"])
        _ = try fixture.migrate()
        let values = fixture.defaults.persistentDomain(forName: fixture.targetDomain) ?? [:]
        #expect(values["quotanest.nodePath"] as? String == fixture.target.appendingPathComponent("runtime/bin/node").path)
        #expect(values["quotanest.providersDir"] as? String == fixture.legacy.path + "/../TokenHUD-other/providers")
    }

    @Test func preservesRootDirectoryFileAndExecutablePermissions() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let account = try fixture.account()
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: fixture.legacy.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o710], ofItemAtPath: account.path)
        try fixture.write(Data("{\"authCredentialFile\":\"\(fixture.legacy.path)/owned.json\"}".utf8), to: account.appendingPathComponent("auth.json"), mode: 0o400)
        let before = try fixture.snapshot(fixture.legacy)
        let result = try fixture.migrate()
        for (relative, description) in before {
            let actual = try FileManager.default.attributesOfItem(atPath: fixture.target.appendingPathComponent(relative).path)
            let expectedMode = description.split(separator: ":")[1]
            #expect(String((actual[.posixPermissions] as? NSNumber)?.intValue ?? -1) == expectedMode)
        }
        #expect(try fixture.snapshot(#require(result.backupDirectory)) == before)
    }

    @Test func freshInstallCreatesUsableProvidersAndIdempotentMarkerWithoutHistoryReport() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let result = try fixture.migrate()
        #expect(!result.migrated)
        #expect(result.backupDirectory == nil)
        #expect(result.reportURL == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: result.providersDir.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.target.appendingPathComponent(AppIdentityMigration.markerFilename).path))
        #expect(!(try fixture.migrate()).migrated)
        #expect(try fixture.noStagingDirectories())
    }

    @Test func preferencesOnlyHistoryMigratesAndNeverRequiresLegacyDirectory() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        fixture.preferences(["tokenhud.appLanguage": "en", "floatingFrame": "fixture frame"])
        let result = try fixture.migrate()
        #expect(result.migrated)
        #expect(result.backupDirectory == nil)
        #expect(result.reportURL != nil)
        #expect(fixture.defaults.persistentDomain(forName: fixture.targetDomain)?["quotanest.appLanguage"] as? String == "en")
        #expect(fixture.defaults.persistentDomain(forName: fixture.targetDomain)?["floatingFrame"] as? String == "fixture frame")
        #expect(!FileManager.default.fileExists(atPath: fixture.legacy.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: result.providersDir.path).isEmpty)
    }

    @Test func malformedJSONAndUnloadableManifestStopWithoutChangingOriginals() throws {
        for invalid in [Data("{invalid-fixture-json".utf8), Data("{\"name\":42,\"label\":false}".utf8)] {
            let fixture = try Fixture(); defer { fixture.cleanup() }
            let account = try fixture.account()
            try fixture.write(invalid, to: account.appendingPathComponent("manifest.json"))
            fixture.preferences(["tokenhud.appLanguage": "en"])
            let before = try fixture.snapshot(fixture.legacy)
            #expect(throws: AppIdentityMigration.MigrationError.self) { try fixture.migrate() }
            #expect(try fixture.snapshot(fixture.legacy) == before)
            #expect(!FileManager.default.fileExists(atPath: fixture.target.path))
            #expect((fixture.defaults.persistentDomain(forName: fixture.targetDomain) ?? [:]).isEmpty)
            #expect(try fixture.noStagingDirectories())
        }
    }

    @Test func externalFileAndDirectorySymlinksArePreservedWithoutFollowingOrRebasing() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let outside = fixture.home.appendingPathComponent("external-auth", isDirectory: true)
        // Deliberately invalid JSON proves a linked external Auth file is never opened or validated.
        let externalFile = outside.appendingPathComponent("auth.json")
        let externalBytes = Data("external-auth-is-not-owned-json".utf8)
        try fixture.write(externalBytes, to: externalFile)
        let account = try fixture.account()
        let link = account.appendingPathComponent("external-auth.json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: externalFile.path)
        try FileManager.default.createSymbolicLink(atPath: account.appendingPathComponent("external-directory").path, withDestinationPath: outside.path)
        let sourceManifest = "{\"name\":\"Fixture\",\"label\":\"Fixture\",\"authFile\":\"\(link.path)\",\"fetch\":\"./fetch.sh\"}"
        try fixture.write(Data(sourceManifest.utf8), to: account.appendingPathComponent("manifest.json"))
        let outsideBefore = try fixture.snapshot(outside)
        let result = try fixture.migrate()
        let copied = result.providersDir.appendingPathComponent("my-account")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: copied.appendingPathComponent("external-auth.json").path) == externalFile.path)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: copied.appendingPathComponent("external-directory").path) == outside.path)
        #expect(try Data(contentsOf: copied.appendingPathComponent("manifest.json")) == Data(sourceManifest.utf8))
        #expect(try fixture.snapshot(outside) == outsideBefore)
        #expect(try Data(contentsOf: externalFile) == externalBytes)
        let report = try JSONSerialization.jsonObject(with: Data(contentsOf: #require(result.reportURL))) as? [String: Any]
        #expect(report?["fileCount"] as? Int == 2)
    }

    @Test func symlinkedLegacyTargetAndSupportRootsAreRejectedWithoutTouchingExternalData() throws {
        for location in ["legacy", "target", "support"] {
            let fixture = try Fixture(); defer { fixture.cleanup() }
            let outside = fixture.home.appendingPathComponent("external", isDirectory: true)
            try fixture.write(Data("external-user-data".utf8), to: outside.appendingPathComponent("keep"))
            let link: URL
            if location == "support" {
                try FileManager.default.createDirectory(at: fixture.home.appendingPathComponent("Library"), withIntermediateDirectories: true)
                link = fixture.support
            } else {
                try FileManager.default.createDirectory(at: fixture.support, withIntermediateDirectories: true)
                link = location == "legacy" ? fixture.legacy : fixture.target
            }
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: outside.path)
            let before = try fixture.snapshot(outside)
            #expect(throws: AppIdentityMigration.MigrationError.self) { try fixture.migrate() }
            #expect(try fixture.snapshot(outside) == before)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == outside.path)
        }
    }

    @Test func stageReplacementWithExternalSymlinkIsRejectedWithoutFollowingIt() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.account()
        let original = try fixture.snapshot(fixture.legacy)
        let outside = fixture.home.appendingPathComponent("external", isDirectory: true)
        try fixture.write(Data("external-stage-sentinel".utf8), to: outside.appendingPathComponent("keep"))
        let outsideBefore = try fixture.snapshot(outside)
        var insertedLink: URL?
        #expect(throws: AppIdentityMigration.MigrationError.self) {
            try fixture.migrate { point in
                if point == .staged {
                    let stage = try #require(FileManager.default.contentsOfDirectory(at: fixture.support, includingPropertiesForKeys: nil)
                        .first { $0.lastPathComponent.hasPrefix(".QuotaNest-migration-") })
                    let movedStage = fixture.home.appendingPathComponent("retained-private-stage", isDirectory: true)
                    try FileManager.default.moveItem(at: stage, to: movedStage)
                    try FileManager.default.createSymbolicLink(atPath: stage.path, withDestinationPath: outside.path)
                    insertedLink = stage
                }
            }
        }
        #expect(try fixture.snapshot(fixture.legacy) == original)
        #expect(try fixture.snapshot(outside) == outsideBefore)
        #expect(!FileManager.default.fileExists(atPath: fixture.target.path))
        if let insertedLink {
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: insertedLink.path) == outside.path)
        }
    }

    @Test func incompleteMarkerIsAnExplicitConflict() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.account()
        try fixture.write(Data("{\"schemaVersion\":1,\"completed\":false}".utf8),
                          to: fixture.target.appendingPathComponent(AppIdentityMigration.markerFilename))
        let old = try fixture.snapshot(fixture.legacy), target = try fixture.snapshot(fixture.target)
        #expect(throws: AppIdentityMigration.MigrationError.self) { try fixture.migrate() }
        #expect(try fixture.snapshot(fixture.legacy) == old)
        #expect(try fixture.snapshot(fixture.target) == target)
    }
}
