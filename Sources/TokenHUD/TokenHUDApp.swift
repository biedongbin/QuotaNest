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
            NSHostingController(rootView: ProviderManagerView(
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
        // QA: 启动即开供应商管理窗 (截图/验收用)
        if ProcessInfo.processInfo.environment["TOKENHUD_AUTO_SETTINGS"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                SettingsWindowManager.shared.show()
            }
        }
        // QA: 探测本机三源可导入项并退出 (不落盘)
        if ProcessInfo.processInfo.environment["TOKENHUD_IMPORT_SCAN"] == "1" {
            let home = NSHomeDirectory()
            let srcs: [(String, [ImportCandidate])] = [
                ("9router", ProviderImporter.from9Router(home: home)),
                ("cc-switch", ProviderImporter.fromCCSwitch(home: home)),
                ("cpamp", ProviderImporter.fromCPAMP(home: home)),
            ]
            for (name, list) in srcs {
                print("## \(name) \(list.count)")
                for c in list {
                    let masked = c.apiKey.isEmpty ? "-" : "***" + String(c.apiKey.suffix(4))
                    print("  \(c.name) | tmpl=\(c.template ?? "-") | \(c.proto) | \(masked) | \(c.baseURL)")
                }
            }
            exit(0)
        }
        // QA: 离屏渲染三版布局到 PNG (无需屏幕录制权限), 用于自检视觉
        if let out = ProcessInfo.processInfo.environment["TOKENHUD_RENDER"] {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                Self.renderSnapshots(engine: e, hudDir: hud, userDir: user,
                                     bundleDir: bundle, to: out)
                NSApplication.shared.terminate(nil)
            }
        }
    }

    var body: some Scene {
        // LSUIElement: 菜单栏图标由 StatusItemController 自绘, 此处仅占位满足 Scene 要求
        Settings { EmptyView() }
    }

    /// 离屏渲染三版布局 (不需要屏幕录制权限)
    @MainActor
    static func renderSnapshots(engine: DataEngine, hudDir: URL, userDir: URL,
                                bundleDir: URL?, to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let settingsURL = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/settings.json")
        var hosts: [NSWindow] = []
        for l in ManagerLayout.allCases {
            let view = ProviderManagerView(engine: engine, hudDir: hudDir, userDir: userDir,
                                           settingsURL: settingsURL, bundleDir: bundleDir,
                                           layoutOverride: l)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 880, height: 580)
            // 真窗口: List/Picker/Toggle 等 AppKit 控件只在 window 上下文布局
            let win = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable],
                               backing: .buffered, defer: false)
            win.contentView = host
            win.appearance = NSAppearance(named: .aqua) // 白底主题验收
            win.orderFrontRegardless()
            hosts.append(win)                            // 存活到截图完成 (否则视图被释放)
            for _ in 0..<8 {
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            }
            // 走 layer.render: 比 cacheDisplay 正确合成 SwiftUI 的透明填充与文字
            host.wantsLayer = true
            host.displayIfNeeded()
            let size = host.bounds.size
            guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { continue }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: size))
            // layer.render 用左上原点, CGContext 左下 → 预翻转让输出正立
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            host.layer?.render(in: ctx)
            guard let cg = ctx.makeImage(),
                  let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            else { continue }
            guard let cg = ctx.makeImage(),
                  let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            else { continue }
            try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(l.rawValue).png"))
        }
    }
}
