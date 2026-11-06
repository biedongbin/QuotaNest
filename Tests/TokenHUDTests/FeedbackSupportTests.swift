import Foundation
import Testing
@testable import QuotaNest

@Suite
struct FeedbackSupportTests {
    @Test func diagnosticsOnlyEncodeBoundedAllowlistedValues() throws {
        let context = FeedbackContext(area: .accountImport, source: .ccSwitch, stage: .scan,
                                      templateID: "private-account-name")
        let event = SafeDiagnosticEvent(stage: .scan, errorCode: .invalidFormat, httpStatus: 999, count: -4)
        let diagnostic = FeedbackDiagnostics(appVersion: "1.2.3", build: "77f583f1234567890", osMajor: 14,
            architecture: .arm64, context: context, counts: .init(candidates: -1, imported: Int.max),
            safeEvents: Array(repeating: event, count: 25), dependencies: .init(ghAvailable: true))
        let encoded = try JSONEncoder().encode(diagnostic)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys) == ["appVersion", "build", "osMajor", "architecture", "area", "source", "stage",
                                    "templateID", "counts", "safeEvents", "dependencies"])
        #expect(diagnostic.templateID == "custom")
        #expect(diagnostic.build == "77f583f12345")
        #expect(diagnostic.counts.candidates == 0 && diagnostic.counts.imported == 100_000)
        #expect(diagnostic.safeEvents.count == 20 && diagnostic.safeEvents.allSatisfy { $0.httpStatus == nil && $0.count == 0 })
        #expect(!String(decoding: encoded, as: UTF8.self).contains("private-account-name"))
        #expect(try JSONDecoder().decode(FeedbackDiagnostics.self, from: encoded) == diagnostic)
        let unsafeMetadata = FeedbackDiagnostics(appVersion: "user@example.invalid", build: "/Users/person/private",
                                                context: context)
        #expect(unsafeMetadata.appVersion == "unknown" && unsafeMetadata.build == nil)
        #expect(FeedbackDiagnostics.bundledTemplateIDs.contains("gpt"))
        let bundled = FeedbackDiagnostics(context: .init(area: .providerCatalog, stage: .catalog, templateID: "gpt"))
        #expect(bundled.templateID == "gpt")
    }

    @Test func secretsAreBlockedWithoutEchoingTheirValues() throws {
        let specimens = [
            ["eyJhbGciOiJub25lIn0", "eyJzdWIiOiJmaXh0dXJlIn0", "dGVzdC1zaWduYXR1cmU"].joined(separator: "."),
            "sk-" + String(repeating: "test", count: 8),
            "Authorization: Bearer fake-credential",
            "api_key = \"fake-credential\"", "password: fake-password",
            "-----BEGIN " + "PRIVATE KEY-----\nfixture-data\n-----END " + "PRIVATE KEY-----",
            "/Users/somebody/config.json", "/home/somebody/config.json", "~/private.json",
            "person@example.invalid",
        ]
        for specimen in specimens {
            do {
                try FeedbackPrivacyGuard.validate(title: "Feedback", body: specimen)
                Issue.record("A known privacy pattern was accepted")
            } catch {
                #expect(error as? FeedbackSubmissionError == .privacyViolation)
                #expect(String(describing: error) == "privacyViolation")
            }
        }
        try FeedbackPrivacyGuard.validate(title: "导入问题", body: "扫描没有发现候选项。Error 403，已手动检查。")
    }

    @Test func reviewedDraftPreservesTextAndIdentityAcrossLanguagesAndFallbacks() throws {
        let id = try #require(UUID(uuidString: "A7F0FF56-4167-4840-8B3A-12467D65A14B"))
        let draft = FeedbackDraft(title: "中文 & ? # 标题", description: "原文 `quoted`\n第二行",
                                  steps: "1. 扫描\n2. 导入", diagnostics: .init(context: .init(area: .accountImport, stage: .scan)),
                                  requestID: id)
        let chinese = try draft.markdown(isEnglish: false)
        let english = try draft.markdown(isEnglish: true)
        #expect(chinese.contains("## 问题描述") && english.contains("## Description"))
        #expect(chinese.contains(draft.description) && english.contains(draft.description))
        #expect(chinese.contains(FeedbackRequestMarker.comment(id)) && english.contains(FeedbackRequestMarker.comment(id)))
        let plan = try FeedbackBrowserFallback.make(title: draft.title, body: chinese, requestID: id)
        let components = try #require(URLComponents(url: plan.url, resolvingAgainstBaseURL: false))
        #expect(components.host == "github.com" && components.path == "/biedongbin/QuotaNest/issues/new")
        #expect(components.queryItems?.first(where: { $0.name == "body" })?.value == chinese)
        #expect(!plan.requiresCopy)
        let long = try FeedbackBrowserFallback.make(title: draft.title, body: String(repeating: "中", count: 3_000), requestID: id)
        #expect(long.requiresCopy && long.url == FeedbackBrowserFallback.newIssueURL)
        #expect(throws: FeedbackSubmissionError.privacyViolation) {
            try FeedbackBrowserFallback.make(title: draft.title, body: "password=example", requestID: id)
        }
        #expect(throws: FeedbackSubmissionError.invalidDraft) {
            try FeedbackBrowserFallback.make(title: String(repeating: "x", count: 161), body: "Details", requestID: id)
        }
        #expect(throws: FeedbackSubmissionError.invalidDraft) {
            try FeedbackRequestMarker.reviewedBody(chinese, requestID: UUID())
        }
        #expect(throws: FeedbackSubmissionError.invalidDraft) {
            try FeedbackBrowserFallback.make(title: draft.title, body: String(repeating: "x", count: 16 * 1024), requestID: id)
        }
    }

    @Test func discoveryFindsGUIHomeToolsWithoutExecutingThemOrReadingConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feedback-tools-\(UUID().uuidString)")
        defer { removeFixture(root, prefix: "feedback-tools-") }
        let local = root.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let gh = local.appendingPathComponent("gh")
        try "#!/bin/sh\nexit 91\n".write(to: gh, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gh.path)
        let available = FeedbackToolAvailability.discover(home: root, environment: ["PATH": "relative/path:"])
        // A system gh may exist, but PATH discovery must never execute either binary.
        #expect(available.ghAvailable)
        let fromPath = FeedbackToolAvailability.discover(home: root, environment: ["PATH": local.path])
        #expect(fromPath.ghPath == gh.path)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".config").path))
        let diagnostic = FeedbackDiagnostics.snapshot(context: .init(area: .providerCatalog, stage: .catalog), tools: fromPath)
        let json = String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self)
        #expect(!json.contains(root.path) && diagnostic.dependencies.ghAvailable)
    }

    private func removeFixture(_ url: URL, prefix: String) {
        guard url.deletingLastPathComponent().resolvingSymlinksInPath() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath(),
              url.lastPathComponent.hasPrefix(prefix) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
