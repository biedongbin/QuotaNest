import AppKit
import ServiceManagement
import Combine

/// The macOS registration is authoritative; no separate enabled preference is stored.
@MainActor protocol LoginItemManaging {
    var status: SMAppService.Status { get }
    var isAvailable: Bool { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor struct SystemLoginItemManager: LoginItemManaging {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier == "local.quotanest"
    }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor final class LoginItemSettings: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorMessage: String?
    let isAvailable: Bool
    private let manager: any LoginItemManaging

    init(manager: any LoginItemManaging) {
        self.manager = manager
        status = manager.status
        isAvailable = manager.isAvailable
    }

    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var statusDescription: String {
        guard isAvailable else { return L10n.tr("请从安装的 QuotaNest.app 修改登录项。") }
        switch status {
        case .enabled: return L10n.tr("已启用开机启动")
        case .requiresApproval: return L10n.tr("等待系统批准，请在登录项设置中允许。")
        case .notRegistered: return L10n.tr("未启用开机启动")
        case .notFound: return L10n.tr("系统暂未找到登录项，请尝试重新启用。")
        @unknown default: return L10n.tr("无法读取登录项状态。")
        }
    }

    func refresh() { status = manager.status }

    func setEnabled(_ enabled: Bool) {
        guard isAvailable else { return }
        errorMessage = nil
        do {
            if enabled { try manager.register() }
            else { try manager.unregister() }
        } catch {
            errorMessage = L10n.tr("无法更新开机启动设置：%@", error.localizedDescription)
        }
        refresh()
    }

    func openSystemSettings() { manager.openSystemSettings() }
}
