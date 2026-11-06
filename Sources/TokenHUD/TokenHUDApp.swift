import SwiftUI
import ImageIO
import QuartzCore

@main
struct QuotaNestApp: App {
    @StateObject private var engine: DataEngine
    @State private var language: AppLanguageSettings

    init() {
        let environment = ProcessInfo.processInfo.environment
        let mode = AppLaunchMode(environment: environment)
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let paths = AppConfigPaths(environment: environment, userHome: home,
                                   workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        if mode == .normal || mode == .migrateConfiguration {
            do {
                let migration = try AppIdentityMigration.migrate(userHome: home)
                if mode == .migrateConfiguration {
                    print("QuotaNest migration verified; providers=\(migration.providersDir.path); changed=\(migration.migrated)")
                    if let backup = migration.backupDirectory { print("Backup: \(backup.path)") }
                    if let report = migration.reportURL { print("Report: \(report.path)") }
                    exit(0)
                }
            } catch {
                if mode == .migrateConfiguration {
                    print("QuotaNest migration failed: \(error.localizedDescription)")
                } else {
                    let alert = NSAlert()
                    alert.messageText = "QuotaNest 历史配置迁移失败"
                    alert.informativeText = "旧配置已保留，未启动后台查询或调用。\n" + error.localizedDescription
                    alert.alertStyle = .critical
                    alert.runModal()
                }
                exit(1)
            }
        }
        _language = State(initialValue: AppLanguageSettings.shared)
        let bundle = Bundle.appResources.resourceURL?.appendingPathComponent("providers")
        switch mode {
        case .render(let directory):
            do {
                guard !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw NSError(domain: "TokenHUD.Render", code: 1, userInfo: [NSLocalizedDescriptionKey: "需要截图输出目录"])
                }
                let fixture = try DiagnosticFixture()
                _engine = StateObject(wrappedValue: fixture.engine)
                Task { @MainActor in
                    await Self.renderSnapshots(fixture: fixture, to: directory)
                    fixture.cleanup()
                    NSApplication.shared.terminate(nil)
                }
            } catch { print("render failed: \(error.localizedDescription)"); exit(1) }
            return
        case .debugSettings:
            do {
                let fixture = try DiagnosticFixture()
                _engine = StateObject(wrappedValue: fixture.engine)
                print("SETTINGS RESUME isolated fixture accounts=\(fixture.engine.allPlugins.count)")
                fixture.cleanup()
                exit(0)
            } catch { print("settings diagnostic failed: \(error.localizedDescription)"); exit(1) }
        case .importScan:
            if let reportPath = environment["QUOTANEST_REBUILD_FROM_REPORT"],
               let backupPath = environment["QUOTANEST_VERIFICATION_BACKUP"],
               let outputPath = environment["QUOTANEST_REBUILD_OUTPUT"] {
                do {
                    let fixture = try DiagnosticFixture()
                    _engine = StateObject(wrappedValue: fixture.engine)
                    Task { @MainActor in
                        let summary = await AccountRebuildVerification.run(backup: URL(fileURLWithPath: backupPath),
                            report: URL(fileURLWithPath: reportPath), output: URL(fileURLWithPath: outputPath))
                        if let bytes = try? JSONEncoder().encode(summary), let text = String(data: bytes, encoding: .utf8) { print(text) }
                        fixture.cleanup()
                        exit(summary.reportWritten ? 0 : 1)
                    }
                    return
                } catch { print("rebuild verification setup failed"); exit(1) }
            }
            if let reportPath = environment["QUOTANEST_VERIFY_IMPORTS_OUT"] {
                do {
                    let fixture = try DiagnosticFixture()
                    _engine = StateObject(wrappedValue: fixture.engine)
                    Task { @MainActor in
                        let summary = await ImportVerification.run(home: home, output: URL(fileURLWithPath: reportPath),
                            backup: environment["QUOTANEST_VERIFICATION_BACKUP"].map { URL(fileURLWithPath: $0) })
                        if let bytes = try? JSONEncoder().encode(summary), let text = String(data: bytes, encoding: .utf8) { print(text) }
                        fixture.cleanup()
                        exit(summary.reportWritten ? 0 : 1)
                    }
                    return
                } catch { print("verification setup failed"); exit(1) }
            }
            let requested = ProcessInfo.processInfo.environment["QUOTANEST_IMPORT_SOURCE"]
            let scanners: [(String, () -> [ImportCandidate])] = [
                ("9router", { ProviderImporter.from9Router(home: home.path) }),
                ("cc-switch", { ProviderImporter.fromCCSwitch(home: home.path) }),
                ("cpamp", { ProviderImporter.fromCPAMP(home: home.path) }),
                ("magpie", { ProviderImporter.fromMagpie(home: home.path) })]
            let templates = ProviderImporter.bundledTemplates()
            if environment["QUOTANEST_DUPLICATE_SCAN"] == "1" {
                let accounts = ProviderRegistry.scan(dir: paths.userProvidersDir)
                let index = ProviderAccountIdentity.index(providers: accounts, templates: templates)
                let groups = ProviderAccountIdentity.duplicateGroups(providers: accounts, templates: templates)
                print("account identity scan: accounts=\(accounts.count), recognized=\(index.count), duplicate-groups=\(groups.count)")
                for (number, group) in groups.enumerated() {
                    let sources = Set(group.map { $0.manifest.sourceReference?.source ?? "manual" }).sorted().joined(separator: ",")
                    print("group \(number + 1): members=\(group.count), sources=\(sources)")
                }
                exit(0)
            }
            for (name, scan) in scanners where requested == nil || requested == name {
                let rows = scan()
                let eligible = rows.filter { row in row.unsupportedReason == nil && ImportCenterModel.quotaAdapted(row,
                    templateLookup: { slug in templates.first { $0.slug == slug }?.manifest }) }
                print("\(name): total=\(rows.count), importable=\(eligible.count)")
                if requested != nil {
                    for slug in Set(eligible.compactMap(\.template)).sorted() {
                        print("\(slug): importable=\(eligible.filter { $0.template == slug }.count)")
                    }
                }
            }
            exit(0)
        case .repairHud:
            print("请在 App 中使用「同步 HUD」，保留账号启停与显示选择。")
            exit(1)
        case .migrateConfiguration: exit(0)
        case .normal: break
        }
        let userDir = paths.userProvidersDir
        let node = NodeLocator.find(nvmHome: home.appendingPathComponent(".nvm").path,
                                    extraPaths: ["/opt/homebrew/bin/node", "/usr/local/bin/node"],
                                    saved: UserDefaults.standard.string(forKey: DataEngine.defaultsNodeKey))
        let engine = DataEngine(hudDir: paths.hudDir, bundleProvidersDir: bundle, userProvidersDir: userDir,
                                runner: ProviderRunner(nodePath: node, logDir: paths.hudDir), settingsURL: paths.settingsURL)
        engine.start()
        _engine = StateObject(wrappedValue: engine)
        let panel = PanelController(engine: engine)
        _ = StatusItemController(engine: engine, panelCtrl: panel)
        SettingsWindowManager.shared.makeModel = {
            SettingsModel(engine: engine, hudDir: paths.hudDir, userDir: userDir,
                          settingsURL: paths.settingsURL, bundleDir: bundle)
        }
        if environment["QUOTANEST_AUTO_TOGGLE"] == "1" || environment["TOKENHUD_AUTO_TOGGLE"] == "1" {
            Task { @MainActor in try? await Task.sleep(nanoseconds: 2_000_000_000); panel.toggle() }
        }
        if environment["QUOTANEST_AUTO_SETTINGS"] == "1" || environment["TOKENHUD_AUTO_SETTINGS"] == "1" {
            Task { @MainActor in try? await Task.sleep(nanoseconds: 1_500_000_000); SettingsWindowManager.shared.show() }
        }
    }

    var body: some Scene {
        let locale = language.locale
        Settings { EmptyView().environment(\.locale, locale) }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button(L10n.tr("设置与外观…")) { SettingsWindowManager.shared.showSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
                CommandMenu(L10n.tr("账号")) {
                    Button(L10n.tr("账号管理…")) { SettingsWindowManager.shared.show() }.keyboardShortcut("0", modifiers: .command)
                    Button(L10n.tr("添加账号…")) {
                        SettingsWindowManager.shared.show()
                        SettingsWindowManager.shared.modelForQuery()?.openTemplates()
                    }.keyboardShortcut("n", modifiers: .command)
                    Button(L10n.tr("导入账号…")) {
                        SettingsWindowManager.shared.show()
                        SettingsWindowManager.shared.modelForQuery()?.openImport()
                    }
                    Divider()
                    Button(L10n.tr("刷新所有可查询账号")) { Task { await engine.refreshBalancesOnly() } }
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                    Button(L10n.tr("切换悬浮速览")) { StatusItemController.shared?.panelController.toggle() }
                        .keyboardShortcut("h", modifiers: [.command, .shift])
                }
            }
    }

    @MainActor private static func renderSnapshots(fixture: DiagnosticFixture, to directory: String) async {
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        do { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        catch { print("render output failed: \(error.localizedDescription)"); return }
        func model() -> SettingsModel {
            SettingsModel(engine: fixture.engine, hudDir: fixture.paths.hudDir, userDir: fixture.userDir,
                          settingsURL: fixture.paths.settingsURL, bundleDir: fixture.templatesDir, defaults: fixture.defaults,
                          confirmDiscardChanges: { false }, confirmTestCall: { _ in false },
                          executeTestCall: { _ in "✓ isolated fixture" })
        }
        var observations: [[String: Any]] = []
        let onlyScene = ProcessInfo.processInfo.environment["TOKENHUD_RENDER_ONLY"]
        func shot<Content: View>(_ name: String, _ view: Content, size: NSSize, dark: Bool) {
            guard onlyScene == nil || onlyScene?.split(separator: ",").contains(Substring(name)) == true else { return }
            var observation = capture(view, to: output.appendingPathComponent(name + ".png"), size: size, dark: dark)
            observation["scene"] = name
            observation["resource_bundle"] = Bundle.appResources.bundleURL.path
            observations.append(observation)
        }
        for width: CGFloat in [640, 900, 1200] {
            for dark in [false, true] {
                let appearance = dark ? "dark" : "light"
                let overview = model()
                overview.navPage = .overview
                shot("accounts-\(Int(width))-\(appearance)", SettingsCenterView(model: overview, engine: fixture.engine),
                     size: NSSize(width: width, height: 780), dark: dark)
                for (name, slug, tab) in [("connection", "demo-a", SettingsModel.Tab.config),
                                           ("api-only", "demo-api", .config),
                                           ("quota", "demo-long", .quota),
                                           ("plan", "demo-a", .trigger)] {
                    let selected = model()
                    _ = selected.selectAccount(slug, tab: tab)
                    shot("\(name)-\(Int(width))-\(appearance)", SettingsCenterView(model: selected, engine: fixture.engine),
                         size: NSSize(width: width, height: 780), dark: dark)
                }
                let editing = model()
                _ = editing.selectAccount("demo-a", tab: .config)
                editing.startEdit()
                shot("editor-\(Int(width))-\(appearance)", SettingsCenterView(model: editing, engine: fixture.engine),
                     size: NSSize(width: width, height: 780), dark: dark)
            }
        }
        let catalog = model()
        catalog.openTemplates()
        shot("provider-catalog-light", SettingsCenterView(model: catalog, engine: fixture.engine),
             size: NSSize(width: 1200, height: 900), dark: false)
        let allPlans = model()
        allPlans.navPage = .plan
        shot("schedules-light", SettingsCenterView(model: allPlans, engine: fixture.engine),
             size: NSSize(width: 1200, height: 850), dark: false)
        let authAccount = model()
        _ = authAccount.selectAccount("demo-auth", tab: .config)
        shot("authentication-light", SettingsCenterView(model: authAccount, engine: fixture.engine),
             size: NSSize(width: 1200, height: 900), dark: false)
        if let row = authAccount.current {
            shot("account-display-light", AccountDisplaySettings(model: authAccount, row: row)
                .padding(20).frame(width: 780, height: 430).background(Palette.canvas)
                .groupBoxStyle(QuietGroupBoxStyle()), size: NSSize(width: 780, height: 430), dark: false)
        }
        let importModel = model()
        let importer = ImportCenterModel(engine: fixture.engine, hudDir: fixture.paths.hudDir, userDir: fixture.userDir)
        importer.source = .magpie
        importer.magpieDirectory = "/tmp/quotanest-demo/magpie"
        importer.scanState = .scanned
        let english = AppLanguageSettings.shared.selection == .english
        for (id, name, mode) in [("cline", "Cline", "apikey"), ("gpt", "GPT", "auth"), ("glm", "GLM", "apikey")] {
            let reference = ProviderSourceReference(source: "magpie", path: "/tmp/quotanest-demo/magpie/providers.json",
                recordId: "demo-" + id, providerId: "demo-" + id, collection: "providers")
            let candidate = ImportCandidate(source: "magpie", name: name + " · Demo", template: id, apiKey: "",
                baseURL: "", proto: "openai", note: "", sourceRecordId: reference.recordId,
                sourceReference: reference, sourceAuthMode: mode)
            importer.rows.append(.init(candidate: candidate, state: .addable,
                note: english ? "Ready to import · read-only source reference" : "可导入 · 只读来源引用"))
        }
        importer.picked = Set(importer.rows.map(\.id))
        shot("import-light", ImportCenterSheet(model: importModel, engine: fixture.engine, im: importer)
            .frame(width: 1000, height: 680), size: NSSize(width: 1000, height: 680), dark: false)
        let preferences = model()
        preferences.navPage = .settings
        shot("settings-light", SettingsCenterView(model: preferences, engine: fixture.engine),
             size: NSSize(width: 1000, height: 1100), dark: false)
        if onlyScene == nil || onlyScene?.contains("imported-connection") == true {
            let source = fixture.userDir.deletingLastPathComponent().appendingPathComponent("demo-imported-codex.json")
            let object: [String: Any] = ["type": "codex", "access_token": "fixture-preview-token",
                "account_id": "fixture-preview-workspace", "model": "fixture-codex-model"]
            if let bytes = try? JSONSerialization.data(withJSONObject: object) { try? bytes.write(to: source) }
            let reference = ProviderSourceReference(source: "cpamp", path: source.path, recordId: source.lastPathComponent,
                                                   providerId: "codex", collection: "auth-files")
            let candidate = ImportCandidate(source: "cpamp", name: "Codex · Demo import", template: "gpt", apiKey: "",
                baseURL: "", proto: "responses", note: "", sourceRecordId: source.lastPathComponent,
                sourceReference: reference, sourceAuthMode: "auth")
            do {
                let slug = try ProviderImporter.apply(candidate, templates: fixture.engine.templates,
                    userDir: fixture.userDir, hudDir: fixture.paths.hudDir)
                fixture.engine.reloadRegistry()
                let imported = model()
                _ = imported.selectAccount(slug, tab: .config)
                shot("imported-connection-light", SettingsCenterView(model: imported, engine: fixture.engine),
                     size: NSSize(width: 1200, height: 880), dark: false)
            } catch { print("imported preview fixture failed: \(error.localizedDescription)") }
        }
        let feedback = FeedbackCoordinator(context: .init(area: .accountImport, source: .magpie, stage: .scan),
                                           counts: .init(candidates: 3), tools: .init())
        feedback.title = english ? "Import preview is empty" : "导入预览未显示账号"
        feedback.problem = english ? "The scan finishes but no importable entries are shown." : "扫描结束后没有显示可导入的记录。"
        feedback.steps = english ? "Open Import Accounts, choose a source, then scan." : "打开导入账号，选择来源后扫描。"
        shot("feedback-form-light", FeedbackWindowView(model: feedback, onClose: {}).frame(width: 760, height: 800),
             size: NSSize(width: 760, height: 800), dark: false)
        feedback.prepare()
        shot("feedback-review-light", FeedbackWindowView(model: feedback, onClose: {}).frame(width: 760, height: 800),
             size: NSSize(width: 760, height: 800), dark: false)
        let logoProviders = Bundle.appResources.resourceURL.map {
            ProviderRegistry.scan(dir: $0.appendingPathComponent("providers"))
        } ?? []
        for dark in [false, true] {
            let board = LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 16) {
                ForEach(logoProviders, id: \.slug) { provider in
                    VStack(spacing: 7) {
                        ProviderLogo(manifest: provider.manifest, slug: provider.slug, size: 32)
                        Text(provider.manifest.fullName).font(.system(size: 11)).lineLimit(2)
                    }.frame(maxWidth: .infinity, minHeight: 60)
                }
            }.padding(24).frame(width: 1100, height: 1050, alignment: .top).background(Palette.canvas)
            shot("provider-logos-\(dark ? "dark" : "light")", board,
                 size: NSSize(width: 1100, height: 1050), dark: dark)
        }
        let quick = model()
        let panel = PanelController(engine: fixture.engine, defaults: fixture.defaults)
        for dark in [false, true] {
            let appearance = dark ? "dark" : "light"
            shot("menu-\(appearance)", MenuBarView(engine: fixture.engine, panelCtrl: panel, model: quick,
                 onOpenSettings: {}, onTogglePanel: {}, onRefresh: {}, onOpenAccount: { _ in }),
                 size: NSSize(width: 350, height: 560), dark: dark)
            for style in PanelStyle.allCases {
                panel.setStyle(style)
                shot("floating-style-\(style.rawValue)-\(appearance)",
                     FloatingView(engine: fixture.engine, controller: panel, expanded: false, onToggle: {}, operationModel: quick),
                     size: NSSize(width: style.preferredWidth, height: 900), dark: dark)
            }
            panel.setStyle(.card)
            for expanded in [false, true] {
                shot("floating-\(expanded ? "expanded" : "compact")-\(appearance)",
                     FloatingView(engine: fixture.engine, controller: panel, expanded: expanded, onToggle: {}, operationModel: quick),
                     size: NSSize(width: 320, height: expanded ? 370 : 66), dark: dark)
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("render-observations.json"))
        }
        if onlyScene == nil || onlyScene?.contains("feedback-") == true {
            let manager = FeedbackWindowManager.shared
            manager.show(context: .init(area: .providerCatalog, stage: .catalog))
            manager.show(context: .init(area: .accountImport, source: .magpie, stage: .scan))
            let windows = NSApp.windows.filter { $0.identifier?.rawValue == "QuotaNestFeedback" && $0.isVisible }
            let evidence: [String: Any] = ["singleton": windows.count == 1,
                "movable": windows.first?.isMovable == true,
                "closable": windows.first?.styleMask.contains(.closable) == true]
            windows.forEach { $0.close() }
            var result = evidence
            result["closed"] = !NSApp.windows.contains { $0.identifier?.rawValue == "QuotaNestFeedback" && $0.isVisible }
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output.appendingPathComponent("feedback-window-checks.json"))
            }
        }
        await diagnoseNativeActions(model: model(), output: output)
        let validImages = observations.filter { $0["image_written"] as? Bool == true }.count
        print("isolated diagnostics completed: \(validImages) valid fixture-window PNGs; inspect render-observations.json for unavailable visual evidence")
    }

    /// Locate actual native controls by accessibility ID; never guess screen coordinates.
    @MainActor private static func diagnoseNativeActions(model: SettingsModel, output: URL) async {
        _ = model.selectAccount("demo-a", tab: .config)
        let host = NSHostingView(rootView: SettingsCenterView(model: model, engine: model.engine))
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: 780)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); window.contentView = nil }
        var steps: [[String: Any]] = []
        for identifier in ["account.edit-connection", "account.test-draft"] {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 150_000_000)
            let elements = accessibilityElements(roots: [window, host])
            let expectedTitle = identifier == "account.edit-connection" ? "编辑连接" : "测试当前 API 配置"
            let byIdentifier = elements.first { accessibilityString($0, selector: "accessibilityIdentifier") == identifier }
            let matches = elements.filter { accessibilityNames($0).contains(expectedTitle) }
            let byTitle = matches.first { $0 is NSButton || accessibilityString($0, selector: "accessibilityRole") == "AXButton" } ?? matches.first
            let target = byIdentifier ?? byTitle
            let metadata = elements.map { element -> [String: String] in
                ["type": String(describing: type(of: element)),
                 "role": accessibilityString(element, selector: "accessibilityRole") ?? "",
                 "subrole": accessibilityString(element, selector: "accessibilitySubrole") ?? "",
                 "identifier": accessibilityString(element, selector: "accessibilityIdentifier") ?? "",
                 "label": accessibilityString(element, selector: "accessibilityLabel") ?? "",
                 "title": accessibilityString(element, selector: "accessibilityTitle") ?? "",
                 "button_title": (element as? NSButton)?.title ?? ""]
            }
            if let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output.appendingPathComponent(identifier + "-ax.json"))
            }
            let draftBefore = model.draft != nil
            let pressed = target.map(accessibilityPress) ?? false
            try? await Task.sleep(nanoseconds: 100_000_000)
            let semanticResult = identifier == "account.edit-connection"
                ? (!draftBefore && model.draft != nil)
                : (model.draft != nil && !model.isTestingCurrentConfig && model.toast?.text.contains("已取消测试") == true)
            steps.append(["identifier": identifier, "located": target != nil, "press_accepted": pressed,
                          "semantic_result": semanticResult, "status": pressed && semanticResult ? "verified_in_process" : "not_verified",
                          "accessibility_nodes": elements.count, "draft": model.draft != nil,
                          "reason": target == nil ? "No matching accessibility element; no coordinate fallback." : "In-process accessibility press on isolated fixture."])
        }
        let result: [String: Any] = ["scope": "In-process NSAccessibility tree and press action; not physical mouse, keyboard or system status item",
                                     "all_controls_located": steps.allSatisfy { $0["located"] as? Bool == true },
                                     "semantic_actions_verified": steps.allSatisfy { $0["status"] as? String == "verified_in_process" },
                                     "steps": steps, "network_executor": "fixture only; confirmation declines"]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("native-actions.json"))
        }
    }

    @MainActor private static func accessibilityString(_ element: NSObject, selector name: String) -> String? {
        let selector = NSSelectorFromString(name)
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue() as? String
    }

    @MainActor private static func accessibilityNames(_ element: NSObject) -> [String] {
        var names = ["accessibilityLabel", "accessibilityTitle"].compactMap { accessibilityString(element, selector: $0) }
        if let button = element as? NSButton { names.append(button.title) }
        if element.accessibilityAttributeNames().contains(.title),
           let title = element.accessibilityAttributeValue(.title) as? String { names.append(title) }
        if accessibilityString(element, selector: "accessibilityRole") == "AXStaticText",
           let text = accessibilityString(element, selector: "accessibilityValue") { names.append(text) }
        return names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    @MainActor private static func accessibilityPress(_ target: NSObject) -> Bool {
        var current: NSObject? = target
        for _ in 0..<12 {
            guard let element = current else { return false }
            if let button = element as? NSButton, button.isEnabled {
                button.performClick(nil)
                return true
            }
            if let accessible = element as? NSAccessibilityProtocol, accessible.accessibilityPerformPress() { return true }
            if element.accessibilityActionNames().contains(.press) {
                element.accessibilityPerformAction(.press)
                return true
            }
            let selector = NSSelectorFromString("accessibilityParent")
            current = element.responds(to: selector) ? element.perform(selector)?.takeUnretainedValue() as? NSObject : nil
        }
        return false
    }

    @MainActor private static func accessibilityElements(roots: [NSObject]) -> [NSObject] {
        var queue = roots
        var visited: Set<ObjectIdentifier> = []
        var result: [NSObject] = []
        while !queue.isEmpty, result.count < 10_000 {
            let element = queue.removeLast()
            guard visited.insert(ObjectIdentifier(element)).inserted else { continue }
            result.append(element)
            for name in ["accessibilityChildren", "accessibilityChildrenInNavigationOrder", "accessibilityContents"] {
                let selector = NSSelectorFromString(name)
                if element.responds(to: selector),
                   let children = element.perform(selector)?.takeUnretainedValue() as? [Any] {
                    queue.append(contentsOf: children.compactMap { $0 as? NSObject })
                }
            }
            if element.accessibilityAttributeNames().contains(.children),
               let children = element.accessibilityAttributeValue(.children) as? [Any] {
                queue.append(contentsOf: children.compactMap { $0 as? NSObject })
            }
            if let view = element as? NSView { queue.append(contentsOf: view.subviews) }
        }
        return result
    }

    @MainActor private static func capture<Content: View>(_ content: Content, to destination: URL,
                                                         size: NSSize, dark: Bool) -> [String: Any] {
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.center()
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); window.contentView = nil }
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        }
        let rendered = host.bounds.size
        let screenCaptureAllowed = CGPreflightScreenCaptureAccess()
        var method = "unavailable"
        var written = false
        var quality: [String: Any] = [:]
        var issues: [String] = []
        if screenCaptureAllowed {
            // -l captures this exact, locally-created fixture window only.
            // Never fall back to a display, rectangle or whole-screen capture.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.windowNumber), destination.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let deadline = Date().addingTimeInterval(3)
                while process.isRunning && Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                }
                if process.isRunning { process.terminate(); issues.append("Fixture window screenshot timed out") }
                else if process.terminationStatus == 0 {
                    quality = imageQuality(at: destination)
                    written = quality["pixels_valid"] as? Bool == true
                    if written { method = "system_fixture_window" }
                    else { issues.append("System window screenshot failed pixel validation") }
                } else { issues.append("Fixture window screenshot failed with status \(process.terminationStatus)") }
            } catch { issues.append("Window capture unavailable: \(error.localizedDescription)") }
        } else {
            issues.append("Screen Recording permission unavailable; no permission request was made")
        }
        if !written {
            issues.append("Visual evidence unavailable. ImageRenderer does not support this AppKit-backed interface; no fallback PNG is produced.")
            // Each destination comes from a fixed diagnostic scene name. Remove
            // only that exact regular PNG, so a previous invalid render cannot
            // be mistaken for the current run's output. Never follow symlinks.
            let target = destination.standardizedFileURL
            let prefixes = ["accounts-", "connection-", "api-only-", "quota-", "plan-", "editor-", "menu-", "floating-"]
            if target.pathExtension == "png", prefixes.contains(where: { target.lastPathComponent.hasPrefix($0) }),
               let values = try? target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
               values.isRegularFile == true, values.isSymbolicLink != true {
                do { try FileManager.default.removeItem(at: target) }
                catch { issues.append("Could not remove previous invalid capture: \(error.localizedDescription)") }
            }
        }
        return ["requested_width": size.width, "requested_height": size.height,
                "rendered_width": rendered.width, "rendered_height": rendered.height,
                "appearance": dark ? "dark" : "light", "image_written": written,
                "capture_method": method, "pixel_check": quality,
                "visual_status": written ? "requires_manual_review" : "unavailable",
                "full_window_capture": method == "system_fixture_window",
                "visual_review_required": true, "limitations": issues,
                "evidence_scope": "Only the isolated fixture window is eligible for system capture; pixel validity does not prove visual correctness or interaction."]
    }

    private static func imageQuality(at url: URL) -> [String: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return ["pixels_valid": false, "reason": "Image cannot be decoded"]
        }
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
            return true
        }
        guard drawn else { return ["pixels_valid": false, "reason": "Cannot inspect pixels"] }
        var black = 0, transparent = 0
        var colors: Set<Int> = []
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[offset]), green = Int(pixels[offset + 1]), blue = Int(pixels[offset + 2])
            if red <= 6 && green <= 6 && blue <= 6 { black += 1 }
            if pixels[offset + 3] < 240 { transparent += 1 }
            colors.insert((red / 24) * 121 + (green / 24) * 11 + blue / 24)
        }
        let total = Double(side * side)
        let blackFraction = Double(black) / total
        let transparentFraction = Double(transparent) / total
        return ["pixels_valid": image.width >= 100 && image.height >= 40
                    && blackFraction < 0.45 && transparentFraction < 0.05 && colors.count >= 6,
                "pixel_width": image.width, "pixel_height": image.height,
                "near_black_fraction": blackFraction, "transparent_fraction": transparentFraction,
                "color_bins": colors.count,
                "note": "Rejects dominant black/transparent or near-blank captures; visual review remains required."]
    }
}

/// All demonstrations, auth-shaped fixtures, caches and preferences live in one temporary directory.
@MainActor private final class DiagnosticFixture {
    let root: URL
    let paths: AppConfigPaths
    let userDir: URL
    let templatesDir: URL
    let defaults: UserDefaults
    let engine: DataEngine
    private let defaultsName: String

    init() throws {
        root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("quotanest-demo-\(UUID().uuidString)", isDirectory: true)
        paths = AppConfigPaths(environment: ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude").path], userHome: root, workingDirectory: root)
        userDir = root.appendingPathComponent("accounts", isDirectory: true)
        templatesDir = root.appendingPathComponent("types", isDirectory: true)
        defaultsName = "tokenhud.diagnostic.\(UUID().uuidString)"
        guard let isolated = UserDefaults(suiteName: defaultsName) else { throw CocoaError(.fileWriteUnknown) }
        defaults = isolated
        for dir in [paths.hudDir, userDir, templatesDir] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try Data("{\"env\":{}}".utf8).write(to: paths.settingsURL)
        if let directory = Bundle.appResources.resourceURL?.appendingPathComponent("providers") {
            for provider in ProviderRegistry.scan(dir: directory) {
                var declaration = provider.manifest
                declaration.autoCreateDefault = false
                declaration.authFile = paths.hudDir.appendingPathComponent(".preview-\(provider.slug)-auth.json").path
                try PluginGenerator.writePlugin(slug: provider.slug, manifest: declaration,
                                                script: "#!/bin/sh\nexit 1\n", into: templatesDir)
                try Data("{}".utf8).write(to: templatesDir.appendingPathComponent(provider.slug + "/auth-template.json"))
            }
        }
        let english = AppLanguageSettings.shared.selection == .english
        let examples: [(String, String, Bool, String?)] = [
            ("demo-a", english ? "Personal development" : "日常开发账号", true, nil),
            ("demo-long", english ? "Team workspace" : "团队协作账号", true, nil),
            ("demo-api", english ? "API-only relay" : "仅用于 API 调用", false, nil),
            ("demo-error", english ? "Backup account" : "备用账号", true, "network")
        ]
        let now = Date().timeIntervalSince1970 * 1000
        for (slug, name, quota, error) in examples {
            let auth = paths.hudDir.appendingPathComponent(".\(slug)-usage-auth.json")
            let cache = paths.hudDir.appendingPathComponent(".\(slug)-usage-cache.json")
            let manifest = ProviderManifest(name: "Fixture-\(slug)", label: english ? "Demo provider" : "示例供应商", displayName: name, intervalSec: 300,
                                            buckets: [:], cacheFile: quota ? cache.path : nil, authFile: auth.path,
                                            queryUrl: quota ? "https://example.invalid/usage" : nil, queryAuth: "bearer", queryKeyField: "apiKey",
                                            refreshUrl: "https://example.invalid/v1/chat/completions", refreshProtocol: "openai", refreshAuth: "bearer",
                                            authMode: "apikey")
            try PluginGenerator.writePlugin(slug: slug, manifest: manifest, script: "#!/bin/sh\nexit 1\n", into: userDir)
            let values: [String: Any] = ["apiUrl": "https://example.invalid/usage", "apiKey": quota ? "FIXTURE-QUERY" : "",
                                         "apiBaseURL": "https://example.invalid/v1", "refreshApiKey": "FIXTURE-CALL",
                                         "testModel": "demo-model", "testPrompt": "只回复 OK", "quotaMode": quota ? "endpoint" : "none",
                                         "scheduleTimes": ["09:00", "12:00", "15:00", "18:00", "20:00", "22:00", "23:00"]]
            try JSONSerialization.data(withJSONObject: values).write(to: auth, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)
            if quota {
                let snapshot = UsageCache(generatedAt: now - (error == nil ? 0 : 600_000), error: error,
                                          stale: error != nil, lastAttemptAt: now, windows: [
                                            WindowBucket(label: "5小时", usedPercentage: slug == "demo-long" ? 71 : 28, period: "5h", resetsAt: Int(now / 1000) + 12_000),
                                            WindowBucket(label: "本周", usedPercentage: 46, period: "7d", resetsAt: Int(now / 1000) + 400_000)
                                          ], accountId: "fixture-\(slug)")
                try JSONEncoder().encode(snapshot).write(to: cache)
            }
        }
        let cliAuth = root.appendingPathComponent("demo-cli-auth.json")
        try Data("{\"access_token\":\"DEMO-TOKEN-NOT-VALID\"}".utf8).write(to: cliAuth)
        let authConfig = paths.hudDir.appendingPathComponent(".demo-auth-usage-auth.json")
        let authCache = paths.hudDir.appendingPathComponent(".demo-auth-usage-cache.json")
        let authManifest = ProviderManifest(name: "DemoAuth", label: english ? "Auth provider" : "Auth 示例",
            displayName: english ? "CLI authorization" : "CLI 授权账号", cacheFile: authCache.path, authFile: authConfig.path,
            queryUrl: "https://example.invalid/usage", queryAuth: "bearer", refreshUrl: "https://example.invalid/v1/chat/completions",
            refreshProtocol: "openai", refreshAuth: "bearer", authMode: "auth", quotaMode: "endpoint", quotaAuthModes: ["auth"],
            credentialSource: ProviderCredentialSource(file: cliAuth.path, tokenPath: "access_token"),
            authCallUrl: "https://example.invalid/v1/chat/completions", authCallProtocol: "openai", authCallHeader: "Authorization: Bearer <token>")
        try PluginGenerator.writePlugin(slug: "demo-auth", manifest: authManifest, script: "#!/bin/sh\nexit 1\n", into: userDir)
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "authMode": "auth", "authCredentialFile": cliAuth.path,
            "testModel": "demo-model", "testPrompt": "OK", "quotaMode": "endpoint"]).write(to: authConfig)
        try JSONEncoder().encode(UsageCache(generatedAt: now, windows: [WindowBucket(label: "5小时", usedPercentage: 35)], accountId: "fixture-demo-auth")).write(to: authCache)
        defaults.set(examples.map { $0.0 } + ["demo-auth"], forKey: DataEngine.defaultsOrderKey)
        engine = DataEngine(hudDir: paths.hudDir, bundleProvidersDir: templatesDir, userProvidersDir: userDir,
                            runner: ProviderRunner(nodePath: nil, logDir: root.appendingPathComponent("logs")), defaults: defaults, settingsURL: paths.settingsURL)
        engine.reloadRegistry()
    }
    func cleanup() { defaults.removePersistentDomain(forName: defaultsName); try? FileManager.default.removeItem(at: root) }
}
