import SwiftUI

/// Source metadata checks are separate from quota requests and model calls.
struct SourceSyncControls: View {
    @ObservedObject var engine: DataEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Label("来源同步", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .medium))
                Toggle("自动同步", isOn: Binding(
                    get: { engine.sourceAutoSyncEnabled },
                    set: { engine.setSourceAutoSyncEnabled($0) }))
                    .toggleStyle(.switch).controlSize(.mini).fixedSize()
                    .accessibilityIdentifier("source-sync.auto")
                Text("每小时").font(Typo.small).foregroundStyle(Palette.muted)
                Spacer(minLength: 8)
                Button {
                    Task { await engine.syncImportedSources() }
                } label: {
                    Label(engine.sourceSyncing ? "同步中…" : "立即同步", systemImage: "arrow.clockwise")
                }
                .barButton()
                .disabled(engine.sourceSyncing)
                .accessibilityIdentifier("source-sync.now")
                .help("检查已导入账号的来源引用，唯一确认身份后订正记录 ID")
            }
            if let date = engine.sourceSyncLastAttempt {
                HStack(spacing: 4) {
                    Text("上次检查")
                    Text(date, format: .dateTime.month().day().hour().minute())
                    if !engine.sourceAutoSyncEnabled { Text("· 自动同步已关闭") }
                }.font(Typo.small).foregroundStyle(Palette.muted)
            }
            Text(engine.sourceSyncMessage.isEmpty
                 ? "只读检查来源与记录 ID；不会发送模型请求或复制凭证。"
                 : engine.sourceSyncMessage)
                .font(Typo.small)
                .foregroundStyle(engine.sourceSyncIssues.isEmpty ? Palette.muted : Palette.warn)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("source-sync.result")
        }
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.border))
    }
}
