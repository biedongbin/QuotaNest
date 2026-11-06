import Foundation
import Darwin
import Testing
@testable import QuotaNest

@Suite(.serialized)
struct FeedbackClaudeAssistantTests {
    private func input(_ problem: String = "Import fails after choosing a provider") throws -> Data {
        try JSONEncoder().encode(FeedbackClaudeBoundary.Input(schemaVersion: 1, problemDescription: problem,
            diagnostics: .init(appVersion: "1.2.3", osMajor: 15, architecture: .arm64,
                context: .init(area: .accountImport, source: .ccSwitch, stage: .scan))))
    }

    @Test func rejectsUnknownNestedFieldsAndNormalizesDTO() throws {
        let data = try input()
        #expect(throws: Never.self) { try FeedbackClaudeBoundary.validateInput(data) }
        for path in ["root", "diagnostics", "counts", "dependencies", "event"] {
            var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var diagnostics = try #require(object["diagnostics"] as? [String: Any])
            switch path {
            case "root": object["apiKey"] = "synthetic"
            case "diagnostics": diagnostics["rawLog"] = "synthetic"
            case "counts", "dependencies":
                var nested = try #require(diagnostics[path] as? [String: Any])
                nested["raw"] = "synthetic"
                diagnostics[path] = nested
            default: diagnostics["safeEvents"] = [["stage": "scan", "errorCode": "none", "count": 1, "raw": "synthetic"]]
            }
            object["diagnostics"] = diagnostics
            let invalid = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: FeedbackClaudeError.invalidInput) { try FeedbackClaudeBoundary.validateInput(invalid) }
        }
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var diagnostics = try #require(object["diagnostics"] as? [String: Any])
        diagnostics["appVersion"] = "unapproved source name"
        object["diagnostics"] = diagnostics
        let normalized = try FeedbackClaudeBoundary.validateInput(JSONSerialization.data(withJSONObject: object))
        #expect(!String(decoding: normalized, as: UTF8.self).contains("unapproved source name"))
    }

    @Test func rejectsUnsafeAndOversizedInputAndModelOutput() throws {
        let syntheticKey = "sk-" + "ant-" + String(repeating: "x", count: 24)
        let syntheticJWT = "eyJ" + String(repeating: "x", count: 8) + ".payload.signature"
        for text in [syntheticKey, "Authorization: Bearer synthetic", "alice@example.invalid",
                     "/Users/synthetic/private.txt", syntheticJWT, "hidden\u{001b}[31m"] {
            #expect(throws: FeedbackClaudeError.invalidInput) { try FeedbackClaudeBoundary.validateInput(input(text)) }
            let output = try JSONSerialization.data(withJSONObject: ["result": text])
            #expect(throws: FeedbackClaudeError.invalidOutput) { try FeedbackClaudeBoundary.result(from: output) }
        }
        #expect(throws: FeedbackClaudeError.invalidInput) { try FeedbackClaudeBoundary.validateInput(input(String(repeating: "a", count: 8_001))) }
        #expect(throws: FeedbackClaudeError.invalidOutput) { try FeedbackClaudeBoundary.result(from: Data("not-json".utf8)) }
        let oversized = try JSONSerialization.data(withJSONObject: ["result": String(repeating: "好", count: 3_000)])
        #expect(throws: FeedbackClaudeError.invalidOutput) { try FeedbackClaudeBoundary.result(from: oversized) }
        let metadata = try JSONSerialization.data(withJSONObject: ["result": "Safe draft", "session_id": "synthetic-session", "unknown": "synthetic-metadata"])
        #expect(try FeedbackClaudeBoundary.result(from: metadata) == "Safe draft")
    }

    @Test func nativeOnlyAndAuthenticationFailClosed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let wrapper = fixture.root.appendingPathComponent("wrapper")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        #expect(throws: FeedbackClaudeError.unsupportedIsolation) { try FeedbackClaudeExecution.nativeBinary(wrapper.path) }
        #expect(throws: FeedbackClaudeError.authenticationUnavailable) {
            try FeedbackClaudeExecution.execute(input: input(), cliPath: fixture.binary.path, run: .init(), environment: [:])
        }
    }

    @Test func wholeProcessSandboxDeniesPrivateReadsAndExternalWrites() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let result = try FeedbackClaudeExecution.execute(input: input(), cliPath: fixture.binary.path,
            run: .init(), environment: Fixture.environment)
        #expect(result == "Synthetic isolated draft")
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("escaped.txt").path))
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("private-canary"), encoding: .utf8) == "SYNTHETIC_PRIVATE_CANARY")
        #expect(try fixture.remainingJobs().isEmpty)
    }

    @Test func malformedAndExcessiveCLIOutputCannotEscape() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for mode in ["MODE_INVALID_JSON", "MODE_SECRET", "MODE_STDOUT_FLOOD", "MODE_STDERR_FLOOD"] {
            #expect(throws: FeedbackClaudeError.invalidOutput) {
                try FeedbackClaudeExecution.execute(input: input(mode), cliPath: fixture.binary.path,
                    run: .init(), environment: Fixture.environment)
            }
        }
        #expect(try fixture.remainingJobs().isEmpty)
    }

    @Test func timeoutAndCancellationReapProcessAndCleanJob() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let data = try input("MODE_TIMEOUT")
        let start = Date()
        let timeoutRun = FeedbackClaudeRun()
        #expect(throws: FeedbackClaudeError.timedOut) {
            try FeedbackClaudeExecution.execute(input: data, cliPath: fixture.binary.path,
                run: timeoutRun, environment: Fixture.environment, timeout: 0.2)
        }
        #expect(timeoutRun.finished)
        #expect(Date().timeIntervalSince(start) < 3)
        let cancelledRun = FeedbackClaudeRun()
        let task = Task.detached {
            try FeedbackClaudeExecution.execute(input: data, cliPath: fixture.binary.path,
                run: cancelledRun, environment: Fixture.environment)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        cancelledRun.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled process returned success")
        } catch {
            #expect(error as? FeedbackClaudeError == .cancelled)
        }
        #expect(cancelledRun.finished)
        #expect(try fixture.remainingJobs().isEmpty)
    }

    /// Only synthetic C fixtures are compiled/executed. The actual Claude CLI is never invoked.
    private struct Fixture {
        let root: URL
        let binary: URL
        let previousJobs: Set<String>
        static let environment = ["ANTHROPIC_API_KEY": "synthetic-auth-only-canary",
            "NODE_OPTIONS": "synthetic-forbidden", "HTTP_PROXY": "synthetic-forbidden",
            "ANTHROPIC_BASE_URL": "https://synthetic.invalid", "GH_TOKEN": "synthetic-forbidden"]

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("FeedbackClaudeTests-\(UUID().uuidString)")
            binary = root.appendingPathComponent("fake-claude")
            previousJobs = try Self.jobs()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data("SYNTHETIC_PRIVATE_CANARY".utf8).write(to: root.appendingPathComponent("private-canary"))
            let fakeConfig = root.appendingPathComponent(".claude")
            try FileManager.default.createDirectory(at: fakeConfig, withIntermediateDirectories: false)
            try Data("SYNTHETIC_CONFIG_CANARY".utf8).write(to: fakeConfig.appendingPathComponent("settings.json"))
            try Data("SYNTHETIC_MCP_CANARY".utf8).write(to: root.appendingPathComponent(".mcp.json"))
            let cPath = root.appendingPathComponent("fixture.c")
            let source = Self.source.replacingOccurrences(of: "FIXTURE_ROOT", with: root.path)
            try Data(source.utf8).write(to: cPath)
            let compiler = Process()
            compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            compiler.arguments = ["clang", cPath.path, "-o", binary.path]
            compiler.standardOutput = FileHandle.nullDevice
            compiler.standardError = FileHandle.nullDevice
            try compiler.run()
            compiler.waitUntilExit()
            guard compiler.terminationStatus == 0 else { throw FeedbackClaudeError.failed }
        }

        func remainingJobs() throws -> Set<String> { try Self.jobs().subtracting(previousJobs) }
        private static func jobs() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: "/private/tmp").filter { $0.hasPrefix("QuotaNest-feedback-") })
        }
        func remove() {
            let canonical = root.resolvingSymlinksInPath()
            guard canonical.deletingLastPathComponent() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath(),
                  canonical.lastPathComponent.hasPrefix("FeedbackClaudeTests-") else { return }
            try? FileManager.default.removeItem(at: canonical)
        }

        private static let source = #"""
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <unistd.h>
        #include <fcntl.h>
        #include <sys/stat.h>
        #include <errno.h>
        static int deny_read(const char *path) {
            int fd = open(path, O_RDONLY);
            if (fd >= 0) { close(fd); return 0; }
            return errno == EPERM || errno == EACCES;
        }
        int main(int argc, char **argv) {
            char input[16384] = {0};
            size_t n = fread(input, 1, sizeof(input)-1, stdin);
            if (!n || !strstr(input, "schemaVersion") || !strstr(input, "diagnostics")) return 10;
            if (getenv("NODE_OPTIONS") || getenv("HTTP_PROXY") || getenv("GH_TOKEN")) return 11;
            if (!getenv("ANTHROPIC_API_KEY") || strcmp(getenv("ANTHROPIC_API_KEY"), "synthetic-auth-only-canary") || strstr(input,"synthetic-auth-only-canary")) return 12;
            if (!getenv("ANTHROPIC_BASE_URL") || strcmp(getenv("ANTHROPIC_BASE_URL"), "https://api.anthropic.com")) return 13;
            const char *flags[] = {"--bare", "--disable-slash-commands", "--strict-mcp-config", "--no-session-persistence", "--no-chrome", "--max-turns", "--max-budget-usd", NULL};
            for (int i=0; flags[i]; i++) {
                int found = 0;
                for (int j=1; j<argc; j++) if (!strcmp(flags[i],argv[j])) found=1;
                if (!found) return 14;
            }
            int tools=0, prompts=0, mcp=0;
            for (int j=1; j<argc; j++) {
                if (strstr(argv[j], "dangerously") || strstr(argv[j], "synthetic-auth")) return 15;
                if (!strcmp(argv[j], "--tools") && j+1<argc && !strcmp(argv[j+1], "")) tools=1;
                if (!strcmp(argv[j], "--permission-prompts") && j+1<argc && !strcmp(argv[j+1], "none")) prompts=1;
                if (!strcmp(argv[j], "--mcp-config") && j+1<argc) {
                    char content[128] = {0}; FILE *f=fopen(argv[j+1],"r");
                    if (!f) return 16;
                    fread(content,1,sizeof(content)-1,f); fclose(f);
                    if (strcmp(content,"{\"mcpServers\":{}}")) return 17;
                    struct stat st; if (stat(argv[j+1],&st) || (st.st_mode & 0777)!=0600) return 18;
                    mcp=1;
                }
            }
            struct stat cwd; if (stat(".",&cwd) || (cwd.st_mode & 0777)!=0700) return 19;
            if (!tools || !prompts || !mcp) return 20;
            if (!deny_read("FIXTURE_ROOT/private-canary") || !deny_read("FIXTURE_ROOT/.claude/settings.json") || !deny_read("FIXTURE_ROOT/.mcp.json")) return 21;
            if (symlink("FIXTURE_ROOT/private-canary", "escape-link") || !deny_read("escape-link")) return 25;
            int escape=open("FIXTURE_ROOT/escaped.txt",O_CREAT|O_WRONLY,0600);
            if (escape>=0) { close(escape); return 22; }
            if (fork()>=0) return 23;
            if (strstr(input,"MODE_TIMEOUT")) { sleep(30); return 24; }
            if (strstr(input,"MODE_INVALID_JSON")) { puts("invalid-json"); return 0; }
            if (strstr(input,"MODE_SECRET")) { puts("{\"result\":\"Authorization: Bearer synthetic\"}"); return 0; }
            if (strstr(input,"MODE_STDOUT_FLOOD")) { for(int i=0;i<40000;i++) putchar('a'); return 0; }
            if (strstr(input,"MODE_STDERR_FLOOD")) { for(int i=0;i<10000;i++) fputc('a',stderr); fflush(stderr); sleep(1); return 0; }
            puts("{\"result\":\"Synthetic isolated draft\",\"session_id\":\"synthetic-session\"}");
            return 0;
        }
        """#
    }
}
