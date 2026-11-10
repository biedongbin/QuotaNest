import Foundation
import SwiftUI
import AppKit

struct CallTestConfirmation: Identifiable {
    let id = UUID()
    let sourceLabel: String
    let model: String
    let target: String
    let providerName: String
}

struct CallTestResult {
    enum Phase { case running, success, failure, uncertain }
    let phase: Phase
    let model: String
    let target: String
    let sourceLabel: String
    let message: String
    let date: Date
    var maxTokens: Int? = nil

    var title: String {
        if sourceLabel == "5h 窗口调用" {
            switch phase {
            case .running: return L10n.tr("5h 开窗调用中")
            case .success: return L10n.tr("5h 开窗调用成功")
            case .failure: return L10n.tr("5h 开窗调用未成功")
            case .uncertain: return L10n.tr("调用结果不确定")
            }
        }
        switch phase {
        case .running: return L10n.tr("测试进行中")
        case .success: return L10n.tr("测试成功")
        case .failure: return L10n.tr("测试未成功")
        case .uncertain: return L10n.tr("调用结果不确定")
        }
    }

    var isError: Bool { phase == .failure || phase == .uncertain }
    var feedbackExpiresAt: Date? { phase == .running ? nil : date.addingTimeInterval(isError ? 8 : 5) }
    func feedbackIsVisible(at now: Date = Date()) -> Bool { feedbackExpiresAt.map { now < $0 } ?? true }

    static func targetDescription(_ raw: String) -> String {
        guard var components = URLComponents(string: raw),
              components.host != nil else { return L10n.tr("未配置调用地址") }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? L10n.tr("调用地址")
    }
}

struct CallTestResultView: View {
    let result: CallTestResult
    @State private var copyLabel = "复制详情"
    private var color: Color {
        switch result.phase {
        case .running: return Palette.accent
        case .success: return Palette.ok
        case .failure: return Palette.danger
        case .uncertain: return Palette.warn
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                if result.phase == .running { ProgressView().controlSize(.small) }
                else { Image(systemName: result.phase == .success ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(color) }
                Text(result.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                Spacer()
                Button(L10n.tr(copyLabel)) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    copyLabel = pasteboard.setString(result.message, forType: .string) ? "已复制" : "复制失败"
                }.barButton().help(L10n.tr("复制已脱敏的完整结果"))
            }
            Text(L10n.tr("实际请求模型：%@", result.model))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.inkSecondary).textSelection(.enabled)
            if let limit = result.maxTokens {
                Text(L10n.tr("输出上限：%@ tokens", String(limit))).font(.system(size: 10.5)).foregroundStyle(Palette.muted)
            }
            CallResponseText(message: result.message)
                .frame(height: result.message.count > 280 || result.message.contains("\n") ? 190 : 70)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.border))
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "\(L10n.tr(result.sourceLabel)) · \(result.model)").fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(result.date, style: .time)
            }.font(.system(size: 11)).foregroundStyle(Palette.muted)
            Text(verbatim: result.target).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).background(Palette.readonlyField, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .onChange(of: result.date) { _, _ in copyLabel = "复制详情" }
    }
}

/// NSTextView lays out large responses without parsing Markdown or HTML, and
/// keeps native selection, Cmd-C and vertical scrolling available.
private final class ResponseScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let text = documentView as? NSTextView, contentSize.width > 0 else { return }
        if text.frame.width != contentSize.width {
            text.setFrameSize(NSSize(width: contentSize.width, height: max(contentSize.height, text.frame.height)))
        }
    }
}

private struct CallResponseText: NSViewRepresentable {
    let message: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ResponseScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 70))
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.importsGraphics = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.containerSize = NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 10, height: 9)
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textColor = .labelColor
        text.drawsBackground = false
        text.layoutManager?.allowsNonContiguousLayout = true
        text.setAccessibilityLabel(L10n.tr("完整测试结果，可选择和复制"))
        scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        text.setAccessibilityLabel(L10n.tr("完整测试结果，可选择和复制"))
        guard text.string != message else { return }
        text.string = message
        text.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
}
