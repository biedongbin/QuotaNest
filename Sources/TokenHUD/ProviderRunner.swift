import Darwin
import Foundation

enum NodeLocator {
    /// nvmHome: ~/.nvm; saved: UserDefaults 存的路径(用户显式选择, 无条件优先); extraPaths: 兜底候选
    static func find(nvmHome: String?, extraPaths: [String], saved: String?) -> String? {
        if let saved { return saved }
        if let nvmHome, let p = pickLatest(from: URL(fileURLWithPath: nvmHome)) { return p }
        return extraPaths.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// glob <nvm>/versions/node/*/bin/node, 取版本号最大 ([Int] 逐位数值比较)
    static func pickLatest(from nvm: URL) -> String? {
        let base = nvm.appendingPathComponent("versions/node")
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return nil }
        var best: (version: [Int], path: String)?
        for d in dirs {
            let node = d.appendingPathComponent("bin/node")
            guard FileManager.default.fileExists(atPath: node.path) else { continue }
            let name = d.lastPathComponent
            let noV = name.hasPrefix("v") ? String(name.dropFirst()) : name
            let parts = noV.split(separator: ".").compactMap { Int($0) }
            guard !parts.isEmpty else { continue }
            if best == nil || isNewer(parts, than: best!.version) {
                best = (parts, nvm.appendingPathComponent("versions/node/\(name)/bin/node").path)
            }
        }
        return best?.path
    }

    /// 逐段数值比较 (22.9.1 > 20.11.0; 22.9 > 22)
    private static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
        for (x, y) in zip(a, b) where x != y { return x > y }
        return a.count > b.count
    }
}

final class ProviderRunner {
    let nodePath: String?
    private let logDir: URL

    init(nodePath: String?, logDir: URL? = nil) {
        self.nodePath = nodePath
        self.logDir = logDir ?? URL(fileURLWithPath: NSHomeDirectory() + "/.claude/hud", isDirectory: true)
    }

    /// spawn: zsh <script> (cwd=插件目录, env 注入 TOKENHUD_NODE)
    /// 以 zsh 直呼脚本路径而非 exec, 免依赖执行位 (测试/打包资源均无 x 位)
    /// 成功: stdout -> UsageCache.make; 任何失败(非0退出/解析失败/超时) -> nil
    /// 失败时 stderr 尾部写 hudDir 下 .{slug}-usage-stderr.log 供诊断 (不进 cache, 免覆盖旧桶数据)
    func run(_ plugin: PluginProvider, timeout: TimeInterval = 20) async -> UsageCache? {
        let script = plugin.dir.appendingPathComponent(plugin.manifest.fetch).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: script) else { return nil }

        let originalAuth = plugin.manifest.authFile.map(PluginGenerator.expandPath)
            ?? logDir.appendingPathComponent(".\(plugin.slug)-usage-auth.json")
        var snapshot: ProviderQuerySnapshot?
        if FileManager.default.fileExists(atPath: originalAuth.path) || plugin.manifest.credentialSource != nil || plugin.manifest.sourceReference != nil {
            do {
                let config = ProviderConfigStore.read(authFile: originalAuth, manifest: plugin.manifest)
                snapshot = try ProviderQuerySnapshot.make(config: config, manifest: plugin.manifest, originalAuth: originalAuth)
            } catch {
                return UsageCache(generatedAt: nil, fiveHour: nil, sevenDay: nil, monthly: nil,
                    error: "配置错误：" + error.localizedDescription, stale: true,
                    lastAttemptAt: Date().timeIntervalSince1970 * 1000)
            }
        }
        defer { snapshot?.cleanup() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [script]
        p.currentDirectoryURL = plugin.dir
        var env = ProcessInfo.processInfo.environment
        if let nodePath { env["TOKENHUD_NODE"] = nodePath }
        env["TOKENHUD_STDOUT_ONLY"] = "1"
        env["TOKENHUD_HUD_DIR"] = logDir.path
        env["TOKENHUD_AUTH_FILE"] = snapshot?.file.path ?? originalAuth.path
        env["TOKENHUD_CACHE_FILE"] = DataEngine.cachePath(for: plugin, hudDir: logDir).path
        env["TOKENHUD_QUERY_URL"] = snapshot?.queryURL ?? plugin.manifest.queryUrl ?? ""
        env["TOKENHUD_QUOTA_MODE"] = plugin.manifest.quotaMode ?? ""
        p.environment = env

        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err

        do { try p.run() } catch { return nil }
        let stdout = PipeCapture(out.fileHandleForReading, limit: 2_000_000)
        let stderr = PipeCapture(err.fileHandleForReading, limit: 4096)

        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if p.isRunning {
            // SIGTERM 宽限 2s, 仍存活则 SIGKILL (防脚本 trap/ignore TERM 致 waitUntilExit 无限阻塞)
            p.terminate()
            let grace = Date().addingTimeInterval(2)
            while p.isRunning && Date() < grace {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            let reapDeadline = Date().addingTimeInterval(1)
            while p.isRunning && Date() < reapDeadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            dumpStderr(stderr.finish(within: 1), plugin: plugin, secrets: snapshot?.secrets ?? [])
            return nil
        }
        guard p.terminationStatus == 0 else {
            dumpStderr(stderr.finish(within: 1), plugin: plugin, secrets: snapshot?.secrets ?? [])
            return nil
        }

        let data = stdout.finish(within: 2)
        var cache = UsageCache.make(body: data, now: Date().timeIntervalSince1970 * 1000)
        // Bind both success and parsed failures to the credentials actually used by this request.
        cache?.sourceRevision = snapshot?.sourceRevision
        if cache == nil { dumpStderr(stderr.finish(within: 1), plugin: plugin, secrets: snapshot?.secrets ?? []) } // stdout 解析失败也留诊断线索
        return cache
    }

    /// stderr 尾部 4KB 写到注入的日志目录，落盘前过滤凭证。
    private func dumpStderr(_ data: Data, plugin: PluginProvider, secrets: [String]) {
        guard !data.isEmpty else { return }
        let tail = data.count > 4096 ? data.suffix(4096) : data[...]
        let text = String(data: tail, encoding: .utf8) ?? String(decoding: tail, as: UTF8.self)
        var safe = Self.redact(text)
        for secret in secrets where !secret.isEmpty { safe = safe.replacingOccurrences(of: secret, with: "[REDACTED]") }
        let log = logDir.appendingPathComponent(".\(plugin.slug)-usage-stderr.log")
        try? Data(safe.utf8).write(to: log, options: .atomic)
    }

    /// 凭证脱敏 (纯函数, 可测): Bearer 头 / api[-_]key 赋值 / sk_ 票据 / 长 token
    nonisolated static func redact(_ s: String) -> String {
        var out = s
        let patterns: [(String, String)] = [
            (#"(?i)(Authorization\s*:\s*Bearer\s+)[^\s"']+"#, "$1[REDACTED]"),
            (#"(?i)(api[-_]?key[=:]\s*)[^\s&"']+"#, "$1[REDACTED]"),
            (#"\bsk-[A-Za-z0-9_-]{8,}\b"#, "[REDACTED]"),
            (#"(?i)(token[=:]\s*)[A-Za-z0-9_-]{20,}"#, "$1[REDACTED]"),
        ]
        for (p, r) in patterns {
            out = out.replacingOccurrences(of: p, with: r, options: .regularExpression)
        }
        return out
    }

    /// 后台持续排空管道，避免先等进程退出导致写端填满。输出有上限，孤儿写端等待有界。
    private final class PipeCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let done = DispatchSemaphore(value: 0)

        init(_ handle: FileHandle, limit: Int) {
            DispatchQueue.global(qos: .utility).async { [self] in
                defer { done.signal() }
                while let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
                    lock.lock()
                    data.append(chunk)
                    if data.count > limit { data = Data(data.suffix(limit)) }
                    lock.unlock()
                }
            }
        }

        func finish(within window: TimeInterval) -> Data {
            _ = done.wait(timeout: .now() + window)
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }
}
