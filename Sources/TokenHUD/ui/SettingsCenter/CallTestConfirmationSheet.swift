import SwiftUI

struct CallTestConfirmationSheet: View {
    let confirmation: CallTestConfirmation
    let onSend: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "paperplane")
                    .font(.system(size: 19, weight: .medium)).foregroundStyle(Palette.accent)
                    .frame(width: 40, height: 40)
                    .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text("发送 API 测试").font(.system(size: 18, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text("确认本次使用的账号和调用配置").font(Typo.small).foregroundStyle(Palette.muted)
                }
            }
            CardBox {
                VStack(alignment: .leading, spacing: 7) {
                    KeyValueRow("账号") { Text(verbatim: confirmation.providerName) }
                    KeyValueRow("配置来源") { Text(verbatim: confirmation.sourceLabel) }
                    KeyValueRow("模型", mono: true) { Text(verbatim: confirmation.model) }
                    KeyValueRow("调用目标", mono: true) { Text(verbatim: confirmation.target) }
                }
            }
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "info.circle").foregroundStyle(Palette.accent).padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text("将发送 1 次请求，会消耗该账号额度。").foregroundStyle(Palette.inkSecondary)
                    Text("不会保存配置或开启定时计划；调用成功不保证额度窗口重置。")
                        .foregroundStyle(Palette.muted)
                }.fixedSize(horizontal: false, vertical: true)
            }.font(Typo.small)
            HStack(spacing: 9) {
                Spacer()
                Button("取消", action: onCancel).barButton().keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("call-test.cancel")
                Button("发送测试", action: onSend).barButton(.primary).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("call-test.send")
            }.padding(.top, 3)
        }
        .padding(24).frame(width: 560)
        .background(Palette.canvas)
        .onExitCommand(perform: onCancel)
        .accessibilityIdentifier("call-test.confirmation")
    }
}
