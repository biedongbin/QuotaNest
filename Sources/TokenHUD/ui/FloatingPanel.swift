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

@MainActor
final class PanelController: ObservableObject {
    @Published private(set) var isVisible = false
    private(set) var expanded = false
    private var panel: FloatingPanel?
    private let engine: DataEngine
    private var openWindowAction: OpenWindowAction?

    init(engine: DataEngine) {
        self.engine = engine
    }

    /// openWindow 只能从 View environment 取到; MenuBarRoot.onAppear 时注入
    func bindOpenWindow(_ action: OpenWindowAction) {
        openWindowAction = action
    }

    /// LSUIElement App 开窗前必须 activate, 否则窗开了也不带焦点/可能不显
    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openWindowAction?(id: "settings")
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
        NSHostingView(rootView: FloatingView(engine: engine, expanded: expanded) { [weak self] in
            self?.toggleExpanded()
        })
    }
}
