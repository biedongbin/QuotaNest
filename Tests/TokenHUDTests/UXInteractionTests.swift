import AppKit
import SwiftUI
import Testing
@testable import TokenHUD

/// In-process accessibility actions exercise the real SwiftUI controls. They do
/// not establish physical mouse, keyboard or system menu-bar acceptance.
@Suite(.serialized)
@MainActor
struct UXInteractionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOKENHUD_UX_INTERACTION_TESTS"] == "1"))
    func connectionEditorAndDraftTestUseAccessibleControls() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenhud-ux-ax-\(UUID().uuidString)")
        let hud = root.appendingPathComponent("hud")
        let providers = root.appendingPathComponent("providers")
        try FileManager.default.createDirectory(at: hud, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        let suite = "tokenhud.ux-ax.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let auth = hud.appendingPathComponent(".sample-usage-auth.json")
        let manifest = ProviderManifest(name: "Fixture", label: "演示服务", displayName: "演示账号",
                                        authFile: auth.path, testModel: "fixture-model",
                                        queryUrl: "https://example.invalid/usage", queryAuth: "bearer",
                                        queryKeyField: "apiKey", refreshUrl: "https://example.invalid/v1/chat/completions",
                                        refreshProtocol: "openai", refreshAuth: "bearer", authMode: "apikey")
        try PluginGenerator.writePlugin(slug: "sample", manifest: manifest, script: "exit 1", into: providers)
        try Data("{\"apiKey\":\"query-fixture\",\"refreshApiKey\":\"call-fixture\",\"testModel\":\"fixture-model\"}".utf8).write(to: auth)
        let before = try Data(contentsOf: auth)
        let settings = root.appendingPathComponent("settings.json")
        let settingsBefore = Data("{\"fixture\":true}".utf8)
        try settingsBefore.write(to: settings)
        let engine = DataEngine(hudDir: hud, bundleProvidersDir: nil, userProvidersDir: providers,
                                runner: ProviderRunner(nodePath: nil, logDir: root.appendingPathComponent("logs")),
                                defaults: defaults, settingsURL: settings)
        engine.reloadRegistry()
        var confirmations = 0, calls = 0
        let model = SettingsModel(engine: engine, hudDir: hud, userDir: providers, settingsURL: settings,
                                  bundleDir: nil, defaults: defaults, confirmDiscardChanges: { false },
                                  confirmTestCall: { _ in confirmations += 1; return false },
                                  executeTestCall: { _ in calls += 1; return "✓ fixture" })
        // Starting on a saved account's Connection page is a fixture precondition.
        // All subsequent edit/test/navigation attempts are actual accessible controls.
        try #require(model.selectAccount("sample", tab: .config))
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        app.setActivationPolicy(.regular)
        let host = NSHostingView(rootView: SettingsCenterView(model: model, engine: engine))
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: 780)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil }
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        await NativeAXTestSupport.settle(host, window: window)
        try NativeAXTestSupport.activate(roots: [window, host], identifier: "account.edit-connection", label: "编辑连接")
        await NativeAXTestSupport.settle(host, window: window)
        try #require(model.draft != nil)
        model.draft?.values.prompt = "当前草稿输入"
        try NativeAXTestSupport.activate(roots: [window, host], identifier: "account.test-draft", label: "测试当前 API 配置")
        await NativeAXTestSupport.settle(host, window: window)
        #expect(confirmations == 1)
        #expect(calls == 0)
        #expect(model.draft?.dirty == true)
        #expect(model.toast?.text.contains("已取消测试") == true)
        // Native sidebar navigation has its own opt-in SettingsInteractionTests.
        // Keep this test focused on real edit/test button actions and credential isolation.
        #expect(try Data(contentsOf: auth) == before)
        #expect(try Data(contentsOf: settings) == settingsBefore)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("logs").path))
    }
}

@MainActor
enum NativeAXTestSupport {
    static func elements(roots: [NSObject]) -> [NSObject] {
        var queue = roots, result: [NSObject] = []
        var visited: Set<ObjectIdentifier> = []
        while !queue.isEmpty, result.count < 10_000 {
            let element = queue.removeLast()
            guard visited.insert(ObjectIdentifier(element)).inserted else { continue }
            result.append(element)
            for name in ["accessibilityChildren", "accessibilityChildrenInNavigationOrder", "accessibilityContents"] {
                if let children = object(element, getter: name) as? [Any] {
                    queue.append(contentsOf: children.compactMap { $0 as? NSObject })
                }
            }
            if element.accessibilityAttributeNames().contains(.children),
               let children = element.accessibilityAttributeValue(.children) as? [Any] {
                queue.append(contentsOf: children.compactMap { $0 as? NSObject })
            }
            if let view = element as? NSView { queue.append(contentsOf: view.subviews) }
        }
        return result
    }
    static func object(_ element: NSObject, getter: String) -> AnyObject? {
        let selector = NSSelectorFromString(getter)
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue()
    }
    static func names(_ element: NSObject) -> [String] {
        var result = ["accessibilityLabel", "accessibilityTitle"].compactMap {
            object(element, getter: $0) as? String
        }
        if let button = element as? NSButton { result.append(button.title) }
        let attributes = element.accessibilityAttributeNames()
        if attributes.contains(.title), let title = element.accessibilityAttributeValue(.title) as? String { result.append(title) }
        // Static text can expose its name as AXValue. Never inspect text-field,
        // secure-field, cookie, key or token input values.
        if object(element, getter: "accessibilityRole") as? String == "AXStaticText",
           let text = object(element, getter: "accessibilityValue") as? String { result.append(text) }
        return result.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    static func activate(roots: [NSObject], identifier: String? = nil, label: String? = nil) throws {
        let candidates = elements(roots: roots)
        let byIdentifier = identifier.flatMap { wanted in
            candidates.first { element in
                object(element, getter: "accessibilityIdentifier") as? String == wanted
                    || (element as? NSView)?.identifier?.rawValue == wanted
            }
        }
        let byName = label.flatMap { wanted -> NSObject? in
            let matches = candidates.filter { names($0).contains(wanted) }
            return matches.first { $0 is NSButton || object($0, getter: "accessibilityRole") as? String == "AXButton" } ?? matches.first
        }
        let target = byIdentifier ?? byName
        let dump = FileManager.default.temporaryDirectory.appendingPathComponent("tokenhud-fixture-ax-\(UUID().uuidString).json")
        let metadata = candidates.map { element -> [String: String] in
            ["type": String(describing: type(of: element)),
             "role": object(element, getter: "accessibilityRole") as? String ?? "",
             "subrole": object(element, getter: "accessibilitySubrole") as? String ?? "",
             "identifier": object(element, getter: "accessibilityIdentifier") as? String ?? "",
             "label": object(element, getter: "accessibilityLabel") as? String ?? "",
             "title": object(element, getter: "accessibilityTitle") as? String ?? "",
             "button_title": (element as? NSButton)?.title ?? ""]
        }
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: dump, options: .atomic)
        print("Fixture AX metadata (no field values): \(dump.path)")
        let element = try #require(target, "Accessibility target unavailable: \(identifier ?? label ?? "unspecified"), \(candidates.count) nodes; metadata: \(dump.path); no coordinate fallback")
        var current: NSObject? = element
        var activated = false
        for _ in 0..<12 {
            guard let candidate = current else { break }
            if let button = candidate as? NSButton, button.isEnabled {
                button.performClick(nil)
                activated = true; break
            }
            if let accessible = candidate as? NSAccessibilityProtocol, accessible.accessibilityPerformPress() {
                activated = true; break
            }
            if candidate.accessibilityActionNames().contains(.press) {
                candidate.accessibilityPerformAction(.press)
                activated = true; break
            }
            if candidate.accessibilityIsAttributeSettable(.selected) {
                candidate.accessibilitySetValue(true, forAttribute: .selected)
                activated = true; break
            }
            current = object(candidate, getter: "accessibilityParent") as? NSObject
        }
        try #require(activated, "Accessibility element has no supported press/selection action: \(identifier ?? label ?? "unspecified")")
    }
    static func settle(_ host: NSView, window: NSWindow) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        while ProcessInfo.processInfo.systemUptime < deadline {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
