import AppKit
import SwiftUI

/// Critical account actions use a standard AppKit button with explicit native
/// accessibility metadata, including when SwiftUI's virtual AX subtree is absent.
struct AccountActionButton: NSViewRepresentable {
    let title: String
    let identifier: String
    var enabled = true
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.invoke))
        button.bezelStyle = .rounded
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        button.setContentHuggingPriority(.required, for: .horizontal)
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.title = title
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(title)
        button.isEnabled = enabled
        context.coordinator.action = action
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func invoke() { action() }
    }
}
