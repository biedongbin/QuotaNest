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
    var onInteraction: (() -> Void)?
    private var windowDrag: NSPanGestureRecognizer?
    private var dragMouseOrigin = NSPoint.zero
    private var dragWindowOrigin = NSPoint.zero

    /// A native pan recognizer delays clicks only until it knows whether this is a drag.
    func enableContentDragging() {
        if let windowDrag, let view = windowDrag.view { view.removeGestureRecognizer(windowDrag) }
        let recognizer = NSPanGestureRecognizer(target: self, action: #selector(dragContent(_:)))
        recognizer.buttonMask = 1
        recognizer.delaysPrimaryMouseButtonEvents = true
        contentView?.addGestureRecognizer(recognizer)
        windowDrag = recognizer
    }

    @objc private func dragContent(_ recognizer: NSPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            onInteraction?()
            dragMouseOrigin = NSEvent.mouseLocation
            dragWindowOrigin = frame.origin
        case .changed:
            let point = NSEvent.mouseLocation
            setFrameOrigin(NSPoint(x: dragWindowOrigin.x + point.x - dragMouseOrigin.x,
                                   y: dragWindowOrigin.y + point.y - dragMouseOrigin.y))
        case .ended, .cancelled:
            persistFrame()
        default: break
        }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown { onInteraction?() }
        super.sendEvent(event)
    }

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

private final class FloatingHostingView: NSHostingView<FloatingView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Panel 生命周期 (App struct 是值语义, NSPanel 引用放这里)

/// 悬浮窗风格
enum PanelStyle: String, CaseIterable, Identifiable {
    case card      // 卡片式
    case glass     // 玻璃拟态
    case compact   // 紧凑单行 (横排多桶)
    case list      // 列表: 每行只显示一个用量桶
    var id: String { rawValue }
    var preferredWidth: CGFloat { self == .compact ? 300 : 340 }
    var label: String {
        switch self {
        case .card: return L10n.tr("卡片")
        case .glass: return L10n.tr("玻璃")
        case .compact: return L10n.tr("紧凑")
        case .list: return L10n.tr("列表")
        }
    }
}

@MainActor
final class PanelController: ObservableObject {
    @Published private(set) var isVisible = false
    @Published private(set) var titleVisible = false
    private var pointerInside = false
    private var titleHideDeadline: Date?
    private var titleHideTask: Task<Void, Never>?
    private var renderedTitleVisible = false

    func revealTitle() {
        pointerInside = true
        titleHideDeadline = nil
        titleHideTask?.cancel()
        titleVisible = true
    }

    func pointerPresenceChanged(_ inside: Bool, now: Date = Date()) {
        pointerInside = inside
        titleHideTask?.cancel()
        titleHideDeadline = nil
        guard !inside, titleVisible else { return }
        titleHideDeadline = now.addingTimeInterval(5)
        titleHideTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.hideTitleIfDue()
        }
    }

    func hideTitleIfDue(now: Date = Date()) {
        guard !pointerInside, let deadline = titleHideDeadline, now >= deadline else { return }
        titleVisible = false
        titleHideDeadline = nil
    }

    private func resetTitle() {
        titleHideTask?.cancel()
        titleHideDeadline = nil
        pointerInside = false
        titleVisible = false
    }

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
        titleHideTask?.cancel()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func setStyle(_ s: PanelStyle) {
        style = s
        expanded = false
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
        resetTitle()
        if panel == nil {
            let hosting = makeHosting()
            hosting.layoutSubtreeIfNeeded()
            let p = FloatingPanel(contentView: hosting, defaults: defaults)
            p.onHide = { [weak self] in
                self?.isVisible = false
                self?.resetTitle()
            }
            p.onInteraction = { [weak self] in self?.revealTitle() }
            p.enableContentDragging()
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
        resetTitle()
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
        panel.enableContentDragging()
        renderedTitleVisible = titleVisible
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

    private func resizeToContent(_ height: CGFloat, withTitle: Bool) {
        guard let panel, height.isFinite, height > 0 else { return }
        let titleChanged = renderedTitleVisible != withTitle
        renderedTitleVisible = withTitle
        let targetHeight = min(height, maximumPanelHeight)
        guard abs(panel.frame.height - targetHeight) > 0.5 else { return }
        var frame = panel.frame
        let top = frame.maxY
        frame.size = NSSize(width: style.preferredWidth, height: targetHeight)
        // Grow the title above the content so the click target stays under the pointer.
        if !titleChanged { frame.origin.y = top - targetHeight }
        panel.setFrame(frame, display: panel.isVisible)
        if panel.isVisible { panel.recoverPosition() }
    }

    private func makeHosting() -> NSHostingView<FloatingView> {
        layoutRevision += 1
        let revision = layoutRevision
        return FloatingHostingView(rootView: FloatingView(
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
                let withTitle = self?.titleVisible ?? false
                Task { @MainActor [weak self] in
                    guard let self, self.layoutRevision == revision else { return }
                    self.resizeToContent(height, withTitle: withTitle)
                }
            }
        ))
    }
}
