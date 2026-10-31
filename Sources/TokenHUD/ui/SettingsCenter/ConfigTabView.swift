import SwiftUI

struct ConfigTabView: View {
    @ObservedObject var model: SettingsModel
    let row: AccountRow
    private var config: ProviderConfig { model.readConfig(row.plugin) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("连接配置").font(.headline)
                Spacer()
                AccountActionButton(title: "编辑连接", identifier: "account.edit-connection") {
                    model.startEdit()
                }.fixedSize().frame(height: 28)
            }
            GroupBox("API 调用") {
                VStack(alignment: .leading, spacing: 8) {
                    KeyValueRow("服务地址", mono: true) { Text(config.apiBaseURL.isEmpty ? "未配置" : config.apiBaseURL) }
                    KeyValueRow("协议") { Text(config.refreshProtocol == "anthropic" ? "Anthropic Messages" : "OpenAI Chat Completions") }
                    KeyValueRow("调用凭证") { Text(maskKey(config.refreshKey)) }
                    KeyValueRow("模型", mono: true) { Text(config.testModel.isEmpty ? "未指定" : config.testModel) }
                    if row.builtin { Label("供应商类型固定服务地址与协议", systemImage: "lock").font(.callout).foregroundStyle(.secondary) }
                    HStack {
                        Label(model.callConfigured(row) ? "调用配置完整" : "调用尚未配置完整",
                              systemImage: model.callConfigured(row) ? "checkmark.circle" : "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button(model.callRunning.contains(row.id) ? "测试中…" : "测试 API 调用") { model.testCall(row.id) }
                            .disabled(!row.canCall || !model.callConfigured(row) || model.callRunning.contains(row.id))
                    }
                    Text("使用已保存配置发送一次请求，会消耗账号额度。").font(.caption).foregroundStyle(.secondary)
                    if let result = model.callTestResult(for: row.id) { CallTestResultView(result: result) }
                }.padding(8)
            }
            GroupBox("额度查询 · 可选") {
                VStack(alignment: .leading, spacing: 8) {
                    if row.canQuery {
                        KeyValueRow("查询地址", mono: true) { Text(config.queryUrl.isEmpty ? "供应商脚本" : config.queryUrl) }
                        KeyValueRow("查询凭证") { Text(config.queryKey.isEmpty ? "独立配置或本机凭证" : maskKey(config.queryKey)) }
                        Text(model.quotaConfigured(row) ? "独立查询配置已就绪。" : "请补全额度查询配置。")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("查看额度", systemImage: "chart.bar") { model.tab = .quota }
                    } else {
                        Label("未启用额度查询", systemImage: "minus.circle").foregroundStyle(.secondary)
                        Text("API 调用和调用计划可独立使用。需要时编辑连接，选择额度查询方式。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("复制账号…", systemImage: "plus.square.on.square") { model.duplicateAccount(row.id) }
                Spacer()
                Button("删除账号…", role: .destructive) { model.delete(row.id) }
            }
        }
    }
}

struct TriggerTabView: View {
    @ObservedObject var model: SettingsModel
    let row: AccountRow
    private var config: ProviderConfig { model.readConfig(row.plugin) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("调用计划").font(.headline)
                Spacer()
                Button("编辑计划", systemImage: "pencil") { model.startEdit() }
            }
            GroupBox("模型定时调用") {
                VStack(alignment: .leading, spacing: 12) {
                    Label(planState, systemImage: "calendar.badge.clock")
                    if !config.scheduleTimes.isEmpty {
                        Text(config.scheduleTimes.joined(separator: "、")).monospacedDigit().textSelection(.enabled)
                    }
                    Text("使用本机时区 \(TimeZone.current.identifier)。到点发送一次模型调用，会消耗该账号额度。")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("额度查询是否开启，不影响 API 调用计划。").font(.callout).foregroundStyle(.secondary)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            if row.canQuery {
                GroupBox("后台额度查询") {
                    VStack(alignment: .leading, spacing: 8) {
                        Stepper("查询间隔：\(interval) 分钟", value: Binding(get: { interval }, set: {
                            model.engine.setIntervalMinutes(row.id, minutes: $0)
                        }), in: 1...1440)
                            .disabled(!row.enabled || !model.quotaConfigured(row))
                        if model.engine.hasIntervalOverride(row.id) {
                            Button("恢复供应商默认间隔") { model.engine.clearIntervalOverride(row.id) }
                        }
                        Text("间隔立即生效。账号停用时后台查询暂停。").font(.callout).foregroundStyle(.secondary)
                    }.padding(8)
                }
            }
        }
    }
    private var interval: Int { model.engine.effectiveIntervalMinutes(row.id, manifest: row.plugin.manifest) }
    private var planState: String {
        if !row.canCall || !model.callConfigured(row) { return "请先配置 API 调用" }
        if config.scheduleTimes.isEmpty { return "未设置调用时间" }
        if model.engine.triggerDisabledSlugs.contains(row.id) { return "计划已关闭" }
        return row.enabled ? "计划已启用" : "账号已停用，计划暂停"
    }
}

struct UnsupportedBox: View {
    let title: String
    let detail: String
    var body: some View { ResultBox(kind: .neutral, title: title, detail: detail) }
}

struct TemplateCatalogView: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择供应商类型").font(.title2.weight(.semibold))
            Text("类型可以重复使用，每个账号单独保存凭证、计划与显示选择。")
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                ForEach(model.choices) { choice in
                    Button { model.pickTemplate(choice) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(choice.label, systemImage: choice.manifest == nil ? "network" : "shippingbox")
                                .font(.headline)
                            Text(choice.manifest == nil ? "自定义 API，额度查询可选" : "使用内置类型的地址与协议")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .padding(12).frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
                    }.buttonStyle(.bordered)
                }
            }
        }
    }
}

struct CallTestResultView: View {
    let result: CallTestResult
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ResultBox(kind: result.phase == .success ? .ok : (result.phase == .running ? .info : .error),
                      title: result.title, detail: result.message)
            Text("\(result.sourceLabel) · \(result.model)").font(.caption).foregroundStyle(.secondary)
            Text(result.target).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            Text(result.date, style: .time).font(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }
}
