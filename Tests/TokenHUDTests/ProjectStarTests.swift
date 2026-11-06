import Foundation
import Testing
@testable import QuotaNest

@Suite(.serialized) struct ProjectStarTests {
    @Test func starUsesTheFixedIdempotentGitHubEndpoint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quotanest-star-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("gh")
        let calls = root.appendingPathComponent("calls")
        let script = """
        #!/bin/sh
        if [ "$1" = auth ]; then exit 0; fi
        test "$GH_HOST" = github.com || exit 2
        test "$*" = 'api --hostname github.com --method PUT user/starred/biedongbin/QuotaNest' || exit 3
        printf 'PUT\\n' >> '\(calls.path)'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let service = FeedbackSubmissionService(timeout: 3, home: root)
        try await service.starProject(ghPath: executable.path)
        #expect(try String(contentsOf: calls, encoding: .utf8) == "PUT\n")
    }

    @Test func missingToolOrAuthenticationDoesNotAttemptStar() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quotanest-star-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = FeedbackSubmissionService(timeout: 3, home: root)
        await #expect(throws: FeedbackSubmissionError.ghUnavailable) {
            try await service.starProject(ghPath: root.appendingPathComponent("missing").path)
        }
        let executable = root.appendingPathComponent("gh")
        let writes = root.appendingPathComponent("unexpected-star")
        let script = """
        #!/bin/sh
        if [ "$1" = auth ]; then exit 1; fi
        touch '\(writes.path)'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        await #expect(throws: FeedbackSubmissionError.authRequired) { try await service.starProject(ghPath: executable.path) }
        #expect(!FileManager.default.fileExists(atPath: writes.path))
    }
}
