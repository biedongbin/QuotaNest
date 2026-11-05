import Foundation
import CryptoKit
import Darwin

/// Run synchronously before constructing any settings singleton or provider engine.
/// Only the supplied application preference domains are read; global defaults are never enumerated.
enum AppIdentityMigration {
    struct Outcome {
        let providersDir: URL
        let migrated: Bool
        let backupDirectory: URL?
        let reportURL: URL?
    }

    enum Checkpoint: CaseIterable, Equatable {
        case staged, activated, preferencesWritten, legacyBackedUp
    }

    struct MigrationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let markerFilename = ".quotanest-identity-migration-v1.json"
    static let reportFilename = "MigrationReport-v1.json"
    private static let schemaVersion = 1

    static func migrate(userHome: URL, legacyDomain: String = "local.tokenhud",
                        targetDomain: String = "local.quotanest", now: Date = Date()) throws -> Outcome {
        try migrate(userHome: userHome, legacyDomain: legacyDomain, targetDomain: targetDomain,
                    now: now, defaults: .standard, checkpoint: { _ in })
    }

    /// Injection is limited to fixture defaults and deterministic transaction failure points.
    static func migrate(userHome: URL, legacyDomain: String, targetDomain: String,
                        now: Date = Date(), defaults: UserDefaults,
                        checkpoint: (Checkpoint) throws -> Void = { _ in }) throws -> Outcome {
        guard userHome.isFileURL, !legacyDomain.isEmpty, !targetDomain.isEmpty,
              legacyDomain != targetDomain else { throw failure("Invalid migration home or preference domains") }
        let home = userHome.standardizedFileURL.resolvingSymlinksInPath()
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let legacy = support.appendingPathComponent("TokenHUD", isDirectory: true)
        let target = support.appendingPathComponent("QuotaNest", isDirectory: true)
        try checkAncestors(support, home: home)
        try checkAncestors(legacy, home: home)
        try checkAncestors(target, home: home)
        if let completed = try completedOutcome(target: target, legacy: legacy) { return completed }

        let targetBefore = try emptyTargetState(target)
        let legacyExists = try directoryExists(legacy)
        let oldPreferences = defaults.persistentDomain(forName: legacyDomain) ?? [:]
        let targetPreferences = defaults.persistentDomain(forName: targetDomain)
        let preferences = try mergedPreferences(oldPreferences, into: targetPreferences ?? [:],
                                               home: home, legacy: legacy, target: target)
        let hasHistory = legacyExists || !oldPreferences.isEmpty
        let original = legacyExists ? try inventory(legacy) : [:]
        if legacyExists {
            for reserved in [markerFilename, reportFilename, "MigrationBackups"] {
                guard original[reserved] == nil else { throw failure("Reserved migration path conflicts in legacy directory") }
            }
        }
        let stage = support.appendingPathComponent(".QuotaNest-migration-\(UUID().uuidString)", isDirectory: true)
        try checkAncestors(stage, home: home)
        // Existing ancestors are checked first; only these known application support ancestors may be created.
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try checkAncestors(support, home: home)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var activated = false
        var preferencesTouched = false
        var legacyBackedUp = false
        let backup = legacyExists ? target.appendingPathComponent("MigrationBackups/TokenHUD-\(timestamp(now))", isDirectory: true) : nil
        do {
            var expected = try copyLegacy(legacy, to: stage, original: original)
            let providers = stage.appendingPathComponent("providers", isDirectory: true)
            if expected["providers"] == nil {
                try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                expected["providers"] = try entry(providers)
            }
            guard expected["providers"]?.kind == .directory else {
                throw failure("The providers root must be an owned directory, not a symbolic link")
            }
            try rewriteJSON(in: stage, original: original, expected: &expected,
                            home: home, legacy: legacy, target: target)
            try validateTree(stage, expected: expected)
            if legacyExists, try inventory(legacy) != original { throw failure("Legacy directory changed during staging") }
            try checkpoint(.staged)
            try checkAncestors(stage, home: home)
            try checkAncestors(target, home: home)
            guard try emptyTargetState(target) == targetBefore else { throw failure("Target directory changed during migration") }
            // POSIX rename atomically publishes the whole tree, including when replacing a pre-existing empty directory.
            guard Darwin.rename(stage.path, target.path) == 0 else { throw failure("Could not atomically activate migration directory") }
            activated = true
            try validateTree(target, expected: expected)
            try checkpoint(.activated)
            if hasHistory {
                preferencesTouched = true
                defaults.setPersistentDomain(preferences.values, forName: targetDomain)
                guard defaults.synchronize(), equal(defaults.persistentDomain(forName: targetDomain), preferences.values) else {
                    throw failure("Migrated application preferences could not be verified")
                }
            }
            try checkpoint(.preferencesWritten)
            if let backup {
                guard try inventory(legacy) == original else { throw failure("Legacy directory changed before backup") }
                let backups = backup.deletingLastPathComponent()
                try checkAncestors(backups, home: home)
                try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                guard try optionalAttributes(backup) == nil else { throw failure("Migration backup path already exists") }
                try FileManager.default.moveItem(at: legacy, to: backup)
                legacyBackedUp = true
                guard try inventory(backup) == original else { throw failure("Legacy backup verification failed") }
            }
            try checkpoint(.legacyBackedUp)
            let record = Record(schemaVersion: schemaVersion, completed: true, migrated: hasHistory,
                                timestamp: now, legacyRoot: legacy.path, targetRoot: target.path,
                                fileCount: original.values.filter { $0.kind == .file }.count,
                                preferenceCount: preferences.count, originalTreeHash: legacyExists ? treeHash(original) : nil,
                                backupDirectory: backup?.path, reportFilename: hasHistory ? reportFilename : nil)
            if hasHistory { try writeRecord(record, to: target.appendingPathComponent(reportFilename)) }
            // The marker is the final commit point, after successful target, defaults and backup verification.
            try writeRecord(record, to: target.appendingPathComponent(markerFilename))
            if let permissions = original[""]?.permissions ?? targetBefore?.permissions {
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
            }
            return Outcome(providersDir: target.appendingPathComponent("providers", isDirectory: true),
                           migrated: hasHistory, backupDirectory: backup,
                           reportURL: hasHistory ? target.appendingPathComponent(reportFilename) : nil)
        } catch {
            var rollbackFailures: [String] = []
            if legacyBackedUp, let backup {
                do {
                    try checkAncestors(legacy, home: home)
                    guard try optionalAttributes(legacy) == nil else { throw failure("Legacy path reappeared") }
                    try FileManager.default.moveItem(at: backup, to: legacy)
                    legacyBackedUp = false
                } catch { rollbackFailures.append("restore legacy backup") }
            }
            if preferencesTouched {
                if let targetPreferences { defaults.setPersistentDomain(targetPreferences, forName: targetDomain) }
                else { defaults.removePersistentDomain(forName: targetDomain) }
                if !defaults.synchronize() || !equal(defaults.persistentDomain(forName: targetDomain), targetPreferences ?? [:]) {
                    rollbackFailures.append("restore target preferences")
                }
            }
            // A failed backup restore keeps the entire target so the only remaining original is never deleted.
            if activated && !legacyBackedUp {
                do {
                    try checkAncestors(target, home: home)
                    try removeOwnedTree(target, home: home)
                    if let targetBefore {
                        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false,
                                                                attributes: [.posixPermissions: targetBefore.permissions])
                    }
                } catch { rollbackFailures.append("remove activated migration directory") }
            }
            do {
                try checkAncestors(stage, home: home)
                if try optionalAttributes(stage) != nil { try removeOwnedTree(stage, home: home) }
            } catch { rollbackFailures.append("remove private staging directory") }
            if !rollbackFailures.isEmpty {
                throw failure("Migration failed; rollback needs attention: \(rollbackFailures.joined(separator: ", "))")
            }
            // Never include JSON decoder contexts or preference values in an error/report.
            if let known = error as? MigrationError { throw known }
            throw failure("Application identity migration failed; original data and preferences were restored")
        }
    }

    private struct Record: Codable, Equatable {
        let schemaVersion: Int
        let completed: Bool
        let migrated: Bool
        let timestamp: Date
        let legacyRoot: String
        let targetRoot: String
        let fileCount: Int
        let preferenceCount: Int
        let originalTreeHash: String?
        let backupDirectory: String?
        let reportFilename: String?
    }

    private enum Kind: String { case directory, file, link }
    private struct Entry: Equatable {
        let kind: Kind
        let permissions: Int
        let hash: String?
        let link: String?
    }
    private struct EmptyTarget: Equatable {
        let permissions: Int
        let inode: UInt64
    }

    private static func failure(_ message: String) -> MigrationError { MigrationError(message: message) }

    private static func optionalAttributes(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return nil }
    }

    /// Checks each existing component without traversing any symlink below the supplied home anchor.
    private static func checkAncestors(_ url: URL, home: URL) throws {
        guard within(url.standardizedFileURL.path, root: home.path) else { throw failure("Migration path escapes user home") }
        var current = home
        for component in url.standardizedFileURL.pathComponents.dropFirst(home.pathComponents.count) {
            current.appendPathComponent(component)
            if let attributes = try optionalAttributes(current) {
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                    throw failure("Migration directory contains a symbolic link or non-directory: \(current.path)")
                }
            }
        }
    }

    /// Writable modes are applied only to our disposable copy, never to the original or its backup.
    private static func removeOwnedTree(_ root: URL, home: URL) throws {
        try checkAncestors(root, home: home)
        func makeRemovable(_ directory: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            try FileManager.default.setAttributes([.posixPermissions: permissions | 0o700], ofItemAtPath: directory.path)
            for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                if try optionalAttributes(child)?[.type] as? FileAttributeType == .typeDirectory { try makeRemovable(child) }
            }
        }
        try makeRemovable(root)
        try FileManager.default.removeItem(at: root)
    }

    private static func directoryExists(_ url: URL) throws -> Bool {
        guard let attributes = try optionalAttributes(url) else { return false }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw failure("Migration root is not an owned directory") }
        return true
    }

    private static func emptyTargetState(_ target: URL) throws -> EmptyTarget? {
        guard let attributes = try optionalAttributes(target) else { return nil }
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty else {
            throw failure("QuotaNest directory is nonempty without a completed migration marker; refusing to overwrite")
        }
        return EmptyTarget(permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o700,
                           inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }

    private static func completedOutcome(target: URL, legacy: URL) throws -> Outcome? {
        let marker = target.appendingPathComponent(markerFilename)
        guard let attributes = try optionalAttributes(marker) else { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw failure("Migration marker is not an owned file") }
        let record: Record
        do { record = try JSONDecoder().decode(Record.self, from: readFile(marker)) }
        catch { throw failure("Migration marker is invalid or incomplete") }
        guard record.schemaVersion == schemaVersion, record.completed,
              record.legacyRoot == legacy.path, record.targetRoot == target.path else {
            throw failure("Migration marker does not describe a completed migration for these directories")
        }
        let providers = target.appendingPathComponent("providers", isDirectory: true)
        guard try directoryExists(providers) else { throw failure("Completed migration is missing its providers directory") }
        var backup: URL?
        if let path = record.backupDirectory {
            let backupRoot = target.appendingPathComponent("MigrationBackups", isDirectory: true)
            let candidate = URL(fileURLWithPath: path).standardizedFileURL
            guard candidate.deletingLastPathComponent() == backupRoot,
                  candidate.lastPathComponent.hasPrefix("TokenHUD-") else {
                throw failure("Completed migration backup path is unsafe")
            }
            // A completed migration remains usable after the user removes its optional recovery artifacts.
            // Present artifacts must still be owned directories, never symbolic links or files.
            if try directoryExists(backupRoot), try directoryExists(candidate) { backup = candidate }
        }
        var report: URL?
        if let name = record.reportFilename {
            guard name == reportFilename else { throw failure("Migration report path is invalid") }
            let candidate = target.appendingPathComponent(name)
            if let attributes = try optionalAttributes(candidate) {
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    throw failure("Completed migration report is unsafe")
                }
                report = candidate
            }
        }
        return Outcome(providersDir: providers, migrated: false, backupDirectory: backup, reportURL: report)
    }

    private static func readFile(_ url: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw failure("Could not read owned migration file: \(url.path)") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { handle.closeFile() }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw failure("Migration input is not a regular file")
        }
        return try handle.readToEnd() ?? Data()
    }

    private static func entry(_ url: URL) throws -> Entry {
        guard let attributes = try optionalAttributes(url) else { throw failure("Migration input disappeared") }
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        switch attributes[.type] as? FileAttributeType {
        case .typeDirectory: return Entry(kind: .directory, permissions: permissions, hash: nil, link: nil)
        case .typeRegular: return Entry(kind: .file, permissions: permissions, hash: hash(try readFile(url)), link: nil)
        case .typeSymbolicLink:
            return Entry(kind: .link, permissions: permissions, hash: nil,
                         link: try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
        default: throw failure("Unsupported special file in migration directory")
        }
    }

    private static func inventory(_ root: URL) throws -> [String: Entry] {
        var result: [String: Entry] = [:]
        func visit(_ url: URL, relative: String) throws {
            let value = try entry(url)
            result[relative] = value
            if value.kind == .directory {
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    let name = relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent
                    try visit(child, relative: name)
                }
            }
        }
        try visit(root, relative: "")
        return result
    }

    private static func copyLegacy(_ legacy: URL, to stage: URL, original: [String: Entry]) throws -> [String: Entry] {
        var expected: [String: Entry] = ["": try entry(stage)]
        let names = original.keys.filter { !$0.isEmpty }.sorted {
            let left = $0.split(separator: "/").count, right = $1.split(separator: "/").count
            return left == right ? $0 < $1 : left < right
        }
        for name in names {
            guard let value = original[name] else { throw failure("Missing migration inventory entry") }
            let source = legacy.appendingPathComponent(name), destination = stage.appendingPathComponent(name)
            switch value.kind {
            case .directory:
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            case .file:
                let data = try readFile(source)
                guard hash(data) == value.hash else { throw failure("Legacy file changed during copy") }
                try data.write(to: destination, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: value.permissions], ofItemAtPath: destination.path)
            case .link:
                guard let link = value.link else { throw failure("Missing symbolic link destination") }
                // Copy only the link text. External Auth files and databases are never opened or dereferenced.
                try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: link)
            }
            expected[name] = value
        }
        return expected
    }

    private static func validateTree(_ root: URL, expected: [String: Entry]) throws {
        guard try inventory(root) == expected else { throw failure("Migration file bytes, permissions or directory entries failed verification") }
        let manifests = expected.filter { $0.value.kind == .file && ($0.key as NSString).lastPathComponent == "manifest.json" }
        for (name, _) in manifests {
            do { _ = try JSONDecoder().decode(ProviderManifest.self, from: readFile(root.appendingPathComponent(name))) }
            catch { throw failure("Provider manifest could not be loaded in migration target") }
        }
    }

    private static func rewriteJSON(in stage: URL, original: [String: Entry], expected: inout [String: Entry],
                                    home: URL, legacy: URL, target: URL) throws {
        for (name, value) in original where value.kind == .file && (name as NSString).pathExtension.lowercased() == "json" {
            let file = stage.appendingPathComponent(name)
            let before = try readFile(file)
            do { _ = try JSONSerialization.jsonObject(with: before, options: [.fragmentsAllowed]) }
            catch { throw failure("Invalid JSON in legacy directory; migration stopped without changing original data") }
            let basename = (name as NSString).lastPathComponent.lowercased()
            if basename == "manifest.json" || basename.contains("auth") {
                let after = try rewritingPathFields(before, home: home, legacy: legacy, target: target)
                if after != before {
                    try FileManager.default.setAttributes([.posixPermissions: value.permissions | 0o600], ofItemAtPath: file.path)
                    try after.write(to: file)
                    try FileManager.default.setAttributes([.posixPermissions: value.permissions], ofItemAtPath: file.path)
                    expected[name] = try entry(file)
                }
            }
        }
        // Apply directory modes only after all descendants have been created and rewritten.
        for (name, value) in original.sorted(by: { $0.key.count > $1.key.count }) where !name.isEmpty && value.kind == .directory {
            try FileManager.default.setAttributes([.posixPermissions: value.permissions],
                                                  ofItemAtPath: stage.appendingPathComponent(name).path)
        }
    }

    private static func mergedPreferences(_ old: [String: Any], into existing: [String: Any],
                                          home: URL, legacy: URL, target: URL) throws -> (values: [String: Any], count: Int) {
        var result = existing
        var count = 0
        // Explicit new-prefix values already present in the old application domain win over their legacy aliases.
        let keys = old.keys.sorted {
            let left = $0.hasPrefix("tokenhud."), right = $1.hasPrefix("tokenhud.")
            return left == right ? $0 < $1 : !left
        }
        let pathKeys: Set<String> = ["nodePath", "providersDir", "providersDirectory", "userProvidersDir", "appSupportDir", "appSupportDirectory"]
        for key in keys {
            let mapped = key.hasPrefix("tokenhud.") ? "quotanest." + key.dropFirst("tokenhud.".count) : key
            guard result[mapped] == nil, let value = old[key] else { continue }
            let field = mapped.hasPrefix("quotanest.") ? String(mapped.dropFirst("quotanest.".count)) : mapped
            if pathKeys.contains(field), let path = value as? String {
                result[mapped] = try rebased(path, home: home, legacy: legacy, target: target)
            } else { result[mapped] = value }
            count += 1
        }
        return (result, count)
    }

    private static func equal(_ left: [String: Any]?, _ right: [String: Any]) -> Bool {
        NSDictionary(dictionary: left ?? [:]).isEqual(to: right)
    }

    private static func within(_ path: String, root: String) -> Bool { path == root || path.hasPrefix(root + "/") }

    /// A lexical old-root prefix is insufficient: an internal symlink may actually refer to external credentials.
    private static func rebased(_ path: String, home: URL, legacy: URL, target: URL) throws -> String {
        let isTilde = path.hasPrefix("~/")
        guard isTilde || path.hasPrefix("/") else { return path }
        let expanded = isTilde ? home.appendingPathComponent(String(path.dropFirst(2))).path : path
        let candidate = URL(fileURLWithPath: expanded).standardizedFileURL
        guard within(candidate.path, root: legacy.path),
              within(candidate.resolvingSymlinksInPath().path, root: legacy.path) else { return path }
        let replacement = target.path + candidate.path.dropFirst(legacy.path.count)
        return isTilde ? "~" + replacement.dropFirst(home.path.count) : replacement
    }

    /// Preserve every non-path byte, including whitespace, large numeric identifiers and encoded secrets.
    /// JSON was validated above; this small scanner locates only explicit root/nested property value spans.
    private static func rewritingPathFields(_ data: Data, home: URL, legacy: URL, target: URL) throws -> Data {
        let bytes = Array(data)
        let fields = try objectFields(bytes, in: 0..<bytes.count)
        var edits: [(Range<Int>, Data)] = []
        func consider(_ range: Range<Int>?) throws {
            guard let range, let path = try JSONSerialization.jsonObject(with: Data(bytes[range]), options: [.fragmentsAllowed]) as? String else { return }
            let next = try rebased(path, home: home, legacy: legacy, target: target)
            if next != path { edits.append((range, try JSONSerialization.data(withJSONObject: next, options: [.fragmentsAllowed, .withoutEscapingSlashes]))) }
        }
        for key in ["fetch", "authFile", "cacheFile", "authCredentialFile"] { try consider(fields[key]) }
        if let range = fields["credentialSource"] {
            let source = try objectFields(bytes, in: range)
            for key in ["path", "file", "environmentDirectory"] { try consider(source[key]) }
        }
        if let range = fields["sourceReference"] {
            let reference = try objectFields(bytes, in: range)
            let external: Set<String> = ["9router", "cc-switch", "ccswitch", "cpamp", "magpie"]
            let source = try reference["source"].flatMap {
                try JSONSerialization.jsonObject(with: Data(bytes[$0]), options: [.fragmentsAllowed]) as? String
            }
            if !external.contains(source?.lowercased() ?? "") { try consider(reference["path"]) }
        }
        var output = data
        for (range, replacement) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            output.replaceSubrange(range, with: replacement)
        }
        return output
    }

    private static func objectFields(_ bytes: [UInt8], in range: Range<Int>) throws -> [String: Range<Int>] {
        var cursor = range.lowerBound
        if range.lowerBound == 0 && bytes.starts(with: [0xEF, 0xBB, 0xBF]) { cursor = 3 }
        func skipWhitespace() { while cursor < range.upperBound && [9, 10, 13, 32].contains(bytes[cursor]) { cursor += 1 } }
        func valueEnd(_ start: Int) -> Int {
            var index = start, nesting = 0, quoted = false, escaped = false
            while index < range.upperBound {
                let byte = bytes[index]
                if quoted {
                    if escaped { escaped = false }
                    else if byte == 92 { escaped = true }
                    else if byte == 34 { quoted = false; if nesting == 0 { return index + 1 } }
                } else if byte == 34 { quoted = true }
                else if byte == 123 || byte == 91 { nesting += 1 }
                else if byte == 125 || byte == 93 { if nesting == 0 { return index }; nesting -= 1; if nesting == 0 { return index + 1 } }
                else if nesting == 0 && (byte == 44 || [9, 10, 13, 32].contains(byte)) { return index }
                index += 1
            }
            return index
        }
        skipWhitespace()
        guard cursor < range.upperBound, bytes[cursor] == 123 else { return [:] }
        cursor += 1
        var fields: [String: Range<Int>] = [:]
        while cursor < range.upperBound {
            skipWhitespace()
            if cursor == range.upperBound || bytes[cursor] == 125 { break }
            let end = valueEnd(cursor)
            guard let key = try JSONSerialization.jsonObject(with: Data(bytes[cursor..<end]), options: [.fragmentsAllowed]) as? String else {
                throw failure("Invalid JSON property in migration file")
            }
            cursor = end
            skipWhitespace()
            guard cursor < range.upperBound, bytes[cursor] == 58 else { throw failure("Invalid JSON property delimiter") }
            cursor += 1
            skipWhitespace()
            let valueStart = cursor
            cursor = valueEnd(cursor)
            guard fields[key] == nil else { throw failure("Duplicate JSON property in migration configuration") }
            fields[key] = valueStart..<cursor
            skipWhitespace()
            if cursor < range.upperBound, bytes[cursor] == 44 { cursor += 1 } else { break }
        }
        return fields
    }

    private static func writeRecord(_ record: Record, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        try data.write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        guard try JSONDecoder().decode(Record.self, from: readFile(url)) == record else { throw failure("Migration metadata failed verification") }
    }

    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func treeHash(_ entries: [String: Entry]) -> String {
        var digest = SHA256()
        for name in entries.keys.sorted() {
            guard let entry = entries[name] else { continue }
            // Length-delimited components prevent ambiguous tree summaries. Only the final digest is recorded.
            for field in [name, entry.kind.rawValue, String(entry.permissions), entry.hash ?? "", entry.link ?? ""] {
                digest.update(data: Data("\(field.utf8.count):".utf8))
                digest.update(data: Data(field.utf8))
            }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }
}
