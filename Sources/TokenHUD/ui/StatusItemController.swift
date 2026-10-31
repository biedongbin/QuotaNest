import SwiftUI
import AppKit

// MARK: - 自绘状态栏 (替代 MenuBarExtra: 右键菜单系统不透传, NSStatusItem 可拦截)

/// 菜单栏图标: 左键弹供应商面板 (NSPopover), 右键弹菜单 (刷新余额/供应商管理/退出)
@MainActor
final class StatusItemController: ObservableObject {
    static var shared: StatusItemController?

    private let engine: DataEngine
    private let panelCtrl: PanelController
    private let statusItem: NSStatusItem
    private var popover: NSPopover?
    private var cancellable: Any?

    init(engine: DataEngine, panelCtrl: PanelController) {
        self.engine = engine
        self.panelCtrl = panelCtrl
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.action = #selector(onClick(_:))
        statusItem.button?.target = self
        Self.shared = self
        updateTitle()
        // states 变化 → 更新图标百分比
        cancellable = engine.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.updateTitle() }
        }
    }

    /// 图标百分比: 指定家则用该家, 否则全部取最高; 刷新中前缀 ⟳
    private func updateTitle() {
        var pct: Double?
        if let slug = engine.iconProviderSlug,
           let st = engine.states.first(where: { $0.slug == slug }) {
            pct = st.cache?.fiveHour?.usedPercentage ?? st.worstPct
        } else {
            pct = engine.states.compactMap(\.worstPct).max()
        }
        let text = pct.map { "\(Int($0.rounded()))%" } ?? "…"
        statusItem.button?.title = engine.isRefreshingAll ? "⟳ \(text)" : text
        statusItem.button?.toolTip = "TokenHUD — 左键明细, 右键菜单"
    }

    @objc private func onClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover()
        }
    }

    // 右键菜单
    private func showMenu() {
        let menu = NSMenu()
        let togglePanel = NSMenuItem(title: panelVisible ? "关闭悬浮窗" : "打开悬浮窗",
                                     action: #selector(togglePanelAction), keyEquivalent: "")
        togglePanel.target = self
        let refresh = NSMenuItem(title: "刷新余额", action: #selector(refreshAll), keyEquivalent: "")
        refresh.target = self
        let settings = NSMenuItem(title: "设置中心…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(togglePanel)
        menu.addItem(.separator())
        menu.addItem(refresh)
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(quit)
        statusItem.menu = menu // 显示期间挂 menu, 结束后移除 (否则左键失效)
        statusItem.button?.performClick(nil)
        DispatchQueue.main.async { [weak self] in self?.statusItem.menu = nil }
    }

    private var panelVisible: Bool { panelCtrl.isVisible }

    @objc private func togglePanelAction() {
        panelCtrl.toggle()
    }

    @objc private func refreshAll() {
        // 快捷入口只查余额, 不发模型调用 (不隐式消费额度)
        Task { await engine.refreshBalancesOnly() }
    }

    @objc private func openSettings() {
        SettingsWindowManager.shared.show()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // 左键: 弹/收供应商面板
    private func togglePopover() {
        if let popover, popover.isShown {
            popover.performClose(nil)
        } else {
            let content = MenuBarView(engine: engine, panelCtrl: panelCtrl,
                                      onOpenSettings: { SettingsWindowManager.shared.show() },
                                      onTogglePanel: { [weak self] in self?.panelCtrl.toggle() },
                                      onRefresh: { [weak self] in
                                          guard let self else { return }
                                          Task { await self.engine.refreshBalancesOnly() }
                                      },
                                      onQueryAccount: { [weak self] slug in
                                          guard let self else { return }
                                          guard let model = SettingsWindowManager.shared.modelForQuery() else { return }
                                          model.query(slug)
                                      })
            let p = NSPopover()
            p.contentViewController = NSHostingController(rootView: content)
            p.behavior = .transient
            p.animates = true
            p.show(relativeTo: statusItem.button!.bounds, of: statusItem.button!, preferredEdge: .minY)
            popover = p
        }
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
    private weak var model: SettingsModel?
    private let defaults: UserDefaults
    private let autosaveName: String
    /// App init 时注入 (engine / 路径在 App 侧)
    var makeModel: (() -> SettingsModel)?

    init(defaults: UserDefaults = .standard, autosaveName: String = WindowFrameMemory.autosaveName) {
        self.defaults = defaults
        self.autosaveName = autosaveName
        super.init()
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
        guard let model = makeModel?() else { return }
        self.model = model
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
