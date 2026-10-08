import SwiftUI

@main
struct TokenHUDApp: App {
    @StateObject private var engine: DataEngine
    @StateObject private var panelCtrl: PanelController

    init() {
        let home = NSHomeDirectory()
        let hud = URL(fileURLWithPath: home + "/.claude/hud")
        let user = URL(fileURLWithPath: home + "/Library/Application Support/TokenHUD/providers")
        let bundle = Bundle.module.resourceURL?.appendingPathComponent("providers")
        let node = NodeLocator.find(
            nvmHome: home + "/.nvm",
            extraPaths: ["/opt/homebrew/bin/node", "/usr/local/bin/node"],
            saved: UserDefaults.standard.string(forKey: DataEngine.defaultsNodeKey))
        let e = DataEngine(hudDir: hud,
                           bundleProvidersDir: bundle,
                           userProvidersDir: user,
                           runner: ProviderRunner(nodePath: node))
        e.start()
        _engine = StateObject(wrappedValue: e)
        let pc = PanelController(engine: e)
        _panelCtrl = StateObject(wrappedValue: pc)

        // 自绘状态栏 (NSStatusItem): 左键面板 + 右键菜单; 替代 MenuBarExtra (右键被系统拦截)
        _ = StatusItemController(engine: e, panelCtrl: pc)
        // 供应商管理窗口工厂 (单例 NSWindow, 全局唯一)
        SettingsWindowManager.shared.makeContent = {
            NSHostingController(rootView: SettingsView(
                engine: e, hudDir: hud, userDir: user,
                settingsURL: URL(fileURLWithPath: home + "/.claude/settings.json"),
                bundleDir: bundle))
        }

        if ProcessInfo.processInfo.environment["TOKENHUD_AUTO_TOGGLE"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                pc.toggle()
            }
        }
    }

    var body: some Scene {
        // LSUIElement: 菜单栏图标由 StatusItemController 自绘, 此处仅占位满足 Scene 要求
        Settings { EmptyView() }
    }
}
