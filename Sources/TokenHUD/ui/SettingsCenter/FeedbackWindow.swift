import AppKit
import SwiftUI

@MainActor final class FeedbackWindowManager: NSObject, NSWindowDelegate {
    static let shared = FeedbackWindowManager()
    private var window: NSWindow?
    private var pending: FeedbackCoordinator?

    func show(context: FeedbackContext, counts: FeedbackCounts = .init(), events: [SafeDiagnosticEvent] = []) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // Keep an uncertain submission's request ID when reopening, rather than allowing a duplicate POST.
        let model = pending ?? FeedbackCoordinator(context: context, counts: counts, events: events)
        pending = model
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 800),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        panel.title = L10n.tr("反馈问题")
        panel.identifier = NSUserInterfaceItemIdentifier("QuotaNestFeedback")
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 640, height: 600)
        let restoredFrame = panel.setFrameUsingName("QuotaNestFeedback")
        panel.setFrameAutosaveName("QuotaNestFeedback")
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: FeedbackWindowView(model: model, onClose: { [weak panel] in panel?.close() }))
        window = panel
        if !restoredFrame { panel.center() }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        pending?.cancel()
        if pending?.uncertain != true { pending = nil }
        window = nil
    }
}

struct FeedbackWindowView: View {
    @ObservedObject var model: FeedbackCoordinator
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("反馈问题")).font(.system(size: 20, weight: .semibold))
                Text("github.com/biedongbin/QuotaNest").font(Typo.small).foregroundStyle(Palette.inkSecondary)
                Text(L10n.tr("仅收集白名单运行摘要，不读取凭证、原始配置或完整日志。提交前可查看全部内容。"))
                    .font(Typo.small).foregroundStyle(Palette.muted)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let url = model.issueURL {
                        Label(L10n.tr("反馈已提交"), systemImage: "checkmark.circle.fill").foregroundStyle(Palette.ok)
                        Link(L10n.tr("在 GitHub 查看反馈"), destination: url)
                    } else if let body = model.body {
                        review(body)
                    } else {
                        editor
                    }
                    if model.isBusy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(L10n.tr("正在提交到 GitHub…"))
                        }.accessibilityIdentifier("feedback.progress")
                    }
                    if let message = model.message {
                        Label(message, systemImage: "info.circle").font(Typo.small).foregroundStyle(Palette.inkSecondary)
                    }
                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(Typo.small).foregroundStyle(Palette.danger).textSelection(.enabled)
                            .accessibilityIdentifier("feedback.error")
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 10) {
                Button(L10n.tr("关闭"), action: onClose).keyboardShortcut(.cancelAction)
                if model.isBusy { Button(L10n.tr("取消操作")) { model.cancel() } }
                Spacer(minLength: 8)
                if model.body == nil && model.issueURL == nil {
                    Button(L10n.tr("生成并预览反馈")) { model.prepare() }
                        .buttonStyle(.borderedProminent).disabled(model.isBusy)
                        .accessibilityIdentifier("feedback.prepare")
                } else if model.issueURL == nil {
                    Button(L10n.tr("复制草稿")) { model.copyDraft() }.disabled(model.isBusy)
                    Button(model.uncertain ? L10n.tr("在 GitHub 核对反馈") : L10n.tr("在浏览器中反馈")) { model.openBrowser() }
                        .disabled(!model.acknowledged || model.isBusy)
                    Button(L10n.tr("确认提交到 GitHub")) { model.send() }
                        .buttonStyle(.borderedProminent).disabled(!model.canSend)
                        .accessibilityIdentifier("feedback.submit")
                }
            }.padding(16)
        }
        .frame(minWidth: 640, minHeight: 600)
        .background(Palette.canvas)
        .font(Typo.body)
        .tint(Palette.accent)
        .groupBoxStyle(QuietGroupBoxStyle())
        .appLanguageEnvironment()
        .onExitCommand(perform: onClose)
        .contextMenu {
            Button(L10n.tr("复制草稿")) { model.copyDraft() }.disabled(model.body == nil || model.isBusy)
            Button(L10n.tr("关闭反馈窗口"), action: onClose)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("请勿填写 API Key、Token、邮箱、账号或私人路径。"))
                .font(Typo.small).foregroundStyle(Palette.warn)
            TextField(L10n.tr("问题标题"), text: $model.title).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("feedback.title")
            input(L10n.tr("问题描述"), text: $model.problem, identifier: "feedback.description")
            input(L10n.tr("复现步骤（可选）"), text: $model.steps, identifier: "feedback.steps")
            if !model.tools.claudeAvailable {
                Text(L10n.tr("未安装 Claude：无需安装，仍可直接提交或复制反馈。"))
                    .font(Typo.small).foregroundStyle(Palette.muted)
            }
            toolStatus
        }.disabled(model.isBusy)
    }

    private func input(_ label: String, text: Binding<String>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .medium))
            TextEditor(text: text).font(.system(size: 12)).frame(minHeight: 92)
                .scrollContentBackground(.hidden).padding(7)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.border))
                .accessibilityLabel(label).accessibilityIdentifier(identifier)
        }
    }

    @ViewBuilder private func review(_ body: String) -> some View {
        HStack {
            Text(model.reviewedTitle).font(.system(size: 15, weight: .semibold))
            Spacer()
            Button(L10n.tr("返回编辑")) { model.edit() }.disabled(!model.canEdit)
        }
        Text(L10n.tr("以下是将要提交的完整内容，请逐项核对。"))
            .font(Typo.small).foregroundStyle(Palette.inkSecondary)
        ScrollView {
            Text(body).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .accessibilityIdentifier("feedback.preview")
        }
        .frame(height: 300)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.border))
        if model.uncertain {
            Label(L10n.tr("提交结果未知，已禁止重复发送。请先检查状态或到 GitHub 核对。"), systemImage: "exclamationmark.triangle")
                .font(Typo.small).foregroundStyle(Palette.warn)
            Button(L10n.tr("检查提交状态")) { model.reconcile() }.disabled(model.isBusy)
        }
        Text(L10n.tr("反馈草稿在本机生成，不需要 Claude，也不会自动安装任何工具。"))
            .font(Typo.small).foregroundStyle(Palette.muted)
        toolStatus
        Text(L10n.tr("敏感检测不能识别所有秘密，请人工核对。"))
            .font(Typo.small).foregroundStyle(Palette.muted)
        Toggle(L10n.tr("我已确认内容不含凭证或隐私，并同意在上述 GitHub 仓库公开发布。"), isOn: $model.acknowledged)
            .toggleStyle(.checkbox).font(Typo.small).disabled(model.isBusy)
            .accessibilityIdentifier("feedback.confirm-public")
    }

    private var toolStatus: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(model.tools.ghAvailable
                 ? L10n.tr("已找到 gh，将使用其已有的 GitHub 登录。")
                 : L10n.tr("未安装 gh：可以复制草稿或在浏览器中提交。"))
                .font(Typo.small).foregroundStyle(Palette.muted)
            Spacer(minLength: 6)
            Button(L10n.tr("重新检查工具")) { model.refreshTools() }
                .font(Typo.small).disabled(model.isBusy || model.uncertain)
        }
    }
}
