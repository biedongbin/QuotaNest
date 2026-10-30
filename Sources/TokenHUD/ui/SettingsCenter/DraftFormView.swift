import SwiftUI
import AppKit

// MARK: - 草稿表单 (配置 / 自动触发 共用, 单页三个分区)

struct DraftFormView: View {
    /// 按 tab 分段: .config = 基本信息 + 查询与凭证, .trigger = 自动触发, .all = 全部
    enum Section { case config, trigger, all }

    @ObservedObject var model: SettingsModel
    let draft: Draft
    var section: Section = .all

    @State private var showKey = false

    private var m: ProviderManifest? { model.draftManifest() }
    private var isNew: Bool { draft.isNew }
    private var isAPIKey: Bool { model.draftAuthStyle() == "apikey" }
    private var builtin: Bool { model.draftBuiltin() }
    private var canCall: Bool { model.draftCanCall() }
    private var hasExistingKey: Bool { !isNew && draft.hasExistingKey }
    private var clearPending: Bool { draft.values.clearKeyIntent }

    /// P1-9: 清除 Key 独立意图 — 确认弹窗后置位; 再点撤销
    private func toggleClearKey() {
        guard var d = model.draft else { return }
        if d.values.clearKeyIntent {
            d.values.clearKeyIntent = false
            model.draft = d
        } else {
            let alert = NSAlert()
            alert.messageText = "清除该账号的 API Key？"
            alert.informativeText = "保存后凭证将被清空，额度查询与测试调用都会失效，需重新填入。"
            alert.addButton(withTitle: "清除")
            alert.addButton(withTitle: "取消")
            alert.alertStyle = .warning
            if alert.runModal() == .alertFirstButtonReturn {
                d.values.clearKeyIntent = true
                d.values.key = ""
                model.draft = d
            }
        }
    }

    /// 内置模板的 url 字段装的是额度查询接口 (脚本型取自 auth-template 的 apiUrl), 通用模板才是服务根地址
    private var urlFieldLabel: String {
        builtin ? "额度查询地址" : "服务地址"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            notice
            if section != .trigger {
                basicGroup
                credentialGroup
            }
            if section != .config {
                if canCall { triggerGroup } else { unsupportedTrigger }
            }
        }
        .onChange(of: draft.values) { _, _ in
            // 用户改动后清掉旧的保存错误汇总, 只保留字段级提示
            if !model.topError.isEmpty { model.topError = "" }
        }
    }

    private var notice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "pencil.circle").font(.system(size: 11))
            Text(isNew ? "新账号保存后加入左侧列表；草稿仅在本机内存，未保存前不会写盘。"
                       : "草稿仅在本机内存，未保存；切换 tab 不丢失，关窗/切换账号会确认。")
                .font(Typo.small)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Palette.muted)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.accentSoft))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.border, lineWidth: 1))
    }

    // MARK: 基本信息

    private var basicGroup: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("基本信息").font(Typo.section).foregroundStyle(Palette.ink)
                Text("名称用于左侧列表与状态栏展示。").font(Typo.small).foregroundStyle(Palette.muted)

                HStack(alignment: .top, spacing: 12) {
                    field("账号名称", required: true, error: model.errors["name"]) {
                        TextField("例如 GLM 工作号", text: bind(\.name))
                            .textFieldStyle(.plain)
                            .fieldBox(invalid: model.errors["name"] != nil)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("供应商 / 授权方式").font(Typo.small).foregroundStyle(Palette.muted)
                        HStack(spacing: 6) {
                            BadgeText(text: m?.fullName ?? "通用兼容")
                            BadgeText(text: isAPIKey ? "API Key" : "授权登录", locked: !isAPIKey)
                        }
                        Text(builtin ? "内置供应商：协议与地址由模板提供，只有密钥/模型/时间可改。"
                                     : "自定义供应商：可修改地址与调用协议。")
                            .font(Typo.small).foregroundStyle(Palette.muted)
                    }
                }

                if !builtin, isAPIKey {
                    field("调用协议", required: false, error: nil) {
                        Picker("", selection: bind(\.proto)) {
                            Text("OpenAI 兼容 · chat/completions").tag("openai")
                            Text("Anthropic 兼容 · messages").tag("anthropic")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
            }
        }
    }

    // MARK: 查询与凭证

    private var credentialGroup: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("查询与凭证").font(Typo.section).foregroundStyle(Palette.ink)
                Text(isAPIKey ? "Key 保存后写入本机凭证文件，仅用于额度查询与调用。"
                              : "凭证来自本机 CLI，只读展示。")
                    .font(Typo.small).foregroundStyle(Palette.muted)

                field(urlFieldLabel, required: false, error: model.errors["url"]) {
                    TextField("https://…", text: bind(\.url))
                        .textFieldStyle(.plain)
                        .font(Typo.mono)
                        .fieldBox(invalid: model.errors["url"] != nil, readonly: builtin)
                        .disabled(builtin)
                    Text(builtin ? "\(AddressPresentation.builtinNote)；该地址用于查询额度。"
                                 : (m?.queryUrl != nil ? "留空表示不查询该账号的额度。" : "自定义地址需为有效的 http(s) URL。"))
                        .font(Typo.small).foregroundStyle(Palette.muted)
                }

                if builtin, let r = m?.refreshUrl {
                    field("调用地址", required: false, error: nil) {
                        Text(r)
                            .font(Typo.mono).foregroundStyle(Palette.muted)
                            .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.readonlyField))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.border, lineWidth: 1))
                        Text("测试调用实际请求的端点，只读。")
                            .font(Typo.small).foregroundStyle(Palette.muted)
                    }
                }

                if isAPIKey {
                    field("API Key", required: !hasExistingKey, error: model.errors["key"]) {
                        HStack(spacing: 8) {
                            Group {
                                if showKey {
                                    TextField(hasExistingKey ? "保持原值" : "粘贴 API Key", text: bind(\.key))
                                } else {
                                    SecureField(hasExistingKey ? "保持原值" : "粘贴 API Key", text: bind(\.key))
                                }
                            }
                            .textFieldStyle(.plain)
                            .font(Typo.mono)
                            .fieldBox(invalid: model.errors["key"] != nil)
                            Button(showKey ? "隐藏" : "显示") { showKey.toggle() }.barButton()
                            // P1-9: 清除 Key 是独立显式意图 (确认后置位, 保存时落盘清空)
                            if hasExistingKey {
                                Button(clearPending ? "撤销清除" : "清除 Key") { toggleClearKey() }
                                    .barButton(clearPending ? .primary : .plain)
                            }
                        }
                        Text(clearPending
                             ? "已标记清除：保存后该账号凭证将被清空。"
                             : (hasExistingKey ? "留空保存即保持原 Key；清除需点「清除 Key」确认。"
                                               : "保存后写入 ~/.claude/hud 下的凭证文件（600 权限）。"))
                            .font(Typo.small).foregroundStyle(clearPending ? Palette.danger : Palette.muted)
                    }
                } else {
                    field("凭证来源", required: false, error: nil) {
                        Text(m?.authFile ?? "本机 CLI")
                            .font(Typo.mono).foregroundStyle(Palette.muted)
                            .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.readonlyField))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.border, lineWidth: 1))
                        Text("只读 · 由本机 CLI 维护，TokenHUD 不写入、不刷新。")
                            .font(Typo.small).foregroundStyle(Palette.muted)
                    }
                }

                if canCall {
                    HStack(alignment: .top, spacing: 12) {
                        field("测试模型", required: false, error: nil) {
                            TextField("glm-4.7", text: bind(\.model))
                                .textFieldStyle(.plain).font(Typo.mono)
                                .fieldBox()
                        }
                        field("测试提示词", required: false, error: nil) {
                            TextField("回复 OK 即视为连通。", text: bind(\.prompt))
                                .textFieldStyle(.plain)
                                .fieldBox()
                        }
                    }
                }
            }
        }
    }

    // MARK: 自动触发

    private var triggerGroup: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("自动触发").font(Typo.section).foregroundStyle(Palette.ink)
                Text("保存不发起任何请求；定时按本机时区 24 小时制执行，会消耗额度。自动查询开关与间隔在保存后的「自动触发」页直接操作。")
                    .font(Typo.small).foregroundStyle(Palette.muted)

                Toggle(isOn: bind(\.autoTrigger)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("模型定时调用").font(Typo.body).foregroundStyle(Palette.ink)
                        Text("到点发送一次测试调用，会消耗额度；与自动查询额度独立。")
                            .font(Typo.small).foregroundStyle(Palette.muted)
                    }
                }
                .toggleStyle(.switch)

                Text("调用时间点").font(Typo.small).bold().foregroundStyle(Palette.muted)

                HStack(spacing: 8) {
                    TextField("09:00", text: bindTimeInput)
                        .textFieldStyle(.plain).font(Typo.mono)
                        .frame(width: 120)
                        .fieldBox(invalid: model.errors["time"] != nil)
                        .onSubmit { model.addTime() }
                    Button("添加") { model.addTime() }.barButton()
                    if let e = model.errors["time"] {
                        Text(e).font(Typo.small).foregroundStyle(Palette.danger)
                    }
                }
                Text("示例：09:00 合法；9:00、24:00、09:60 非法；时间点不可重复。")
                    .font(Typo.small).foregroundStyle(Palette.muted)

                if draft.values.times.isEmpty {
                    Text("尚未添加时间点。").font(Typo.small).foregroundStyle(Palette.muted)
                } else {
                    FlowChips(times: draft.values.times) { model.removeTime(at: $0) }
                }
                if let e = model.errors["times"] {
                    Text(e).font(Typo.small).foregroundStyle(Palette.danger)
                }

                HStack(spacing: 8) {
                    Button("保存并发送一次测试调用") {
                        guard let slug = model.draft?.slug else {
                            model.flash("请先保存草稿，再发送测试调用", error: true); return
                        }
                        model.testCall(slug)
                    }
                        .barButton()
                        .disabled(draft.slug == nil)
                        .help("草稿未保存前无法调用；先保存再测试")
                    // P1-6: 显式用草稿当前配置发测试调用, 不落盘 (盘上配置不变)
                    Button("用当前草稿发送测试调用") {
                        model.testCallDraft(values: draft.values)
                    }
                        .barButton()
                        .help("使用草稿配置（未保存，盘上账号配置不受影响）发送一次测试调用")
                }
            }
        }
    }

    private var unsupportedTrigger: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("自动触发").font(Typo.section).foregroundStyle(Palette.ink)
                Text("自动查询开关与间隔在保存后的「自动触发」页直接操作。")
                    .font(Typo.small).foregroundStyle(Palette.muted)
                UnsupportedBox(title: "未配置调用端点",
                               detail: "填入服务地址与模型后即可启用定时调用；当前草稿尚未填写服务地址。")
            }
        }
    }

    // MARK: 底栏 (由 DetailPanel 固定在滚动区外, 两个 tab 都可见)

    // MARK: 绑定

    private func bind<T>(_ kp: WritableKeyPath<DraftValues, T>) -> Binding<T> {
        Binding(
            get: { model.draft?.values[keyPath: kp] ?? draft.values[keyPath: kp] },
            set: { v in
                if model.draft != nil { model.draft?.values[keyPath: kp] = v }
            })
    }

    private var bindTimeInput: Binding<String> {
        Binding(
            get: { model.draft?.timeInput ?? "" },
            set: { v in
                model.draft?.timeInput = v
                if model.errors["time"] != nil { model.errors["time"] = nil }
            })
    }

    private func field<C: View>(_ label: String, required: Bool, error: String?,
                                @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                Text(label).font(Typo.small).foregroundStyle(Palette.muted)
                if required { Text("*").font(Typo.small).foregroundStyle(Palette.danger) }
            }
            content()
            if let error {
                Text(error).font(Typo.small).foregroundStyle(Palette.danger)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 时间点 chips 流式排布 (无第三方布局, 手算换行)
struct FlowChips: View {
    let times: [String]
    let onRemove: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { i in
                        chip(times[i], index: i)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// 每行 6 个 (HH:MM chip 固定宽度, 无需真实测量)
    private var rows: [[Int]] {
        stride(from: 0, to: times.count, by: 6).map { start in
            Array(start..<min(start + 6, times.count))
        }
    }

    private func chip(_ t: String, index: Int) -> some View {
        HStack(spacing: 4) {
            Text(t).font(Typo.small).monospacedDigit().foregroundStyle(Palette.ink)
            Button { onRemove(index) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.muted)
            .accessibilityLabel("删除 \(t)")
        }
        .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 3)
        .background(Capsule().fill(Palette.badgeBg))
        .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 1))
    }
}
