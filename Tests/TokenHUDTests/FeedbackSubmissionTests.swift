import Foundation
import Darwin
import Testing
@testable import QuotaNest

@Suite(.serialized)
struct FeedbackSubmissionTests {
    @Test func successUsesFixedArgvPrivateFilesMinimalEnvironmentAndOneCreate() async throws {
        let fixture = try FakeFeedbackGH(mode: "success")
        defer { fixture.remove() }
        let service = FeedbackSubmissionService(home: fixture.root)
        let requestID = UUID()
        let title = "导入 & 特殊 ' \" $(echo untouched) `uname`"
        let body = "原文保留\n$(echo never) ; `uname` & < > \" '"
        async let first = service.submit(title: title, body: body, requestID: requestID, ghPath: fixture.executable.path)
        async let second = service.submit(title: title, body: body, requestID: requestID, ghPath: fixture.executable.path)
        let urls = try await [first, second]
        #expect(urls.map(\.absoluteString) == Array(repeating: "https://github.com/biedongbin/QuotaNest/issues/91", count: 2))
        #expect(try fixture.text("creates").split(separator: "\n").count == 1)
        let arguments = try fixture.text("arguments")
        #expect(arguments.contains("<--repo>\n<github.com/biedongbin/QuotaNest>"))
        #expect(arguments.contains("<--title>\n<\(title)>\n<--body-file>"))
        #expect(arguments.contains("<--hostname>\n<github.com>\n<--active>"))
        #expect(!arguments.contains(body))
        #expect(try fixture.text("body-recorded") == body + "\n\n" + FeedbackRequestMarker.comment(requestID))
        #expect(try fixture.text("permissions") == "600\n700\n")
        let environment = try fixture.text("environment").split(separator: "\n").map(String.init)
        #expect(environment.contains("GH_HOST=github.com"))
        #expect(environment.contains("GH_PROMPT_DISABLED=1"))
        #expect(environment.contains("HOME=\(fixture.root.path)"))
        #expect(!environment.contains { $0.hasPrefix("GH_DEBUG=") || $0.hasPrefix("GH_TOKEN=") || $0.hasPrefix("GH_EDITOR=") })
        let bodyPath = try fixture.text("body-path").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!FileManager.default.fileExists(atPath: bodyPath))
        let repeatURL = try await service.submit(title: title, body: body, requestID: requestID, ghPath: fixture.executable.path)
        let createCount = try fixture.text("creates").split(separator: "\n").count
        #expect(repeatURL == urls[0] && createCount == 1)
    }

    @Test func missingToolPrivacyAndAuthenticationFailBeforeCreatingAnything() async throws {
        let fixture = try FakeFeedbackGH(mode: "authfail")
        defer { fixture.remove() }
        let service = FeedbackSubmissionService(home: fixture.root)
        await expectError(.ghUnavailable) {
            _ = try await service.submit(title: "Feedback", body: "Details", requestID: UUID(),
                                         ghPath: fixture.root.appendingPathComponent("missing-gh").path)
        }
        await expectError(.privacyViolation) {
            _ = try await service.submit(title: "Feedback", body: "api_key=example", requestID: UUID(), ghPath: fixture.executable.path)
        }
        #expect(!fixture.exists("arguments"))
        await expectError(.authRequired) {
            _ = try await service.submit(title: "Feedback", body: "Details", requestID: UUID(), ghPath: fixture.executable.path)
        }
        #expect(!fixture.exists("created"))
        #expect(!(try fixture.text("arguments")).contains("<issue>"))
    }

    @Test func markerLookupWorksAcrossServiceInstancesAndRejectsForeignURLs() async throws {
        let fixture = try FakeFeedbackGH(mode: "success")
        defer { fixture.remove() }
        try fixture.write("list.json", "[{\"number\":91,\"url\":\"https://github.com/biedongbin/QuotaNest/issues/91\"}]")
        let requestID = UUID()
        let service = FeedbackSubmissionService(home: fixture.root)
        let url = try await service.submit(title: "Feedback", body: "Details", requestID: requestID, ghPath: fixture.executable.path)
        #expect(url.absoluteString.hasSuffix("/issues/91") && !fixture.exists("created"))
        #expect(try fixture.text("arguments").contains(FeedbackRequestMarker.searchTerm(requestID)))
        try fixture.write("list.json", "[{\"number\":91,\"url\":\"https://github.com/another/repo/issues/91\"}]")
        let restarted = FeedbackSubmissionService(home: fixture.root)
        await expectError(.outputInvalid) {
            _ = try await restarted.submit(title: "Feedback", body: "Details", requestID: requestID, ghPath: fixture.executable.path)
        }
        #expect(!fixture.exists("created"))
        for invalid in ["http://github.com/biedongbin/QuotaNest/issues/91", "https://evil.invalid/biedongbin/QuotaNest/issues/91",
                        "https://github.com/biedongbin/QuotaNest/issues/91?token=example",
                        "https://github.com/biedongbin/QuotaNest/issues/91\nextra output"] {
            #expect(FeedbackSubmissionService.issueURL(invalid) == nil)
        }
    }

    @Test func uncertainExitAndUntrustedStdioNeverLeakAndCannotCreateAgain() async throws {
        for mode in ["invalid", "failure", "flood"] {
            let fixture = try FakeFeedbackGH(mode: mode)
            defer { fixture.remove() }
            // These cases test create outcomes, not preflight startup latency under parallel test load.
            let service = FeedbackSubmissionService(timeout: 3, home: fixture.root)
            let requestID = UUID()
            await expectError(.submissionUnknown) {
                _ = try await service.submit(title: "Feedback", body: "Details", requestID: requestID, ghPath: fixture.executable.path)
            }
            await expectError(.submissionUnknown) {
                _ = try await service.submit(title: "Feedback", body: "Details", requestID: requestID, ghPath: fixture.executable.path)
            }
            #expect(try fixture.text("creates").split(separator: "\n").count == 1)
            #expect(try await service.reconcile(requestID: requestID, ghPath: fixture.executable.path) == nil)
            await expectError(.submissionUnknown) {
                _ = try await service.submit(title: "Feedback", body: "Details", requestID: requestID, ghPath: fixture.executable.path)
            }
        }
    }

    @Test func timeoutAndCancellationKillChildrenAndFreezeRequest() async throws {
        for cancel in [false, true] {
            let fixture = try FakeFeedbackGH(mode: "slow")
            defer { fixture.remove() }
            let processTimeout: TimeInterval = cancel ? 3 : 2
            let service = FeedbackSubmissionService(timeout: processTimeout, home: fixture.root)
            let id = UUID()
            let task = Task { try await service.submit(title: "Feedback", body: "Details", requestID: id, ghPath: fixture.executable.path) }
            try await waitForFile("child", in: fixture)
            // Start the completion bound only after proving create, rather than timing auth/list cold starts.
            let reachedCreate = Date()
            if cancel { task.cancel() }
            await expectError(.submissionUnknown) { _ = try await task.value }
            // One create timeout, one read-only recovery budget, and pipe/process cleanup.
            #expect(Date().timeIntervalSince(reachedCreate) < processTimeout * 2 + 2)
            await expectError(.submissionUnknown) {
                _ = try await service.submit(title: "Feedback", body: "Details", requestID: id, ghPath: fixture.executable.path)
            }
            #expect(try fixture.text("creates").split(separator: "\n").count == 1)
            let child = try #require(Int32(try fixture.text("child").trimmingCharacters(in: .whitespacesAndNewlines)))
            // A dead child's PID may briefly remain until the OS reaps it; allow that bounded interval.
            for _ in 0..<100 {
                if kill(child, 0) != 0 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(kill(child, 0) != 0)
        }
    }

    @Test func failedCreateCanRecoverOnlyThroughValidatedReadOnlyLookup() async throws {
        let fixture = try FakeFeedbackGH(mode: "recover")
        defer { fixture.remove() }
        let service = FeedbackSubmissionService(home: fixture.root)
        let id = UUID()
        let result = try await service.submit(title: "Feedback", body: "Details", requestID: id, ghPath: fixture.executable.path)
        #expect(result.absoluteString == "https://github.com/biedongbin/QuotaNest/issues/91")
        #expect(try fixture.text("creates").split(separator: "\n").count == 1)
        #expect(try await service.reconcile(requestID: id, ghPath: fixture.executable.path) == result)
    }

    private func expectError(_ expected: FeedbackSubmissionError, operation: () async throws -> Void) async {
        do { try await operation(); Issue.record("Expected a typed feedback failure") }
        catch {
            #expect(error as? FeedbackSubmissionError == expected)
            #expect(!String(describing: error).contains("FAKE_PRIVATE_STDIO"))
        }
    }

    private func waitForFile(_ name: String, in fixture: FakeFeedbackGH) async throws {
        // Auth and marker lookup each receive the same per-process budget before create can begin.
        for _ in 0..<800 {
            if fixture.exists(name) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Fake gh did not reach create before the test deadline")
        throw FeedbackSubmissionError.timedOut
    }
}

private struct FakeFeedbackGH {
    let root: URL
    let executable: URL

    init(mode: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("feedback-gh-test-\(UUID().uuidString)", isDirectory: true)
        executable = root.appendingPathComponent("fake-gh")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try write("mode", mode)
        try write("list.json", "[]")
        try Self.script.write(to: executable, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func text(_ name: String) throws -> String { try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) }
    func write(_ name: String, _ text: String) throws { try text.write(to: root.appendingPathComponent(name), atomically: false, encoding: .utf8) }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) }

    func remove() {
        guard root.deletingLastPathComponent().resolvingSymlinksInPath() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath(),
              root.lastPathComponent.hasPrefix("feedback-gh-test-") else { return }
        try? FileManager.default.removeItem(at: root)
    }

    private static let script = #"""
    #!/bin/sh
    mode=$(/bin/cat "$HOME/mode")
    printf '<%s>\n' "$@" >> "$HOME/arguments"
    /usr/bin/env > "$HOME/environment"
    case "$1 $2" in
      'auth status')
        if [ "$mode" = authfail ]; then printf 'FAKE_PRIVATE_STDIO\n' >&2; exit 1; fi
        exit 0
        ;;
      'issue list')
        if [ "$mode" = recover ] && [ -f "$HOME/created" ]; then
          printf '[{"number":91,"url":"https://github.com/biedongbin/QuotaNest/issues/91"}]\n'
        else
          /bin/cat "$HOME/list.json"
        fi
        exit 0
        ;;
      'issue create')
        printf 'create\n' >> "$HOME/creates"
        : > "$HOME/created"
        while [ "$#" -gt 0 ]; do
          if [ "$1" = --body-file ]; then shift; body_file=$1; break; fi
          shift
        done
        /bin/cp "$body_file" "$HOME/body-recorded"
        printf '%s\n' "$body_file" > "$HOME/body-path"
        /usr/bin/stat -f '%Lp' "$body_file" > "$HOME/permissions"
        /usr/bin/stat -f '%Lp' "${body_file%/*}" >> "$HOME/permissions"
        case "$mode" in
          slow)
            trap '' TERM
            /bin/sleep 30 &
            printf '%s\n' "$!" > "$HOME/child"
            wait
            ;;
          invalid) printf 'https://github.com/another/repo/issues/91\n'; exit 0 ;;
          failure|recover) printf 'FAKE_PRIVATE_STDIO password=private\n' >&2; exit 7 ;;
          flood) /usr/bin/head -c 70000 /dev/zero; exit 0 ;;
          *) printf 'https://github.com/biedongbin/QuotaNest/issues/91\n'; exit 0 ;;
        esac
        ;;
      *) exit 99 ;;
    esac
    """#
}
