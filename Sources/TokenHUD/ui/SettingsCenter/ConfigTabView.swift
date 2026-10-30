import SwiftUI

// MARK: - 配置 tab (只读) + 自动触发 tab (只读)

struct ConfigTabView: View {
    @ObservedObject var model: SettingsModel
    let row: AccountRow

    private var m: ProviderManifest { row.plugin.manifest }
    private var cfg: ProviderConfig { model.readConfig(row.plugin) }
    /// P1-8 四态: 模型调用能力 (模板无 refreshUrl = 不支持; 通用未填地址 = 未配置)
    private var callStatus: CapabilityStatus { .call(manifest: m, configUrl: cfg.queryUrl) }

    private var addressRows: [AddressRow] {
        // 脚本型模板把查询地址放在 auth-template 的 apiUrl, 读盘后由 cfg.queryUrl 兜底
        let query = m.queryUrl ?? (cfg.queryUrl.isEmpty ? nil : cfg.queryUrl)
        return AddressPresentation.rows(generic: !row.builtin, queryUrl: query,
                                        refreshUrl: m.refreshUrl,
                                        configUrl: cfg.queryUrl)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text("配置").font(Typo.section).foregroundStyle(Palette.ink)
                                // P1-10: 执行性缺失已保存的账号标「未配置」(可补齐后再开依赖配置的开关)
                                if !row.isConfigured {
                                    BadgeText(text: "未配置", locked: true)
                                }
                            }
                            Text(row.isConfigured
                                 ? "默认只读；点「编辑」进入草稿，保存前不会影响当前账号。"
                                 : "凭证或地址缺失：账号已保存但查询与定时调用不可用，点「编辑」补齐。")
                                .font(Typo.small).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        if row.authStyle == "apikey" {
                            Button("编辑") { model.startEdit() }.barButton()
                        } else {
                            BadgeText(text: "只读 · 本机凭证", locked: true)
                        }
                    }
                    VStack(spacing: 0) {
                        KeyValueRow("显示名称") { Text(row.name) }
                        KeyValueRow("供应商") {
                            HStack(spacing: 6) {
                                Text(m.fullName)
                                BadgeText(text: row.builtin ? "内置" : "自定义", locked: row.builtin)
                            }
                        }
                        KeyValueRow("授权方式") { Text(row.authLabel) }
                        // queryUrl 在模板里是额度查询接口, 不是服务根地址 — 标签按语义给
                        ForEach(Array(addressRows.enumerated()), id: \.offset) { _, a in
                            KeyValueRow(a.label, mono: true) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.value)
                                    Text(a.note).font(Typo.small).foregroundStyle(Palette.muted)
                                }
                            }
                        }
                        KeyValueRow("调用协议") {
                            // P1-8: 端点缺失按四态给文案 — 通用未填 = 「未配置调用端点」(可补), 不写「未提供」
                            switch callStatus {
                            case .configured:
                                Text(cfg.refreshProtocol == "anthropic" ? "Anthropic 兼容 · messages" : "OpenAI 兼容 · chat/completions")
                            case .notConfigured:
                                Text("未配置调用端点（填入服务地址后可调用）")
                            case .notSupported:
                                Text("该供应商不支持模型调用")
                            case .notIntegrated:
                                Text("未接入")
                            case .unverified:
                                Text("待核实")
                            }
                        }
                        KeyValueRow("凭证来源", mono: true) {
                            Text(row.authStyle == "apikey"
                                 ? maskKey(cfg.queryKey.isEmpty ? cfg.refreshKey : cfg.queryKey)
                                 : (m.authFile ?? "本机 CLI"))
                        }
                        KeyValueRow("测试模型") { Text(cfg.testModel.isEmpty ? "—" : cfg.testModel) }
                        KeyValueRow("测试提示词") { Text(cfg.testPrompt.isEmpty ? "—" : cfg.testPrompt) }
                    }
                }
            }

            CardBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("账号操作").font(Typo.section).foregroundStyle(Palette.ink)
                    Text("删除会移除插件目录与凭证文件，不可撤销。")
                        .font(Typo.small).foregroundStyle(Palette.muted)
                    Button("删除账号") { model.delete(row.id) }.barButton(.danger)
                }
            }

            CardBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Claude Code HUD").font(Typo.section).foregroundStyle(Palette.ink)
                    Text("把当前账号写入 envs.json 与 settings.json，下次渲染生效。")
                        .font(Typo.small).foregroundStyle(Palette.muted)
                    Button("写入 Claude Code HUD") { model.syncHUD() }.barButton()
                }
            }
        }
    }
}

struct TriggerTabView: View {
    @ObservedObject var model: SettingsModel
    let row: AccountRow

    private var cfg: ProviderConfig { model.readConfig(row.plugin) }
    /// P1-8 四态: 查询/调用能力判定集中引用
    private var quotaStatus: CapabilityStatus { .quota(manifest: row.plugin.manifest) }
    private var callStatus: CapabilityStatus { .call(manifest: row.plugin.manifest, configUrl: cfg.queryUrl) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("自动触发").font(Typo.section).foregroundStyle(Palette.ink)
                            Text("开关即时生效，无需保存；定时按本机时区执行，会消耗额度。")
                                .font(Typo.small).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        if row.authStyle == "apikey" {
                            Button("编辑调用配置") { model.startEdit() }.barButton()
                        }
                    }

                    // v0.2 三开关 (即时生效): 启用监控 / 悬浮窗显示 / 同步 HUD
                    VStack(spacing: 10) {
                        Toggle(isOn: monitorBinding) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("启用监控").font(Typo.body).foregroundStyle(Palette.ink)
                                Text("关闭后不查询、不调度，不出现在菜单栏与 HUD。")
                                    .font(Typo.small).foregroundStyle(Palette.muted)
                            }
                        }
                        .toggleStyle(.switch)

                        Toggle(isOn: floatingBinding) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("悬浮窗显示").font(Typo.body).foregroundStyle(Palette.ink)
                                Text("在悬浮窗与菜单栏显示该账号余额；不影响查询。")
                                    .font(Typo.small).foregroundStyle(Palette.muted)
                            }
                        }
                        .toggleStyle(.switch)

                        Toggle(isOn: hudBinding) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("同步 HUD").font(Typo.body).foregroundStyle(Palette.ink)
                                Text("写入 envs.json 与 ACCOUNT_ENVS；关闭即时摘除。")
                                    .font(Typo.small).foregroundStyle(Palette.muted)
                            }
                        }
                        .toggleStyle(.switch)
                    }

                    Divider().overlay(Palette.border)

                    // v0.2 自动查询间隔 (即时生效 Stepper; 主开关开 = 按此间隔自动查)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("自动查询间隔").font(Typo.body).foregroundStyle(Palette.ink)
                            Text(intervalNote).font(Typo.small).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        Stepper("\(intervalMin) 分钟", value: intervalBinding, in: 1...1440)
                            .font(Typo.body)
                            .frame(width: 180)
                        if hasOverride {
                            Button("恢复默认") { model.engine.clearIntervalOverride(row.id) }
                                .barButton()
                        }
                    }
                    .opacity(row.enabled ? 1 : 0.5)
                    .disabled(!row.enabled)

                    Divider().overlay(Palette.border)
                    Text("模型定时调用").font(Typo.small).bold().foregroundStyle(Palette.muted)

                    if row.canCall {
                        VStack(spacing: 0) {
                            KeyValueRow("模型定时调用") {
                                Text(triggerEnabled ? "已开启" : "已关闭")
                            }
                            KeyValueRow("执行时间") {
                                if cfg.scheduleTimes.isEmpty {
                                    Text("尚未设置时间，不会定时调用模型")
                                } else {
                                    HStack(spacing: 6) {
                                        ForEach(cfg.scheduleTimes, id: \.self) { t in
                                            Text(t).font(Typo.small).monospacedDigit()
                                                .padding(.horizontal, 10).padding(.vertical, 2)
                                                .background(Capsule().fill(Palette.badgeBg))
                                                .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 1))
                                        }
                                    }
                                }
                            }
                        }
                        Button("发送一次测试调用") { model.testCall(row.id) }
                            .barButton()
                            .disabled(model.running.contains(row.id))
                            .padding(.top, 4)
                    } else {
                        // P1-8 四态区分: 通用未填地址 = 未配置 (可补); 模板无端点 = 不支持 (不可补)
                        switch callStatus {
                        case .notConfigured:
                            UnsupportedBox(
                                title: "未配置调用端点",
                                detail: "在配置中填入服务地址与模型即可启用定时调用。")
                        default:
                            UnsupportedBox(
                                title: "该供应商不支持模型调用",
                                detail: "此账号的供应商端没有模型调用接口，无法定时调用。")
                        }
                    }
                }
            }
        }
    }

    // v0.2 即时开关绑定 (直落盘, 不进草稿)
    private var monitorBinding: Binding<Bool> {
        Binding(get: { row.enabled }, set: { model.toggleMonitoring(row.id, enabled: $0) })
    }
    private var floatingBinding: Binding<Bool> {
        Binding(get: { !model.engine.floatingHiddenSlugs.contains(row.id) },
                set: { model.toggleFloating(row.id, shown: $0) })
    }
    private var hudBinding: Binding<Bool> {
        Binding(get: { !model.engine.hudHiddenSlugs.contains(row.id) },
                set: { model.toggleHudSync(row.id, synced: $0) })
    }

    private var intervalMin: Int {
        model.engine.effectiveIntervalMinutes(row.id, manifest: row.plugin.manifest)
    }
    private var hasOverride: Bool {
        UserDefaults.standard.integer(forKey: DataEngine.intervalKey(row.id)) > 0
    }
    private var intervalBinding: Binding<Int> {
        Binding(get: { intervalMin },
                set: { model.engine.setIntervalMinutes(row.id, minutes: $0) })
    }
    private var intervalNote: String {
        hasOverride ? "已覆盖默认间隔，立即生效。" : "未设置时使用供应商默认（\(max(1, row.plugin.manifest.interval / 60)) 分钟）。"
    }

    private var triggerEnabled: Bool {
        !model.engine.triggerDisabledSlugs.contains(row.id) && row.canCall
    }
}

struct UnsupportedBox: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
            Text(detail).font(Typo.body).foregroundStyle(Palette.muted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.badgeBg))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Palette.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

// MARK: - 模板目录

struct TemplateCatalogView: View {
    @ObservedObject var model: SettingsModel
    private let columns = [GridItem(.adaptive(minimum: 210), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("选择模板").font(Typo.section).foregroundStyle(Palette.ink)
                    Text("选中模板后直接进入同一编辑区，不弹出新窗口。内置模板的地址由模板提供，不可修改；通用模板的额度查询尚未适配。")
                        .font(Typo.small).foregroundStyle(Palette.muted)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(model.choices) { c in
                            Button { model.pickTemplate(c) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text(c.label).font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(Palette.ink)
                                        Spacer(minLength: 4)
                                        Text(c.tag).font(.system(size: 11))
                                            .foregroundStyle(Palette.muted)
                                            .padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(Capsule().fill(Palette.badgeBg))
                                            .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 1))
                                    }
                                    Text(c.detail).font(Typo.small).foregroundStyle(Palette.muted)
                                    Spacer(minLength: 0)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.surface))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.border, lineWidth: 1))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle").font(.system(size: 11))
                Text("通用 OpenAI / Anthropic 兼容模板保存后只能手动测试调用；额度查询显示「尚未适配」，不按 one-api 口径自动解析。")
                    .font(Typo.small)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.badgeBg))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.border, lineWidth: 1))
        }
    }
}
