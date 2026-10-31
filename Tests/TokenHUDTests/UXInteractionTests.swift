import AppKit
import SwiftUI
import Testing
@testable import TokenHUD

@Suite(.serialized)
@MainActor
struct UXInteractionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOKENHUD_UX_INTERACTION_TESTS"] == "1"))
    func visibleConfigurationAndDraftTestButtonsUseCurrentPage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenhud-ux-click-\(UUID().uuidString)")
        let hud = root.appendingPathComponent("hud")
        let providers = root.appendingPathComponent("providers")
        try FileManager.default.createDirectory(at: hud, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        let suite = "tokenhud.ux-click.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let auth = hud.appendingPathComponent(".sample-usage-auth.json")
        let manifest = ProviderManifest(name: "Fixture", label: "演示服务", displayName: "演示账号",
                                        authFile: auth.path, testModel: "fixture-model",
                                        queryUrl: "https://example.invalid/usage", queryAuth: "bearer",
                                        queryKeyField: "apiKey", refreshUrl: "https://example.invalid/v1/chat/completions",
                                        refreshProtocol: "openai", refreshAuth: "bearer", authMode: "apikey")
        try PluginGenerator.writePlugin(slug: "sample", manifest: manifest, script: "exit 1", into: providers)
        try Data("{\"apiKey\":\"fixture-key\",\"testModel\":\"fixture-model\"}".utf8).write(to: auth)
        let before = try Data(contentsOf: auth)
        let settings = root.appendingPathComponent("settings.json")
        try Data("{\"fixture\":true}".utf8).write(to: settings)
        let engine = DataEngine(hudDir: hud, bundleProvidersDir: nil, userProvidersDir: providers,
                                runner: ProviderRunner(nodePath: nil, logDir: root.appendingPathComponent("logs")),
                                defaults: defaults, settingsURL: settings)
        engine.reloadRegistry()
        var confirmations = 0
        var calls = 0
        let model = SettingsModel(engine: engine, hudDir: hud, userDir: providers, settingsURL: settings,
                                  bundleDir: nil, defaults: defaults,
                                  confirmDiscardChanges: { false },
                                  confirmTestCall: { _ in confirmations += 1; return false },
                                  executeTestCall: { _ in calls += 1; return "✓ fixture" })
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
        await pump(app, host: host, window: window)
        try saveImage(host, name: "overview")
        print("UX window geometry host=\(host.frame) flipped=\(host.isFlipped) window=\(window.frame)")
        try await click("配置", host: host, window: window, app: app)
        try #require(model.navPage == .detail && model.tab == .config)
        try saveImage(host, name: "configuration")
        try await click("编辑配置", host: host, window: window, app: app)
        #expect(model.draft != nil)
        model.draft?.values.prompt = "当前草稿输入"
        let scrolls = views(host).compactMap { $0 as? NSScrollView }
        if let scroll = scrolls.first, let document = scroll.documentView {
            let y = document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        await pump(app, host: host, window: window)
        try await click("发送测试调用", host: host, window: window, app: app)
        #expect(confirmations == 1)
        #expect(calls == 0)
        #expect(model.navPage == .detail && model.tab == .config && model.draft != nil)
        let local = NSPoint(x: 80, y: host.isFlipped ? 99 : host.bounds.height - 99)
        try await clickPoint(host.convert(local, to: nil), host: host, window: window, app: app)
        #expect(model.navPage == .detail && model.tab == .config && model.draft?.dirty == true)
        #expect(try Data(contentsOf: auth) == before)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("logs").path))
        print("UX 测试函数已完成动作与断言；通过与否以 Swift Testing 正式完成记录为准")
    }

    private func saveImage(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["TOKENHUD_UX_EVIDENCE_DIR"],
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("native-\(name).png"))
        }
    }

    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

    private func click(_ title: String, host: NSView, window: NSWindow, app: NSApplication) async throws {
        let candidates = views(host).compactMap { $0 as? NSButton }
        let button = candidates.first {
            $0.title == title && !$0.isHidden && $0.isEnabled &&
                host.bounds.contains($0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: host))
        }
        let point: NSPoint
        if let button {
            point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        } else {
            print("UX native title lookup unavailable for \(title); NSButton titles=\(candidates.map(\.title))")
            let topPoint: NSPoint
            switch title {
            case "配置": topPoint = NSPoint(x: 1055, y: 389)
            case "编辑配置": topPoint = NSPoint(x: 1128, y: 30)
            case "发送测试调用": topPoint = NSPoint(x: 1024, y: 754)
            default: throw NSError(domain: "UXInteraction", code: 1)
            }
            let local = NSPoint(x: topPoint.x, y: host.isFlipped ? topPoint.y : host.bounds.height - topPoint.y)
            try #require(host.hitTest(local) != nil, "截图定位点不可命中：\(title)")
            point = host.convert(local, to: nil)
        }
        try await clickPoint(point, host: host, window: window, app: app)
    }

    private func clickPoint(_ point: NSPoint, host: NSView, window: NSWindow, app: NSApplication) async throws {
        let now = ProcessInfo.processInfo.systemUptime
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                                 timestamp: now, windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                               timestamp: now + 0.01, windowNumber: window.windowNumber, context: nil,
                                               eventNumber: 2, clickCount: 1, pressure: 0))
        app.postEvent(down, atStart: false)
        app.postEvent(up, atStart: false)
        await pump(app, host: host, window: window)
    }

    private func pump(_ app: NSApplication, host: NSView, window: NSWindow) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.15
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let event = app.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.01),
                                         inMode: .default, dequeue: true) { app.sendEvent(event) }
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}
