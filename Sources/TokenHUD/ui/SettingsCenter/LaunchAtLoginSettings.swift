import SwiftUI
import AppKit
import ServiceManagement

@MainActor struct LaunchAtLoginSettings: View {
    @StateObject private var settings = LoginItemSettings(manager: SystemLoginItemManager())

    var body: some View {
        GroupBox(L10n.tr("启动")) {
            VStack(alignment: .leading, spacing: 9) {
                Toggle(L10n.tr("登录时自动启动 QuotaNest"), isOn: Binding(
                    get: { settings.isOn },
                    set: { settings.setEnabled($0) }))
                    .toggleStyle(.checkbox)
                    .disabled(!settings.isAvailable)
                    .accessibilityIdentifier("settings.launch-at-login")
                Text(L10n.tr("登录 macOS 后自动启动菜单栏应用。"))
                    .font(Typo.small).foregroundStyle(Palette.muted)
                HStack(spacing: 10) {
                    Text(settings.statusDescription)
                        .font(Typo.small)
                        .foregroundStyle(settings.status == .requiresApproval ? Palette.warn : Palette.inkSecondary)
                    if settings.isAvailable {
                        Button(L10n.tr("打开系统登录项设置")) { settings.openSystemSettings() }
                            .barButton()
                    }
                }
                if let error = settings.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(Typo.small).foregroundStyle(Palette.danger).textSelection(.enabled)
                        .accessibilityIdentifier("settings.launch-at-login.error")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { settings.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refresh()
        }
    }
}
