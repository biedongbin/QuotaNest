import Foundation
import Testing
@testable import TokenHUD

@Suite
final class RegistryTests {
    let tmp: URL

    init() {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-\(UUID().uuidString)")
    }

    deinit { try? FileManager.default.removeItem(at: tmp) }

    private func mkPlugin(dir: URL, slug: String, name: String? = nil) throws {
        let d = dir.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let m = #"{"name":"\#(name ?? slug)","label":"\#(slug)","buckets":{"seven_day":"周"}}"#
        try m.data(using: .utf8)!.write(to: d.appendingPathComponent("manifest.json"))
    }

    private var userDir_: URL {
        tmp.appendingPathComponent("u", isDirectory: true)
    }

    @Test func scanFindsPlugins() throws {
        try mkPlugin(dir: tmp, slug: "glm")
        try mkPlugin(dir: tmp, slug: "ollama")
        let plugins = ProviderRegistry.scan(dir: tmp)
        #expect(Set(plugins.map(\.slug)) == ["glm", "ollama"])
    }

    @Test func scanSkipsBadManifest() throws {
        let d = tmp.appendingPathComponent("bad", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try "not json".data(using: .utf8)!.write(to: d.appendingPathComponent("manifest.json"))
        try mkPlugin(dir: tmp, slug: "good")
        #expect(ProviderRegistry.scan(dir: tmp).map(\.slug) == ["good"])
    }

    @Test func slugValidation() {
        #expect(ProviderRegistry.isValidSlug("opencode-go"))
        #expect(!ProviderRegistry.isValidSlug("My Relay"))
        #expect(!ProviderRegistry.isValidSlug(""))
    }

    @Test func userOverridesBundle() throws {
        let bundleDir = tmp.appendingPathComponent("b", isDirectory: true)
        let userDir = tmp.appendingPathComponent("u", isDirectory: true)
        try mkPlugin(dir: bundleDir, slug: "glm", name: "Builtin")
        try mkPlugin(dir: userDir, slug: "glm", name: "Custom")
        try mkPlugin(dir: bundleDir, slug: "ollama")
        let (plugins, _) = ProviderRegistry.load(bundleDir: bundleDir, userDir: userDir)
        let glm = plugins.first { $0.slug == "glm" }
        #expect(glm?.manifest.name == "Custom")
        #expect(plugins.count == 2)
    }

    @Test func loadReportsBrokenUserPlugins() throws {
        try mkPlugin(dir: userDir_, slug: "ok")
        let d = userDir_.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try "{}".data(using: .utf8)!.write(to: d.appendingPathComponent("manifest.json")) // 缺 name
        let (_, errors) = ProviderRegistry.load(bundleDir: nil, userDir: userDir_)
        #expect(errors["broken"] != nil)
    }
}
