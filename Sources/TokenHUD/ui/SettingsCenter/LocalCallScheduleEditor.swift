import SwiftUI

/// Owns local scheduling preferences only. External source authentication is never edited here.
@MainActor
struct LocalCallScheduleEditor: View {
    @ObservedObject var model: SettingsModel
    let row: AccountRow
    var onClose: () -> Void
    @State private var times: [String]
    @State private var enabled: Bool
    @State private var chosenModel: String
    @State private var timeInput = ""
    @State private var error: String?

    init(model: SettingsModel, row: AccountRow, initialTimes: [String]? = nil, onClose: @escaping () -> Void) {
        self.model = model
        self.row = row
        self.onClose = onClose
        let config = model.readConfig(row.plugin)
        _times = State(initialValue: initialTimes ?? config.scheduleTimes)
        _enabled = State(initialValue: !config.scheduleTimes.isEmpty && !model.engine.triggerDisabledSlugs.contains(row.id))
        _chosenModel = State(initialValue: model.scheduleModel(row))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ProviderLogo(manifest: row.plugin.manifest, slug: row.id, size: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("编辑本地调用计划")).font(.system(size: 18, weight: .semibold))
                    Text(row.name).font(Typo.small).foregroundStyle(Palette.muted)
                }
                Spacer()
            }
            Text(L10n.tr("计划保存在 QuotaNest；运行时使用导入认证，不修改外部工具。"))
                .font(Typo.small).foregroundStyle(Palette.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(L10n.tr("启用 API 调度"), isOn: $enabled).toggleStyle(.switch)
                    Text(L10n.tr("按本机时区 %@ 在每个时间点发送一次调用，会消耗额度；尝试开启 5h 窗口，不保证开窗或重置。账号停用时计划暂停。", TimeZone.current.identifier))
                        .font(Typo.small).foregroundStyle(Palette.muted)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(L10n.tr("计划调用模型")).font(Typo.small).foregroundStyle(Palette.inkSecondary)
                        TextField(L10n.tr("调用模型"), text: $chosenModel).fieldBox()
                            .accessibilityIdentifier("schedule.model")
                        ModelCatalogControls(model: model, savedAccount: row, modelSelection: $chosenModel)
                    }
                    RecommendedScheduleTimes { preset in
                        times = preset
                        timeInput = ""
                        error = nil
                    }
                    HStack(spacing: 8) {
                        TextField("09:00", text: $timeInput).fieldBox().frame(width: 100)
                            .accessibilityLabel(L10n.tr("添加调用时间，24小时制"))
                            .onSubmit(addTime)
                        Button(L10n.tr("添加时间"), action: addTime).barButton()
                    }
                    FlowChips(times: times) { index in times.remove(at: index); error = nil }
                    if times.isEmpty { Text(L10n.tr("尚未添加时间点")).font(Typo.small).foregroundStyle(Palette.muted) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 4)
            }.frame(height: 360)
            if let error { Text(error).font(Typo.small).foregroundStyle(Palette.danger).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 9) {
                Spacer()
                Button(L10n.tr("取消"), action: onClose).barButton().keyboardShortcut(.cancelAction)
                Button(L10n.tr("保存计划"), action: save).barButton(.primary)
                    .keyboardShortcut("s", modifiers: .command)
                    .accessibilityIdentifier("schedule.save")
            }
        }
        .padding(24).frame(width: 560)
        .foregroundStyle(Palette.ink).background(Palette.canvas)
        .onExitCommand(perform: onClose)
    }

    private func addTime() {
        let pending = timeInput.trimmingCharacters(in: .whitespaces)
        guard !pending.isEmpty else { return }
        let issues = SettingsValidation.triggerErrors(times: times, timeInput: pending, triggerEnabled: false, canCall: true)
        if let message = issues["time"] ?? issues["times"] { error = message; return }
        times.append(pending); times.sort(); timeInput = ""; error = nil
    }

    private func save() {
        if model.saveCallSchedule(row.id, times: times, timeInput: timeInput, model: chosenModel, enabled: enabled) {
            onClose()
        } else { error = model.toast?.text ?? L10n.tr("保存失败") }
    }
}
