import AppKit
import Testing
@testable import TokenHUD

@Suite(.serialized)
struct FloatingPanelTests {
    private let main = NSRect(x: 0, y: 66, width: 1470, height: 856)

    @Test func savedFrameOutsideCurrentScreenIsRecovered() {
        let saved = NSRect(x: 1582, y: 530, width: 261, height: 284)
        let resolved = FloatingPanelPlacement.resolve(saved, visibleFrames: [main])
        #expect(main.contains(resolved))
        #expect(resolved.size == saved.size)
    }

    @Test func reasonablePositionIsPreserved() {
        let saved = NSRect(x: 190, y: 360, width: 261, height: 284)
        #expect(FloatingPanelPlacement.resolve(saved, visibleFrames: [main]) == saved)
    }

    @Test func negativeCoordinatesOnConnectedScreenArePreserved() {
        let left = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        let saved = NSRect(x: -1700, y: 300, width: 261, height: 284)
        #expect(FloatingPanelPlacement.resolve(saved, visibleFrames: [main, left], preferredScreen: main) == saved)
    }

    @Test func visibleSecondaryScreenWinsOverPreferredScreen() {
        let right = NSRect(x: 1470, y: 0, width: 1920, height: 1080)
        let saved = NSRect(x: 1800, y: 300, width: 261, height: 284)
        #expect(FloatingPanelPlacement.resolve(saved, visibleFrames: [main, right], preferredScreen: main) == saved)
    }

    @Test func offscreenFrameUsesPreferredScreen() {
        let left = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        let saved = NSRect(x: 9000, y: 300, width: 261, height: 284)
        let resolved = FloatingPanelPlacement.resolve(saved, visibleFrames: [main, left], preferredScreen: left)
        #expect(left.contains(resolved))
        #expect(resolved.size == saved.size)
    }

    @Test func thinVisibleStripDoesNotKeepWindowOnWrongScreen() {
        let right = NSRect(x: 1470, y: 0, width: 1920, height: 1080)
        let saved = NSRect(x: right.maxX - 1, y: 300, width: 261, height: 284)
        let resolved = FloatingPanelPlacement.resolve(saved, visibleFrames: [main, right], preferredScreen: main)
        #expect(main.contains(resolved))
    }

    @Test func partlyVisibleFrameKeepsItsScreenAndBecomesDraggable() {
        let saved = NSRect(x: 1400, y: 900, width: 261, height: 284)
        let resolved = FloatingPanelPlacement.resolve(saved, visibleFrames: [main])
        #expect(main.contains(resolved))
        #expect(resolved.size == saved.size)
    }

    @Test func oversizedWindowIsLimitedToVisibleScreen() {
        let saved = NSRect(x: 80, y: 90, width: 5000, height: 3000)
        let resolved = FloatingPanelPlacement.resolve(saved, visibleFrames: [main])
        #expect(resolved == main)
    }

    @Test func invalidFramesUseSafeDefaultOnVisibleScreen() {
        let invalid = [
            NSRect.zero,
            NSRect(x: CGFloat.nan, y: 100, width: 260, height: 40),
            NSRect(x: 100, y: CGFloat.infinity, width: 260, height: 40),
            NSRect(x: 100, y: 100, width: CGFloat.infinity, height: 40),
            NSRect(x: 100, y: 100, width: -260, height: 40),
            NSRect(x: 100, y: 100, width: 260, height: 0),
            NSRect(x: 100, y: 100, width: 1, height: 1)
        ]
        for saved in invalid {
            let resolved = FloatingPanelPlacement.resolve(saved, visibleFrames: [main])
            #expect(main.contains(resolved))
            #expect(resolved.width == 260 && resolved.height == 40)
        }
    }

    @Test func disconnectedScreenIsReevaluatedOnNextPlacement() {
        let right = NSRect(x: 1470, y: 0, width: 1920, height: 1080)
        let saved = NSRect(x: 1800, y: 300, width: 261, height: 284)
        let connected = FloatingPanelPlacement.resolve(saved, visibleFrames: [main, right])
        #expect(connected == saved)
        let disconnected = FloatingPanelPlacement.resolve(connected, visibleFrames: [main])
        #expect(main.contains(disconnected))
        #expect(disconnected.size == saved.size)
    }

    @Test func missingOrInvalidScreensStillProduceFiniteFrame() {
        let resolved = FloatingPanelPlacement.resolve(nil, visibleFrames: [.zero])
        #expect(resolved.origin.x.isFinite && resolved.origin.y.isFinite)
        #expect(resolved.width == 260 && resolved.height == 40)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOKENHUD_FLOATING_PANEL_TESTS"] == "1"))
    @MainActor func panelShowHideToggleAndCloseStayConsistent() throws {
        let app = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenhud-panel-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = FloatingPanelTestDefaults()
        defaults.set("{{1582, 530}, {261, 284}}", forKey: FloatingPanel.defaultsFrameKey)
        let settings = root.appendingPathComponent("settings.json")
        let original = Data("{\"fixture\":true}".utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try original.write(to: settings)
        let engine = DataEngine(hudDir: root.appendingPathComponent("hud"), bundleProvidersDir: nil,
                                userProvidersDir: root.appendingPathComponent("providers"),
                                runner: ProviderRunner(nodePath: nil, logDir: root.appendingPathComponent("logs")),
                                defaults: defaults, settingsURL: settings)
        let before = Set(app.windows.map(ObjectIdentifier.init))
        let controller = PanelController(engine: engine, defaults: defaults)
        defer { controller.hide() }
        #expect(!controller.isVisible)
        controller.show()
        let panel = try #require(app.windows.compactMap { $0 as? FloatingPanel }
            .first { !before.contains(ObjectIdentifier($0)) })
        defer { panel.close() }
        #expect(controller.isVisible && panel.isVisible)
        let screens = NSScreen.screens.map(\.visibleFrame)
        try #require(!screens.isEmpty)
        #expect(screens.contains { $0.contains(panel.frame) })
        #expect(defaults.string(forKey: FloatingPanel.defaultsFrameKey) == NSStringFromRect(panel.frame))
        let number = panel.windowNumber
        controller.show()
        #expect(panel.windowNumber == number)
        #expect(app.windows.compactMap { $0 as? FloatingPanel }
            .filter { !before.contains(ObjectIdentifier($0)) }.count == 1)
        controller.hide()
        #expect(!controller.isVisible && !panel.isVisible)
        controller.toggle()
        #expect(controller.isVisible && panel.isVisible)
        controller.toggle()
        #expect(!controller.isVisible && !panel.isVisible)
        panel.setFrameOrigin(NSPoint(x: 100_000, y: 100_000))
        controller.show()
        #expect(screens.contains { $0.contains(panel.frame) })
        panel.cancelOperation(nil)
        #expect(!controller.isVisible && !panel.isVisible)
        controller.show()
        panel.close()
        #expect(!controller.isVisible && !panel.isVisible)
        controller.show()
        #expect(controller.isVisible && panel.isVisible)
        #expect(try Data(contentsOf: settings) == original)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("logs").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("hud/envs.json").path))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOKENHUD_FLOATING_PANEL_TESTS"] == "1"))
    @MainActor func panelGrowsWhenAllQuotaRowsAppear() async throws {
        let app = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenhud-panel-content-\(UUID())")
        let hud = root.appendingPathComponent("hud")
        let providers = root.appendingPathComponent("providers")
        try FileManager.default.createDirectory(at: hud, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("settings.json")
        try Data("{}".utf8).write(to: settings)
        func addAccount(_ index: Int) throws {
            let slug = "account-\(index)"
            let cache = hud.appendingPathComponent(".\(slug)-usage-cache.json")
            let manifest = ProviderManifest(name: slug, label: slug,
                buckets: ["five_hour": "5h", "seven_day": "周", "monthly": "月"], cacheFile: cache.path)
            try PluginGenerator.writePlugin(slug: slug, manifest: manifest, script: "exit 1", into: providers)
            let body: [String: Any] = ["generatedAt": Date().timeIntervalSince1970 * 1000,
                "five_hour": ["used_percentage": 10], "seven_day": ["used_percentage": 20],
                "monthly": ["used_percentage": 30]]
            try JSONSerialization.data(withJSONObject: body).write(to: cache)
        }
        try addAccount(0)
        let defaults = FloatingPanelTestDefaults()
        let engine = DataEngine(hudDir: hud, bundleProvidersDir: nil, userProvidersDir: providers,
            runner: ProviderRunner(nodePath: nil, logDir: root.appendingPathComponent("logs")),
            defaults: defaults, settingsURL: settings)
        engine.reloadRegistry()
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        let controller = PanelController(engine: engine, defaults: defaults)
        controller.show()
        let panel = try #require(NSApp.windows.compactMap { $0 as? FloatingPanel }
            .first { !before.contains(ObjectIdentifier($0)) })
        defer { controller.hide(); panel.close() }
        for _ in 0..<10 { panel.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 20_000_000) }
        let initial = panel.frame.height
        for index in 1..<7 { try addAccount(index) }
        engine.reloadRegistry()
        for _ in 0..<50 where panel.frame.height <= 350 {
            panel.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(panel.frame.height > initial)
        #expect(panel.frame.height > 350)
        #expect(panel.frame.height <= controller.maximumPanelHeight + 1)
        #expect(engine.states.count == 7)
        let cardHeight = panel.frame.height
        controller.toggleExpanded()
        controller.setStyle(.compact)
        for _ in 0..<30 where panel.frame.height >= cardHeight {
            panel.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(!controller.expanded)
        #expect(panel.frame.width == PanelStyle.compact.preferredWidth)
        #expect(panel.frame.height < cardHeight)
        #expect(defaults.string(forKey: PanelController.defaultsStyleKey) == "compact")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("logs").path))
    }
}

/// 测试偏好只存在于内存，不写入 App 或其他持久化域。
private final class FloatingPanelTestDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    init() { super.init(suiteName: "tokenhud.panel-test.\(UUID().uuidString)")! }
    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}
