import SwiftUI
import AppKit

/// System colors keep every surface consistent with the user's appearance and accent.
enum Palette {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let sidebar = Color(nsColor: .underPageBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let ink = Color.primary
    static let muted = Color.secondary
    static let accent = Color.accentColor
    static let border = Color(nsColor: .separatorColor)
    static let accentSoft = Color.accentColor.opacity(0.09)
    static let danger = Color.red
    static let dangerSoft = Color.red.opacity(0.08)
    static let ok = Color.green
    static let warn = Color.orange
    static let readonlyField = Color.primary.opacity(0.04)
    static let barTrack = Color.primary.opacity(0.08)
    static let badgeBg = Color.primary.opacity(0.05)
}

enum Typo {
    static let body = Font.body
    static let small = Font.callout
    static let section = Font.headline
    static let title = Font.title2.weight(.semibold)
    static let mono = Font.system(.callout, design: .monospaced)
}

struct CardBox<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border.opacity(0.5)))
    }
}

struct KeyValueRow<Content: View>: View {
    let key: String
    var mono = false
    @ViewBuilder var value: Content
    init(_ key: String, mono: Bool = false, @ViewBuilder value: () -> Content) {
        self.key = key; self.mono = mono; self.value = value()
    }
    var body: some View {
        LabeledContent(key) {
            value.font(mono ? Typo.mono : Typo.body)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 5)
    }
}

struct BadgeText: View {
    let text: String
    var locked = false
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Palette.badgeBg, in: Capsule())
    }
}
struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true) }
}
enum ButtonKind { case plain, primary, danger, ghost }
extension View {
    @ViewBuilder func barButton(_ kind: ButtonKind = .plain) -> some View {
        if kind == .primary { self.buttonStyle(.borderedProminent) }
        else { self.buttonStyle(.bordered) }
    }
    func fieldBox(invalid: Bool = false, readonly: Bool = false) -> some View {
        self.textFieldStyle(.roundedBorder)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(invalid ? Color.red : .clear))
    }
}
func maskKey(_ key: String) -> String {
    key.isEmpty ? "未配置" : "已配置 · ••••" + (key.count > 4 ? String(key.suffix(4)) : "")
}
func formatCacheTime(_ epoch: Double?) -> String {
    guard let epoch, epoch > 0 else { return "尚未查询" }
    let date = Date(timeIntervalSince1970: epoch > 1e12 ? epoch / 1000 : epoch)
    return date.formatted(.dateTime.month().day().hour().minute())
}
func formatResetAt(_ epoch: Int?) -> String? {
    guard let epoch else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(epoch)).formatted(.dateTime.month().day().hour().minute()) + " 重置"
}
