import SwiftUI
import AppKit

/// Surface roles follow the observed reference, with independent light and dark values.
enum Palette {
    static let canvas = color(0xf4f4f6, 0x1a1a1e)
    static let sidebar = canvas
    static let surface = color(0xffffff, 0x232327)
    static let readonlyField = color(0xf9f9fb, 0x1f1f23)
    static let ink = color(0x1c1c21, 0xededf1)
    static let inkSecondary = color(0x4b4b53, 0xb9b9c1)
    static let muted = color(0x73737c, 0x9a9aa4)
    static let controlText = color(0x63636b, 0xa1a1aa)
    static let accent = color(0x4f46e5, 0xa5b4fc)
    static let accentForeground = color(0xffffff, 0x14142a)
    static let border = color(0xe3e3e8, 0x333339)
    static let lineSoft = color(0xececf0, 0x2c2c32)
    static let accentSoft = color(0xeeedfd, 0x2b2c47)
    static let selection = color(0xe7e7eb, 0x303036)
    static let hover = color(0xe9e9ee, 0x36363d)
    static let badgeBg = color(0xf1f1f4, 0x2d2d33)
    static let barTrack = badgeBg
    static let danger = color(0xd64545, 0xf28b82)
    static let dangerSoft = color(0xfbe9e9, 0x45272a)
    static let ok = color(0x189a58, 0x6fd99b)
    static let warn = color(0xb45309, 0xf2b544)
    private static func color(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

enum Typo {
    static let body = Font.system(size: 13)
    static let small = Font.system(size: 12)
    static let section = Font.system(size: 15, weight: .semibold)
    static let title = Font.system(size: 22, weight: .semibold)
    static let mono = Font.system(size: 12, design: .monospaced)
}

struct CardBox<Content: View>: View {
    var onDoubleClick: (() -> Void)?
    @ViewBuilder var content: Content
    init(onDoubleClick: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.onDoubleClick = onDoubleClick
        self.content = content()
    }
    var body: some View {
        content.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if let onDoubleClick {
                    RoundedRectangle(cornerRadius: 10).fill(Palette.surface)
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                        .onTapGesture(count: 2, perform: onDoubleClick)
                } else {
                    RoundedRectangle(cornerRadius: 10).fill(Palette.surface)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border).allowsHitTesting(false))
    }
}

struct QuietGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label.font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
            configuration.content.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(16)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border))
    }
}

struct QuietTabs: View {
    @Binding var selection: String
    let items: [(String, String)]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { index in
                Button { selection = items[index].0 } label: {
                    Text(items[index].1).font(.system(size: 12, weight: selection == items[index].0 ? .medium : .regular))
                        .foregroundStyle(selection == items[index].0 ? Palette.ink : Palette.controlText)
                        .padding(.horizontal, 13).frame(height: 26)
                        .background(selection == items[index].0 ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selection == items[index].0 ? Palette.border : .clear, lineWidth: 0.5))
                }.buttonStyle(.plain).accessibilityValue(selection == items[index].0 ? "已选择" : "")
            }
        }.padding(3).background(Palette.badgeBg, in: RoundedRectangle(cornerRadius: 8)).fixedSize()
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
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(key).font(Typo.small).foregroundStyle(Palette.muted).frame(width: 100, alignment: .leading)
            value.font(mono ? Typo.mono : Typo.body).foregroundStyle(Palette.inkSecondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 5)
    }
}
struct BadgeText: View {
    let text: String
    var locked = false
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Palette.controlText)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Palette.badgeBg, in: RoundedRectangle(cornerRadius: 4))
    }
}
struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true) }
}
enum ButtonKind { case plain, primary, danger, ghost }
struct QuietButtonStyle: ButtonStyle {
    var kind: ButtonKind = .plain
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Typo.small)
            .foregroundStyle(kind == .primary ? Palette.accentForeground : (kind == .danger ? Palette.danger : Palette.inkSecondary))
            .padding(.horizontal, kind == .ghost ? 7 : 10).frame(minHeight: 28)
            .background(background(configuration.isPressed), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(kind == .ghost ? .clear : (kind == .primary ? Palette.accent : Palette.border)))
            .opacity(enabled ? 1 : 0.42)
    }
    private func background(_ pressed: Bool) -> Color {
        if kind == .primary { return Palette.accent.opacity(pressed ? 0.8 : 1) }
        if pressed { return Palette.hover }
        return kind == .ghost ? .clear : Palette.surface
    }
}
extension View {
    func barButton(_ kind: ButtonKind = .plain) -> some View { buttonStyle(QuietButtonStyle(kind: kind)) }
    func fieldBox(invalid: Bool = false, readonly: Bool = false) -> some View {
        self.textFieldStyle(.plain).font(Typo.body).padding(.horizontal, 9).frame(minHeight: 29)
            .background(readonly ? Palette.readonlyField : Palette.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(invalid ? Palette.danger : Palette.border))
    }
}
func maskKey(_ key: String) -> String {
    key.isEmpty ? "未配置" : "已配置 · ••••" + (key.count > 4 ? String(key.suffix(4)) : "")
}
func formatCacheTime(_ epoch: Double?) -> String {
    guard let epoch, epoch > 0 else { return "尚未查询" }
    return Date(timeIntervalSince1970: epoch > 1e12 ? epoch / 1000 : epoch).formatted(.dateTime.month().day().hour().minute())
}
func formatResetAt(_ epoch: Int?) -> String? {
    guard let epoch else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(epoch)).formatted(.dateTime.month().day().hour().minute()) + " 重置"
}
