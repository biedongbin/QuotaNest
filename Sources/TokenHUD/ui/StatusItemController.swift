import SwiftUI
import AppKit

@MainActor
final class StatusItemController: ObservableObject {
    static var shared: StatusItemController?
    private let engine: DataEngine
    let panelController: PanelController
    private let statusItem: NSStatusItem
    private var popover: NSPopover?
    private var cancellable: Any?

    init(engine: DataEngine, panelCtrl: PanelController) {
        self.engine = engine
        panelController = panelCtrl
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.action = #selector(onClick(_:))
        statusItem.button?.target = self
        Self.shared = self
        updateTitle()
        cancellable = engine.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.updateTitle() }
        }
    }

    private func updateTitle() {
        let eligible = engine.states.filter { $0.manifest.supportsQuota }
        let chosen = engine.iconProviderSlug.flatMap { slug in eligible.first { $0.slug == slug } }
        let states = chosen.map { [$0] } ?? eligible
        let percentage = states.compactMap { state in
            QuotaPresentation(state: state).metrics.compactMap(\.percentage).max()
        }.max()
        let old = states.contains { QuotaPresentation(state: $0).isOld }
        let value = percentage.map { "\(Int($0.rounded()))%" } ?? "—"
        statusItem.button?.title = (engine.isRefreshingAll ? "↻ " : "") + value + (old && percentage != nil ? " ·" : "")
        statusItem.button?.toolTip = "TokenHUD · 单击快览，双击悬浮，右键操作" + (old ? " · 包含旧数据" : "")
        statusItem.button?.setAccessibilityLabel("TokenHUD，\(value)" + (old ? "，包含旧数据" : ""))
    }

    @objc private func onClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            popover?.performClose(nil)
            showMenu()
        } else if event.clickCount == 2 {
            // The first click opens immediately; the second closes that transient
            // preview and performs only the floating-panel command. No timer races.
            popover?.performClose(nil)
            panelController.toggle()
        } else if event.clickCount == 1 {
            togglePopover()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        add("\(panelController.isVisible ? "关闭" : "打开")悬浮速览", action: #selector(togglePanel), to: menu)
        add("刷新可查询账号", action: #selector(refreshAll), key: "r", to: menu)
        menu.addItem(.separator())
        add("账号管理…", action: #selector(openAccounts), key: "0", to: menu)
        add("设置与外观…", action: #selector(openSettings), key: ",", to: menu)
        menu.addItem(.separator())
        add("退出 TokenHUD", action: #selector(quit), key: "q", to: menu)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
    private func add(_ title: String, action: Selector, key: String = "", to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }
    @objc private func togglePanel() { panelController.toggle() }
    @objc private func refreshAll() { Task { await engine.refreshBalancesOnly() } }
    @objc private func openAccounts() { SettingsWindowManager.shared.show() }
    @objc private func openSettings() { SettingsWindowManager.shared.showSettings() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    private func togglePopover() {
        if let popover, popover.isShown { popover.performClose(nil); return }
        guard let model = SettingsWindowManager.shared.modelForQuery(), let button = statusItem.button else { return }
        let content = MenuBarView(engine: engine, panelCtrl: panelController, model: model,
                                 onOpenSettings: { [weak self] in self?.popover?.performClose(nil); SettingsWindowManager.shared.show() },
                                 onTogglePanel: { [weak self] in self?.panelController.toggle() },
                                 onRefresh: { [weak self] in self?.refreshAll() },
                                 onOpenAccount: { [weak self] slug in
                                     self?.popover?.performClose(nil)
                                     SettingsWindowManager.shared.showAccount(slug)
                                 })
        let preview = NSPopover()
        preview.contentViewController = NSHostingController(rootView: content)
        preview.behavior = .transient
        preview.animates = false
        preview.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover = preview
    }
}

// MARK: - 窗口位置记忆

/// autosave 名与 defaults 键 ("NSWindow Frame <name>") 的判定 (纯函数, 可测)
enum WindowFrameMemory {
    static let autosaveName = "settingsWindow"
    static var defaultsKey: String { "NSWindow Frame \(autosaveName)" }

    /// 保存值格式 "x y w h sx sy sw sh "; 宽高 > 0 才算有效
    static func hasUsableFrame(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let n = raw.split(separator: " ").compactMap { Double($0) }
        return n.count >= 4 && n[2] > 0 && n[3] > 0
    }

    static func hasSavedFrame(in defaults: UserDefaults = .standard) -> Bool {
        hasUsableFrame(defaults.string(forKey: defaultsKey))
    }
}

// MARK: - 设置中心窗口 (单例 NSWindow, 内容 = SettingsCenterView)

@MainActor
final class SettingsWindowManager: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowManager()
    private var window: NSWindow?
    private var model: SettingsModel?
    private let defaults: UserDefaults
    private let autosaveName: String
    /// App init 时注入 (engine / 路径在 App 侧)
    var makeModel: (() -> SettingsModel)?

    init(defaults: UserDefaults = .standard, autosaveName: String = WindowFrameMemory.autosaveName) {
        self.defaults = defaults
        self.autosaveName = autosaveName
        super.init()
    }

    func showAccount(_ slug: String) {
        guard let model = modelForQuery(), model.selectAccount(slug, tab: .config) else { return }
        show()
    }

    func showSettings() {
        guard let model = modelForQuery() else { return }
        model.navigate(to: .settings)
        show()
    }

    func show() {
        if let window {
            NSApp.setActivationPolicy(SettingsWindowLifecycle.activationPolicy(after: .show))
            if window.isMiniaturized { window.deminiaturize(nil) }
            restoreVisiblePosition(window)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let model = modelForQuery() else { return }
        let host = NSHostingController(rootView: SettingsCenterView(model: model, engine: model.engine))
        let w = SettingsMainWindow(contentViewController: host)
        w.title = "TokenHUD"
        w.styleMask.insert([.closable, .miniaturizable, .resizable])
        w.minSize = NSSize(width: 640, height: 560)
        w.delegate = self
        w.isReleasedWhenClosed = false
        if defaults === UserDefaults.standard {
            w.setFrameAutosaveName(autosaveName)
        } else if let saved = defaults.string(forKey: "NSWindow Frame \(autosaveName)") {
            let numbers = saved.split(separator: " ").compactMap { Double($0) }
            if numbers.count >= 4 {
                w.setFrame(NSRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]), display: false)
            }
        }
        window = w
        restoreVisiblePosition(w)
        NSApp.setActivationPolicy(SettingsWindowLifecycle.activationPolicy(after: .show))
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func restoreVisiblePosition(_ window: NSWindow) {
        let frames = NSScreen.screens.map(\.visibleFrame)
        var frame = window.frame
        frame.size.width = max(frame.width, window.minSize.width)
        frame.size.height = max(frame.height, window.minSize.height)
        let preferred = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
        let resolved = FloatingPanelPlacement.resolve(frame, visibleFrames: frames, preferredScreen: preferred)
        if resolved != window.frame { window.setFrame(resolved, display: window.isVisible) }
    }

    /// 关窗: 有未保存草稿先确认 (返回 false 阻止关闭)
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let accepted = model?.leaveGuard() ?? true
        if accepted, let model, model.draft != nil || model.showingTemplates { model.discardDraft() }
        if !accepted {
            NSApp.setActivationPolicy(SettingsWindowLifecycle.activationPolicy(after: .closeCancelled))
        }
        return accepted
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(SettingsWindowLifecycle.activationPolicy(after: .closeAccepted))
    }

    func windowDidMiniaturize(_ notification: Notification) {
        NSApp.setActivationPolicy(SettingsWindowLifecycle.activationPolicy(after: .minimize))
    }

    /// 菜单栏点单条查询: 复用设置中心模型 (未开窗时懒建, 不 show)
    func modelForQuery() -> SettingsModel? {
        if let model { return model }
        guard let model = makeModel?() else { return nil }
        self.model = model
        return model
    }
}
