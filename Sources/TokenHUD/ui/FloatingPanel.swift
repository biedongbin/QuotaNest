import AppKit
import SwiftUI

enum FloatingPanelPlacement {
    private static let defaultSize = NSSize(width: 260, height: 40)

    private static func isFinitePositive(_ frame: NSRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite &&
        frame.size.width.isFinite && frame.size.height.isFinite &&
        frame.size.width > 0 && frame.size.height > 0 &&
        frame.maxX.isFinite && frame.maxY.isFinite
    }

    static func resolve(_ saved: NSRect?, visibleFrames: [NSRect],
                        preferredScreen: NSRect? = nil) -> NSRect {
        let screens = visibleFrames.filter(isFinitePositive)
        let valid = saved.flatMap { frame in
            isFinitePositive(frame) && frame.width >= 16 && frame.height >= 16 ? frame : nil
        }
        let defaultFrame = NSRect(origin: .zero, size: defaultSize)
        guard let first = screens.first else { return valid ?? defaultFrame }

        // 留有足够交集才保留所属屏幕；一像素细条不能成为无法拖回的窗口。
        let candidates = screens.filter { screen in
            guard let frame = valid else { return false }
            let overlap = frame.intersection(screen)
            return !overlap.isNull && overlap.width >= min(frame.width, 64) &&
                overlap.height >= min(frame.height, 24)
        }
        let target = candidates.max { lhs, rhs in
            let frame = valid ?? defaultFrame
            let a = frame.intersection(lhs)
            let b = frame.intersection(rhs)
            return a.width * a.height < b.width * b.height
        } ?? screens.first(where: { $0 == preferredScreen }) ?? first
        var result = valid ?? defaultFrame
        result.size.width = min(result.width, target.width)
        result.size.height = min(result.height, target.height)
        if valid == nil {
            result.origin = NSPoint(x: target.midX - result.width / 2,
                                    y: target.midY - result.height / 2)
        } else {
            result.origin.x = min(max(result.minX, target.minX), target.maxX - result.width)
            result.origin.y = min(max(result.minY, target.minY), target.maxY - result.height)
        }
        return result
    }
}

final class FloatingPanel: NSPanel {
    static let defaultsFrameKey = "floatingFrame"
    private let defaults: UserDefaults
    var onHide: (() -> Void)?
    var onScreenChange: (() -> Void)?

    init(contentView: NSView, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init(contentRect: NSRect(x: 0, y: 0, width: 260, height: 40),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        self.contentView = contentView
        level = .floating
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        hasShadow = true
        let saved = defaults.string(forKey: Self.defaultsFrameKey).map(NSRectFromString)
        let screens = NSScreen.screens
        let preferred = Self.preferredScreen(in: screens)
        setFrame(FloatingPanelPlacement.resolve(saved, visibleFrames: screens.map(\.visibleFrame),
                                                preferredScreen: preferred), display: false)
        delegate = self
    }

    override var canBecomeKey: Bool { false }

    private static func preferredScreen(in screens: [NSScreen]) -> NSRect? {
        screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
    }

    func recoverPosition() {
        let screens = NSScreen.screens
        let resolved = FloatingPanelPlacement.resolve(frame, visibleFrames: screens.map(\.visibleFrame),
                                                      preferredScreen: Self.preferredScreen(in: screens))
        if frame != resolved { setFrame(resolved, display: isVisible) }
        persistFrame()
    }

    func persistFrame() {
        defaults.set(NSStringFromRect(frame), forKey: Self.defaultsFrameKey)
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(sender)
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        onHide?()
    }
}

extension FloatingPanel: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        persistFrame()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        onScreenChange?()
    }

    func windowWillClose(_ notification: Notification) {
        onHide?()
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
    private let defaults: UserDefaults
    private var screenObserver: NSObjectProtocol?
    private var layoutRevision = 0
    var maximumPanelHeight: CGFloat {
        max(80, (panel?.screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? 800) - 24)
    }

    static let defaultsStyleKey = "tokenhud.panelStyle"
    static let defaultsBgOpacityKey = "tokenhud.panelBgOpacity"
    static let defaultsTextOpacityKey = "tokenhud.panelTextOpacity"

    init(engine: DataEngine, defaults: UserDefaults = .standard) {
        self.engine = engine
        self.defaults = defaults
        self.style = PanelStyle(rawValue: defaults.string(forKey: Self.defaultsStyleKey) ?? "") ?? .card
        self.bgOpacity = defaults.object(forKey: Self.defaultsBgOpacityKey) as? Double ?? 0.85
        self.textOpacity = defaults.object(forKey: Self.defaultsTextOpacityKey) as? Double ?? 1.0
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                panel.recoverPosition()
                self.rebuild()
            }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func setStyle(_ s: PanelStyle) {
        style = s
        defaults.set(s.rawValue, forKey: Self.defaultsStyleKey)
        rebuild() // 布局结构变, 需重建
    }

    func setBgOpacity(_ v: Double) {
        bgOpacity = v
        defaults.set(v, forKey: Self.defaultsBgOpacityKey)
        // @Published 驱动 FloatingView 重渲染, 无需 rebuild (避免打断 Slider)
    }

    func setTextOpacity(_ v: Double) {
        textOpacity = v
        defaults.set(v, forKey: Self.defaultsTextOpacityKey)
    }

    /// 供应商管理窗 (单例 NSWindow, 全局唯一)
    func openSettings() {
        SettingsWindowManager.shared.show()
    }

    func show() {
        if panel == nil {
            let hosting = makeHosting()
            hosting.layoutSubtreeIfNeeded()
            let p = FloatingPanel(contentView: hosting, defaults: defaults)
            p.onHide = { [weak self] in self?.isVisible = false }
            p.onScreenChange = { [weak self] in
                Task { @MainActor [weak self] in self?.refreshScreenLimit() }
            }
            p.setContentSize(hosting.fittingSize)
            panel = p
        }
        guard let panel else { return }
        panel.recoverPosition()
        refreshScreenLimit()
        panel.orderFrontRegardless()
        isVisible = panel.isVisible
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func rebuild() {
        guard let panel else { return }
        let hosting = makeHosting()
        hosting.layoutSubtreeIfNeeded()
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        if panel.isVisible { panel.recoverPosition() }
    }

    func toggleExpanded() {
        expanded.toggle()
        rebuild()
    }

    private func refreshScreenLimit() {
        guard let hosting = panel?.contentView as? NSHostingView<FloatingView>,
              abs(hosting.rootView.maximumHeight - maximumPanelHeight) > 0.5 else { return }
        rebuild()
    }

    private func resizeToContent(_ height: CGFloat) {
        guard let panel, height.isFinite, height > 0 else { return }
        let targetHeight = min(height, maximumPanelHeight)
        guard abs(panel.frame.height - targetHeight) > 0.5 else { return }
        var frame = panel.frame
        let top = frame.maxY
        frame.size = NSSize(width: 340, height: targetHeight)
        frame.origin.y = top - targetHeight
        panel.setFrame(frame, display: panel.isVisible)
        if panel.isVisible { panel.recoverPosition() }
    }

    private func makeHosting() -> NSHostingView<FloatingView> {
        layoutRevision += 1
        let revision = layoutRevision
        return NSHostingView(rootView: FloatingView(
            engine: engine, controller: self, expanded: expanded,
            onToggle: { [weak self] in self?.toggleExpanded() },
            onQuit: { NSApplication.shared.terminate(nil) },
            onRefreshAll: { [weak self] in
                guard let self else { return }
                // 快捷入口只查余额, 不发模型调用 (不隐式消费额度)
                Task { await self.engine.refreshBalancesOnly() }
            },
            onOpenSettings: { [weak self] in self?.openSettings() },
            operationModel: SettingsWindowManager.shared.modelForQuery(),
            maximumHeight: maximumPanelHeight,
            onHeightChange: { [weak self] height in
                Task { @MainActor [weak self] in
                    guard let self, self.layoutRevision == revision else { return }
                    self.resizeToContent(height)
                }
            }
        ))
    }
}
