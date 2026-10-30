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
    /// App init 时注入 (engine / 路径在 App 侧)
    var makeModel: (() -> SettingsModel)?

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let model = makeModel?() else { return }
        self.model = model
        let host = NSHostingController(rootView: SettingsCenterView(model: model, engine: model.engine))
        let w = NSWindow(contentViewController: host)
        w.title = "TokenHUD 设置中心"
        w.styleMask.insert(.closable)
        w.styleMask.insert(.miniaturizable)
        w.styleMask.insert(.resizable)
        w.minSize = NSSize(width: 820, height: 560)  // P2-5: 主窗最小尺寸 (FR-08.6)
        let restored = WindowFrameMemory.hasSavedFrame()
        w.setFrameAutosaveName(WindowFrameMemory.autosaveName)
        w.delegate = self
        w.isReleasedWhenClosed = false
        // 首次显示后才套记忆 (此时才有屏幕坐标系), 且不覆盖已恢复的原点
        w.makeKeyAndOrderFront(nil)
        if restored { w.setFrameUsingName(WindowFrameMemory.autosaveName) } else { w.center() }
        window = w
    }

    /// 关窗: 有未保存草稿先确认 (返回 false 阻止关闭)
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model, model.draft != nil else { return true }
        return model.leaveGuard()
    }
}
