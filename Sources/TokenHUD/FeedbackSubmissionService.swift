import Foundation
import Darwin

/// Marker lookup reduces duplicates across launches but GitHub search is eventually consistent.
/// This is not an exactly-once delivery guarantee. Unknown requests must be reconciled, never retried automatically.
actor FeedbackSubmissionService {
    static let repository = "github.com/biedongbin/QuotaNest"
    private let timeout: TimeInterval
    private let home: URL
    private var inFlight: [UUID: Task<URL, Error>] = [:]
    private var knownURLs: [UUID: URL] = [:]
    private var uncertain: Set<UUID> = []

    init(timeout: TimeInterval = 20, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.timeout = timeout.isFinite ? min(30, max(0.05, timeout)) : 20
        self.home = home
    }

    func submit(title: String, body: String, requestID: UUID, ghPath: String) async throws -> URL {
        let reviewed = try FeedbackRequestMarker.reviewedBody(body, requestID: requestID)
        try FeedbackPrivacyGuard.validate(title: title, body: reviewed)
        if let url = knownURLs[requestID] { return url }
        if let task = inFlight[requestID] { return try await waiting(for: task) }
        guard !uncertain.contains(requestID) else { throw FeedbackSubmissionError.submissionUnknown }
        let task = Task { try await self.perform(title: title, body: reviewed, requestID: requestID, ghPath: ghPath) }
        inFlight[requestID] = task
        defer { inFlight[requestID] = nil }
        let url = try await waiting(for: task)
        knownURLs[requestID] = url
        return url
    }

    /// Called only after the user clicks Star. The GitHub PUT is idempotent.
    func starProject(ghPath: String) async throws {
        try checkExecutable(ghPath)
        let authentication = try await command(ghPath, ["auth", "status", "--hostname", "github.com", "--active"])
        guard authentication.exitCode == 0 else { throw FeedbackSubmissionError.authRequired }
        let result = try await command(ghPath, ["api", "--hostname", "github.com", "--method", "PUT",
                                               "user/starred/biedongbin/QuotaNest"])
        guard result.exitCode == 0 else { throw FeedbackSubmissionError.submissionFailed }
    }

    /// Read-only: even an empty search never clears the prohibition on retrying an unknown request.
    func reconcile(requestID: UUID, ghPath: String) async throws -> URL? {
        if let known = knownURLs[requestID] { return known }
        guard inFlight[requestID] == nil else { throw FeedbackSubmissionError.submissionUnknown }
        let url = try await lookup(requestID: requestID, ghPath: ghPath)
        if let url { knownURLs[requestID] = url }
        return url
    }

    private func waiting(for task: Task<URL, Error>) async throws -> URL {
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    private func perform(title: String, body: String, requestID: UUID, ghPath: String) async throws -> URL {
        try checkExecutable(ghPath)
        let authentication = try await command(ghPath, ["auth", "status", "--hostname", "github.com", "--active"])
        guard authentication.exitCode == 0 else { throw FeedbackSubmissionError.authRequired }
        if let existing = try await lookup(requestID: requestID, ghPath: ghPath) { return existing }
        guard !Task.isCancelled else { throw FeedbackSubmissionError.cancelled }
        let temporary = try FeedbackPrivateBody(body: body)
        defer { temporary.remove() }
        // Once create may have started, every ambiguous outcome is frozen until read-only reconciliation.
        uncertain.insert(requestID)
        do {
            let result = try await command(ghPath, ["issue", "create", "--repo", Self.repository,
                                                   "--title", title, "--body-file", temporary.file.path])
            if result.exitCode == 0, let url = Self.issueURL(String(data: result.stdout, encoding: .utf8)) {
                uncertain.remove(requestID)
                return url
            }
        } catch FeedbackSubmissionError.ghUnavailable {
            // The runner could not spawn the executable; no write was possible.
            uncertain.remove(requestID)
            throw FeedbackSubmissionError.ghUnavailable
        } catch {
            // Subprocess errors carry no raw output. Cancellation and timeouts still need reconciliation.
        }
        let environment = self.environment
        let timeout = min(self.timeout, 5)
        let recovered = await Task.detached { () -> URL? in
            do {
                return try await Self.lookup(requestID: requestID, ghPath: ghPath,
                                             environment: environment, timeout: timeout)
            } catch { return nil }
        }.value
        if let recovered {
            uncertain.remove(requestID)
            return recovered
        }
        throw FeedbackSubmissionError.submissionUnknown
    }

    private var environment: [String: String] {
        ["HOME": home.path, "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
         "GH_HOST": "github.com", "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1",
         "GH_PAGER": "cat", "PAGER": "cat", "NO_COLOR": "1", "TERM": "dumb"]
    }

    private func checkExecutable(_ path: String) throws {
        var directory: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &directory),
              !directory.boolValue, FileManager.default.isExecutableFile(atPath: path) else {
            throw FeedbackSubmissionError.ghUnavailable
        }
    }

    private func command(_ path: String, _ arguments: [String]) async throws -> FeedbackProcessResult {
        do {
            return try await FeedbackProcessRunner.run(path: path, arguments: arguments,
                                                       environment: environment, timeout: timeout)
        } catch is CancellationError { throw FeedbackSubmissionError.cancelled }
    }

    private func lookup(requestID: UUID, ghPath: String) async throws -> URL? {
        try checkExecutable(ghPath)
        return try await Self.lookup(requestID: requestID, ghPath: ghPath, environment: environment, timeout: timeout)
    }

    private struct Issue: Decodable { let number: Int; let url: String }

    private static func lookup(requestID: UUID, ghPath: String, environment: [String: String],
                               timeout: TimeInterval) async throws -> URL? {
        let result = try await FeedbackProcessRunner.run(path: ghPath, arguments: ["issue", "list", "--repo", repository,
            "--state", "all", "--search", "\"\(FeedbackRequestMarker.searchTerm(requestID))\" in:body",
            "--json", "number,url", "--limit", "20"], environment: environment, timeout: timeout)
        guard result.exitCode == 0 else { throw FeedbackSubmissionError.submissionFailed }
        let issues: [Issue]
        do { issues = try JSONDecoder().decode([Issue].self, from: result.stdout) }
        catch { throw FeedbackSubmissionError.outputInvalid }
        guard issues.count <= 20 else { throw FeedbackSubmissionError.outputInvalid }
        let urls = try issues.map { issue -> URL in
            guard issue.number > 0, let url = issueURL(issue.url),
                  url.lastPathComponent == String(issue.number) else { throw FeedbackSubmissionError.outputInvalid }
            return url
        }
        let unique = Set(urls)
        guard unique.count <= 1 else { throw FeedbackSubmissionError.submissionUnknown }
        return unique.first
    }

    static func issueURL(_ output: String?) -> URL? {
        guard let value = output?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.utf8.count <= 256, let components = URLComponents(string: value),
              components.scheme == "https", components.host == "github.com",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath == components.path,
              components.path.range(of: #"^/biedongbin/QuotaNest/issues/[1-9][0-9]{0,17}$"#,
                                    options: .regularExpression) != nil,
              let url = components.url, url.absoluteString == value else { return nil }
        return url
    }
}

private struct FeedbackPrivateBody {
    let directory: URL
    let file: URL

    init(body: String) throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        directory = base.appendingPathComponent("quotanest-feedback-\(UUID().uuidString)", isDirectory: true)
        file = directory.appendingPathComponent("body.md")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700])
            guard FileManager.default.createFile(atPath: file.path, contents: Data(body.utf8),
                                                  attributes: [.posixPermissions: 0o600]) else {
                throw FeedbackSubmissionError.submissionFailed
            }
        } catch {
            Self.remove(directory)
            throw FeedbackSubmissionError.submissionFailed
        }
    }

    func remove() { Self.remove(directory) }

    private static func remove(_ directory: URL) {
        // Only this newly created, resolved direct child of the temporary directory is removable.
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        guard directory.deletingLastPathComponent() == base,
              directory.lastPathComponent.hasPrefix("quotanest-feedback-") else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct FeedbackProcessResult: Sendable {
    let exitCode: Int32
    let stdout: Data
}

private enum FeedbackProcessRunner {
    static func run(path: String, arguments: [String], environment: [String: String],
                    timeout: TimeInterval) async throws -> FeedbackProcessResult {
        let execution = FeedbackProcessExecution()
        return try await withTaskCancellationHandler(operation: {
            guard !Task.isCancelled else { throw FeedbackSubmissionError.cancelled }
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try execution.run(path: path, arguments: arguments,
                                                                         environment: environment, timeout: timeout) })
                }
            }
        }, onCancel: { execution.cancel() })
    }
}

/// All state shared by cancellation, pipe readers, and the worker is protected by lock.
private final class FeedbackProcessExecution: @unchecked Sendable {
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var process: Process?
    private var stopped: FeedbackSubmissionError?
    private var stdout = Data()
    private var outputBytes = 0
    private static let maximumOutputBytes = 64 * 1024

    func cancel() { stop(.cancelled) }

    func run(path: String, arguments: [String], environment: [String: String],
             timeout: TimeInterval) throws -> FeedbackProcessResult {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { [finished] _ in finished.signal() }
        lock.lock()
        if let stopped { lock.unlock(); throw stopped }
        self.process = process
        do { try process.run() }
        catch { self.process = nil; lock.unlock(); throw FeedbackSubmissionError.ghUnavailable }
        lock.unlock()
        let readers = DispatchGroup()
        read(output.fileHandleForReading, keep: true, group: readers)
        read(errors.fileHandleForReading, keep: false, group: readers)
        if finished.wait(timeout: .now() + timeout) == .timedOut { stop(.timedOut) }
        // NSTask starts its own process group on macOS. Kill remaining descendants even after a normal exit.
        terminateGroup(process)
        if process.isRunning { _ = finished.wait(timeout: .now() + 1) }
        let drained = readers.wait(timeout: .now() + 1) == .success
        lock.lock()
        self.process = nil
        let failure = stopped
        let data = stdout
        lock.unlock()
        guard drained, !process.isRunning else { throw failure ?? FeedbackSubmissionError.timedOut }
        if let failure { throw failure }
        return FeedbackProcessResult(exitCode: process.terminationStatus, stdout: data)
    }

    private func read(_ handle: FileHandle, keep: Bool, group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { try? handle.close(); group.leave() }
            do {
                while let chunk = try handle.read(upToCount: 4_096), !chunk.isEmpty {
                    lock.lock()
                    outputBytes += chunk.count
                    let overflow = outputBytes > Self.maximumOutputBytes
                    if keep && !overflow { stdout.append(chunk) }
                    lock.unlock()
                    if overflow { stop(.outputInvalid) }
                }
            } catch { stop(.outputInvalid) }
        }
    }

    private func stop(_ reason: FeedbackSubmissionError) {
        lock.lock()
        if stopped == nil { stopped = reason }
        let running = process
        lock.unlock()
        if let running { terminateGroup(running) }
        finished.signal()
    }

    private func terminateGroup(_ process: Process) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        // Keep the original group ID even when its leader has exited and only children remain.
        // Foundation's macOS Process creates this group during spawn; it cannot be our own group.
        guard pid != getpgrp() else { return }
        _ = kill(-pid, SIGKILL)
        if process.isRunning { _ = kill(pid, SIGKILL) }
    }
}
