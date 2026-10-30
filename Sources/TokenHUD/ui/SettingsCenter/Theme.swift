import SwiftUI
import AppKit

// MARK: - 方案 C 配色 (浅色值锁定原型 docs/provider-manager-v2/prototypes/settings.html)

enum Palette {
    static let canvas = dyn(0xF2F4F8, 0x151A22)
    static let sidebar = dyn(0xE8EDF5, 0x1B2230)
    static let surface = dyn(0xFFFFFF, 0x222A38)
    static let ink = dyn(0x202D43, 0xE8ECF4)
    static let muted = dyn(0x53627A, 0x9AA7BD)
    static let accent = dyn(0x445DAA, 0x8FA5E8)
    static let border = dyn(0xCDD5E3, 0x38445A)
    static let accentSoft = dyn(0xEAEEF8, 0x2A3550)
    static let danger = dyn(0xA33B3B, 0xE08C8C)
    static let dangerSoft = dyn(0xFBEDED, 0x3A2525)
    static let ok = dyn(0x2F6B4F, 0x7FC4A0)
    static let warn = dyn(0x8A5A1E, 0xD8AE70)
    static let readonlyField = dyn(0xF5F7FA, 0x2A3242)
    static let barTrack = dyn(0xE3E8F1, 0x323C4E)
    static let badgeBg = dyn(0xF7F9FC, 0x2A3242)

    private static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return nsColor(isDark ? dark : light)
        })
    }

    private static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

enum Typo {
    static let body = Font.system(size: 13)
    /// P2-5: 正文最小字号 12 (FR-08.6, 原 11)
    static let small = Font.system(size: 12)
    static let section = Font.system(size: 16, weight: .semibold)
    static let title = Font.system(size: 24, weight: .semibold)
    static let mono = Font.system(size: 12, design: .monospaced)
}

// MARK: - 零件

/// 卡片容器: surface + 1pt border + 8pt 圆角
struct CardBox<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Palette.border, lineWidth: 1))
    }
}

/// 一行键值: 键固定 132pt, 值自适应换行
struct KeyValueRow<Content: View>: View {
    let key: String
    var mono = false
    @ViewBuilder var value: Content

    init(_ key: String, mono: Bool = false, @ViewBuilder value: () -> Content) {
        self.key = key
        self.mono = mono
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key).font(Typo.body).foregroundStyle(Palette.muted)
                .frame(width: 132, alignment: .leading)
            value
                .font(mono ? Typo.mono : Typo.body)
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.border).frame(height: 1)
        }
    }
}

struct BadgeText: View {
    let text: String
    var locked = false

    var body: some View {
        Text(text)
            .font(Typo.small)
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(locked ? Palette.readonlyField : Palette.badgeBg))
            .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 1))
    }
}

struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6)
    }
}

enum ButtonKind { case plain, primary, danger, ghost }

struct BarButtonStyle: ButtonStyle {
    var kind: ButtonKind = .plain
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(fg)
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(bg(pressed: configuration.isPressed)))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(kind == .ghost ? .clear : borderColor, lineWidth: 1))
            .opacity(enabled ? 1 : 0.45)
    }

    private var fg: Color {
        switch kind {
        case .primary: return .white
        case .danger: return Palette.danger
        default: return Palette.ink
        }
    }

    private var borderColor: Color {
        switch kind {
        case .primary: return Palette.accent
        case .danger: return Palette.border
        default: return Palette.border
        }
    }

    private func bg(pressed: Bool) -> Color {
        switch kind {
        case .primary: return pressed ? Palette.accent.opacity(0.82) : Palette.accent
        case .danger: return pressed ? Palette.dangerSoft : Palette.surface
        case .ghost: return .clear
        case .plain: return pressed ? Palette.accentSoft : Palette.surface
        }
    }
}

extension View {
    /// 输入框外观: 与 CardBox 同 radius; readonly 灰底; invalid 红框
    func fieldBox(invalid: Bool = false, readonly: Bool = false) -> some View {
        self
            .font(Typo.body)
            .foregroundStyle(readonly ? Palette.muted : Palette.ink)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(readonly ? Palette.readonlyField : Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(invalid ? Palette.danger : Palette.border, lineWidth: 1))
    }

    func barButton(_ kind: ButtonKind = .plain) -> some View {
        buttonStyle(BarButtonStyle(kind: kind))
    }
}

/// 密钥打码: 仅露末 4 位
func maskKey(_ key: String) -> String {
    if key.isEmpty { return "—" }
    if key.count <= 4 { return "••••" }
    return "••••" + String(key.suffix(4))
}

/// 时间戳 (ms 或 s) → "今天 14:02" / "MM-dd HH:mm"
func formatCacheTime(_ epoch: Double?) -> String {
    guard let epoch, epoch > 0 else { return "—" }
    let date = Date(timeIntervalSince1970: epoch > 1e12 ? epoch / 1000 : epoch)
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    if Calendar.current.isDateInToday(date) {
        f.dateFormat = "'今天' HH:mm"
    } else {
        f.dateFormat = "MM-dd HH:mm"
    }
    return f.string(from: date)
}

/// 重置时刻 → "15:00 重置" / "11-01 00:00 重置"; 无值 nil
func formatResetAt(_ epoch: Int?) -> String? {
    guard let epoch else { return nil }
    let date = Date(timeIntervalSince1970: TimeInterval(epoch))
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "MM-dd HH:mm"
    return f.string(from: date) + " 重置"
}
