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
                    await Self.renderSnapshots(fixture: fixture, to: output)
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
    private static func renderSnapshots(fixture: DiagnosticFixture, to directory: String) async {
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        } catch {
            print("render output failed: \(error.localizedDescription)")
            return
        }
        if ProcessInfo.processInfo.environment["TOKENHUD_RENDER_CASE"] == "entries" {
            await diagnoseEntryConsistency(fixture: fixture, output: output)
            return
        }
        var observations: [[String: Any]] = []
        func model(engine: DataEngine? = nil, userDir: URL? = nil) -> SettingsModel {
            SettingsModel(engine: engine ?? fixture.engine, hudDir: fixture.paths.hudDir,
                          userDir: userDir ?? fixture.userDir, settingsURL: fixture.paths.settingsURL,
                          bundleDir: fixture.templatesDir, defaults: fixture.defaults,
                          confirmTestCall: { _ in true }, executeTestCall: { _ in "✓ 演示调用返回 OK" })
        }
        func snapshot(_ name: String, width: CGFloat, dark: Bool, model: SettingsModel,
                      engine: DataEngine? = nil, scrollDown: Bool = false) {
            let view = SettingsCenterView(model: model, engine: engine ?? fixture.engine)
            var observation = capture(view, to: output.appendingPathComponent("\(name).png"),
                                      size: NSSize(width: width, height: 780), dark: dark, scrollDown: scrollDown)
            observation["scene"] = name
            observations.append(observation)
        }
        for width: CGFloat in [640, 900, 1200] {
            for dark in [false, true] {
                let m = model()
                m.selected = nil
                m.navPage = .overview
                snapshot("overview-\(Int(width))-\(dark ? "dark" : "light")", width: width, dark: dark,
                         model: m, scrollDown: dark)
            }
        }
        for width: CGFloat in [640, 1200] {
            let config = model()
            _ = config.selectAccount("demo-a", tab: .config)
            config.startEdit()
            snapshot("config-\(Int(width))-light", width: width, dark: false, model: config)
            if let values = config.draft?.values {
                config.testCallDraft(values: values)
                let deadline = Date().addingTimeInterval(2)
                while config.isTestingCurrentConfig && Date() < deadline {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                snapshot("config-result-\(Int(width))-dark", width: width, dark: true, model: config, scrollDown: true)
            }
            let plan = model()
            _ = plan.selectAccount("demo-a", tab: .trigger)
            snapshot("schedule-\(Int(width))-light", width: width, dark: false, model: plan)
        }
        for (name, slug, width, dark) in [
            ("weekly-detail-1200-light", "demo-week", CGFloat(1200), false),
            ("error-detail-640-light", "demo-error", CGFloat(640), false),
            ("unqueried-detail-640-dark", "demo-unqueried", CGFloat(640), true)
        ] {
            let m = model()
            _ = m.selectAccount(slug, tab: .quota)
            snapshot(name, width: width, dark: dark, model: m)
        }
        let noResults = model()
        noResults.navPage = .overview
        noResults.search = "未匹配的演示账号"
        snapshot("search-empty-640-light", width: 640, dark: false, model: noResults)

        let emptyDir = fixture.root.appendingPathComponent("empty-providers", isDirectory: true)
        try? FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        let emptyEngine = DataEngine(hudDir: fixture.paths.hudDir, bundleProvidersDir: nil,
                                     userProvidersDir: emptyDir,
                                     runner: ProviderRunner(nodePath: nil, logDir: fixture.paths.hudDir),
                                     defaults: fixture.defaults, settingsURL: fixture.paths.settingsURL)
        emptyEngine.reloadRegistry()
        let empty = model(engine: emptyEngine, userDir: emptyDir)
        empty.selected = nil
        empty.navPage = .overview
        snapshot("overview-empty-1200-dark", width: 1200, dark: true, model: empty, engine: emptyEngine)
        if let data = try? JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("render-observations.json"))
        }
        await diagnoseNativeActions(fixture: fixture, output: output)
        print("rendered isolated demonstration snapshots to \(output.path)")
    }

    @MainActor
    private static func diagnoseNativeActions(fixture: DiagnosticFixture, output: URL) async {
        var confirmations = 0, calls = 0
        let model = SettingsModel(engine: fixture.engine, hudDir: fixture.paths.hudDir, userDir: fixture.userDir,
                                  settingsURL: fixture.paths.settingsURL, bundleDir: fixture.templatesDir,
                                  defaults: fixture.defaults, confirmTestCall: { _ in confirmations += 1; return false },
                                  executeTestCall: { _ in calls += 1; return "✓ 演示" })
        model.selected = nil
        let host = NSHostingView(rootView: SettingsCenterView(model: model, engine: fixture.engine))
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: 780)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(nanoseconds: 100_000_000)
        var steps: [[String: Any]] = []
        let auth = fixture.paths.hudDir.appendingPathComponent(".demo-a-usage-auth.json")
        let original = try? Data(contentsOf: auth)
        for (name, point) in [("配置", NSPoint(x: 1055, y: 421)),
                              ("编辑配置", NSPoint(x: 1125, y: 30)),
                              ("发送测试调用", NSPoint(x: 1025, y: 754))] {
            host.layoutSubtreeIfNeeded()
            let local = NSPoint(x: point.x, y: host.isFlipped ? point.y : host.bounds.height - point.y)
            let location = host.convert(local, to: nil)
            let now = ProcessInfo.processInfo.systemUptime
            if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: now,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
               let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: now + 0.01,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0) {
                NSApp.postEvent(down, atStart: false)
                NSApp.postEvent(up, atStart: false)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            steps.append(["action": name, "page": String(describing: model.navPage), "tab": model.tab.rawValue,
                          "draft": model.draft != nil, "confirmations": confirmations, "calls": calls,
                          "hit_view": host.hitTest(local).map { String(describing: type(of: $0)) } ?? "none"])
        }
        let passed = model.navPage == .detail && model.tab == .config && model.draft != nil && confirmations == 1 && calls == 0
        let result: [String: Any] = ["completed": true, "pass": passed, "steps": steps,
                                    "window_key": window.isKeyWindow, "activation_regular": NSApp.activationPolicy() == .regular,
                                    "auth_unchanged": original == (try? Data(contentsOf: auth)), "scope": "In-process NSEvent actions on isolated fixture; no desktop input or real model request."]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("native-actions.json"))
        }
        window.orderOut(nil)
        window.contentView = nil
    }

    @MainActor
    private static func diagnoseEntryConsistency(fixture: DiagnosticFixture, output: URL) async {
        let defaults = fixture.defaults
        let engine = fixture.engine
        let selectedSlugs = ["demo-a", "demo-paused"]
        for plugin in engine.allPlugins where !selectedSlugs.contains(plugin.slug) {
            try? FileManager.default.removeItem(at: plugin.dir)
        }
        defaults.set(selectedSlugs, forKey: DataEngine.defaultsDisabledKey)
        defaults.set([String](), forKey: DataEngine.defaultsFloatingHiddenKey)
        defaults.set([String](), forKey: DataEngine.defaultsHudHiddenKey)
        for slug in selectedSlugs {
            let auth = fixture.paths.hudDir.appendingPathComponent(".\(slug)-usage-auth.json")
            let values: [String: Any] = ["apiKey": "ENTRY-FIXTURE-KEY", "testModel": "demo-model",
                                         "scheduleTimes": slug == "demo-a" ? [] : ["09:00", "18:00"]]
            try? JSONSerialization.data(withJSONObject: values).write(to: auth)
            let script = "#!/bin/zsh\nprintf 'query\\n' >> '\(fixture.root.appendingPathComponent("query-count").path)'\nprintf '%s' '{\"five_hour\":{\"used_percentage\":28,\"resets_at\":1999999999},\"seven_day\":{\"used_percentage\":19,\"resets_at\":1999999999},\"windows\":[{\"label\":\"5小时\",\"period\":\"5小时\",\"used_percentage\":28,\"resets_at\":1999999999},{\"label\":\"本周\",\"period\":\"7天\",\"used_percentage\":19,\"resets_at\":1999999999}]}'\n"
            try? Data(script.utf8).write(to: fixture.userDir.appendingPathComponent("\(slug)/fetch.sh"))
        }
        let isolatedEngine = DataEngine(hudDir: fixture.paths.hudDir, bundleProvidersDir: nil,
                                        userProvidersDir: fixture.userDir,
                                        runner: ProviderRunner(nodePath: nil, logDir: fixture.root.appendingPathComponent("logs")),
                                        defaults: defaults, settingsURL: fixture.paths.settingsURL)
        isolatedEngine.reloadRegistry()
        for slug in selectedSlugs { isolatedEngine.setTracking(slug, enabled: false) }
        var resumeConfirmations = 0
        let model = SettingsModel(engine: isolatedEngine, hudDir: fixture.paths.hudDir, userDir: fixture.userDir,
                                  settingsURL: fixture.paths.settingsURL, bundleDir: fixture.templatesDir,
                                  defaults: defaults, confirmDiscardChanges: { false },
                                  confirmResumePlan: { resumeConfirmations += 1; return false },
                                  confirmTestCall: { _ in false }, executeTestCall: { _ in "✓ fixture" })
        model.selected = nil
        let authBefore = selectedSlugs.map { try? Data(contentsOf: fixture.paths.hudDir.appendingPathComponent(".\($0)-usage-auth.json")) }
        let host = NSHostingView(rootView: SettingsCenterView(model: model, engine: isolatedEngine))
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: 780)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(nanoseconds: 100_000_000)
        var steps: [[String: Any]] = []
        let initialAccounts = isolatedEngine.allPlugins.map(\.slug).sorted()
        let initialDisabled = isolatedEngine.disabledSlugs.sorted()
        let preconditionPassed = initialAccounts == selectedSlugs.sorted() && initialDisabled == selectedSlugs.sorted()
        func state() -> [String: Any] {
            let queryData = (try? String(contentsOf: fixture.root.appendingPathComponent("query-count"))) ?? ""
            return ["page": String(describing: model.navPage), "selected": model.selected ?? "",
                    "tab": model.tab.rawValue, "disabled": isolatedEngine.disabledSlugs.sorted(),
                    "floating_hidden": isolatedEngine.floatingHiddenSlugs.sorted(),
                    "hud_hidden": isolatedEngine.hudHiddenSlugs.sorted(), "draft": model.draft != nil,
                    "queries": queryData.split(separator: "\n").count, "resume_confirmations": resumeConfirmations,
                    "scope": model.scope.rawValue]
        }
        func click(_ name: String, point: NSPoint, expected: String, check: () -> Bool) async {
            let before = state()
            let local = NSPoint(x: point.x, y: host.isFlipped ? point.y : host.bounds.height - point.y)
            let location = host.convert(local, to: nil)
            let now = ProcessInfo.processInfo.systemUptime
            if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: now,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
               let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: now + 0.01,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0) {
                NSApp.postEvent(down, atStart: false); NSApp.postEvent(up, atStart: false)
            }
            try? await Task.sleep(nanoseconds: 180_000_000)
            steps.append(["action": name, "expected": expected, "pass": check(), "before": before, "after": state()])
        }
        func shot(_ name: String, width: CGFloat) {
            _ = capture(SettingsCenterView(model: model, engine: isolatedEngine), to: output.appendingPathComponent(name + ".png"),
                        size: NSSize(width: width, height: 780), dark: false)
        }
        shot("overview-1200", width: 1200)
        shot("overview-640", width: 640)
        let execute = ProcessInfo.processInfo.environment["TOKENHUD_ENTRY_ACTIONS"] == "1"
        if execute {
            await click("已停用筛选", point: NSPoint(x: 856, y: 74), expected: "scope disabled且不导航") {
                model.scope == .disabled && model.navPage == .overview
            }
            await click("全部筛选", point: NSPoint(x: 536, y: 74), expected: "scope all且不导航") {
                model.scope == .all && model.navPage == .overview
            }
            await click("卡片主体", point: NSPoint(x: 680, y: 350), expected: "demo-a quota 详情") {
                model.selected == "demo-a" && model.navPage == .detail && model.tab == .quota
            }
        }
        if !execute { _ = model.selectAccount("demo-a", tab: .quota) }
        shot("quota-disabled-640", width: 640)
        shot("quota-disabled-1200", width: 1200)
        if execute {
            await click("详情启用", point: NSPoint(x: 242, y: 93), expected: "demo-a 启用，停用入口可见") {
                !isolatedEngine.disabledSlugs.contains("demo-a")
            }
            shot("quota-enabled-1200", width: 1200)
            await click("详情停用", point: NSPoint(x: 242, y: 93), expected: "demo-a 停用且偏好保留") {
                isolatedEngine.disabledSlugs.contains("demo-a") && isolatedEngine.floatingHiddenSlugs.isEmpty && isolatedEngine.hudHiddenSlugs.isEmpty
            }
        }
        if execute {
            await click("返回总览", point: NSPoint(x: 250, y: 30), expected: "overview 保持demo-a") {
                model.navPage == .overview && model.selected == "demo-a"
            }
            await click("卡片启用开关", point: NSPoint(x: 1145, y: 188), expected: "启用但不进入详情") {
                model.navPage == .overview && !isolatedEngine.disabledSlugs.contains("demo-a")
            }
            await click("卡片再停用开关", point: NSPoint(x: 1145, y: 188), expected: "停用但不进入详情") {
                model.navPage == .overview && isolatedEngine.disabledSlugs.contains("demo-a")
            }
            await click("悬浮显示复选框", point: NSPoint(x: 228, y: 439), expected: "只变显示偏好，不导航") {
                model.navPage == .overview && isolatedEngine.floatingHiddenSlugs.contains("demo-a")
            }
            await click("HUD显示复选框", point: NSPoint(x: 350, y: 370), expected: "只变HUD偏好，不导航") {
                model.navPage == .overview && isolatedEngine.hudHiddenSlugs.contains("demo-a")
            }
            await click("卡片查询", point: NSPoint(x: 1125, y: 407), expected: "只调用假查询，不导航") {
                let count = (try? String(contentsOf: fixture.root.appendingPathComponent("query-count"))) ?? ""
                return model.navPage == .overview && count.split(separator: "\n").count == 1 && isolatedEngine.states.first(where: { $0.slug == "demo-a" })?.cache?.sevenDay?.usedPercentage == 19
            }
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try? data.write(to: output.appendingPathComponent("post-query-host.png"))
                }
            }
            await click("卡片配置", point: NSPoint(x: 1055, y: 407), expected: "只进入demo-a配置tab") {
                model.selected == "demo-a" && model.navPage == .detail && model.tab == .config
            }
            await click("调用计划导航", point: NSPoint(x: 80, y: 99), expected: "plan页") { model.navPage == .plan }
            await click("计划账号行", point: NSPoint(x: 580, y: 230), expected: "计划行仍进入demo-paused自动任务") {
                model.selected == "demo-paused" && model.navPage == .detail && model.tab == .trigger
            }
            await click("有消费计划的账号启用", point: NSPoint(x: 242, y: 93), expected: "确认取消，账号保持停用且计划保留") {
                resumeConfirmations == 1 && isolatedEngine.disabledSlugs.contains("demo-paused")
            }
        }
        let unchanged = authBefore == selectedSlugs.map { try? Data(contentsOf: fixture.paths.hudDir.appendingPathComponent(".\($0)-usage-auth.json")) }
        let result: [String: Any] = ["completed": true, "actions_executed": execute,
                                    "precondition": ["accounts": initialAccounts, "initial_disabled": initialDisabled,
                                                     "pass": preconditionPassed, "engine_started": false],
                                    "pass": execute && preconditionPassed && !steps.isEmpty && steps.allSatisfy { $0["pass"] as? Bool == true } && unchanged,
                                    "steps": steps, "auth_and_plan_unchanged": unchanged, "final": state(),
                                    "window_key": window.isKeyWindow, "engine_started": false]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("entry-actions.json"))
        }
        window.orderOut(nil)
        window.contentView = nil
    }

    @MainActor
    private static func capture<Content: View>(_ content: Content, to destination: URL,
                                               size: NSSize, dark: Bool, scrollDown: Bool = false) -> [String: Any] {
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.orderFrontRegardless()
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        func descend(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descend) }
        if scrollDown, let scroll = descend(host).compactMap({ $0 as? NSScrollView }).first,
           let document = scroll.documentView {
            let y = document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
        }
        host.wantsLayer = true
        host.displayIfNeeded()
        let rendered = host.bounds.size
        var observation: [String: Any] = ["requested_width": size.width, "requested_height": size.height,
                                           "rendered_width": rendered.width, "rendered_height": rendered.height,
                                           "appearance": dark ? "dark" : "light", "scrolled_to_end": scrollDown,
                                           "center_has_hit_view": host.hitTest(NSPoint(x: rendered.width / 2,
                                                                                        y: rendered.height / 2)) != nil,
                                           "evidence_scope": "Actual SwiftUI render; screenshot state does not prove button activation."]
        if let context = CGContext(data: nil, width: Int(rendered.width), height: Int(rendered.height),
                                   bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.setFillColor(CGColor(gray: dark ? 0.1 : 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: rendered))
            context.translateBy(x: 0, y: rendered.height)
            context.scaleBy(x: 1, y: -1)
            host.layer?.render(in: context)
            if let image = context.makeImage(),
               let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                do { try data.write(to: destination); observation["image_written"] = true }
                catch { observation["image_written"] = false }
            }
        }
        window.orderOut(nil)
        window.contentView = nil
        return observation
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
        let fixtures: [(slug: String, provider: String, title: String, local: Bool, values: [Double], error: String?, disabled: Bool)] = [
            ("demo-a", "示例云", "日常开发账号", false, [28, 46], nil, false),
            ("demo-long", "示例云", "用于跨团队研发与文档校对的长名称工作账号，保留用户自己的完整命名", false, [8, 61], nil, false),
            ("demo-error", "示例云", "连接异常账号", false, [], "network", false),
            ("demo-paused", "示例云", "已暂停的备用账号", false, [5, 12], nil, true),
            ("demo-week", "示例登录", "订阅账号", true, [19], nil, false),
            ("demo-unqueried", "示例登录", "尚未查询的账号", true, [], nil, false)
        ]
        defaults.set(fixtures.filter(\.disabled).map(\.slug), forKey: DataEngine.defaultsDisabledKey)
        defaults.set(fixtures.map(\.slug), forKey: DataEngine.defaultsOrderKey)
        for item in fixtures {
            let slug = item.slug
            let pluginDir = userDir.appendingPathComponent(slug, isDirectory: true)
            let templateDir = templatesDir.appendingPathComponent(slug, isDirectory: true)
            try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: templateDir, withIntermediateDirectories: true)
            let authURL = paths.hudDir.appendingPathComponent(".\(slug)-usage-auth.json")
            let cacheURL = paths.hudDir.appendingPathComponent(".\(slug)-usage-cache.json")
            let manifest = ProviderManifest(name: "Demo-\(slug)", label: item.provider,
                                             displayName: item.title, intervalSec: 300,
                                             buckets: ["five_hour": "5小时", "seven_day": "本周"],
                                             cacheFile: cacheURL.path, authFile: authURL.path,
                                             needsCredential: !item.local, testModel: item.local ? nil : "demo-model",
                                             queryUrl: "https://example.invalid/usage",
                                             queryAuth: item.local ? "header" : "bearer",
                                             queryKeyField: item.local ? nil : "apiKey",
                                             refreshUrl: item.local ? nil : "https://example.invalid/v1/chat/completions",
                                             refreshProtocol: item.local ? nil : "openai",
                                             refreshAuth: item.local ? nil : "bearer", template: slug,
                                             accent: item.local ? "purple" : "blue", authMode: item.local ? "local" : "apikey")
            try JSONEncoder().encode(manifest).write(to: pluginDir.appendingPathComponent("manifest.json"))
            var template = manifest
            template.displayName = item.provider
            try JSONEncoder().encode(template).write(to: templateDir.appendingPathComponent("manifest.json"))
            let script = Data("#!/bin/zsh\nexit 1\n".utf8)
            try script.write(to: pluginDir.appendingPathComponent("fetch.sh"))
            try script.write(to: templateDir.appendingPathComponent("fetch.sh"))
            let auth: [String: Any] = ["apiKey": "DEMO-LOCAL-FIXTURE",
                                       "testModel": "demo-model", "scheduleTimes": item.local ? [] : ["09:00", "18:00"]]
            let authData = try JSONSerialization.data(withJSONObject: auth)
            try authData.write(to: authURL, options: .atomic)
            try authData.write(to: templateDir.appendingPathComponent("auth-template.json"), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
            guard !item.values.isEmpty || item.error != nil else { continue }
            let weekOnly = item.values.count == 1
            let windows = item.values.enumerated().map { i, value in
                WindowBucket(label: weekOnly || i == 1 ? "本周" : "5小时", usedPercentage: value,
                             period: weekOnly || i == 1 ? "7天" : "5小时",
                             resetsAt: Int(Date().timeIntervalSince1970) + (weekOnly || i == 1 ? 400_000 : 12_000))
            }
            let cache = UsageCache(generatedAt: item.values.isEmpty ? nil : now,
                                   fiveHour: !weekOnly && !item.values.isEmpty
                                       ? Bucket(usedPercentage: item.values[0], resetsAt: windows[0].resetsAt) : nil,
                                   sevenDay: windows.last.map { Bucket(usedPercentage: $0.usedPercentage, resetsAt: $0.resetsAt) },
                                   error: item.error, stale: item.error != nil, lastAttemptAt: now, windows: windows,
                                   accountId: "fixture-\(slug)")
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
