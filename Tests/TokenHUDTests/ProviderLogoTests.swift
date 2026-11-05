import AppKit
import Testing
@testable import TokenHUD

@Suite struct ProviderLogoTests {
    private func providers() throws -> [PluginProvider] {
        let directory = try #require(Bundle.appResources.resourceURL?.appendingPathComponent("providers"))
        return ProviderRegistry.scan(dir: directory)
    }

    @Test func allBuiltinTypesLoadTheirDeclaredBrandImages() throws {
        let templates = try providers()
        #expect(templates.count == 55)
        for provider in templates {
            let symbol = try #require(provider.manifest.icon)
            #expect(ProviderLogoAssets.isBrand(symbol), "Missing brand for \(provider.slug)")
            let image = try #require(ProviderLogoAssets.image(for: symbol), "Unreadable logo for \(provider.slug)")
            #expect(image.size.width > 0 && image.size.height > 0)
            #expect(image.tiffRepresentation != nil)
            #expect(image.isTemplate == symbol.hasPrefix("logo-mono:"))
        }
    }

    @Test func existingAccountsUseTemplateLogosWithoutRewritingTheirConfiguration() throws {
        let original = ProviderManifest(name: "My GLM account", label: "Personal", template: "glm", icon: "brain")
        let before = try JSONEncoder().encode(original)
        let symbol = ProviderLogoAssets.symbol(manifest: original, slug: "glm-personal-id")
        let template = try #require(try providers().first { $0.slug == "glm" })
        #expect(symbol == template.manifest.icon)
        #expect(ProviderLogoAssets.image(for: symbol) != nil)
        #expect(original.icon == "brain")
        #expect(try JSONDecoder().decode(ProviderManifest.self, from: before).icon == original.icon)
    }

    @Test func accountNamesDoNotChooseAProviderBrand() {
        let custom = ProviderManifest(name: "OpenAI Claude Gemini", label: "Custom", icon: "network")
        #expect(ProviderLogoAssets.symbol(manifest: custom, slug: "my-private-relay") == "network")
        #expect(!ProviderLogoAssets.isBrand(ProviderLogoAssets.symbol(manifest: nil)))
    }

    @Test func malformedAssetNamesCannotEscapeTheResourceBundle() {
        for symbol in ["logo:../secret", "logo:/tmp/secret", "logo:", "logo-mono:../../key"] {
            #expect(ProviderLogoAssets.image(for: symbol) == nil)
        }
    }
}
