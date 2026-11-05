import Foundation
import Testing
@testable import QuotaNest

@MainActor
struct ProviderCapabilityPresentationTests {
    private func authQuotaManifest() -> ProviderManifest {
        ProviderManifest(name: "AuthCloud", label: "Auth Cloud", quotaMode: "script", quotaAuthModes: ["auth"],
                         credentialSource: ProviderCredentialSource(file: "~/.fixture/auth.json", tokenPath: "access_token"))
    }

    @Test func authOnlyQuotaDoesNotOfferAPIKeyOrModelCalls() {
        let capability = ProviderCapabilityPresentation(manifest: authQuotaManifest(), generic: false)
        #expect(capability.allowsAuth)
        #expect(!capability.allowsAPIKey)
        #expect(!capability.canCall(using: "auth"))
        #expect(!capability.canCall(using: "apikey"))
        #expect(capability.authenticationSummary == "授权文件")
        #expect(capability.capabilitySummary == "仅用量查询，模型调用与调度未接入")
        #expect(capability.authenticationIssue(for: "apikey")?.contains("改用授权文件") == true)
        #expect(capability.authenticationIssue(for: "local")?.contains("local") == true)
    }

    @Test func APIQuotaWithoutModelEndpointCanUseKeyButCannotCall() {
        let manifest = ProviderManifest(name: "Balance", label: "Balance", quotaMode: "script", quotaAuthModes: ["apikey"])
        let capability = ProviderCapabilityPresentation(manifest: manifest, generic: false)
        #expect(capability.allowsAPIKey)
        #expect(!capability.allowsAuth)
        #expect(!capability.canCall(using: "apikey"))
        #expect(capability.authenticationIssue(for: "auth") != nil)
        #expect(capability.authenticationSummary == "API Key")
    }

    @Test func callEndpointsGateEachAuthenticationModeIndependently() {
        var manifest = authQuotaManifest()
        manifest.refreshUrl = "https://api.example.test/v1/messages"
        let apiOnly = ProviderCapabilityPresentation(manifest: manifest, generic: false)
        #expect(apiOnly.allowsAPIKey)
        #expect(apiOnly.canCall(using: "apikey"))
        #expect(!apiOnly.canCall(using: "auth"))
        manifest.authCallUrl = "https://auth.example.test/v1/responses"
        manifest.authCallProtocol = "responses"
        let both = ProviderCapabilityPresentation(manifest: manifest, generic: false)
        #expect(both.canCall(using: "auth"))
        #expect(both.authenticationSummary == "API Key / 授权文件")
        manifest.authCallProtocol = "private-protocol"
        #expect(!ProviderCapabilityPresentation(manifest: manifest, generic: false).canCall(using: "auth"))
    }

    @Test func bothGenericTemplatesRemainSearchableAndAPIKeyCapable() {
        for id in ["generic-openai", "generic-anthropic"] {
            let choice = TemplateChoice(id: id, label: "通用 " + id, detail: "", tag: "API Key", authStyle: "apikey",
                                        manifest: nil, proto: nil)
            #expect(ProviderCapabilityPresentation.matches(choice, search: id.uppercased()))
            let capability = ProviderCapabilityPresentation(manifest: nil, generic: true)
            #expect(capability.allowsAPIKey)
            #expect(!capability.allowsAuth)
            #expect(capability.canCall(using: "apikey"))
        }
    }

    @Test func catalogSearchMatchesNameAndIDWithoutCaseAndHandlesNoMatches() {
        let choice = TemplateChoice(id: "auth-cloud", label: "Auth Cloud", detail: "", tag: "", authStyle: "auth",
                                    manifest: authQuotaManifest(), proto: nil)
        #expect(ProviderCapabilityPresentation.matches(choice, search: "  AUTH CLOUD  "))
        #expect(ProviderCapabilityPresentation.matches(choice, search: "AUTH-CLOUD"))
        #expect(ProviderCapabilityPresentation.matches(choice, search: "authcloud"))
        #expect(ProviderCapabilityPresentation.matches(choice, search: " \n "))
        #expect(!ProviderCapabilityPresentation.matches(choice, search: "missing-provider"))
    }

    @Test func balanceAmountHasNoResetPlaceholderOrPercentage() {
        for unit in ["USD", "CNY", "credits"] {
            let balance = QuotaMetric(id: 0, label: "余额/购买剩余", percentage: nil, amount: 12.5,
                                      limit: nil, unit: unit, period: "balance", resetsAt: nil)
            #expect(balance.resetDescription == nil)
            #expect(balance.percentage == nil)
            #expect(balance.value.contains(unit))
            #expect(!balance.value.contains("%"))
        }
    }

    @Test func cycleMetricsKeepPercentageAndUnknownResetSemantics() {
        let cycle = QuotaMetric(id: 0, label: "本月", percentage: 25, amount: 25, limit: 100,
                                unit: "credits", period: "monthly", resetsAt: nil)
        #expect(cycle.value == "25%")
        #expect(cycle.resetDescription == "重置时间未知")
        let balanceWithReset = QuotaMetric(id: 1, label: "购买剩余", percentage: nil, amount: 10, limit: nil,
                                          unit: "USD", period: "balance", resetsAt: 2_000_000_000)
        #expect(balanceWithReset.resetDescription != nil)
        #expect(balanceWithReset.resetDescription != "重置时间未知")
    }
}
