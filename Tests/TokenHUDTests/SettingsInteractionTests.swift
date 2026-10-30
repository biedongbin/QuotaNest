import AppKit
import SwiftUI
import Testing
@testable import TokenHUD

/// Explicitly enabled native acceptance: local mouse hit testing and actual
/// SwiftUI actions, not system menu-bar or cross-process mouse interaction.
@Suite(.serialized)
@MainActor
struct SettingsInteractionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOKENHUD_INTERACTION_TESTS"] == "1"))
    func sidebarMouseActionsPreserveSelectedAccount() throws {
        try #require(Thread.isMainThread)
        let root = URL(fileURLWithPath: "/tmp/tokenhud-settings-interaction-\(UUID().uuidString)", isDirectory: true)
        let inputs = root.appendingPathComponent("fixture", isDirectory: true)
        let hud = inputs.appendingPathComponent("hud", isDirectory: true)
        let providers = inputs.appendingPathComponent("providers", isDirectory: true)
        let settings = inputs.appendingPathComponent("settings.json")
        let marker = inputs.appendingPathComponent("unexpected-fetch")
        for directory in [hud, providers] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: inputs) }
        var evidence: [[String: String]] = []
        func checkpoint(_ stage: String) throws {
            evidence.append(["lifecycle": stage])
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("events.json"), options: .atomic)
            print("SettingsInteraction lifecycle=\(stage) evidence=\(root.path)")
        }
        let originalSettings = Data("{\"fixture\":true}\n".utf8)
        try originalSettings.write(to: settings)
        let defaults = InteractionDefaults()
        // Restore the second account as an ordinary starting precondition. No
        // navPage, navigate/selectAccount, or renderScript shortcut is used.
        defaults.set("zeta", forKey: SettingsPersist.selectedKey)
        for (slug, title) in [("cline", "Cline fixture"), ("zeta", "Zeta fixture")] {
            let auth = hud.appendingPathComponent(".\(slug)-usage-auth.json")
            let manifest = ProviderManifest(name: slug, label: title, authFile: auth.path,
                                            refreshUrl: "fixture-only://disabled/never-call", authMode: "oauth")
            let script = "#!/bin/sh\nprintf 'unexpected-fetch\\n' >> '\(marker.path)'\nexit 93\n"
            try PluginGenerator.writePlugin(slug: slug, manifest: manifest, script: script, into: providers)
            try Data("{\"scheduleTimes\":[\"09:00\"]}".utf8).write(to: auth)
        }
        let engine = DataEngine(hudDir: hud, bundleProvidersDir: nil, userProvidersDir: providers,
                                runner: ProviderRunner(nodePath: "/usr/bin/false", logDir: inputs),
                                defaults: defaults, settingsURL: settings)
        engine.reloadRegistry() // Never start the engine or its timers.
        let model = SettingsModel(engine: engine, hudDir: hud, userDir: providers,
                                  settingsURL: settings, bundleDir: nil, defaults: defaults)
        try #require(engine.allPlugins.map(\.slug) == ["cline", "zeta"])
        try #require(model.selected == "zeta")
        try #require(model.navPage == .overview)

        let app = NSApplication.shared
        let previousApp = NSWorkspace.shared.frontmostApplication
        let previousPolicy = app.activationPolicy()
        let previousDelegate = app.delegate
        let lifecycleDelegate = InteractionApplicationDelegate { stage in
            try? checkpoint(stage)
        }
        app.delegate = lifecycleDelegate
        // Swift Testing owns process launch and completion. Do not send another
        // finishLaunching lifecycle through the test runner's shared NSApp.
        app.setActivationPolicy(.accessory)
        let host = NSHostingView(rootView: SettingsCenterView(model: model, engine: engine, renderScript: nil))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1000, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "TokenHUD isolated navigation acceptance"
        window.isReleasedWhenClosed = false
        window.contentView = host
        var cleanedUp = false
        func cleanup() throws {
            guard !cleanedUp else { return }
            try checkpoint("cleanup-begin")
            window.close()
            try checkpoint("window-closed")
            app.setActivationPolicy(previousPolicy)
            if previousApp?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previousApp?.activate(options: [])
            }
            try checkpoint("activation-restored")
            try FileManager.default.removeItem(at: inputs)
            try #require(!FileManager.default.fileExists(atPath: inputs.path))
            cleanedUp = true
            try checkpoint("cleanup-complete")
        }
        defer {
            if !cleanedUp {
                do { try cleanup() }
                catch { Issue.record("Interaction fixture cleanup failed: \(error)") }
            }
            app.delegate = previousDelegate
            withExtendedLifetime(lifecycleDelegate) {}
            do { try checkpoint("defer-complete") }
            catch { Issue.record("Interaction completion evidence failed: \(error)") }
        }
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        pump(app, host: host, window: window, seconds: 0.4)
        try #require(window.isVisible && window.isKeyWindow)
        try #require(host.bounds.size == NSSize(width: 1000, height: 700))
        try checkpoint("window-ready")

        // NavColumn is 200pt wide. Title plus padding occupies ~46pt, followed
        // by three 34pt rows separated by 2pt. Points are host top-left based.
        for (index, page, topY) in [(1, SettingsModel.NavPage.plan, 99.0),
                                    (2, .settings, 135.0), (3, .overview, 63.0)] {
            let local = NSPoint(x: 100, y: host.isFlipped ? topY : host.bounds.height - topY)
            let point = host.convert(local, to: nil)
            let hit = host.hitTest(local).map { String(describing: type(of: $0)) } ?? "none"
            let before = String(describing: model.navPage)
            let time = ProcessInfo.processInfo.systemUptime
            let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                modifierFlags: [], timestamp: time, windowNumber: window.windowNumber, context: nil,
                eventNumber: index * 2, clickCount: 1, pressure: 1))
            let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
                modifierFlags: [], timestamp: time + 0.01, windowNumber: window.windowNumber, context: nil,
                eventNumber: index * 2 + 1, clickCount: 1, pressure: 0))
            // Queue both first: native tracking loops must be able to consume up.
            app.postEvent(down, atStart: false)
            app.postEvent(up, atStart: false)
            pump(app, host: host, window: window, seconds: 0.25)
            evidence.append(["expectedPage": String(describing: page), "beforePage": before,
                             "afterPage": String(describing: model.navPage), "selected": model.selected ?? "nil",
                             "windowPoint": NSStringFromPoint(point), "hit": hit])
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("events.json"), options: .atomic)
            print("localMouse \(before)->\(model.navPage), selected=\(model.selected ?? "nil"), hit=\(hit), evidence=\(root.path)")
            try #require(model.navPage == page)
            try #require(model.selected == "zeta")
        }
        try #require(model.running.isEmpty)
        try #require(!FileManager.default.fileExists(atPath: marker.path))
        try #require(try Data(contentsOf: settings) == originalSettings)
        try #require(!FileManager.default.fileExists(atPath: hud.appendingPathComponent("envs.json").path))
        try checkpoint("assertions-complete")
        try cleanup()
        try checkpoint("body-return")
        // These checkpoints are diagnostics. Only Swift Testing's formal test
        // and run completion records establish PASS after this method returns.
    }

    /// Every pump has a monotonic deadline <=5s. sendEvent is synchronous, so
    /// run this opt-in suite with an external process timeout as the last guard.
    private func pump(_ app: NSApplication, host: NSView, window: NSWindow, seconds: Double) {
        let deadline = ProcessInfo.processInfo.systemUptime + min(max(seconds, 0), 5)
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let event = app.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.01),
                                         inMode: .default, dequeue: true) {
                app.sendEvent(event)
            }
            app.updateWindows()
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.003))
        }
    }
}

/// A test window must not terminate Swift Testing's process on close. Record
/// any native termination request so the lifecycle hypothesis stays observable.
@MainActor
private final class InteractionApplicationDelegate: NSObject, NSApplicationDelegate {
    let record: (String) -> Void
    init(record: @escaping (String) -> Void) { self.record = record }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        record("last-window-termination-refused")
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        record("application-termination-refused")
        return .terminateCancel
    }
}

/// Preferences used by the fixture never reach a persistent defaults domain.
private final class InteractionDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    init() { super.init(suiteName: "tokenhud.interaction.\(UUID().uuidString)")! }
    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    override func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Int, forKey key: String) { values[key] = value }
    override func set(_ value: Bool, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}
