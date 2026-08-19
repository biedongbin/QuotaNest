import SwiftUI

@main
struct TokenHUDApp: App {
    @StateObject private var engine: DataEngine
    @StateObject private var panelCtrl: PanelController

    init() {
        let home = NSHomeDirectory()
        let hud = URL(fileURLWithPath: home + "/.claude/hud")
        let user = URL(fileURLWithPath: home + "/Library/Application Support/TokenHUD/providers")
        let node = NodeLocator.find(
            nvmHome: home + "/.nvm",
            extraPaths: ["/opt/homebrew/bin/node", "/usr/local/bin/node"],
            saved: UserDefaults.standard.string(forKey: DataEngine.defaultsNodeKey))
        let e = DataEngine(hudDir: hud,
                           bundleProvidersDir: Bundle.module.resourceURL?.appendingPathComponent("providers"),
                           userProvidersDir: user,
                           runner: ProviderRunner(nodePath: node))
        e.start()
        _engine = StateObject(wrappedValue: e)
        _panelCtrl = StateObject(wrappedValue: PanelController(engine: e))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(engine: engine,
                        onOpenSettings: {},
                        onTogglePanel: { panelCtrl.toggle() },
                        onRefresh: { Task { await engine.refreshNow() } })
        } label: {
            let worst = engine.states.compactMap(\.worstPct).max()
            Text(worst.map { "\(Int($0.rounded()))%" } ?? "…")
        }
        .menuBarExtraStyle(.window)
    }
}
