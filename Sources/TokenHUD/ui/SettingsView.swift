import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var engine: DataEngine
    let hudDir: URL
    let userDir: URL
    let settingsURL: URL
    let bundleDir: URL?

    @State private var newName = ""
    @State private var newBase = ""
    @State private var newKey = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var syncResult: String?

    var body: some View {
        Form {
            Section("供应商") {
                ForEach(engine.states) { st in
                    HStack {
                        Text(st.manifest.label)
                        Text(st.slug).foregroundStyle(.secondary).font(.caption)
                        Spacer()
                        Text(st.cache?.error ?? formatPct(st.worstPct))
                            .foregroundStyle(hudColor(HUDFmt.pctColor(st.worstPct)))
                        if !isBuiltin(st.slug) {
                            Button("删除", role: .destructive) { delete(st.slug) }
                        }
                    }
                }
                ForEach(engine.registryErrors.sorted(by: { $0.key < $1.key }), id: \.key) { slug, msg in
                    HStack { Text(slug).foregroundStyle(.orange); Text(msg).font(.caption) }
                }
            }

            Section("添加 (one-api / OpenAI 兼容)") {
                TextField("名称 (如 my-relay)", text: $newName)
                TextField("baseURL (https://…)", text: $newBase)
                SecureField("apiKey", text: $newKey)
                HStack {
                    Button("测试连接") { test() }.disabled(newBase.isEmpty || newKey.isEmpty || testing)
                    if testing { ProgressView().controlSize(.small) }
                    if let testResult { Text(testResult).font(.caption) }
                }
                Button("保存") { save() }.disabled(newName.isEmpty || newBase.isEmpty || newKey.isEmpty)
            }

            Section("写入 Claude Code HUD") {
                Button("写入 Claude Code HUD") { syncHUD() }
                if let syncResult { Text(syncResult).font(.caption) }
            }

            Section("环境") {
                HStack {
                    Text("node: \(engine.nodeMissing ? "未找到" : "已定位")")
                    Button("手动指定…") { pickNode() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 480)
    }

    private func isBuiltin(_ slug: String) -> Bool {
        ["glm", "gpt", "ollama", "opencode-go"].contains(slug)
    }

    private func test() {
        testing = true; testResult = nil
        let script = PluginGenerator.oneAPIFetchScript(baseURL: newBase, apiKey: newKey)
        Task {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("tokenhud-test-\(UUID())")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            try? script.write(to: tmp.appendingPathComponent("fetch.sh"), atomically: true, encoding: .utf8)
            let m = PluginGenerator.oneAPIManifest(label: newName.isEmpty ? "test" : newName)
            let runner = ProviderRunner(nodePath: NodeLocator.find(
                nvmHome: NSHomeDirectory() + "/.nvm",
                extraPaths: ["/opt/homebrew/bin/node", "/usr/local/bin/node"],
                saved: UserDefaults.standard.string(forKey: DataEngine.defaultsNodeKey)))
            let cache = await runner.run(PluginProvider(slug: "test", manifest: m, dir: tmp), timeout: 15)
            try? FileManager.default.removeItem(at: tmp)
            await MainActor.run {
                testing = false
                if let pct = cache?.sevenDay?.usedPercentage {
                    testResult = "✓ 已用 \(pct)%"
                } else {
                    testResult = "✗ 连接失败 (查 baseURL/key)"
                }
            }
        }
    }

    private func save() {
        let slug = PluginGenerator.slugify(newName)
        let m = PluginGenerator.oneAPIManifest(label: newName)
        let script = PluginGenerator.oneAPIFetchScript(baseURL: newBase, apiKey: newKey)
        do {
            try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
            try PluginGenerator.writePlugin(slug: slug, manifest: m, script: script, into: userDir)
            newName = ""; newBase = ""; newKey = ""
            engine.reloadRegistry()
            Task { await engine.refreshNow() }
        } catch {
            testResult = "保存失败: \(error.localizedDescription)"
        }
    }

    private func delete(_ slug: String) {
        try? PluginGenerator.removePlugin(slug: slug, in: userDir)
        engine.reloadRegistry()
    }

    private func syncHUD() {
        do {
            let plugins = ProviderRegistry.load(bundleDir: bundleDir, userDir: userDir).plugins
            let new = HUDSync.envsDict(plugins: plugins, hudDir: hudDir)
            let envsURL = hudDir.appendingPathComponent("envs.json")
            let existing = (try? Data(contentsOf: envsURL))
                .flatMap { try? JSONDecoder().decode([String: EnvsEntry].self, from: $0) } ?? [:]
            try HUDSync.writeEnvs(HUDSync.mergeEnvs(existing: existing, new: new), to: envsURL)
            let keys = plugins.filter(\.manifest.isEnabled).map(\.manifest.name)
            let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
            let current = (settings?["env"] as? [String: Any])?["ACCOUNT_ENVS"] as? String
            try HUDSync.patchSettings(settingsURL: settingsURL,
                accountEnvs: HUDSync.mergeAccountEnvs(current: current, keys: keys))
            syncResult = "✓ 已写入 (statusline 下次渲染生效)"
        } catch {
            syncResult = "✗ \(error.localizedDescription)"
        }
    }

    private func pickNode() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        // 不设 allowedContentTypes: node 无扩展名, 任何 UTType 过滤都会置灰; 默认不限可选到任意文件
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: DataEngine.defaultsNodeKey)
            syncResult = "node 路径已存, 重启 App 生效"
        }
    }
}
