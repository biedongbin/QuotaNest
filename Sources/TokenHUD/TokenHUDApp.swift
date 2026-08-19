import SwiftUI

@main
struct TokenHUDApp: App {
    @StateObject private var engine: DataEngine
    @StateObject private var panelCtrl: PanelController

    private let hudDir: URL
    private let userDir: URL
    private let settingsURL: URL
    private let bundleDir: URL?

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
        _panelCtrl = StateObject(wrappedValue: PanelController(engine: e))
        hudDir = hud
        userDir = user
        bundleDir = bundle
        settingsURL = URL(fileURLWithPath: home + "/.claude/settings.json")
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarRoot(engine: engine, panelCtrl: panelCtrl,
                        onRefresh: { Task { await engine.refreshNow() } })
        } label: {
            let worst = engine.states.compactMap(\.worstPct).max()
            Text(worst.map { "\(Int($0.rounded()))%" } ?? "…")
        }
        .menuBarExtraStyle(.window)

        // macOS 14 SDK 的 openWindow 必须带 id (无参调用不可用), 故显式给 id
        WindowGroup("TokenHUD 供应商管理", id: "settings") {
            SettingsView(engine: engine, hudDir: hudDir, userDir: userDir,
                         settingsURL: settingsURL, bundleDir: bundleDir)
        }
        .windowResizability(.contentSize)
    }
}

/// MenuBarExtra 内容与 App 之间的桥: openWindow 只能从 View 的 environment 取,
/// onAppear 时把 action 绑给 PanelController, 之后菜单回调直接用
private struct MenuBarRoot: View {
    @ObservedObject var engine: DataEngine
    @ObservedObject var panelCtrl: PanelController
    let onRefresh: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarView(engine: engine,
                    onOpenSettings: { panelCtrl.openSettings() },
                    onTogglePanel: { panelCtrl.toggle() },
                    onRefresh: onRefresh)
            .onAppear { panelCtrl.bindOpenWindow(openWindow) }
    }
}
