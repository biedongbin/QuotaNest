import SwiftUI

@main
struct TokenHUDApp: App {
    @StateObject private var engine: DataEngine

    init() {
        let environment = ProcessInfo.processInfo.environment
        let mode = AppLaunchMode(environment: environment)
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let paths = AppConfigPaths(environment: environment, userHome: home,
                                   workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath,
                                                         isDirectory: true))
        let bundle = Bundle.module.resourceURL?.appendingPathComponent("providers")

        // 必须在构造生产引擎／状态栏前分流；旧入口先 start() 会让截图发出真实请求。
        switch mode {
        case .render(let output):
            do {
                guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw NSError(domain: "TokenHUD.Render", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "TOKENHUD_RENDER 需要输出目录"])
                }
                let fixture = try DiagnosticFixture()
                _engine = StateObject(wrappedValue: fixture.engine)
                Task { @MainActor in
                    Self.renderSnapshots(fixture: fixture, to: output)
                    fixture.cleanup()
                    NSApplication.shared.terminate(nil)
                }
            } catch {
                print("render failed: \(error.localizedDescription)")
                exit(1)
            }
            return
        case .debugSettings:
            do {
                let fixture = try DiagnosticFixture()
                _engine = StateObject(wrappedValue: fixture.engine)
                // 只检查注入的临时偏好；不构造带有旧调试 exit 的 SettingsModel。
                let selected = SettingsPersist.resumeSlug(
                    saved: fixture.defaults.string(forKey: SettingsPersist.selectedKey),
                    available: fixture.engine.allPlugins.map(\.slug))
                let tab = SettingsPersist.resumeTab(
                    saved: fixture.defaults.string(forKey: SettingsPersist.tabKey))
                print("SETTINGS RESUME selected=\(selected ?? "nil") tab=\(tab.rawValue) (isolated fixture)")
                fixture.cleanup()
                exit(0)
            } catch {
                print("settings diagnostic failed: \(error.localizedDescription)")
                exit(1)
            }
        case .importScan:
            // 显式的只读扫描保留，但不创建生产 engine、状态栏或启动任何调度。
            Self.printImportCounts(home: home.path)
            exit(0)
        case .repairHud:
            // 旧快捷入口未加载用户启停偏好，不能用它直接重写真实 HUD。
            print("TOKENHUD_ENVS_FIX 已停用；请在 App 中使用「同步 HUD」，保留现有账号启停与显示选择。")
            exit(1)
        case .normal:
            break
        }

        let userDir = home.appendingPathComponent("Library/Application Support/TokenHUD/providers", isDirectory: true)
        let node = NodeLocator.find(
            nvmHome: home.appendingPathComponent(".nvm").path,
            extraPaths: ["/opt/homebrew/bin/node", "/usr/local/bin/node"],
            saved: UserDefaults.standard.string(forKey: DataEngine.defaultsNodeKey))
        let e = DataEngine(hudDir: paths.hudDir, bundleProvidersDir: bundle,
                           userProvidersDir: userDir,
                           runner: ProviderRunner(nodePath: node, logDir: paths.hudDir),
                           settingsURL: paths.settingsURL)
        e.start()
        _engine = StateObject(wrappedValue: e)
        let panel = PanelController(engine: e)
        _ = StatusItemController(engine: e, panelCtrl: panel)
        SettingsWindowManager.shared.makeModel = {
            SettingsModel(engine: e, hudDir: paths.hudDir, userDir: userDir,
                          settingsURL: paths.settingsURL, bundleDir: bundle)
        }

        if environment["TOKENHUD_AUTO_TOGGLE"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                panel.toggle()
            }
        }
        if environment["TOKENHUD_AUTO_SETTINGS"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                SettingsWindowManager.shared.show()
            }
        }
    }

    var body: some Scene {
        Settings { EmptyView() }
    }

    @MainActor
    private static func printImportCounts(home: String) {
        let sources: [(String, [ImportCandidate])] = [
            ("9router", ProviderImporter.from9Router(home: home)),
            ("cc-switch", ProviderImporter.fromCCSwitch(home: home)),
            ("cpamp", ProviderImporter.fromCPAMP(home: home)),
        ]
        // 诊断只输出计数与分类，不把源账号、凭证后缀或接口地址写入终端。
        for (name, candidates) in sources {
            let supported = candidates.filter { $0.unsupportedReason == nil }.count
            print("\(name): total=\(candidates.count), importable=\(supported)")
        }
    }

    /// 仅渲染临时演示账号；不调用 start、真实来源扫描或真实 HUD 安装。
    @MainActor
    private static func renderSnapshots(fixture: DiagnosticFixture, to directory: String) {
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        } catch {
            print("render output failed: \(error.localizedDescription)")
            return
        }
        let imported = ImportCenterModel(engine: fixture.engine, hudDir: fixture.paths.hudDir,
                                         userDir: fixture.userDir)
        let candidate = ImportCandidate(source: "演示来源", name: "演示待导入账号", template: "demo-a",
                                        apiKey: "demo-key-not-a-real-credential", baseURL: "", proto: "openai",
                                        note: "演示数据，不读取本机配置", sourceRecordId: "fixture-import-1")
        imported.rows = [.init(candidate: candidate, state: .addable,
                               note: "演示数据，不读取本机配置")]
        imported.scanState = .scanned // 阻止 ImportCenterSheet.onAppear 自动扫描真实目录。
        imported.picked = Set(imported.rows.map(\.id))

        let selected = ProcessInfo.processInfo.environment["TOKENHUD_RENDER_SLUG"]
        let slug = fixture.engine.allPlugins.contains(where: { $0.slug == selected }) ? selected : "demo-a"
        let shots: [(String, RenderScript)] = [
            ("01-quota", .init(mode: .quota, slug: slug, templateID: nil)),
            ("02-config", .init(mode: .config, slug: slug, templateID: nil)),
            ("03-trigger", .init(mode: .trigger, slug: slug, templateID: nil)),
            ("04-templates", .init(mode: .templates, slug: nil, templateID: nil)),
            // .full 不调用 applyRenderScript(.importer) 中的真实 scanSynchronously。
            ("05-import", .init(mode: .full, slug: nil, templateID: nil, importModel: imported)),
            ("06-edit", .init(mode: .edit, slug: slug, templateID: nil)),
            ("06b-edit-trigger", .init(mode: .editTrigger, slug: slug, templateID: nil)),
            ("07-create", .init(mode: .create, slug: nil, templateID: "demo-a")),
            ("08-overview", .init(mode: .overview, slug: nil, templateID: nil)),
            ("10-plan", .init(mode: .plan, slug: nil, templateID: nil)),
            ("11-settings", .init(mode: .globalSettings, slug: nil, templateID: nil)),
        ]
        for (name, script) in shots {
            let model = SettingsModel(engine: fixture.engine, hudDir: fixture.paths.hudDir,
                                      userDir: fixture.userDir, settingsURL: fixture.paths.settingsURL,
                                      bundleDir: fixture.templatesDir, defaults: fixture.defaults)
            if script.mode == .overview { model.selected = nil; model.navPage = .overview }
            let view = SettingsCenterView(model: model, engine: fixture.engine, renderScript: script)
            capture(view, to: output.appendingPathComponent("\(name).png"))
        }

        let emptyDir = fixture.root.appendingPathComponent("empty-providers", isDirectory: true)
        try? FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        let emptyEngine = DataEngine(hudDir: fixture.paths.hudDir, bundleProvidersDir: nil,
                                     userProvidersDir: emptyDir,
                                     runner: ProviderRunner(nodePath: nil, logDir: fixture.paths.hudDir),
                                     defaults: fixture.defaults, settingsURL: fixture.paths.settingsURL)
        emptyEngine.reloadRegistry()
        for (name, mode) in [("12-empty-overview", RenderScript.Mode.overview),
                              ("13-empty-plan", .plan), ("14-empty-settings", .globalSettings)] {
            let model = SettingsModel(engine: emptyEngine, hudDir: fixture.paths.hudDir,
                                      userDir: emptyDir, settingsURL: fixture.paths.settingsURL,
                                      bundleDir: nil, defaults: fixture.defaults)
            capture(SettingsCenterView(model: model, engine: emptyEngine,
                                        renderScript: .init(mode: mode, slug: nil, templateID: nil)),
                    to: output.appendingPathComponent("\(name).png"))
        }
        print("rendered isolated demonstration snapshots to \(output.path)")
    }

    @MainActor
    private static func capture<Content: View>(_ content: Content, to destination: URL) {
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        window.orderFrontRegardless()
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        host.wantsLayer = true
        host.displayIfNeeded()
        let size = host.bounds.size
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        host.layer?.render(in: context)
        if let image = context.makeImage(),
           let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? data.write(to: destination)
        }
        window.orderOut(nil)
    }
}

/// 诊断用数据全部位于系统临时目录；不扫描或复制用户账号、凭证和偏好。
@MainActor
private final class DiagnosticFixture {
    let root: URL
    let paths: AppConfigPaths
    let userDir: URL
    let templatesDir: URL
    let defaults: UserDefaults
    let engine: DataEngine
    private let defaultsName: String

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenhud-diagnostic-\(UUID().uuidString)", isDirectory: true)
        paths = AppConfigPaths(environment: ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude").path],
                               userHome: root, workingDirectory: root)
        userDir = root.appendingPathComponent("providers", isDirectory: true)
        templatesDir = root.appendingPathComponent("templates", isDirectory: true)
        defaultsName = "tokenhud.diagnostic.\(UUID().uuidString)"
        guard let isolated = UserDefaults(suiteName: defaultsName) else {
            throw NSError(domain: "TokenHUD.Diagnostic", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法建立独立诊断偏好"])
        }
        defaults = isolated
        for directory in [paths.hudDir, userDir, templatesDir] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("{\"env\":{},\"statusLine\":{}}".utf8).write(to: paths.settingsURL, options: .atomic)
        let now = Date().timeIntervalSince1970 * 1000
        for (slug, label, local, values) in [("demo-a", "演示供应商 A", false, [28.0, 46.0, 72.0]),
                                             ("demo-b", "演示供应商 B", true, [64.0, 35.0])] {
            let pluginDir = userDir.appendingPathComponent(slug, isDirectory: true)
            let templateDir = templatesDir.appendingPathComponent(slug, isDirectory: true)
            try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: templateDir, withIntermediateDirectories: true)
            let authURL = paths.hudDir.appendingPathComponent(".\(slug)-usage-auth.json")
            let cacheURL = paths.hudDir.appendingPathComponent(".\(slug)-usage-cache.json")
            let manifest = ProviderManifest(name: "Demo-\(slug)", label: label,
                                             displayName: local ? "演示本机账号" : "演示 API 账号",
                                             intervalSec: 300,
                                             buckets: ["five_hour": "5小时", "seven_day": "本周", "monthly": "本月"],
                                             cacheFile: cacheURL.path, authFile: authURL.path,
                                             needsCredential: !local, testModel: local ? nil : "demo-model",
                                             queryUrl: "https://example.invalid/usage",
                                             queryAuth: local ? "header" : "bearer",
                                             queryKeyField: local ? nil : "apiKey",
                                             refreshUrl: local ? nil : "https://example.invalid/v1/chat/completions",
                                             refreshProtocol: local ? nil : "openai",
                                             refreshAuth: local ? nil : "bearer", template: slug,
                                             accent: local ? "purple" : "blue", authMode: local ? "local" : "apikey")
            let encoded = try JSONEncoder().encode(manifest)
            try encoded.write(to: pluginDir.appendingPathComponent("manifest.json"))
            var template = manifest
            template.displayName = label
            try JSONEncoder().encode(template).write(to: templateDir.appendingPathComponent("manifest.json"))
            // 即便误调用测试 fixture，也只返回空数据并失败，不请求网络。
            let script = Data("#!/bin/zsh\nexit 1\n".utf8)
            try script.write(to: pluginDir.appendingPathComponent("fetch.sh"))
            try script.write(to: templateDir.appendingPathComponent("fetch.sh"))
            let auth: [String: Any] = ["apiKey": "demo-key-not-a-real-credential",
                                        "testModel": "demo-model", "scheduleTimes": local ? [] : ["09:00", "18:00"]]
            let authData = try JSONSerialization.data(withJSONObject: auth)
            try authData.write(to: authURL, options: .atomic)
            try authData.write(to: templateDir.appendingPathComponent("auth-template.json"), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
            let labels = ["5小时", "本周", "本月"]
            let windows = values.enumerated().map { i, value in
                WindowBucket(label: labels[i], usedPercentage: value,
                             resetsAt: Int(Date().timeIntervalSince1970) + (i + 1) * 3600)
            }
            let cache = UsageCache(generatedAt: now,
                                   fiveHour: Bucket(usedPercentage: values[0], resetsAt: windows[0].resetsAt),
                                   sevenDay: Bucket(usedPercentage: values[1], resetsAt: windows[1].resetsAt),
                                   monthly: values.count == 3 ? Bucket(usedPercentage: values[2], resetsAt: windows[2].resetsAt) : nil,
                                   error: nil, stale: false, lastAttemptAt: now, windows: windows)
            try JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
        }
        engine = DataEngine(hudDir: paths.hudDir, bundleProvidersDir: templatesDir,
                             userProvidersDir: userDir,
                             runner: ProviderRunner(nodePath: nil, logDir: paths.hudDir),
                             defaults: defaults, settingsURL: paths.settingsURL)
        engine.reloadRegistry()
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }
}
