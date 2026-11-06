import Foundation
import Darwin

enum FeedbackArea: String, Codable, Sendable {
    case providerCatalog, accountImport
}

enum FeedbackSource: String, Codable, Sendable {
    case nineRouter, ccSwitch, cpamp, magpie
}

enum FeedbackStage: String, Codable, Sendable {
    case catalog, scan, importApply
}

struct FeedbackContext: Equatable, Sendable {
    let area: FeedbackArea
    let source: FeedbackSource?
    let stage: FeedbackStage
    let templateID: String?

    init(area: FeedbackArea, source: FeedbackSource? = nil, stage: FeedbackStage, templateID: String? = nil) {
        self.area = area
        self.source = source
        self.stage = stage
        self.templateID = templateID
    }
}

struct FeedbackCounts: Codable, Equatable, Sendable {
    let candidates: Int
    let imported: Int
    let skipped: Int
    let failed: Int

    init(candidates: Int = 0, imported: Int = 0, skipped: Int = 0, failed: Int = 0) {
        self.candidates = Self.bounded(candidates)
        self.imported = Self.bounded(imported)
        self.skipped = Self.bounded(skipped)
        self.failed = Self.bounded(failed)
    }

    private static func bounded(_ value: Int) -> Int { min(100_000, max(0, value)) }

    private enum CodingKeys: String, CodingKey { case candidates, imported, skipped, failed }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(candidates: try values.decode(Int.self, forKey: .candidates),
                  imported: try values.decode(Int.self, forKey: .imported),
                  skipped: try values.decode(Int.self, forKey: .skipped),
                  failed: try values.decode(Int.self, forKey: .failed))
    }
}

struct SafeDiagnosticEvent: Codable, Equatable, Sendable {
    enum ErrorCode: String, Codable, Sendable {
        case none, unavailable, unsupported, invalidFormat, permissionDenied, authenticationRequired, network, other
    }
    enum DurationBucket: String, Codable, Sendable {
        case underOneSecond, oneToFiveSeconds, fiveToTwentySeconds, overTwentySeconds
    }

    let stage: FeedbackStage
    let source: FeedbackSource?
    let errorCode: ErrorCode
    let httpStatus: Int?
    let durationBucket: DurationBucket?
    let count: Int

    init(stage: FeedbackStage, source: FeedbackSource? = nil, errorCode: ErrorCode = .none,
         httpStatus: Int? = nil, durationBucket: DurationBucket? = nil, count: Int = 1) {
        self.stage = stage
        self.source = source
        self.errorCode = errorCode
        self.httpStatus = httpStatus.flatMap { (100...599).contains($0) ? $0 : nil }
        self.durationBucket = durationBucket
        self.count = min(100_000, max(0, count))
    }

    private enum CodingKeys: String, CodingKey { case stage, source, errorCode, httpStatus, durationBucket, count }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(stage: try values.decode(FeedbackStage.self, forKey: .stage),
                  source: try values.decodeIfPresent(FeedbackSource.self, forKey: .source),
                  errorCode: try values.decode(ErrorCode.self, forKey: .errorCode),
                  httpStatus: try values.decodeIfPresent(Int.self, forKey: .httpStatus),
                  durationBucket: try values.decodeIfPresent(DurationBucket.self, forKey: .durationBucket),
                  count: try values.decode(Int.self, forKey: .count))
    }
}

struct FeedbackDependencyAvailability: Codable, Equatable, Sendable {
    let ghAvailable: Bool
    let claudeAvailable: Bool

    init(ghAvailable: Bool = false, claudeAvailable: Bool = false) {
        self.ghAvailable = ghAvailable
        self.claudeAvailable = claudeAvailable
    }
}

/// A snapshot of allowlisted scalar values. It never reads accounts, sources, logs, or credentials.
struct FeedbackDiagnostics: Codable, Equatable, Sendable {
    enum Architecture: String, Codable, Sendable { case arm64, x86_64, unknown }

    let appVersion: String
    let build: String?
    let osMajor: Int
    let architecture: Architecture
    let area: FeedbackArea
    let source: FeedbackSource?
    let stage: FeedbackStage
    let templateID: String?
    let counts: FeedbackCounts
    let safeEvents: [SafeDiagnosticEvent]
    let dependencies: FeedbackDependencyAvailability

    init(appVersion: String = "unknown", build: String? = nil, osMajor: Int = 0,
         architecture: Architecture = .unknown, context: FeedbackContext,
         counts: FeedbackCounts = .init(), safeEvents: [SafeDiagnosticEvent] = [],
         dependencies: FeedbackDependencyAvailability = .init()) {
        self.appVersion = Self.matches(appVersion, #"^[0-9]{1,4}(\.[0-9]{1,4}){0,3}$"#) ? appVersion : "unknown"
        self.build = build.flatMap { Self.matches($0, #"^[a-fA-F0-9]{7,40}$"#) ? String($0.prefix(12)).lowercased() : nil }
        self.osMajor = min(100, max(0, osMajor))
        self.architecture = architecture
        self.area = context.area
        self.source = context.source
        self.stage = context.stage
        self.templateID = context.templateID.map { Self.bundledTemplateIDs.contains($0) ? $0 : "custom" }
        self.counts = counts
        self.safeEvents = Array(safeEvents.suffix(20))
        self.dependencies = dependencies
    }

    static func snapshot(context: FeedbackContext, counts: FeedbackCounts = .init(),
                         tools: FeedbackToolAvailability = .init(), safeEvents: [SafeDiagnosticEvent] = [],
                         bundle: Bundle = .main) -> Self {
        #if arch(arm64)
        let architecture = Architecture.arm64
        #elseif arch(x86_64)
        let architecture = Architecture.x86_64
        #else
        let architecture = Architecture.unknown
        #endif
        return Self(appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                    build: bundle.object(forInfoDictionaryKey: "QuotaNestSourceRevision") as? String,
                    osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                    architecture: architecture, context: context, counts: counts, safeEvents: safeEvents,
                    dependencies: .init(ghAvailable: tools.ghPath != nil, claudeAvailable: tools.claudePath != nil))
    }

    // Only names of packaged resources are inspected; manifests and external directories are never loaded.
    static let bundledTemplateIDs: Set<String> = {
        guard let root = Bundle.appResources.resourceURL?.appendingPathComponent("providers", isDirectory: true),
              let entries = try? FileManager.default.contentsOfDirectory(at: root,
                  includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return [] }
        return Set(entries.compactMap { entry in
            guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  matches(entry.lastPathComponent, #"^[a-z0-9][a-z0-9-]{0,63}$"#) else { return nil }
            return entry.lastPathComponent
        })
    }()

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex
    }

    private enum CodingKeys: String, CodingKey {
        case appVersion, build, osMajor, architecture, area, source, stage, templateID, counts, safeEvents, dependencies
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let context = FeedbackContext(area: try values.decode(FeedbackArea.self, forKey: .area),
                                      source: try values.decodeIfPresent(FeedbackSource.self, forKey: .source),
                                      stage: try values.decode(FeedbackStage.self, forKey: .stage),
                                      templateID: try values.decodeIfPresent(String.self, forKey: .templateID))
        self.init(appVersion: try values.decode(String.self, forKey: .appVersion),
                  build: try values.decodeIfPresent(String.self, forKey: .build),
                  osMajor: try values.decode(Int.self, forKey: .osMajor),
                  architecture: try values.decode(Architecture.self, forKey: .architecture), context: context,
                  counts: try values.decode(FeedbackCounts.self, forKey: .counts),
                  safeEvents: try values.decode([SafeDiagnosticEvent].self, forKey: .safeEvents),
                  dependencies: try values.decode(FeedbackDependencyAvailability.self, forKey: .dependencies))
    }
}

enum FeedbackSubmissionError: String, Error, Equatable, Sendable {
    case ghUnavailable, authRequired, timedOut, cancelled, submissionUnknown
    case submissionFailed, outputInvalid, privacyViolation, invalidDraft
}

/// Detection is an aid to review, not a guarantee that arbitrary secrets can be recognized.
/// Errors intentionally carry no matching text, subprocess output, or local paths.
enum FeedbackPrivacyGuard {
    static let maximumTitleCharacters = 160
    static let maximumTitleBytes = 640
    static let maximumBodyBytes = 16 * 1024

    private static let patterns = [
        #"\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#,
        #"\bsk-[A-Za-z0-9_-]{12,}"#,
        #"\b(?:gh[pousr]_[A-Za-z0-9_]{12,}|github_pat_[A-Za-z0-9_]{12,})"#,
        #"(?i)\bauthorization\s*[:=]?\s*[\"']?bearer\s+\S+"#,
        #"(?i)\b(?:password|passwd|api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|cookie)\s*[\"']?\s*[:=]\s*[\"']?[^\s\"']+"#,
        #"-----BEGIN (?:[A-Z0-9]+ )?PRIVATE KEY-----"#,
        #"(?i)(?:/Users/|/home/|[A-Z]:[\\/]Users[\\/])[^\s/\\]+"#,
        #"(?:^|[\s\"'`(])~/[^\s]+"#,
        #"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+"#,
        #"(?i)https?://[^\s/]+:[^\s/]+@"#,
    ]

    static func validate(title: String, body: String) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= maximumTitleCharacters, title.utf8.count <= maximumTitleBytes,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              body.utf8.count <= maximumBodyBytes,
              !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !body.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t"
              }) else { throw FeedbackSubmissionError.invalidDraft }
        try validateText(title)
        try validateText(body)
    }

    static func validateText(_ text: String) throws {
        guard !patterns.contains(where: { text.range(of: $0, options: .regularExpression) != nil }) else {
            throw FeedbackSubmissionError.privacyViolation
        }
    }
}

struct FeedbackDraft: Equatable, Sendable {
    var title: String
    var description: String
    var steps: String
    let diagnostics: FeedbackDiagnostics
    let requestID: UUID

    init(title: String, description: String, steps: String, diagnostics: FeedbackDiagnostics, requestID: UUID = UUID()) {
        self.title = title
        self.description = description
        self.steps = steps
        self.diagnostics = diagnostics
        self.requestID = requestID
    }

    func markdown(isEnglish: Bool) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(diagnostics)
        guard let diagnosticsJSON = String(data: encoded, encoding: .utf8) else {
            throw FeedbackSubmissionError.invalidDraft
        }
        let body = """
        ## \(isEnglish ? "Description" : "问题描述")

        \(description)

        ## \(isEnglish ? "Steps to reproduce" : "复现步骤")

        \(steps)

        ## \(isEnglish ? "Reviewed diagnostics" : "已审阅的诊断摘要")

        ```json
        \(diagnosticsJSON)
        ```

        \(FeedbackRequestMarker.comment(requestID))
        """
        try FeedbackPrivacyGuard.validate(title: title, body: body)
        return try FeedbackRequestMarker.reviewedBody(body, requestID: requestID)
    }
}

enum FeedbackRequestMarker {
    static func searchTerm(_ requestID: UUID) -> String { "QuotaNest-feedback:\(requestID.uuidString.lowercased())" }
    static func comment(_ requestID: UUID) -> String { "<!-- \(searchTerm(requestID)) -->" }

    static func reviewedBody(_ body: String, requestID: UUID) throws -> String {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              body.utf8.count <= FeedbackPrivacyGuard.maximumBodyBytes else {
            throw FeedbackSubmissionError.invalidDraft
        }
        let marker = comment(requestID)
        let occurrences = body.components(separatedBy: "QuotaNest-feedback:").count - 1
        guard occurrences == 0 || (occurrences == 1 && body.contains(marker)) else {
            throw FeedbackSubmissionError.invalidDraft
        }
        return occurrences == 0 ? body + "\n\n" + marker : body
    }
}

struct FeedbackToolAvailability: Equatable, Sendable {
    let ghPath: String?
    let claudePath: String?
    var ghAvailable: Bool { ghPath != nil }
    var claudeAvailable: Bool { claudePath != nil }

    init(ghPath: String? = nil, claudePath: String? = nil) {
        self.ghPath = ghPath
        self.claudePath = claudePath
    }

    static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                         environment: [String: String]? = nil) -> Self {
        let runtimePath = environment.map { $0["PATH"] ?? "" }
            ?? getenv("PATH").map { String(cString: $0) } ?? ""
        let inherited = runtimePath.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        let directories = inherited + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                                      home.appendingPathComponent(".local/bin").path,
                                      home.appendingPathComponent("bin").path,
                                      home.appendingPathComponent(".claude/local").path]
        func executable(_ name: String) -> String? {
            directories.lazy.map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(name).path }
                .first { path in
                    var directory: ObjCBool = false
                    return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
                        && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
                }
        }
        return Self(ghPath: executable("gh"), claudePath: executable("claude"))
    }
}

enum FeedbackBrowserFallback {
    struct Plan: Equatable, Sendable {
        let url: URL
        /// Copy the already reviewed body before opening this URL when true.
        let requiresCopy: Bool
    }
    static let maximumURLBytes = 7_500
    static let newIssueURL = URL(string: "https://github.com/biedongbin/QuotaNest/issues/new")

    static func make(title: String, body: String, requestID: UUID) throws -> Plan {
        let reviewed = try FeedbackRequestMarker.reviewedBody(body, requestID: requestID)
        try FeedbackPrivacyGuard.validate(title: title, body: reviewed)
        guard let newIssueURL else { throw FeedbackSubmissionError.invalidDraft }
        var components = URLComponents(url: newIssueURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [.init(name: "title", value: title), .init(name: "body", value: reviewed)]
        guard let url = components?.url else { throw FeedbackSubmissionError.invalidDraft }
        guard url.absoluteString.utf8.count <= maximumURLBytes else {
            return Plan(url: newIssueURL, requiresCopy: true)
        }
        return Plan(url: url, requiresCopy: false)
    }
}
