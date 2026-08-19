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

    init(nodePath: String?) { self.nodePath = nodePath }

    /// spawn: zsh <script> (cwd=插件目录, env 注入 TOKENHUD_NODE)
    /// 以 zsh 直呼脚本路径而非 exec, 免依赖执行位 (测试/打包资源均无 x 位)
    /// 成功: stdout -> UsageCache.make; 任何失败(非0退出/解析失败/超时) -> nil
    func run(_ plugin: PluginProvider, timeout: TimeInterval = 15) async -> UsageCache? {
        let script = plugin.dir.appendingPathComponent(plugin.manifest.fetch).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: script) else { return nil }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [script]
        p.currentDirectoryURL = plugin.dir
        var env = ProcessInfo.processInfo.environment
        if let nodePath { env["TOKENHUD_NODE"] = nodePath }
        p.environment = env

        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe() // 丢弃

        do { try p.run() } catch { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline {
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
            p.waitUntilExit() // SIGKILL 后进程必死, 此等待有界
            return nil
        }
        guard p.terminationStatus == 0 else { return nil }

        let data = Self.readAllBounded(out.fileHandleForReading, within: 2)
        return UsageCache.make(body: data, now: Date().timeIntervalSince1970 * 1000)
    }

    /// 有界读取: 进程已退出但孤儿孙进程可能仍持有 stdout 写端; 同步读丢后台队列, 超时放弃
    private static func readAllBounded(_ handle: FileHandle, within window: TimeInterval) -> Data {
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var d = Data()
            func set(_ v: Data) { lock.lock(); d = v; lock.unlock() }
            func get() -> Data { lock.lock(); defer { lock.unlock() }; return d }
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.set(handle.readDataToEndOfFile())
            done.signal()
        }
        _ = done.wait(timeout: .now() + window)
        return box.get()
    }
}
