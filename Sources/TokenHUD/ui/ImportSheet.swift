import SwiftUI

// MARK: - 一键导入 (9router / cc-switch / cpamp)

struct ImportSheet: View {
    @ObservedObject var engine: DataEngine
    let hudDir: URL
    let userDir: URL
    let onDone: (String) -> Void

    @State private var source: ImportSource = .nineRouter
    @State private var candidates: [ImportCandidate] = []
    @State private var picked: Set<UUID> = []
    @State private var busy = false
    @State private var result: String?

    enum ImportSource: String, CaseIterable, Identifiable {
        case nineRouter, ccSwitch, cpamp
        var id: String { rawValue }
        var label: String {
            switch self {
            case .nineRouter: return "9router"
            case .ccSwitch: return "cc-switch"
            case .cpamp: return "cpamp"
            }
        }
        var path: String {
            switch self {
            case .nineRouter: return "~/.9router/db/data.sqlite"
            case .ccSwitch: return "~/.cc-switch/cc-switch.db"
            case .cpamp: return "~/.cli-proxy-api/*.json"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("一键导入供应商").font(.system(.title3, design: .rounded).weight(.semibold))
                Text("从本机其他管理器读取已有凭证, 生成 TokenHUD 供应商实例。\n只读取, 不修改源端数据。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $source) {
                    ForEach(ImportSource.allCases) { s in Text(s.label).tag(s) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Text(source.path).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            .padding(16)

            Divider()

            list
                .frame(height: 300)

            Divider()

            HStack {
                if let result {
                    Text(result).font(.caption)
                        .foregroundStyle(result.hasPrefix("✓") ? .green : .orange)
                }
                Spacer()
                Button("取消") { onDone("已取消") }.keyboardShortcut(.cancelAction)
                Button {
                    apply()
                } label: {
                    if busy { ProgressView().controlSize(.small) }
                    else { Text("导入所选 (\(picked.count))") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty || busy)
            }
            .padding(14)
        }
        .frame(width: 560)
        .onAppear { scan() }
        .onChange(of: source) { _, _ in scan() }
    }

    @ViewBuilder
    private var list: some View {
        if candidates.isEmpty {
            EmptyHint(title: "此源无可导入项", detail: "可能未安装、未登录, 或凭证格式不支持")
        } else {
            List {
                ForEach(candidates) { c in
                    HStack(spacing: 9) {
                        Toggle("", isOn: Binding(
                            get: { picked.contains(c.id) },
                            set: { on in if on { picked.insert(c.id) } else { picked.remove(c.id) } }))
                            .labelsHidden().toggleStyle(.checkbox)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.name).font(.callout)
                            Text(c.note).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if c.template != nil {
                            Text("模板 \(c.template!)")
                                .font(.caption2).foregroundStyle(.blue)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.blue.opacity(0.12)))
                        } else {
                            Text(c.proto).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(c.apiKey.isEmpty ? "无凭证" : "••••" + String(c.apiKey.suffix(4)))
                            .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func scan() {
        let home = NSHomeDirectory()
        candidates = {
            switch source {
            case .nineRouter: return ProviderImporter.from9Router(home: home)
            case .ccSwitch: return ProviderImporter.fromCCSwitch(home: home)
            case .cpamp: return ProviderImporter.fromCPAMP(home: home)
            }
        }()
        picked = Set(candidates.map(\.id))
    }

    private func apply() {
        busy = true
        result = nil
        let chosen = candidates.filter { picked.contains($0.id) }
        var ok = 0, fail = 0
        for c in chosen {
            do {
                try ProviderImporter.apply(c, templates: engine.templates, userDir: userDir, hudDir: hudDir)
                ok += 1
            } catch {
                fail += 1
            }
        }
        engine.reloadRegistry()
        busy = false
        if fail == 0 {
            onDone("✓ 已导入 \(ok) 个供应商")
        } else {
            result = "✓ \(ok) 成功, ✗ \(fail) 失败"
        }
    }
}
