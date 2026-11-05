import AppKit
import SwiftUI

/// Brand choices live in provider manifests; this loader does not guess brands from account names.
enum ProviderLogoAssets {
    private static let templates: [String: String] = {
        guard let directory = Bundle.appResources.resourceURL?.appendingPathComponent("providers") else { return [:] }
        return Dictionary(uniqueKeysWithValues: ProviderRegistry.scan(dir: directory).compactMap { provider in
            provider.manifest.icon.map { (provider.slug, $0) }
        })
    }()
    private static let images = NSCache<NSString, NSImage>()

    static func symbol(manifest: ProviderManifest?, slug: String? = nil, template: String? = nil) -> String {
        if let declared = manifest?.icon, isBrand(declared) { return declared }
        if let id = template ?? manifest?.template ?? slug, let declared = templates[id], isBrand(declared) {
            return declared
        }
        return manifest?.icon ?? "network"
    }

    static func isBrand(_ symbol: String) -> Bool {
        symbol.hasPrefix("logo:") || symbol.hasPrefix("logo-mono:")
    }

    static func image(for symbol: String) -> NSImage? {
        guard isBrand(symbol), let separator = symbol.firstIndex(of: ":") else { return nil }
        if let cached = images.object(forKey: symbol as NSString) { return cached }
        let name = String(symbol[symbol.index(after: separator)...])
        guard !name.isEmpty, name.unicodeScalars.allSatisfy({
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }) else { return nil }
        let bundle = Bundle.appResources
        let url = bundle.url(forResource: name, withExtension: "png", subdirectory: "ProviderLogos")
            ?? bundle.url(forResource: name, withExtension: "png")
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = symbol.hasPrefix("logo-mono:")
        images.setObject(image, forKey: symbol as NSString)
        return image
    }
}

struct ProviderLogo: View {
    var manifest: ProviderManifest? = nil
    var slug: String? = nil
    var template: String? = nil
    var size: CGFloat = 18

    var body: some View {
        let symbol = ProviderLogoAssets.symbol(manifest: manifest, slug: slug, template: template)
        Group {
            if let image = ProviderLogoAssets.image(for: symbol) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(image.isTemplate ? .template : .original)
                    .scaledToFit()
            } else {
                Image(systemName: ProviderLogoAssets.isBrand(symbol) ? "network" : symbol)
                    .resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
