import Foundation
import CryptoKit
import Darwin

/// Explicit, isolated diagnostics. Never starts DataEngine or schedules model calls.
enum ImportVerification {
    enum Source: String, Codable, CaseIterable {
        case router = "9router", ccSwitch = "cc-switch", cpamp, magpie
    }

    enum Status: String, Codable {
        case ready, success, notAttempted = "not-attempted"
        case missingIdentity = "missing-identity", missingCredential = "missing-credential"
        case authSchema = "auth-schema-unmatched", unsupportedType = "unsupported-type"
        case unsupportedCapability = "quota-not-adapted", sourceUnavailable = "source-unavailable"
        case configuration = "configuration-error", applyFailed = "app-import-error"
        case credentialMetadata = "source-auth-metadata-rejected-without-request"
        case queryImplementation = "app-query-transport-needs-review"
        case registry = "app-registry-error", nodeMissing = "node-unavailable"
        case serviceRejected = "service-rejected-native-comparison-needed"
        case rateLimited = "service-rate-limited", network = "transport-error"
        case responseSchema = "response-schema-needs-comparison", empty = "empty-usage-data"
        case noSubscription = "no-subscription", getOnly = "request-needs-reference-review"
        case hostBoundary = "credential-host-boundary", cancelled, reportFailed = "private-report-failed"
        case complete, incomplete
    }

    struct Summary: Codable {
        var status: Status = .incomplete
        var total = 0
        var counts: [String: Int] = [:]
        var outcomes: [String: Int] = [:]
        var queried = 0
        var succeeded = 0
        var sourceFilesUnchanged = true
        var reportWritten = false
    }

    enum SourceIntegrity: String, Codable, Sendable {
        case pending = "pending-final-source-check"
        case unchanged = "unchanged-during-run"
        case externallyChanged = "externally-changed-needs-recheck"
        case unverified = "source-integrity-unverified"
    }

    struct Account: Codable {
        let name: String
        let recordId: String
        let collection: String?
    }

    struct FileHash: Codable, Equatable {
        let pathHash: String
        let state: String
        let sha256: String?
    }

    struct Attempt: Codable {
        let number: Int
        let status: Status
        let hasUsage: Bool
        let transport: [String]
    }

    struct Reference: Codable {
        let status: String
        let hasRecognizableShape: Bool
        let nativeComparisonNeeded: Bool
    }

    struct Record: Codable {
        let source: Source
        let account: Account
        let template: String?
        let authMode: String
        let sourceEnabled: Bool
        var preflight: Status = .ready
        var apply: Status = .notAttempted
        var quota: Status = .notAttempted
        var attempts: [Attempt] = []
        var attemptCount = 0
        var retryCount = 0
        var reference: Reference?
        var before: [FileHash] = []
        var after: [FileHash] = []
        var sourceChangeStatus: SourceIntegrity = .pending
        var sourceUnchanged = true {
            didSet { sourceChangeStatus = ImportVerification.integrityStatus(before, after) }
        }
    }

    private struct Report: Codable {
        let schemaVersion = 1
        let templatePool: [String]
        var summary = Summary()
        var records: [Record] = []
        var sourceBefore: [FileHash] = []
        var sourceAfter: [FileHash] = []
        var sourceChangeStatus: SourceIntegrity = .pending
    }

    /// `output` must be inside `backup`, or inside an existing owner-only directory.
    /// The returned value contains only fixed statuses and source/count aggregates.
    @MainActor
    static func run(home: URL, output: URL, backup: URL? = nil) async -> Summary {
        let templates = ProviderImporter.bundledTemplates()
        var report = Report(templatePool: templates.map(\.slug).sorted())
        var scratch: URL?
        do {
            try validateOutput(output, backup: backup)
            let root = output.deletingLastPathComponent().appendingPathComponent(".import-verification-" + UUID().uuidString,
                                                                                 isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            scratch = root
            defer { cleanup(root, parent: output.deletingLastPathComponent()) }
            let sourceFiles = inventoryFiles(home: home)
            report.sourceBefore = sourceFiles.map(hashFile)
            let candidates = ProviderImporter.from9Router(home: home.path, templates: templates)
                + ProviderImporter.fromCCSwitch(home: home.path, templates: templates)
                + ProviderImporter.fromCPAMP(home: home.path, templates: templates)
                + ProviderImporter.fromMagpie(home: home.path, templates: templates)
            report.summary.total = candidates.count
            for source in Source.allCases {
                report.summary.counts[source.rawValue] = candidates.filter { $0.source == source.rawValue }.count
            }
            try save(report, to: output)
            let node = NodeLocator.find(nvmHome: home.appendingPathComponent(".nvm").path,
                extraPaths: ["/opt/homebrew/bin/node", "/usr/local/bin/node"],
                saved: UserDefaults.standard.string(forKey: DataEngine.defaultsNodeKey))
            let jobs = candidates.enumerated().compactMap { index, candidate -> (Int, ImportCandidate, Source)? in
                guard let source = Source(rawValue: candidate.source) else { return nil }
                return (index, candidate, source)
            }
            // Three sliding slots bound the entire per-record operation, including retries/reference reads.
            // Only this MainActor parent mutates the report or writes its incremental snapshots.
            try await withThrowingTaskGroup(of: (Int, Record).self) { group in
                var next = 0
                var completed: [Int: Record] = [:]
                func submit(_ job: (Int, ImportCandidate, Source)) {
                    group.addTask {
                        let directory = root.appendingPathComponent("record-\(job.0 + 1)", isDirectory: true)
                        return (job.0, await verify(job.1, source: job.2, templates: templates, node: node, directory: directory))
                    }
                }
                while next < min(3, jobs.count) { submit(jobs[next]); next += 1 }
                while let (index, row) = try await group.next() {
                    completed[index] = row
                    report.records = completed.keys.sorted().compactMap { completed[$0] }
                    let outcome = row.quota == .notAttempted ? (row.apply == .success ? row.preflight : row.apply) : row.quota
                    report.summary.outcomes[outcome.rawValue, default: 0] += 1
                    if row.attemptCount > 0 { report.summary.queried += 1 }
                    if row.quota == .success { report.summary.succeeded += 1 }
                    report.summary.sourceFilesUnchanged = report.summary.sourceFilesUnchanged && row.sourceUnchanged
                    report.sourceChangeStatus = aggregateIntegrity(report.records, baseline: .pending)
                    try save(report, to: output)
                    if next < jobs.count { submit(jobs[next]); next += 1 }
                }
            }
            report.sourceAfter = sourceFiles.map(hashFile)
            report.summary.sourceFilesUnchanged = report.summary.sourceFilesUnchanged && unchanged(report.sourceBefore, report.sourceAfter)
            report.sourceChangeStatus = aggregateIntegrity(report.records,
                baseline: integrityStatus(report.sourceBefore, report.sourceAfter))
            report.summary.status = Task.isCancelled ? .cancelled : .complete
            report.summary.reportWritten = true
            try save(report, to: output)
            return report.summary
        } catch {
            if let scratch { cleanup(scratch, parent: output.deletingLastPathComponent()) }
            report.summary.status = .reportFailed
            report.summary.reportWritten = false
            return report.summary
        }
    }

    private static func verify(_ candidate: ImportCandidate, source: Source, templates: [PluginProvider],
                               node: String?, directory: URL) async -> Record {
        var row = Record(source: source,
            account: Account(name: candidate.name, recordId: candidate.sourceRecordId,
                             collection: candidate.sourceReference?.collection),
            template: candidate.template, authMode: candidate.sourceAuthMode, sourceEnabled: candidate.enabled)
        let dependencies = candidate.sourceReference.map(ImportedSource.dependencies) ?? []
        row.before = dependencies.map(hashFile)
        defer { cleanup(directory, parent: directory.deletingLastPathComponent()) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let providers = directory.appendingPathComponent("providers", isDirectory: true)
            let hud = directory.appendingPathComponent("hud", isDirectory: true)
            for folder in [providers, hud] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            }
            row.preflight = preflight(candidate, templates: templates)
            // Even rejected candidates exercise apply, in a fresh directory per source record.
            let slug: String
            do {
                slug = try ProviderImporter.apply(candidate, templates: templates, userDir: providers, hudDir: hud)
                row.apply = .success
            } catch {
                row.apply = row.preflight == .ready ? classify(error.localizedDescription, fallback: .applyFailed) : row.preflight
                row.after = dependencies.map(hashFile)
                row.sourceUnchanged = unchanged(row.before, row.after)
                return row
            }
            let bundle = Bundle.appResources.resourceURL?.appendingPathComponent("providers")
            // Same installation path as installScripts(), without constructing or starting an engine.
            DataEngine.installMjs(bundleDir: bundle, hudDir: hud)
            guard let plugin = ProviderRegistry.scan(dir: providers).first(where: { $0.slug == slug }) else {
                row.quota = .registry
                row.after = dependencies.map(hashFile); row.sourceUnchanged = unchanged(row.before, row.after)
                return row
            }
            guard plugin.manifest.supportsQuota else {
                row.quota = .unsupportedCapability
                row.after = dependencies.map(hashFile); row.sourceUnchanged = unchanged(row.before, row.after)
                return row
            }
            guard let node, FileManager.default.isExecutableFile(atPath: node) else {
                row.quota = .nodeMissing
                row.after = dependencies.map(hashFile); row.sourceUnchanged = unchanged(row.before, row.after)
                return row
            }
            let launcher = try installTransportGuard(node: node, directory: directory)
            let runner = ProviderRunner(nodePath: launcher.path, logDir: hud)
            let trace = hud.appendingPathComponent("verification-transport.json")
            var attempts: [Attempt] = []
            let result = await runner.runWithRetries(plugin, attempt: { plugin in
                do { try privateWrite(Data("[]".utf8), to: trace) }
                catch { return UsageCache(error: "verification-report-error", stale: true) }
                var cache = await runner.run(plugin, reportFailure: true)
                let transport = readTransport(trace)
                var status = cacheStatus(cache)
                if transport.contains("blocked-method") { status = .getOnly }
                else if transport.contains("blocked-host") { status = .hostBoundary }
                else if transport.contains("blocked-option") { status = .queryImplementation }
                else if cache == nil && transport.contains("http-success") { status = .responseSchema }
                else if status == .serviceRejected && transport.isEmpty { status = .credentialMetadata }
                let valid = cache.map(hasUsage) ?? false
                attempts.append(Attempt(number: attempts.count + 1, status: status, hasUsage: valid, transport: transport))
                if status != .success && cache?.error == nil {
                    cache = UsageCache(error: status.rawValue, stale: true)
                }
                return cache
            })
            row.attempts = attempts
            row.attemptCount = result.attemptCount
            row.retryCount = result.retryCount
            row.quota = attempts.last?.status ?? classify(result.failureReason ?? "cancelled", fallback: .network)
            if row.quota != .success && row.quota != .cancelled {
                row.reference = await referenceComparison(plugin: plugin, hud: hud)
            }
        } catch {
            row.quota = classify(error.localizedDescription, fallback: .configuration)
        }
        row.after = dependencies.map(hashFile)
        row.sourceUnchanged = unchanged(row.before, row.after)
        return row
    }

    static func hasUsage(_ cache: UsageCache) -> Bool {
        func valid(_ value: Double?) -> Bool { value.map { $0.isFinite && $0 >= 0 } ?? false }
        if [cache.fiveHour, cache.sevenDay, cache.monthly].compactMap({ $0 }).contains(where: { valid($0.usedPercentage) }) {
            return true
        }
        return (cache.windows ?? []).contains { window in
            valid(window.usedPercentage) || valid(window.remainingPercentage) || valid(window.amount)
        }
    }

    static func cacheStatus(_ cache: UsageCache?) -> Status {
        guard let cache else { return .network }
        if let error = cache.error { return classify(error, fallback: .responseSchema) }
        return hasUsage(cache) ? .success : .empty
    }

    private static func preflight(_ candidate: ImportCandidate, templates: [PluginProvider]) -> Status {
        guard !candidate.sourceRecordId.isEmpty, candidate.sourceReference != nil else { return .missingIdentity }
        if let reason = candidate.unsupportedReason { return classify(reason, fallback: .unsupportedType) }
        if let template = candidate.template.flatMap({ slug in templates.first { $0.slug == slug } }),
           !template.manifest.supportsQuota { return .unsupportedCapability }
        return .ready
    }

    /// Never copies an external error into the report: messages select only fixed classifications.
    static func classify(_ message: String, fallback: Status) -> Status {
        let text = message.lowercased()
        if text.contains("cancel") { return .cancelled }
        if text.contains("no-subscription") { return .noSubscription }
        if text.contains("get-only") { return .getOnly }
        if text.contains("host-boundary") { return .hostBoundary }
        if text.contains("ratelimit") { return .rateLimited }
        if text == "auth" || text.contains("401") || text.contains("403") { return .serviceRejected }
        if text == "no-auth" || text.contains("没有可用的 api key") || text.contains("填写基础接入") { return .missingCredential }
        if text.contains("稳定账号身份") || text.contains("缺少原始记录") || text.contains("身份不一致") { return .missingIdentity }
        if text.contains("格式") || text.contains("有效访问令牌") || text.contains("授权结构") { return .authSchema }
        if text.contains("尚未提供只读接入适配") || text.contains("没有匹配") || text.contains("没有对应") { return .unsupportedType }
        if text == "no-query" || text.contains("额度适配") || text.contains("用量接口不支持") || text.contains("auth 适配") { return .unsupportedCapability }
        if text.contains("记录已删除") || text.contains("读取失败") || text.contains("无法读取") { return .sourceUnavailable }
        if text.hasPrefix("配置错误") { return .configuration }
        if ["network", "fetch", "timeout", "process-launch"].contains(text) { return .network }
        if text == "parse" || text == "unknown" || text.hasPrefix("api:") { return .responseSchema }
        return fallback
    }

    private static func inventoryFiles(home: URL) -> [URL] {
        var paths = [home.appendingPathComponent(".9router/db/data.sqlite"),
                     home.appendingPathComponent(".9router/db/data.sqlite-wal"),
                     home.appendingPathComponent(".cc-switch/cc-switch.db"),
                     home.appendingPathComponent(".cc-switch/cc-switch.db-wal")]
        let cpa = home.appendingPathComponent(".cli-proxy-api")
        if let files = try? FileManager.default.contentsOfDirectory(at: cpa, includingPropertiesForKeys: nil) {
            paths += files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
        }
        let magpie = URL(fileURLWithPath: ProviderImporter.magpieRoot(home: home.path))
        paths += ["providers.json", "plugin-auth.json", "plugin-providers.json", "logins.json"].map { magpie.appendingPathComponent($0) }
        return paths
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func integrityStatus(_ before: [FileHash], _ after: [FileHash]) -> SourceIntegrity {
        guard !before.isEmpty, !after.isEmpty,
              !(before + after).contains(where: { $0.state == "unreadable" }) else { return .unverified }
        return before == after ? .unchanged : .externallyChanged
    }

    private static func aggregateIntegrity(_ records: [Record], baseline: SourceIntegrity) -> SourceIntegrity {
        let statuses = records.map(\.sourceChangeStatus) + [baseline]
        if statuses.contains(.externallyChanged) { return .externallyChanged }
        if statuses.contains(.unverified) { return .unverified }
        return baseline
    }

    private static func unchanged(_ before: [FileHash], _ after: [FileHash]) -> Bool {
        integrityStatus(before, after) == .unchanged
    }

    private static func hashFile(_ url: URL) -> FileHash {
        let pathHash = digest(Data(url.standardizedFileURL.path.utf8))
        guard FileManager.default.fileExists(atPath: url.path) else { return FileHash(pathHash: pathHash, state: "absent", sha256: nil) }
        do { return FileHash(pathHash: pathHash, state: "read", sha256: digest(try Data(contentsOf: url))) }
        catch { return FileHash(pathHash: pathHash, state: "unreadable", sha256: nil) }
    }

    private static func validateOutput(_ output: URL, backup: URL?) throws {
        let parent = output.deletingLastPathComponent().standardizedFileURL
        let resolvedParent = parent.resolvingSymlinksInPath()
        guard output.isFileURL, parent == resolvedParent,
              output.standardizedFileURL == output.resolvingSymlinksInPath() else { throw ImportedSource.failure("private-output") }
        if let backup {
            let root = backup.standardizedFileURL.resolvingSymlinksInPath()
            guard parent.path == root.path || parent.path.hasPrefix(root.path + "/") else { throw ImportedSource.failure("private-output") }
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: parent.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0,
              let owner = attributes[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid() else {
            throw ImportedSource.failure("private-output")
        }
        if FileManager.default.fileExists(atPath: output.path) {
            let existing = try FileManager.default.attributesOfItem(atPath: output.path)
            guard existing[.type] as? FileAttributeType == .typeRegular else { throw ImportedSource.failure("private-output") }
        }
    }

    private static func privateWrite(_ data: Data, to file: URL) throws {
        try data.write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func save(_ report: Report, to output: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try privateWrite(encoder.encode(report), to: output)
    }

    private static func cleanup(_ directory: URL, parent: URL) {
        let resolved = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.deletingLastPathComponent() == parent.standardizedFileURL.resolvingSymlinksInPath(),
              directory.lastPathComponent.hasPrefix(".import-verification-") || directory.lastPathComponent.hasPrefix("record-") else { return }
        try? FileManager.default.removeItem(at: resolved)
    }

    private static func readTransport(_ file: URL) -> [String] {
        guard let data = try? Data(contentsOf: file), let values = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        let allowed: Set<String> = ["blocked-method", "blocked-host", "blocked-option", "transport-error", "http-success",
                                    "http-rejected", "http-rate-limited", "http-redirect", "http-error"]
        return values.map { allowed.contains($0) ? $0 : "transport-error" }
    }

    private static func installTransportGuard(node: String, directory: URL) throws -> URL {
        let preload = directory.appendingPathComponent("transport-guard.cjs")
        try privateWrite(Data(transportGuard.utf8), to: preload)
        let launcher = directory.appendingPathComponent("node-get-only.sh")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = "#!/bin/zsh\nunset USAGE_VERBOSE GLM_PROVIDER_VERBOSE USAGE_DEBUG NODE_OPTIONS\nexec "
            + quote(node) + " --require " + quote(preload.path) + " \"$@\"\n"
        try privateWrite(Data(script.utf8), to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        return launcher
    }

    /// Converts existing adapters' curl arguments to stdin config before any process launch.
    /// Secrets never reach OS argv; only exact reviewed quota POSTs are allowed alongside GET.
    private static let transportGuard = #"""
    const cp = require('node:child_process');
    const fs = require('node:fs');
    const path = require('node:path');
    const { syncBuiltinESMExports } = require('node:module');
    const spawn = cp.spawnSync;
    const trace = path.join(process.env.TOKENHUD_HUD_DIR, 'verification-transport.json');
    function note(status) {
      let list = [];
      try { list = JSON.parse(fs.readFileSync(trace, 'utf8')); } catch {}
      list.push(status);
      fs.writeFileSync(trace, JSON.stringify(list), { mode: 0o600 });
    }
    function blocked(status) {
      note(status);
      return { status: 1, signal: null, stdout: '', stderr: '', error: new Error('verification-boundary') };
    }
    cp.spawnSync = (command, args, options = {}) => {
      if (command !== '/usr/bin/curl') return blocked('blocked-option');
      const names = { '-H': 'header', '--header': 'header', '-X': 'request', '--request': 'request',
        '-w': 'write-out', '--write-out': 'write-out', '--url': 'url', '--max-time': 'max-time',
        '--connect-timeout': 'connect-timeout', '--proto': 'proto', '--max-redirs': 'max-redirs' };
      const flags = { '-q': null, '-s': 'silent', '-sS': 'silent', '--silent': 'silent', '--show-error': null, '--compressed': 'compressed', '--http1.1': 'http1.1' };
      const config = ['silent', 'max-redirs = 0', 'proto = "=https"'];
      let url, method = 'GET', body;
      const headers = {};
      const quoted = value => '"' + String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n').replace(/\r/g, '\\r').replace(/\t/g, '\\t') + '"';
      for (let index = 0; index < args.length; index++) {
        const arg = args[index];
        if (['--data', '--data-binary', '-d'].includes(arg)) {
          body = args[++index];
          if (typeof body !== 'string' || body.startsWith('@') || body.includes('\0')) return blocked('blocked-method');
          config.push('data-binary = ' + quoted(body));
          continue;
        }
        if (['--form', '-F', '-L', '--location'].includes(arg)) return blocked('blocked-method');
        if (Object.hasOwn(flags, arg)) { if (flags[arg]) config.push(flags[arg]); continue; }
        if (Object.hasOwn(names, arg)) {
          const value = args[++index];
          if (typeof value !== 'string' || value.includes('\0')) return blocked('blocked-option');
          if (names[arg] === 'request') { method = value.toUpperCase(); continue; }
          if (names[arg] === 'url') { url = value; continue; }
          if (names[arg] === 'header') {
            const colon = value.indexOf(':');
            if (colon < 1 || /[\r\n]/.test(value)) return blocked('blocked-option');
            headers[value.slice(0, colon).toLowerCase()] = value.slice(colon + 1).trim();
          }
          if (names[arg] === 'proto' || names[arg] === 'max-redirs') continue;
          config.push(names[arg] + ' = ' + quoted(value));
        } else if (/^https:\/\//.test(arg) && !url) url = arg;
        else return blocked('blocked-option');
      }
      try {
        const target = new URL(url), expected = new URL(process.env.TOKENHUD_QUERY_URL);
        if (target.protocol !== 'https:' || target.origin !== expected.origin || target.username || target.password ||
            /\/(?:login|signin|logout|refresh|exchange|responses|messages)(?:\/|$)|\/chat\/completions(?:\/|$)/i.test(target.pathname)) return blocked('blocked-host');
        if (method === 'POST') {
          // Exact official read operations reviewed in the bundled adapters; no token exchanges.
          const reads = new Set([
            'https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary',
            'https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota',
            'https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist',
            'https://server.codeium.com/exa.seat_management_pb.SeatManagementService/GetUserStatus',
            'https://copilot.tencent.com/v2/billing/meter/get-user-resource',
            'https://www.codebuddy.ai/v2/billing/meter/get-user-resource',
            'https://agent.minimaxi.com/matrix/api/v1/user/get_user_extra_info',
            'https://agent.minimax.io/matrix/api/v1/user/get_user_extra_info',
            'https://agent.minimaxi.com/matrix/api/v1/commerce/get_membership_info',
            'https://agent.minimax.io/matrix/api/v1/commerce/get_membership_info',
            'https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage',
            'https://copilot.tencent.com/billing/meter/get-user-resource-summary',
            'https://www.workbuddy.ai/billing/meter/get-user-resource-summary',
            'https://mimo-server-sgp.xiaomimimo.com/api/user/usage',
            'https://api.trae.cn/trae/api/v2/pay/ide_user_ent_usage',
            'https://api-sg-central.trae.ai/trae/api/v1/pay/user_current_entitlement_list'
          ]);
          const exact = target.origin + target.pathname;
          const kiroRead = exact === 'https://codewhisperer.us-east-1.amazonaws.com/' &&
            headers['x-amz-target'] === 'AmazonCodeWhispererService.GetUsageLimits';
          const joyRead = exact === 'https://api-ai.jd.com/api' && target.searchParams.get('functionId') === 'get_newpoint_ide';
          let json;
          try { json = JSON.parse(body ?? '{}'); } catch { return blocked('blocked-method'); }
          if ((!reads.has(exact) && !kiroRead && !joyRead) || !json || typeof json !== 'object' || Array.isArray(json)) return blocked('blocked-method');
        } else if (method !== 'GET' || body !== undefined) return blocked('blocked-method');
        config.push('request = ' + quoted(method));
      } catch { return blocked('blocked-host'); }
      const marker = '\n__QUOTANEST_VERIFY_HTTP__';
      config.push('url = ' + quoted(url), 'write-out = ' + quoted(marker + '%{http_code}'));
      // curl's last write-out wins, so preserve the adapter's original requested suffix explicitly.
      let suffix = '';
      for (let index = 0; index < args.length; index++) if (['-w', '--write-out'].includes(args[index])) suffix = args[index + 1];
      const filtered = config.filter(line => !line.startsWith('write-out = '));
      filtered.push('write-out = ' + quoted(suffix + marker + '%{http_code}'));
      const result = spawn('/usr/bin/curl', ['-q', '-K', '-'], { ...options,
        input: filtered.join('\n') + '\n', stdio: ['pipe', 'pipe', 'pipe'],
        encoding: 'utf8', timeout: Math.min(options.timeout || 15000, 20000), maxBuffer: 2000000 });
      let text = result.stdout || '', split = text.lastIndexOf(marker);
      const status = split >= 0 ? Number(text.slice(split + marker.length).trim()) : 0;
      if (split >= 0) text = text.slice(0, split);
      note(result.error || result.status !== 0 ? 'transport-error' : status >= 200 && status < 300 ? 'http-success'
        : [401, 403].includes(status) ? 'http-rejected' : status === 429 ? 'http-rate-limited'
        : status >= 300 && status < 400 ? 'http-redirect' : 'http-error');
      return { ...result, stdout: text, stderr: '', error: result.error ? new Error('transport-error') : undefined };
    };
    // Suppress diagnostics even when inherited environment settings request verbose logging.
    console.error = () => {};
    syncBuiltinESMExports();
    """#

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static func referenceComparison(plugin: PluginProvider, hud: URL) async -> Reference {
        let fixed = plugin.manifest.inheritQueryUrl ?? plugin.manifest.queryUrl ?? ""
        guard let url = URL(string: fixed), url.scheme == "https", url.user == nil, url.password == nil else {
            return Reference(status: "no-fixed-get-reference", hasRecognizableShape: false, nativeComparisonNeeded: true)
        }
        // These protocols require POST or a token exchange; no independent read is authorized here.
        let blocked: Set<String> = ["antigravity", "gemini-cli", "devin", "kiro", "codebuddy", "codebuddy-cn",
            "minimax-code", "minimax-code-cn", "qoder", "qoder-cn", "cursor", "workbuddy", "workbuddy-cn",
            "xiaomi-mimo-desktop", "trae", "trae-cn", "joycode", "cloudflare-workers-ai", "orcaterm"]
        if blocked.contains(plugin.manifest.template ?? "") {
            return Reference(status: "native-protocol-needs-non-get", hasRecognizableShape: false, nativeComparisonNeeded: true)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let auth = plugin.manifest.authFile.map(PluginGenerator.expandPath)
                ?? hud.appendingPathComponent(".\(plugin.slug)-usage-auth.json")
            let config = try ProviderAuthentication.resolveQuota(ProviderConfigStore.read(authFile: auth, manifest: plugin.manifest))
            guard URL(string: config.queryUrl)?.host == url.host else {
                return Reference(status: "credential-host-boundary", hasRecognizableShape: false, nativeComparisonNeeded: true)
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            RefreshTrigger.applyHeaders(&request, config.queryHeader, key: config.queryKey, protocol: config.refreshProtocol)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if plugin.manifest.template == "claude-code" { request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta") }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return Reference(status: "reference-transport-error", hasRecognizableShape: false, nativeComparisonNeeded: true)
            }
            if [401, 403].contains(http.statusCode) {
                return Reference(status: "reference-service-rejected", hasRecognizableShape: false, nativeComparisonNeeded: true)
            }
            guard (200..<300).contains(http.statusCode) else {
                return Reference(status: http.statusCode == 429 ? "reference-rate-limited" : "reference-http-error", hasRecognizableShape: false, nativeComparisonNeeded: true)
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return Reference(status: "reference-non-object-response", hasRecognizableShape: false, nativeComparisonNeeded: true)
            }
            let recognizable = referenceShape(object, template: plugin.manifest.template)
            return Reference(status: recognizable ? "reference-schema-present-app-parser-needs-review" : "reference-schema-absent-native-comparison-needed",
                             hasRecognizableShape: recognizable, nativeComparisonNeeded: !recognizable)
        } catch {
            return Reference(status: "reference-configuration-or-transport-error", hasRecognizableShape: false, nativeComparisonNeeded: true)
        }
    }

    private static func referenceShape(_ object: [String: Any], template: String?) -> Bool {
        switch template {
        case "gpt": return object["rate_limit"] is [String: Any] || object["rate_limits"] is [String: Any] || object["rate_limits_by_limit_id"] is [String: Any]
        case "claude-code": return object["five_hour"] is [String: Any] || object["seven_day"] is [String: Any]
        case "cline": return (object["data"] as? [String: Any])?["limits"] is [[String: Any]]
        case "glm", "zai-coding": return (object["data"] as? [String: Any])?["limits"] is [[String: Any]]
        case "deepseek": return object["balance_infos"] is [[String: Any]]
        case "openrouter": return (object["data"] as? [String: Any])?["total_credits"] != nil
        case "moonshot", "moonshot-cn": return (object["data"] as? [String: Any])?["available_balance"] != nil
        default: return false
        }
    }
}
