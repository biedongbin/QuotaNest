import Foundation

enum AccountSourceFilter: Hashable, Identifiable {
    case all
    case manual
    case imported(String)

    var id: String {
        switch self {
        case .all: return "all"
        case .manual: return "manual"
        case .imported(let source): return "source:" + source
        }
    }
    var label: String {
        switch self {
        case .all: return L10n.tr("全部来源")
        case .manual: return L10n.tr("自己创建")
        case .imported(let source):
            switch source {
            case "magpie": return "Magpie"
            case "cc-switch": return "cc-switch"
            case "cpamp": return "CPAMP"
            case "9router": return "9router"
            default: return source
            }
        }
    }
    func includes(_ manifest: ProviderManifest) -> Bool {
        self == .all || self == Self.origin(of: manifest)
    }
    static func origin(of manifest: ProviderManifest) -> Self {
        if let source = manifest.sourceReference?.source, !source.isEmpty { return .imported(normalized(source)) }
        if let origin = manifest.origin, !origin.isEmpty {
            return .imported(normalized(String(origin.split(separator: ":", maxSplits: 1).first ?? "")))
        }
        return .manual
    }
    private static func normalized(_ source: String) -> String {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "ccswitch" ? "cc-switch" : value
    }
}
