import Foundation
import CryptoKit
import Darwin

/// Explicitly authorized local rebuild. This entry point never starts an engine or a request.
@MainActor
enum AccountRebuildVerification {
    struct Summary: Codable {
        var status = "fail"
        var failure = "not-started"
        var finalAccounts = 0
        var imported = 0
        var duplicatesSkipped = 0
        var manualRetained = false
        var fixtureCRUD = false
        var localCRUD = false
        var importedCRUD = false
        var deleteChecks = false
        var filterChecks = false
        var externalFilesUnchanged = false
        var globalPreferencesUnchanged = false
        var plansDisabled = false
        var modelCalls = 0
        var quotaCalls = 0
        var reportWritten = false
    }

    struct RecordOutcome: Codable {
        let position: Int
        let source: String
        let priorAttempts: Int
        var outcome: String
    }

    private struct ExternalChange: Codable {
        let phase: String
        let pathHash: String
        let category: String
        let existenceChanged: Bool
        let contentChanged: Bool
        let destinationChanged: Bool
        let beforeExists: Bool
        let afterExists: Bool
        let beforeSHA256: String?
        let afterSHA256: String?
        let beforeDestinationHash: String?
        let afterDestinationHash: String?
    }

    private struct Result: Codable {
        let schemaVersion = 1
        var summary = Summary()
        var perRecord: [RecordOutcome] = []
        // Private diagnostics only: no raw external path, record identity or credential.
        var externalChanges: [ExternalChange] = []
    }

    private struct InputReport: Decodable {
        let summary: ImportVerification.Summary
        let records: [ImportVerification.Record]
    }

    private struct Inventory: Decodable {
        struct Entry: Decodable {
            let source: String
            let backup: String
            let type: String
            let sha256: String?
        }
        let entries: [Entry]
    }

    private struct Manual {
        let choice: TemplateChoice
        let values: DraftValues
        let canonicalIdentity: String?
    }

    private struct Identity: Hashable {
        let source: String
        let record: String
        let collection: String?
        let template: String?
        init(_ candidate: ImportCandidate) {
            source = candidate.source
            record = candidate.sourceRecordId
            collection = candidate.sourceReference?.collection
            template = candidate.template
        }
        init(_ row: ImportVerification.Record) {
            source = row.source.rawValue
            record = row.account.recordId
            collection = row.account.collection
            template = row.template
        }
    }

    private struct FileStamp: Equatable {
        let exists: Bool
        let destination: String
        let digest: String?
    }

    private struct Stop: Error { let code: String }
    private final class Requests {
        var models = 0
        var quotas = 0
    }

    /// `report` is the completed private ImportVerification JSON; `output` is a new file inside backup.
    /// Failure preserves existing local changes for inspection and never restores over an account.
    static func run(backup: URL, report: URL, output: URL) async -> Summary {
        var result = Result()
        var mayWrite = false
        let requests = Requests()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let userDir = home.appendingPathComponent("Library/Application Support/QuotaNest/providers")
        let hud = home.appendingPathComponent(".claude/hud")
        var sourcePaths = Set<URL>()
        var before: [String: FileStamp] = [:]
        var originalPreferences: [String: Any] = [:]
        let domain = "local.quotanest"
        let defaults = UserDefaults(suiteName: domain)
        let previousMask = umask(0o077)
        defer { umask(previousMask) }
        do {
            try privateTree(backup)
            try privateFile(report)
            try requireInside(report, root: backup)
            try requireInside(output, root: backup)
            try privateDirectory(output.deletingLastPathComponent())
            guard !FileManager.default.fileExists(atPath: output.path),
                  !isLink(output), report.standardizedFileURL != output.standardizedFileURL else {
                throw Stop(code: "output-already-exists")
            }
            mayWrite = true
            try requireStopped()
            try ordinaryDirectory(userDir)
            try ordinaryDirectory(hud)
            guard try FileManager.default.contentsOfDirectory(atPath: userDir.path).isEmpty else {
                throw Stop(code: "real-account-directory-not-empty")
            }
            guard ProcessInfo.processInfo.environment["TOKENHUD_DEBUG_SETTINGS"] != "1",
                  let defaults else { throw Stop(code: "unsafe-runtime") }
            let plan = try object(backup.appendingPathComponent("clear-plan.json"))
            guard plan["executed"] as? Bool == true,
                  (plan["providers_directory"] as? String).map({ URL(fileURLWithPath: $0).standardizedFileURL }) == userDir.standardizedFileURL else {
                throw Stop(code: "clear-plan-not-executed")
            }
            let input = try JSONDecoder().decode(InputReport.self, from: Data(contentsOf: report))
            guard input.summary.status == .complete, input.summary.reportWritten,
                  input.records.count == input.summary.total else { throw Stop(code: "quota-report-incomplete") }
            let templates = ProviderImporter.bundledTemplates()
            guard !templates.isEmpty,
                  let bundle = Bundle.appResources.resourceURL?.appendingPathComponent("providers") else {
                throw Stop(code: "bundled-templates-unavailable")
            }
            originalPreferences = defaults.persistentDomain(forName: domain) ?? [:]
            guard defaults.object(forKey: DataEngine.defaultsSourceAutoSyncKey) as? Bool == false else {
                throw Stop(code: "source-auto-sync-must-remain-off")
            }
            let candidates = scan(home: home, templates: templates)
            sourcePaths = externalPaths(plan: plan, candidates: candidates, home: home)
            before = try stamps(sourcePaths)
            let scratchSettings = backup.appendingPathComponent("metadata/local-rebuild-hud-settings-" + UUID().uuidString + ".json")
            try Data("{}".utf8).write(to: scratchSettings, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scratchSettings.path)
            let engine = DataEngine(hudDir: hud, bundleProvidersDir: bundle, userProvidersDir: userDir,
                                    runner: ProviderRunner(nodePath: nil, logDir: hud), defaults: defaults,
                                    settingsURL: scratchSettings)
            engine.quotaAttempt = { _ in requests.quotas += 1; return nil }
            engine.installRuntimeScripts()
            engine.reloadRegistry()
            let model = SettingsModel(engine: engine, hudDir: hud, userDir: userDir,
                                      settingsURL: scratchSettings, bundleDir: bundle, defaults: defaults,
                                      confirmDiscardChanges: { true }, confirmResumePlan: { false },
                                      confirmTestCall: { _ in false },
                                      executeTestCall: { _ in requests.models += 1; return "local-verification-network-disabled" },
                                      executeQuotaQuery: { _ in requests.quotas += 1; return .failed("local-verification-network-disabled") },
                                      confirmDeleteAccount: { true })
            var firstImported: (ImportCandidate, String)?
            for (index, row) in input.records.enumerated() {
                var outcome = RecordOutcome(position: index + 1, source: row.source.rawValue,
                                            priorAttempts: row.attemptCount, outcome: "prior-quota-not-successful")
                guard row.quota == .success, row.apply == .success, row.attemptCount > 0,
                      row.attempts.last?.status == .success else {
                    result.perRecord.append(outcome)
                    continue
                }
                let matches = candidates.filter { Identity($0) == Identity(row) }
                guard matches.count == 1, let candidate = matches.first,
                      candidate.unsupportedReason == nil else {
                    outcome.outcome = "successful-source-record-no-longer-unique"
                    result.perRecord.append(outcome)
                    continue
                }
                try requireStopped()
                var applied = false
                do {
                    let slug = try ProviderImporter.apply(candidate, templates: templates, userDir: userDir, hudDir: hud)
                    applied = true
                    engine.reloadRegistry()
                    engine.setTriggerEnabled(slug, enabled: false)
                    try checkImported(slug, candidate: candidate, userDir: userDir, hud: hud)
                    result.summary.imported += 1
                    outcome.outcome = "imported"
                    if firstImported == nil { firstImported = (candidate, slug) }
                } catch {
                    if applied { throw Stop(code: "import-postcondition-failed") }
                    if duplicate(candidate, templates: templates, userDir: userDir) {
                        outcome.outcome = "duplicate-skipped"
                        result.summary.duplicatesSkipped += 1
                    } else { outcome.outcome = "local-import-failed" }
                }
                result.perRecord.append(outcome)
            }
            if let (candidate, slug) = firstImported {
                let snapshot = try stamps(sourcePaths)
                guard let plugin = ProviderRegistry.scan(dir: userDir).first(where: { $0.slug == slug }) else {
                    throw Stop(code: "imported-account-missing")
                }
                let reference = plugin.manifest.sourceReference
                guard model.renameDisplayName(slug, name: "Local verification display"),
                      ProviderRegistry.scan(dir: userDir).first(where: { $0.slug == slug })?.manifest.sourceReference == reference else {
                    throw Stop(code: "imported-rename-failed")
                }
                try delete(slug, model: model, userDir: userDir, hud: hud)
                try requireStopped()
                let restored = try ProviderImporter.apply(candidate, templates: templates, userDir: userDir, hudDir: hud)
                engine.reloadRegistry()
                engine.setTriggerEnabled(restored, enabled: false)
                try checkImported(restored, candidate: candidate, userDir: userDir, hud: hud)
                let after = try stamps(sourcePaths)
                result.externalChanges += externalChanges(before: snapshot, after: after, phase: "imported-crud", home: home)
                result.summary.importedCRUD = true
                guard snapshot == after else { throw Stop(code: "externally-changed-needs-recheck") }
            }
            let manual = try loadManual(backup: backup, userDir: userDir, templates: templates, model: model)
            let values: DraftValues
            let choice: TemplateChoice
            if let manual {
                values = manual.values
                choice = manual.choice
            } else {
                guard let generic = model.choices.first(where: { $0.id == "generic-openai" }) else {
                    throw Stop(code: "fixture-template-unavailable")
                }
                choice = generic
                var fixture = DraftValues()
                fixture.name = "fixture-test-account"
                fixture.url = "https://example.invalid"
                fixture.autoQuery = false
                fixture.autoTrigger = false
                fixture.times = []
                values = fixture
                result.summary.fixtureCRUD = true
            }
            let snapshot = try stamps(sourcePaths)
            var testValues = values
            if manual != nil { testValues.name = "Local verification manual" }
            let testSlug = try create(testValues, choice: choice, model: model, engine: engine, userDir: userDir, hud: hud)
            guard let testPlugin = ProviderRegistry.scan(dir: userDir).first(where: { $0.slug == testSlug }) else {
                throw Stop(code: "manual-account-missing")
            }
            let pointer = model.readConfig(testPlugin).authCredentialFile
            guard model.renameDisplayName(testSlug, name: "Local verification renamed"),
                  model.renameDisplayName(testSlug, name: testValues.name),
                  let renamed = ProviderRegistry.scan(dir: userDir).first(where: { $0.slug == testSlug }),
                  renamed.manifest.fullName == testValues.name,
                  model.readConfig(renamed).authCredentialFile == pointer,
                  renamed.manifest.sourceReference == nil else { throw Stop(code: "manual-rename-failed") }
            try delete(testSlug, model: model, userDir: userDir, hud: hud)
            let afterManual = try stamps(sourcePaths)
            result.externalChanges += externalChanges(before: snapshot, after: afterManual, phase: "manual-crud", home: home)
            result.summary.localCRUD = true
            result.summary.deleteChecks = result.summary.localCRUD && result.summary.importedCRUD
            guard snapshot == afterManual else { throw Stop(code: "externally-changed-needs-recheck") }
            if let manual {
                let live = ProviderRegistry.scan(dir: userDir)
                let duplicateIdentity = manual.canonicalIdentity.map { identity in
                    live.contains { ProviderAccountIdentity.fingerprint(provider: $0, templates: templates) == identity }
                } ?? false
                if duplicateIdentity { result.summary.duplicatesSkipped += 1 }
                else {
                    _ = try create(manual.values, choice: manual.choice, model: model, engine: engine, userDir: userDir, hud: hud)
                    result.summary.manualRetained = true
                }
            }
            result.summary.filterChecks = try verifyFilters(model: model, userDir: userDir)
            let final = ProviderRegistry.scan(dir: userDir)
            for plugin in final { engine.setTriggerEnabled(plugin.slug, enabled: false) }
            result.summary.plansDisabled = final.allSatisfy { plugin in
                model.readConfig(plugin).scheduleTimes.isEmpty && engine.triggerDisabledSlugs.contains(plugin.slug)
            }
            let afterRun = try stamps(sourcePaths)
            result.externalChanges += externalChanges(before: before, after: afterRun, phase: "whole-run", home: home)
            result.summary.externalFilesUnchanged = before == afterRun
            result.summary.globalPreferencesUnchanged = preferencesUnchanged(originalPreferences,
                after: defaults.persistentDomain(forName: domain) ?? [:])
            result.summary.finalAccounts = final.count
            result.summary.modelCalls = requests.models
            result.summary.quotaCalls = requests.quotas
            let recordFailures = result.perRecord.contains {
                ["successful-source-record-no-longer-unique", "local-import-failed"].contains($0.outcome)
            }
            let passed = !recordFailures && result.summary.localCRUD && result.summary.importedCRUD
                && result.summary.deleteChecks && result.summary.filterChecks && result.summary.plansDisabled
                && result.summary.externalFilesUnchanged && result.summary.globalPreferencesUnchanged
                && requests.models == 0 && requests.quotas == 0
            result.summary.status = passed ? "success" : "fail"
            result.summary.failure = passed ? "none" : (result.summary.externalFilesUnchanged
                ? "local-acceptance-incomplete" : "externally-changed-needs-recheck")
        } catch {
            result.summary.status = "fail"
            result.summary.failure = (error as? Stop)?.code ?? "local-verification-failed"
            result.summary.modelCalls = requests.models
            result.summary.quotaCalls = requests.quotas
            if !before.isEmpty, let after = try? stamps(sourcePaths) {
                result.externalChanges += externalChanges(before: before, after: after, phase: "failure-exit", home: home)
                result.summary.externalFilesUnchanged = before == after
            }
            result.summary.finalAccounts = ProviderRegistry.scan(dir: userDir).count
        }
        if mayWrite {
            do {
                result.summary.reportWritten = true
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(result).write(to: output, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
            } catch {
                result.summary.status = "fail"
                result.summary.failure = "private-output-write-failed"
                result.summary.reportWritten = false
            }
        }
        return result.summary
    }

    private static func scan(home: URL, templates: [PluginProvider]) -> [ImportCandidate] {
        ProviderImporter.from9Router(home: home.path, templates: templates)
            + ProviderImporter.fromCCSwitch(home: home.path, templates: templates)
            + ProviderImporter.fromCPAMP(home: home.path, templates: templates)
            + ProviderImporter.fromMagpie(home: home.path, templates: templates)
    }

    private static func duplicate(_ candidate: ImportCandidate, templates: [PluginProvider], userDir: URL) -> Bool {
        let providers = ProviderRegistry.scan(dir: userDir)
        if providers.contains(where: { provider in
            ProviderImporter.sameSourceAccount(candidate, manifest: provider.manifest,
                templateLookup: { slug in templates.first { $0.slug == slug }?.manifest })
        }) { return true }
        guard let reference = candidate.sourceReference,
              let record = try? ImportedSource.read(reference),
              let identity = ProviderAccountIdentity.fingerprint(record: record,
                template: templates.first { $0.slug == candidate.template }) else { return false }
        return providers.contains { ProviderAccountIdentity.fingerprint(provider: $0, templates: templates) == identity }
    }

    private static func checkImported(_ slug: String, candidate: ImportCandidate, userDir: URL, hud: URL) throws {
        guard let plugin = ProviderRegistry.scan(dir: userDir).first(where: { $0.slug == slug }),
              plugin.manifest.sourceReference == candidate.sourceReference,
              let raw = plugin.manifest.authFile else { throw Stop(code: "import-reference-mismatch") }
        let auth = PluginGenerator.expandPath(raw)
        guard AccountFileOwnership.canRemoveHUDFile(auth, slug: slug, kind: .auth, hudDir: hud) else {
            throw Stop(code: "import-auth-not-owned")
        }
        try privateFile(auth)
        let config = try object(auth)
        guard Set(config.keys) == Set(["schemaVersion", "sourceReference"]) else {
            throw Stop(code: "import-copied-source-secret")
        }
    }

    private static func create(_ values: DraftValues, choice: TemplateChoice, model: SettingsModel,
                               engine: DataEngine, userDir: URL, hud: URL) throws -> String {
        try requireStopped()
        let old = Set(ProviderRegistry.scan(dir: userDir).map(\.slug))
        let base = PluginGenerator.slugify(values.name.trimmingCharacters(in: .whitespaces))
        var expectedSlug = base
        var suffix = 2
        while engine.allPlugins.contains(where: { $0.slug == expectedSlug })
            || FileManager.default.fileExists(atPath: userDir.appendingPathComponent(expectedSlug).path) {
            expectedSlug = "\(base)-\(suffix)"
            suffix += 1
        }
        for path in [PluginGenerator.authPath(slug: expectedSlug, hudDir: hud),
                     PluginGenerator.cachePath(slug: expectedSlug, hudDir: hud)] {
            let file = PluginGenerator.expandPath(path)
            guard !FileManager.default.fileExists(atPath: file.path), !isLink(file) else {
                throw Stop(code: "manual-destination-already-exists")
            }
        }
        model.pickTemplate(choice)
        guard model.draft != nil else { throw Stop(code: "manual-draft-not-created") }
        var safe = values
        safe.autoTrigger = false
        safe.times = []
        safe.model = ""
        model.draft?.values = safe
        model.save()
        let added = ProviderRegistry.scan(dir: userDir).filter { !old.contains($0.slug) }
        guard model.draft == nil, model.errors.isEmpty, added.count == 1,
              let plugin = added.first, let raw = plugin.manifest.authFile else {
            throw Stop(code: "manual-save-failed")
        }
        let auth = PluginGenerator.expandPath(raw)
        guard AccountFileOwnership.canRemoveHUDFile(auth, slug: plugin.slug, kind: .auth, hudDir: hud) else {
            throw Stop(code: "manual-auth-not-owned")
        }
        try privateFile(auth)
        engine.setTriggerEnabled(plugin.slug, enabled: false)
        guard model.readConfig(plugin).scheduleTimes.isEmpty else { throw Stop(code: "manual-plan-not-empty") }
        return plugin.slug
    }

    private static func delete(_ slug: String, model: SettingsModel, userDir: URL, hud: URL) throws {
        try requireStopped()
        guard let plugin = ProviderRegistry.scan(dir: userDir).first(where: { $0.slug == slug }),
              AccountFileOwnership.canRemovePluginDirectory(plugin.dir, slug: slug, userDir: userDir),
              let auth = model.authURL(plugin),
              AccountFileOwnership.canRemoveHUDFile(auth, slug: slug, kind: .auth, hudDir: hud) else {
            throw Stop(code: "delete-ownership-rejected")
        }
        let cache = DataEngine.cachePath(for: plugin, hudDir: hud)
        if FileManager.default.fileExists(atPath: cache.path),
           !AccountFileOwnership.canRemoveHUDFile(cache, slug: slug, kind: .cache, hudDir: hud) {
            throw Stop(code: "delete-cache-ownership-rejected")
        }
        model.delete(slug)
        guard !FileManager.default.fileExists(atPath: plugin.dir.path),
              !FileManager.default.fileExists(atPath: auth.path),
              !FileManager.default.fileExists(atPath: cache.path) else { throw Stop(code: "local-delete-incomplete") }
    }

    private static func loadManual(backup: URL, userDir: URL, templates: [PluginProvider], model: SettingsModel) throws -> Manual? {
        let inventoryURL = backup.appendingPathComponent("metadata/inventory.json")
        try privateFile(inventoryURL)
        let inventory = try JSONDecoder().decode(Inventory.self, from: Data(contentsOf: inventoryURL))
        let manifests = inventory.entries.filter {
            $0.type == "file" && $0.source.hasPrefix(userDir.path + "/") && $0.source.hasSuffix("/manifest.json")
        }
        for entry in manifests {
            let file = try verifiedCopy(entry, root: backup)
            let manifest = try JSONDecoder().decode(ProviderManifest.self, from: Data(contentsOf: file))
            guard manifest.sourceReference == nil, manifest.origin?.isEmpty != false,
                  let template = manifest.template,
                  templates.contains(where: { $0.slug == template }),
                  let choice = model.choices.first(where: { $0.id == template }),
                  let raw = manifest.authFile,
                  let authEntry = inventory.entries.first(where: { $0.type == "file" && $0.source == PluginGenerator.expandPath(raw).path }) else { continue }
            let auth = try verifiedCopy(authEntry, root: backup)
            var config = ProviderConfigStore.read(authFile: auth, manifest: manifest)
            config.scheduleTimes = []
            config.testModel = ""
            guard config.authMode == "apikey" || config.authMode == "auth",
                  (try? ProviderAuthentication.resolveQuota(config)) != nil,
                  config.authMode != "apikey" || !config.refreshKey.isEmpty else { continue }
            var values = DraftValues()
            values.name = manifest.fullName
            values.url = config.apiBaseURL
            values.key = config.authMode == "apikey" ? config.refreshKey : ""
            values.model = ""
            values.prompt = config.testPrompt
            values.proto = config.refreshProtocol
            values.autoQuery = true
            values.autoTrigger = false
            values.times = []
            values.queryURL = config.queryUrl
            values.quotaMode = config.quotaMode
            values.authMode = config.authMode
            values.authCredentialFile = config.authCredentialFile
            var probeManifest = manifest
            probeManifest.authFile = auth.path
            let probe = PluginProvider(slug: template, manifest: probeManifest, dir: file.deletingLastPathComponent())
            return Manual(choice: choice, values: values,
                          canonicalIdentity: ProviderAccountIdentity.fingerprint(provider: probe, templates: templates))
        }
        return nil
    }

    private static func verifiedCopy(_ entry: Inventory.Entry, root: URL) throws -> URL {
        let file = root.appendingPathComponent(entry.backup)
        try requireInside(file, root: root)
        try privateFile(file)
        guard let expected = entry.sha256, digest(try Data(contentsOf: file)) == expected else {
            throw Stop(code: "backup-copy-hash-mismatch")
        }
        return file
    }

    private static func verifyFilters(model: SettingsModel, userDir: URL) throws -> Bool {
        let before = try localStamps(userDir)
        let all = model.allAccounts
        let filters = Set(model.availableSourceFilters + [.all, .manual]
            + ["9router", "cc-switch", "cpamp", "magpie"].map { AccountSourceFilter.imported($0) })
        var valid = true
        for source in filters {
            model.sourceFilter = source
            for query in ["", "no-local-account-matches-this-query", all.first?.name ?? ""] {
                model.search = query
                let expected = all.filter { row in
                    source.includes(row.plugin.manifest) && (query.isEmpty || row.name.lowercased().contains(query.lowercased())
                        || row.plugin.manifest.label.lowercased().contains(query.lowercased()))
                }
                valid = valid && Set(model.accounts.map(\.id)) == Set(expected.map(\.id))
                for status in AccountStatusFilter.allCases {
                    model.overviewStatusFilter = status
                    model.sidebarStatusFilter = status
                    model.scope = .all
                    let wanted = Set(expected.filter(status.includes).map(\.id))
                    valid = valid && Set(model.overviewGroups.flatMap { $0.rows }.map(\.id)) == wanted
                        && Set(model.sidebarGroups.flatMap { $0.rows }.map(\.id)) == wanted
                }
            }
        }
        model.search = ""
        model.sourceFilter = .all
        model.overviewStatusFilter = .all
        model.sidebarStatusFilter = .healthyEnabled
        let after = try localStamps(userDir)
        return valid && before == after
    }

    private static func externalPaths(plan: [String: Any], candidates: [ImportCandidate], home: URL) -> Set<URL> {
        var paths = Set<URL>()
        for item in plan["external_exclusions"] as? [[String: Any]] ?? [] {
            if let path = item["path"] as? String { paths.insert(PluginGenerator.expandPath(path)) }
        }
        for candidate in candidates {
            if let reference = candidate.sourceReference { paths.formUnion(ImportedSource.dependencies(reference)) }
        }
        paths.insert(home.appendingPathComponent(".claude/settings.json"))
        paths.insert(home.appendingPathComponent(".codex/auth.json"))
        paths.insert(home.appendingPathComponent(".claude/.credentials.json"))
        return paths
    }

    private static func stamps(_ paths: Set<URL>) throws -> [String: FileStamp] {
        var result: [String: FileStamp] = [:]
        for file in paths {
            let exists = FileManager.default.fileExists(atPath: file.path)
            let target = file.resolvingSymlinksInPath().path
            var hash: String?
            if exists {
                let attrs = try FileManager.default.attributesOfItem(atPath: target)
                guard attrs[.type] as? FileAttributeType == .typeRegular else {
                    throw Stop(code: "external-path-not-regular")
                }
                hash = digest(try Data(contentsOf: file))
            }
            result[file.standardizedFileURL.path] = FileStamp(exists: exists, destination: target, digest: hash)
        }
        return result
    }

    private static func externalChanges(before: [String: FileStamp], after: [String: FileStamp],
                                        phase: String, home: URL) -> [ExternalChange] {
        Set(before.keys).union(after.keys).sorted().compactMap { path in
            let previous = before[path]
            let current = after[path]
            guard previous != current else { return nil }
            return ExternalChange(phase: phase, pathHash: digest(Data(path.utf8)),
                category: externalCategory(URL(fileURLWithPath: path), home: home),
                existenceChanged: previous?.exists != current?.exists,
                contentChanged: previous?.digest != current?.digest,
                destinationChanged: previous?.destination != current?.destination,
                beforeExists: previous?.exists ?? false, afterExists: current?.exists ?? false,
                beforeSHA256: previous?.digest, afterSHA256: current?.digest,
                beforeDestinationHash: previous.map { digest(Data($0.destination.utf8)) },
                afterDestinationHash: current.map { digest(Data($0.destination.utf8)) })
        }
    }

    private static func externalCategory(_ file: URL, home: URL) -> String {
        if file == home.appendingPathComponent(".claude/settings.json") { return "real-cli-settings" }
        if file == home.appendingPathComponent(".codex/auth.json") { return "codex-cli-auth" }
        if file == home.appendingPathComponent(".claude/.credentials.json") { return "claude-cli-auth" }
        if file.deletingLastPathComponent() == home.appendingPathComponent(".claude/hud") {
            return "hud-protected-reference"
        }
        let roots: [(URL, String)] = [
            (home.appendingPathComponent(".9router"), "9router"),
            (home.appendingPathComponent(".cc-switch"), "cc-switch"),
            (home.appendingPathComponent(".cli-proxy-api"), "cpamp"),
            (URL(fileURLWithPath: ProviderImporter.magpieRoot(home: home.path)), "magpie")
        ]
        for (root, category) in roots where file.path.hasPrefix(root.standardizedFileURL.path + "/") {
            return category
        }
        return "other-external-reference"
    }

    private static func localStamps(_ root: URL) throws -> [String: FileStamp] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw Stop(code: "local-inventory-unavailable")
        }
        var paths = Set<URL>()
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true else { throw Stop(code: "local-symbolic-link") }
            if values.isRegularFile == true { paths.insert(file) }
        }
        return try stamps(paths)
    }

    private static func preferencesUnchanged(_ before: [String: Any], after: [String: Any]) -> Bool {
        let allowed: Set<String> = [DataEngine.defaultsDisabledKey, DataEngine.defaultsFloatingHiddenKey,
            DataEngine.defaultsHudHiddenKey, DataEngine.defaultsTriggerDisabledKey, DataEngine.defaultsDeletedKey,
            SettingsPersist.selectedKey, SettingsPersist.tabKey]
        func global(_ values: [String: Any]) -> [String: Any] {
            values.filter { !allowed.contains($0.key) && !$0.key.hasPrefix("quotanest.interval.") }
        }
        return NSDictionary(dictionary: global(before)).isEqual(to: global(after))
    }

    private static func requireStopped() throws {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,comm="]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw Stop(code: "process-check-failed") }
        let paths: Set<String> = ["/Applications/QuotaNest.app/Contents/MacOS/QuotaNest",
            NSHomeDirectory() + "/Applications/QuotaNest.app/Contents/MacOS/QuotaNest"]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            if fields.count == 2, paths.contains(String(fields[1])) { throw Stop(code: "application-is-running") }
        }
    }

    private static func object(_ file: URL) throws -> [String: Any] {
        try privateFile(file)
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
            throw Stop(code: "private-metadata-invalid")
        }
        return value
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isLink(_ file: URL) -> Bool {
        (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    private static func requireInside(_ file: URL, root: URL) throws {
        let parent = root.standardizedFileURL
        let value = file.standardizedFileURL
        guard value.path.hasPrefix(parent.path + "/"), !isLink(value),
              value.resolvingSymlinksInPath() == value else { throw Stop(code: "private-path-boundary") }
    }

    private static func privateDirectory(_ file: URL) throws { try permissions(file, directory: true, mode: 0o700) }
    private static func privateFile(_ file: URL) throws { try permissions(file, directory: false, mode: 0o600) }

    private static func ordinaryDirectory(_ file: URL) throws {
        guard !isLink(file), file.standardizedFileURL.resolvingSymlinksInPath() == file.standardizedFileURL,
              try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw Stop(code: "real-directory-boundary")
        }
    }

    private static func permissions(_ file: URL, directory: Bool, mode: Int) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard !isLink(file), attributes[.type] as? FileAttributeType == (directory ? .typeDirectory : .typeRegular),
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == mode else { throw Stop(code: "private-permissions-invalid") }
    }

    private static func privateTree(_ root: URL) throws {
        try privateDirectory(root)
        guard root.standardizedFileURL.resolvingSymlinksInPath() == root.standardizedFileURL,
              let enumerator = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            throw Stop(code: "backup-boundary-invalid")
        }
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            try permissions(file, directory: values.isDirectory == true, mode: values.isDirectory == true ? 0o700 : 0o600)
        }
    }
}
