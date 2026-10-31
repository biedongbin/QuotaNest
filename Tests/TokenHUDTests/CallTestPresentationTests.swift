import Foundation
import Testing
@testable import TokenHUD

@Suite(.serialized)
@MainActor
struct CallTestPresentationTests {
    private func fixture(confirm: ((CallTestConfirmation) -> Bool)? = nil,
                         execute: @escaping (ProviderConfig) async -> String?) throws -> (SettingsModel, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenhud-confirmation-\(UUID().uuidString)")
        let hud = root.appendingPathComponent("hud")
        let providers = root.appendingPathComponent("providers")
        try FileManager.default.createDirectory(at: hud, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        let auth = hud.appendingPathComponent(".sample-usage-auth.json")
        let manifest = ProviderManifest(name: "Sample", label: "Sample", authFile: auth.path,
            refreshUrl: "https://api.example.test/v1/chat/completions", refreshProtocol: "openai",
            refreshHeader: "X-Fixture-Key: <key>", quotaMode: "none")
        try PluginGenerator.writePlugin(slug: "sample", manifest: manifest, script: "exit 1", into: providers)
        var config = ProviderConfig()
        config.apiBaseURL = "https://api.example.test/v1"
        config.refreshUrl = "https://api.example.test/v1/chat/completions"
        config.refreshKey = "fixture-private-call-key"
        config.testModel = "fixture-model"
        try ProviderConfigStore.write(config, manifest: manifest, to: auth)
        let suite = "tokenhud.confirmation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = root.appendingPathComponent("settings.json")
        try Data("{}".utf8).write(to: settings)
        let engine = DataEngine(hudDir: hud, bundleProvidersDir: nil, userProvidersDir: providers,
                                runner: ProviderRunner(nodePath: nil, logDir: hud), defaults: defaults, settingsURL: settings)
        engine.reloadRegistry()
        let model = SettingsModel(engine: engine, hudDir: hud, userDir: providers, settingsURL: settings,
                                  bundleDir: nil, defaults: defaults, confirmDiscardChanges: { true },
                                  confirmTestCall: confirm, executeTestCall: execute)
        try #require(model.selectAccount("sample", tab: .config))
        return (model, root, auth)
    }

    @Test func pendingConfirmationDoesNotExecuteAndCancelClearsIt() throws {
        var calls = 0
        let (model, root, _) = try fixture { _ in calls += 1; return "✓ fixture" }
        defer { try? FileManager.default.removeItem(at: root) }
        model.testCall("sample")
        let first = try #require(model.pendingTestConfirmation)
        #expect(first.model == "fixture-model")
        #expect(first.target == "https://api.example.test/v1/chat/completions")
        #expect(calls == 0)
        #expect(model.callRunning.isEmpty)
        model.testCall("sample")
        #expect(model.pendingTestConfirmation?.id == first.id)
        model.cancelPendingTestCall()
        #expect(model.pendingTestConfirmation == nil)
        #expect(!model.isTestingCurrentConfig)
        model.confirmPendingTestCall()
        #expect(calls == 0)
    }

    @Test func sheetConfirmationExecutesTheDisplayedSnapshotOnlyOnce() async throws {
        var sent: [ProviderConfig] = []
        let (model, root, auth) = try fixture { config in sent.append(config); return "✓ fixture" }
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: auth)
        model.startEdit()
        model.draft?.values.model = "clicked-model"
        let values = try #require(model.draft?.values)
        let expected = model.callConfigForDraft(values)
        model.testCallDraft(values: values)
        #expect(model.isTestingCurrentConfig)
        model.save()
        #expect(model.draft != nil)
        #expect(try Data(contentsOf: auth) == original)
        model.draft?.values.model = "later-input"
        model.confirmPendingTestCall()
        model.confirmPendingTestCall()
        for _ in 0..<100 where !model.callRunning.isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(sent.count == 1)
        #expect(sent.first?.testModel == "clicked-model")
        #expect(sent.first?.refreshUrl == expected.refreshUrl)
        #expect(sent.first?.refreshKey == expected.refreshKey)
        #expect(sent.first?.refreshHeader == expected.refreshHeader)
        #expect(model.pendingTestConfirmation == nil)
        #expect(model.draft?.values.model == "later-input")
        #expect(try Data(contentsOf: auth) == original)
    }

    @Test func longFailureRetainsItsTailAndRedactsTheCallKey() async throws {
        let tail = "END-OF-FULL-SERVER-ERROR"
        let longBody = String(repeating: "error detail line\n", count: 600)
        let (model, root, _) = try fixture(confirm: { _ in true }) { config in
            "HTTP 500: " + longBody + config.refreshKey + "\n" + tail
        }
        defer { try? FileManager.default.removeItem(at: root) }
        model.testCall("sample")
        for _ in 0..<100 where !model.callRunning.isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
        let result = try #require(model.callTestResult(for: "sample"))
        #expect(result.message.hasSuffix(tail))
        #expect(!result.message.contains("fixture-private-call-key"))
        #expect(result.message.contains("[已隐藏]"))
        #expect((model.toast?.text.count ?? 0) < 100)
    }

    @Test func errorFormatterPreservesFullBodyBelowItsExplicitLimit() {
        let body = String(repeating: "error details\n", count: 400) + "TAIL-REMAINS"
        #expect(RefreshTrigger.responseMessage(statusCode: 400, body: Data(body.utf8)) == "HTTP 400: " + body)
        #expect(RefreshTrigger.responseMessage(statusCode: 200, body: Data()) == RefreshTrigger.emptyBodyMessage)
    }

    @Test func responseLimitRedactsCredentialsBeforeCuttingTheirBytes() {
        let key = "private-fixture-call-key-at-boundary"
        let body = String(repeating: "A", count: RefreshTrigger.maximumResponseBodyBytes - 4) + key + "tail"
        let message = RefreshTrigger.responseMessage(statusCode: 401, body: Data(body.utf8), redacting: [key])
        #expect(!message.contains("priv"))
        #expect(message.contains("响应超过显示上限"))
    }

    @Test func oversizedResponseDisplaysAnExplicitLimitNotice() {
        let data = Data(repeating: 65, count: RefreshTrigger.maximumResponseBodyBytes + 128)
        let message = RefreshTrigger.responseMessage(statusCode: 502, body: data)
        #expect(message.contains("响应超过显示上限"))
        #expect(message.contains("原始响应 \(data.count) 字节"))
        #expect(message.contains("后续内容未显示"))
    }
}
