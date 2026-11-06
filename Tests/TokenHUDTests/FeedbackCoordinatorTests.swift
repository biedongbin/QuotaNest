import Testing
@testable import QuotaNest

@Suite @MainActor struct FeedbackCoordinatorTests {
    @Test func feedbackWithoutEitherCLINeedsNoInstallOrModelCall() {
        let model = FeedbackCoordinator(context: .init(area: .providerCatalog, stage: .catalog), tools: .init())
        model.title = "Please support a provider"
        model.problem = "The provider type is not in the catalog."
        model.prepare()
        #expect(model.body != nil)
        #expect(model.errorMessage == nil)
        #expect(!model.tools.ghAvailable && !model.tools.claudeAvailable)
        #expect(!model.canSend)
        #expect(!model.isBusy)
    }

    @Test func detectedSecretsCannotReachAReviewableDraft() {
        let model = FeedbackCoordinator(context: .init(area: .accountImport, source: .magpie, stage: .scan), tools: .init())
        model.title = "Import problem"
        let secret = "sk-" + String(repeating: "a", count: 24)
        model.problem = "The input contained " + secret
        model.prepare()
        #expect(model.body == nil)
        #expect(model.errorMessage != nil)
        #expect(model.errorMessage?.contains(secret) == false)
    }

    @Test func finalConfirmationIsRequiredAndEditingInvalidatesIt() {
        let model = FeedbackCoordinator(context: .init(area: .providerCatalog, stage: .catalog),
                                        tools: .init(ghPath: "/nonexistent/fake-gh"))
        model.title = "Catalog issue"
        model.problem = "The search result is empty."
        model.prepare()
        #expect(!model.canSend)
        model.acknowledged = true
        #expect(model.canSend)
        let marker = model.body?.split(separator: "\n").last
        model.edit()
        #expect(model.body == nil && !model.acknowledged)
        model.title = "Catalog issue revised"
        model.prepare()
        #expect(model.reviewedTitle == "Catalog issue revised")
        #expect(model.body?.split(separator: "\n").last == marker)
        #expect(!model.canSend)
    }
}
