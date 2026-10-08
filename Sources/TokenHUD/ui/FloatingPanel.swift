import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {
    init(contentView: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 260, height: 40),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        self.contentView = contentView
        level = .floating
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        hasShadow = true
        delegate = self
        // 恢复位置
        if let s = UserDefaults.standard.string(forKey: "floatingFrame") {
            let r = NSRectFromString(s)
            if r != .zero { setFrame(r, display: false) } else { center() }
        } else {
            center()
        }
    }

    override var canBecomeKey: Bool { false }

    func persistFrame() {
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: "floatingFrame")
    }
}

extension FloatingPanel: NSWindowDelegate {
    // brief 的 `override func move(_ event: NSEvent)` 在 NSWindow 上不存在对应方法
    // (只有 @IBAction move(_: Any?)) — 改用 didMove 委托回调, 拖动结束即落盘
    func windowDidMove(_ notification: Notification) {
        persistFrame()
    }
}

// MARK: - Panel 生命周期 (App struct 是值语义, NSPanel 引用放这里)

/// 悬浮窗风格
enum PanelStyle: String, CaseIterable, Identifiable {
    case card      // 卡片式
    case glass     // 玻璃拟态
    case compact   // 紧凑单行 (横排多桶)
    case list      // 列表: 每行只显示一个用量桶
    var id: String { rawValue }
    var label: String {
        switch self {
        case .card: return "卡片"
        case .glass: return "玻璃"
        case .compact: return "紧凑"
        case .list: return "列表"
        }
    }
}

@MainActor
final class PanelController: ObservableObject {
    @Published private(set) var isVisible = false
    private(set) var expanded = false // 默认紧凑 (单行迷你条)
    @Published var style: PanelStyle
    @Published var bgOpacity: Double
    @Published var textOpacity: Double
    private var panel: FloatingPanel?
    private let engine: DataEngine


    static let defaultsStyleKey = "tokenhud.panelStyle"
    static let defaultsBgOpacityKey = "tokenhud.panelBgOpacity"
    static let defaultsTextOpacityKey = "tokenhud.panelTextOpacity"

    init(engine: DataEngine) {
        self.engine = engine
        let d = UserDefaults.standard
        self.style = PanelStyle(rawValue: d.string(forKey: Self.defaultsStyleKey) ?? "") ?? .card
        self.bgOpacity = d.object(forKey: Self.defaultsBgOpacityKey) as? Double ?? 0.85
        self.textOpacity = d.object(forKey: Self.defaultsTextOpacityKey) as? Double ?? 1.0
    }

    func setStyle(_ s: PanelStyle) {
        style = s
        UserDefaults.standard.set(s.rawValue, forKey: Self.defaultsStyleKey)
        rebuild() // 布局结构变, 需重建
    }

    func setBgOpacity(_ v: Double) {
        bgOpacity = v
        UserDefaults.standard.set(v, forKey: Self.defaultsBgOpacityKey)
        // @Published 驱动 FloatingView 重渲染, 无需 rebuild (避免打断 Slider)
    }

    func setTextOpacity(_ v: Double) {
        textOpacity = v
        UserDefaults.standard.set(v, forKey: Self.defaultsTextOpacityKey)
    }

    /// 供应商管理窗 (单例 NSWindow, 全局唯一)
    func openSettings() {
        SettingsWindowManager.shared.show()
    }

    func toggle() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            isVisible = false
        } else {
            let hosting = makeHosting()
            hosting.layoutSubtreeIfNeeded()
            let p = FloatingPanel(contentView: hosting)
            p.setContentSize(hosting.fittingSize)
            p.orderFrontRegardless()
            panel = p
            isVisible = true
        }
    }

    func rebuild() {
        guard let panel else { return }
        let hosting = makeHosting()
        hosting.layoutSubtreeIfNeeded()
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
    }

    func toggleExpanded() {
        expanded.toggle()
        rebuild()
    }

    private func makeHosting() -> NSHostingView<FloatingView> {
        NSHostingView(rootView: FloatingView(
            engine: engine, controller: self, expanded: expanded,
            onToggle: { [weak self] in self?.toggleExpanded() },
            onQuit: { NSApplication.shared.terminate(nil) },
            onRefreshAll: { [weak self] in
                guard let self else { return }
                Task { await self.engine.triggerAndRefreshAll() }
            },
            onOpenSettings: { [weak self] in self?.openSettings() }
        ))
    }
}
