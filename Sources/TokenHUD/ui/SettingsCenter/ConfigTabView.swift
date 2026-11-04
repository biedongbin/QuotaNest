import SwiftUI

struct ConfigTabView: View {
    @ObservedObject var model: SettingsModel
    let row: AccountRow
    private var config: ProviderConfig { model.readConfig(row.plugin) }
    private var quotaAddress: String {
        do {
            let resolved = try ProviderAuthentication.resolveQuota(config)
            return resolved.queryUrl.isEmpty ? "供应商脚本" : resolved.queryUrl
        } catch {
            return "基础认证解析失败，查询地址暂不可用"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("连接配置").font(.headline)
                Spacer()
                AccountActionButton(title: "编辑连接", identifier: "account.edit-connection") {
                    model.startEdit()
                }.fixedSize().frame(height: 28)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                apiConnection
                quotaConnection
            }
            HStack {
                Button("复制账号…", systemImage: "plus.square.on.square") { model.duplicateAccount(row.id) }
                Spacer()
                Button("删除账号…", role: .destructive) { model.delete(row.id) }
            }
        }
    }
    private var apiConnection: some View {
        GroupBox("① 基础接入") {
                VStack(alignment: .leading, spacing: 8) {
                    KeyValueRow("服务地址", mono: true) { Text(model.baseAddressDescription(config)) }
                    KeyValueRow("协议") { Text(model.baseProtocolDescription(config)) }
                    KeyValueRow("认证方式") { Text(config.authMode == "auth" ? "Auth · 本机授权" : "API Key") }
                    if config.authMode == "auth" {
                        KeyValueRow("有效来源") { Text(model.authSourceDescription(config)) }
                        if let issue = model.authenticationIssue(config) {
                            Text(issue).font(.callout).foregroundStyle(Palette.danger).textSelection(.enabled)
                        }
                    } else {
                        KeyValueRow("调用凭证") { Text(maskKey(config.refreshKey)) }
                    }
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
                }
            }
    }
    private var quotaConnection: some View {
        GroupBox("② 用量查询 · 可选") {
                VStack(alignment: .leading, spacing: 8) {
                    if row.canQuery && config.quotaMode != "none" {
                        KeyValueRow("查询地址", mono: true) { Text(quotaAddress) }
                        KeyValueRow("查询认证") { Text("跟随基础接入") }
                        Text(model.quotaConfigured(row) ? "用量查询配置已就绪。" : (model.quotaAuthenticationIssue(config) ?? "请检查基础接入的查询地址配置。"))
                            .font(.callout).foregroundStyle(.secondary)
                        Button("查看额度", systemImage: "chart.bar") { model.tab = .quota }
                    } else {
                        Label("未启用额度查询", systemImage: "minus.circle").foregroundStyle(.secondary)
                        Text("API 调用和调用计划可独立使用。需要时编辑连接，选择额度查询方式。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
    }
}

struct TriggerTabView: View {
    @ObservedObject var model: SettingsModel
    let row: AccountRow
    private var config: ProviderConfig { model.readConfig(row.plugin) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("调用计划").font(.headline)
                Spacer()
                Button("编辑计划", systemImage: "pencil") { model.startEdit() }
            }
            GroupBox("③ API 调度 · 启动 5h 使用窗口") {
                VStack(alignment: .leading, spacing: 12) {
                    Label(planState, systemImage: "calendar.badge.clock")
                    KeyValueRow("调用模型", mono: true) { Text(config.testModel.isEmpty ? "未指定" : config.testModel) }
                    if !config.scheduleTimes.isEmpty {
                        Text(config.scheduleTimes.joined(separator: "、")).monospacedDigit().textSelection(.enabled)
                    }
                    Text("在设置时间首次调用，启动动态 5h 使用窗口，以覆盖工作时段。使用本机时区 \(TimeZone.current.identifier)，到点发送一次调用并消耗额度。")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("使用基础接入认证及目标套餐可调用模型。仅执行用户设置的时间，不推断或自动重置窗口。").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
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
                    }
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
