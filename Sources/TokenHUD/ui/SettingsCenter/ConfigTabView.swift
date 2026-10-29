import SwiftUI

// MARK: - 配置 tab (只读) + 自动触发 tab (只读)

struct ConfigTabView: View {
    @ObservedObject var model: SettingsModel
    let row: AccountRow

    private var m: ProviderManifest { row.plugin.manifest }
    private var cfg: ProviderConfig { model.readConfig(row.plugin) }

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
                            Text("配置").font(Typo.section).foregroundStyle(Palette.ink)
                            Text("默认只读；点「编辑」进入草稿，保存前不会影响当前账号。")
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
                            Text(row.canCall
                                 ? (cfg.refreshProtocol == "anthropic" ? "Anthropic 兼容 · messages" : "OpenAI 兼容 · chat/completions")
                                 : "尚未配置调用端点")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("自动触发").font(Typo.section).foregroundStyle(Palette.ink)
                            Text("自动查询额度与模型定时调用相互独立；保存不会发起请求；按本机时区执行。")
                                .font(Typo.small).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        if row.authStyle == "apikey" {
                            Button("编辑") { model.startEdit() }.barButton()
                        }
                    }

                    Text("自动查询额度").font(Typo.small).bold().foregroundStyle(Palette.muted)
                    VStack(spacing: 0) {
                        KeyValueRow("自动查询额度") {
                            Text(row.autoQuery ? "已开启" : "已关闭")
                        }
                        KeyValueRow("查询能力") {
                            Text(row.canQuery ? "支持" : "该供应商未提供额度查询接口")
                        }
                    }

                    Text("模型定时调用").font(Typo.small).bold()
                        .foregroundStyle(Palette.muted).padding(.top, 4)

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
                        UnsupportedBox(
                            title: "尚未配置调用端点",
                            detail: "该供应商支持模型调用，在配置中填入调用地址与模型即可启用定时调用。")
                    }
                }
            }
        }
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
