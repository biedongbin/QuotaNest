import Foundation
import Testing
@testable import TokenHUD

@Suite
final class RunnerTests {
    let tmp: URL

    init() {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("runner-\(UUID().uuidString)")
    }

    deinit { try? FileManager.default.removeItem(at: tmp) }

    /// 造假 nvm 结构: versions/node/v{version}/bin/node
    private func mkNode(v: String) throws -> URL {
        let d = tmp.appendingPathComponent("nvm/versions/node/v\(v)/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let node = d.appendingPathComponent("node")
        FileManager.default.createFile(atPath: node.path, contents: nil)
        return tmp.appendingPathComponent("nvm")
    }

    @Test func pickLatestNode() throws {
        _ = try mkNode(v: "20.11.0")
        _ = try mkNode(v: "22.9.1")
        _ = try mkNode(v: "18.3.0")
        let got = NodeLocator.pickLatest(from: tmp.appendingPathComponent("nvm"))
        let expect = tmp.appendingPathComponent("nvm/versions/node/v22.9.1/bin/node").path
        #expect(got == expect)
    }

    @Test func savedPathWins() {
        #expect(NodeLocator.find(nvmHome: nil, extraPaths: [], saved: "/saved/node") == "/saved/node")
    }

    @Test func fallbacks() throws {
        _ = try mkNode(v: "20.0.0")
        let got = NodeLocator.find(nvmHome: tmp.appendingPathComponent("nvm").path,
                                   extraPaths: ["/x/node"], saved: nil)
        #expect(got?.hasSuffix("v20.0.0/bin/node") == true)
    }

    @Test func runnerParsesStdout() async throws {
        let d = tmp.appendingPathComponent("p/fake", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try "#!/bin/zsh\necho '{\"seven_day\":{\"used_percentage\":42}}'"
            .write(to: d.appendingPathComponent("fetch.sh"), atomically: true, encoding: .utf8)
        let m = ProviderManifest(name: "Fake", label: "F", buckets: ["seven_day": "周"])
        let runner = ProviderRunner(nodePath: "/usr/bin/true") // 假 node, 脚本没用它
        let cache = await runner.run(PluginProvider(slug: "fake", manifest: m, dir: d), timeout: 10)
        #expect(cache?.sevenDay?.usedPercentage == 42)
        #expect(cache?.generatedAt != nil)
    }

    @Test func runnerTimeoutReturnsNil() async throws {
        let d = tmp.appendingPathComponent("p/slow", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try "#!/bin/zsh\nsleep 30".write(to: d.appendingPathComponent("fetch.sh"), atomically: true, encoding: .utf8)
        let m = ProviderManifest(name: "Slow", label: "S")
        let runner = ProviderRunner(nodePath: nil)
        let t0 = Date()
        let cache = await runner.run(PluginProvider(slug: "slow", manifest: m, dir: d), timeout: 1)
        #expect(cache == nil)
        #expect(Date().timeIntervalSince(t0) < 5)
    }

    @Test func runnerFailingScriptReturnsNil() async throws {
        let d = tmp.appendingPathComponent("p/bad", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try "#!/bin/zsh\nexit 3".write(to: d.appendingPathComponent("fetch.sh"), atomically: true, encoding: .utf8)
        let m = ProviderManifest(name: "Bad", label: "B")
        let runner = ProviderRunner(nodePath: nil)
        let cache = await runner.run(PluginProvider(slug: "bad", manifest: m, dir: d), timeout: 5)
        #expect(cache == nil)
    }
}
