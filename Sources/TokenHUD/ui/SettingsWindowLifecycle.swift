import AppKit

/// 主窗口存在时参与系统应用切换；关闭后继续作为菜单栏工具运行。
enum SettingsWindowLifecycle {
    enum Event { case show, minimize, closeAccepted, closeCancelled }
    static func activationPolicy(after event: Event) -> NSApplication.ActivationPolicy {
        switch event {
        case .show, .minimize, .closeCancelled: return .regular
        case .closeAccepted: return .accessory
        }
    }
}

final class SettingsMainWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
