import SwiftUI
import AppKit

// MARK: - 自绘状态栏 (替代 MenuBarExtra: 右键菜单系统不透传, NSStatusItem 可拦截)

/// 菜单栏图标: 左键弹供应商面板 (NSPopover), 右键弹菜单 (立刻刷新/供应商管理/退出)
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
        let refresh = NSMenuItem(title: "立刻刷新", action: #selector(refreshAll), keyEquivalent: "")
        refresh.target = self
        let settings = NSMenuItem(title: "供应商管理…", action: #selector(openSettings), keyEquivalent: "")
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
        Task { await engine.triggerAndRefreshAll() }
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
                                          Task { await self.engine.triggerAndRefreshAll() }
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

// MARK: - 供应商管理窗口 (独立 NSWindow, 替代 openWindow: 不依赖 SwiftUI scene)

@MainActor
final class SettingsWindowManager {
    static let shared = SettingsWindowManager()
    private var window: NSWindow?
    /// App init 时注入内容工厂 (engine/URL 等在 App 侧)
    var makeContent: (() -> NSViewController)?

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let vc = makeContent?() else { return }
        let w = NSWindow(contentViewController: vc)
        w.title = "TokenHUD 供应商管理"
        w.styleMask.insert(.closable)
        w.styleMask.insert(.miniaturizable)
        w.styleMask.insert(.resizable) // 自由缩放 (HIG 2.1)
        w.minSize = NSSize(width: 480, height: 400)
        w.setFrameAutosaveName("settingsWindow") // 位置/大小记忆 (HIG 2.5)
        w.center()
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        window = w
    }
}
