import AppKit
import SwiftUI
import Testing
@testable import QuotaNest

/// Opt-in native sidebar acceptance through the actual accessibility tree.
/// A missing or non-operable target fails the test; no coordinates or direct
/// model navigation stand in for the user action.
@Suite(.serialized)
@MainActor
struct SettingsInteractionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOKENHUD_INTERACTION_TESTS"] == "1"))
    func sidebarAccessibilityActionsPreserveSelectedAccount() async throws {
        try #require(Thread.isMainThread)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenhud-sidebar-ax-\(UUID().uuidString)")
        let hud = root.appendingPathComponent("hud")
        let providers = root.appendingPathComponent("providers")
        let settings = root.appendingPathComponent("settings.json")
        let marker = root.appendingPathComponent("unexpected-fetch")
        for directory in [hud, providers] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let suite = "tokenhud.sidebar-ax.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        defaults.set("zeta", forKey: SettingsPersist.selectedKey)
        let originalSettings = Data("{\"fixture\":true}".utf8)
        try originalSettings.write(to: settings)
        var originalAuth: [URL: Data] = [:]
        for (slug, title) in [("alpha", "Alpha fixture"), ("zeta", "Zeta fixture")] {
            let auth = hud.appendingPathComponent(".\(slug)-usage-auth.json")
            let manifest = ProviderManifest(name: slug, label: "Fixture provider", displayName: title,
                                            authFile: auth.path, refreshUrl: "https://example.invalid/v1/chat/completions",
                                            refreshProtocol: "openai", authMode: "apikey", quotaMode: "none")
            let script = "#!/bin/sh\nprintf 'unexpected-fetch\\n' >> '\(marker.path)'\nexit 93\n"
            try PluginGenerator.writePlugin(slug: slug, manifest: manifest, script: script, into: providers)
            let data = Data("{\"refreshApiKey\":\"fixture-call\",\"testModel\":\"fixture-model\",\"scheduleTimes\":[\"09:00\"]}".utf8)
            try data.write(to: auth)
            originalAuth[auth] = data
        }
        let engine = DataEngine(hudDir: hud, bundleProvidersDir: nil, userProvidersDir: providers,
                                runner: ProviderRunner(nodePath: "/usr/bin/false", logDir: root.appendingPathComponent("logs")),
                                defaults: defaults, settingsURL: settings)
        engine.reloadRegistry() // No engine start, timers or real requests.
        let model = SettingsModel(engine: engine, hudDir: hud, userDir: providers,
                                  settingsURL: settings, bundleDir: nil, defaults: defaults)
        try #require(model.selected == "zeta" && model.navPage == .overview)
        let app = NSApplication.shared
        let previousPolicy = app.activationPolicy()
        let previousApp = NSWorkspace.shared.frontmostApplication
        defer {
            app.setActivationPolicy(previousPolicy)
            if previousApp?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp?.activate(options: []) }
        }
        app.setActivationPolicy(.regular)
        let host = NSHostingView(rootView: SettingsCenterView(model: model, engine: engine))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil }
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        await NativeAXTestSupport.settle(host, window: window)
        try #require(window.isVisible && window.isKeyWindow)
        for (label, page) in [("调用计划", SettingsModel.NavPage.plan),
                              ("设置与外观", .settings), ("全部账号", .overview)] {
            try NativeAXTestSupport.activate(roots: [window, host], label: label)
            await NativeAXTestSupport.settle(host, window: window)
            try #require(model.navPage == page, "Native sidebar action \(label) did not reach its page")
            #expect(model.selected == "zeta")
            #expect(model.draft == nil)
        }
        #expect(model.running.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("logs").path))
        #expect(!FileManager.default.fileExists(atPath: hud.appendingPathComponent("envs.json").path))
        #expect(try Data(contentsOf: settings) == originalSettings)
        for (url, data) in originalAuth { #expect(try Data(contentsOf: url) == data) }
    }
}
