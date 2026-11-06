import Foundation
import SQLite3
import CryptoKit
import Darwin

/// Raw records and secrets exist only for the duration of a request snapshot.
struct SourceRecord {
    let object: [String: Any]
    let authMode: String
    let key: String
    let baseURL: String
    let protocolName: String
    let model: String
    let revision: String
}

enum ImportedSource {
    /// Paths whose changes can invalidate a live reference; does not read any source contents.
    static func dependencies(_ reference: ProviderSourceReference) -> [URL] {
        let file = URL(fileURLWithPath: (reference.path as NSString).expandingTildeInPath).standardizedFileURL
        switch reference.source {
        case "9router", "cc-switch":
            return [file, URL(fileURLWithPath: file.path + "-wal")]
        case "magpie" where reference.collection == "plugin-auth":
            let directory = file.deletingLastPathComponent()
            return [file, directory.appendingPathComponent("providers.json"),
                    directory.appendingPathComponent("plugin-providers.json")]
        default:
            return [file]
        }
    }

    static func read(_ reference: ProviderSourceReference) throws -> SourceRecord {
        let file = URL(fileURLWithPath: (reference.path as NSString).expandingTildeInPath)
        guard !reference.recordId.isEmpty, let expected = reference.providerId, !expected.isEmpty else {
            throw failure("导入来源引用缺少原始记录或供应商类型")
        }
        var object: [String: Any]
        var mode = "apikey", key = "", base = "", proto = "openai", model = ""
        switch reference.source {
        case "9router":
            let rows = try ReadonlySQLite.query(path: file.path, sql: "SELECT provider, authType, data FROM providerConnections WHERE id = \(ReadonlySQLite.literal(reference.recordId)) LIMIT 2")
            guard rows.count == 1, let row = rows.first else { throw failure("导入来源记录已删除或不唯一") }
            guard row["provider"] as? String == expected else { throw failure("导入来源供应商类型已变化，请重新导入") }
            object = try jsonString(row["data"])
            object["provider"] = expected
            object["authType"] = row["authType"]
            mode = (row["authType"] as? String) == "oauth" ? "auth" : "apikey"
            key = object["apiKey"] as? String ?? ""
            let specific = object["providerSpecificData"] as? [String: Any] ?? [:]
            base = specific["baseUrl"] as? String ?? object["baseUrl"] as? String ?? ""
            proto = expected.hasPrefix("anthropic") ? "anthropic" : "openai"
            model = specific["model"] as? String ?? object["model"] as? String ?? ""
        case "cc-switch":
            let rows = try ReadonlySQLite.query(path: file.path, sql: "SELECT app_type, settings_config FROM providers WHERE id = \(ReadonlySQLite.literal(reference.recordId)) AND app_type = \(ReadonlySQLite.literal(expected)) LIMIT 2")
            guard rows.count == 1, let row = rows.first else { throw failure("导入来源记录已删除或类型已变化") }
            object = try jsonString(row["settings_config"])
            if expected == "claude" {
                let env = object["env"] as? [String: Any] ?? [:]
                key = env["ANTHROPIC_AUTH_TOKEN"] as? String ?? env["ANTHROPIC_API_KEY"] as? String ?? ""
                base = env["ANTHROPIC_BASE_URL"] as? String ?? ""
                model = env["ANTHROPIC_MODEL"] as? String ?? ""
                proto = "anthropic"
            } else { throw failure("此 cc-switch 来源类型尚未提供只读接入适配") }
        case "cpamp":
            guard file.lastPathComponent == reference.recordId else { throw failure("导入来源文件名与记录不一致") }
            object = try json(Data(contentsOf: file))
            guard object["type"] as? String == expected else { throw failure("导入来源供应商类型已变化，请重新导入") }
            key = object["api_key"] as? String ?? ""
            mode = key.isEmpty ? "auth" : "apikey"
            base = object["base_url"] as? String ?? ""
            proto = ["cline-pass", "clinepass", "claude"].contains(expected) ? "anthropic" : "responses"
            model = object["model"] as? String ?? ""
        case "magpie":
            let bytes = try Data(contentsOf: file)
            if reference.collection == "logins" {
                guard file.lastPathComponent == "logins.json",
                      let records = try JSONSerialization.jsonObject(with: bytes) as? [[String: Any]] else {
                    throw failure("Magpie 原生登录列表格式无效")
                }
                let matches = records.filter { $0["id"] as? String == reference.recordId }
                guard matches.count == 1, let login = matches.first, login["agent"] as? String == expected else {
                    throw failure("Magpie 原生登录记录已删除、不唯一或类型已变化")
                }
                guard let snapshot = login["auth"] as? [String: Any], !snapshot.isEmpty else {
                    throw failure("此 Magpie 原生登录没有可只读使用的内联授权快照")
                }
                object = snapshot
                mode = "auth"
            } else if reference.collection == "plugin-auth" {
                let credentialProvider = reference.credentialProviderId ?? expected
                guard file.lastPathComponent == "plugin-auth.json",
                      reference.recordId == credentialProvider || reference.recordId.hasPrefix(credentialProvider + "#") else {
                    throw failure("Magpie 插件来源引用类型不一致")
                }
                let records = try json(bytes)
                guard let record = records[reference.recordId] as? [String: Any] else { throw failure("Magpie 来源记录已删除") }
                try validateMagpiePlugin(reference, file: file, credentialProvider: credentialProvider, expected: expected, record: record)
                object = record
                switch record["type"] as? String {
                case "oauth": mode = "auth"
                case "api": key = record["key"] as? String ?? ""
                default: throw failure("Magpie 来源认证类型不支持")
                }
            } else {
                guard file.lastPathComponent == "providers.json", reference.recordId == expected,
                      let records = try json(bytes)["providers"] as? [[String: Any]] else {
                    throw failure("Magpie 来源引用格式无效")
                }
                let matches = records.filter { $0["id"] as? String == expected }
                guard matches.count == 1, let record = matches.first else { throw failure("Magpie 来源记录已删除或不唯一") }
                object = record
                var keyProtocol = ""
                if reference.collection == "providers" {
                    key = record["key"] as? String ?? ""
                    keyProtocol = record["keyProtocol"] as? String ?? ""
                } else if let collection = reference.collection, collection.hasPrefix("providers:key:") {
                    let fingerprint = String(collection.dropFirst("providers:key:".count))
                    let keys = record["keys"] as? [[String: Any]] ?? []
                    let matches = keys.filter { item in
                        guard let value = item["key"] as? String else { return false }
                        return SHA256.hash(data: Data(value.utf8)).prefix(5).map { String(format: "%02x", $0) }.joined() == fingerprint
                    }
                    guard matches.count == 1, let item = matches.first else { throw failure("Magpie 来源 Key 已删除或变化") }
                    key = item["key"] as? String ?? ""
                    keyProtocol = item["protocol"] as? String ?? ""
                } else { throw failure("Magpie 来源集合不支持") }
                let selection = keyProtocol.isEmpty ? (record["baseAPI"] as? String ?? "") : keyProtocol
                let selected = selection == "openai" ? "chat" : selection
                let endpointNames = selected.isEmpty ? ["chat", "responses", "anthropic"] : [selected]
                guard let endpoint = endpointNames.first(where: { name in
                    ["chat", "responses", "anthropic"].contains(name)
                        && (record[name] as? String)?.isEmpty == false
                }), let url = record[endpoint] as? String else { throw failure("Magpie 来源缺少受支持模型接口") }
                base = url
                proto = endpoint == "chat" ? "openai" : endpoint
            }
        default:
            throw failure("不支持的导入来源")
        }
        if let expectedAccount = reference.identityAccount, accountIdentity(object) != expectedAccount {
            throw failure("来源账号身份已变化，请重新扫描导入；不会改用其他账号")
        }
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let revision = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return SourceRecord(object: object, authMode: mode, key: key, baseURL: base,
                            protocolName: proto, model: model, revision: revision)
    }

    private static func validateMagpiePlugin(_ reference: ProviderSourceReference, file: URL,
                                             credentialProvider: String, expected: String, record: [String: Any]) throws {
        let directory = file.deletingLastPathComponent()
        let providers = try json(Data(contentsOf: directory.appendingPathComponent("providers.json")))["providers"] as? [[String: Any]] ?? []
        let actual = providers.filter { $0["id"] as? String == expected }
        guard actual.count == 1,
              expected == credentialProvider || expected == credentialProvider + "-plugin" else {
            throw failure("Magpie 原供应商与插件身份映射已变化")
        }
        let data = try Data(contentsOf: directory.appendingPathComponent("plugin-providers.json"))
        guard let cache = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw failure("Magpie 插件身份缓存格式无效")
        }
        let owners = cache.filter { $0["id"] as? String == credentialProvider }
        guard owners.count == 1, let owner = owners.first else { throw failure("Magpie 插件身份映射不唯一或已删除") }
        let accounts = owner["accounts"] as? [[String: Any]] ?? []
        let matches = accounts.filter { $0["key"] as? String == reference.recordId }
        guard matches.count == 1, let account = matches.first else {
            throw failure("Magpie 插件来源账号已删除或归属变化")
        }
        if let cached = account["accountId"] as? String, !cached.isEmpty, cached != accountIdentifier(record) {
            throw failure("Magpie 插件缓存与授权快照的账号身份不一致")
        }
        if let cached = account["type"] as? String, cached != record["type"] as? String {
            throw failure("Magpie 插件缓存与授权快照的认证类型不一致")
        }
    }

    private static func accountIdentifier(_ object: [String: Any]) -> String? {
        ["tokens.account_id", "accountId", "metadata.email", "email"].lazy
            .compactMap { ProviderAuthentication.string(at: $0, in: object) }.first { !$0.isEmpty }
    }

    /// Account evidence is hashed, separate from rotating access tokens. Never uses display names.
    static func accountIdentity(_ object: [String: Any]) -> String? {
        var evidence: [String: String] = [:]
        if let account = accountIdentifier(object) { evidence["account"] = account }
        if let uid = object["uid"] as? String, !uid.isEmpty { evidence["uid"] = uid }
        for path in ["tokens.id_token", "tokens.access_token", "accessToken", "jwt", "refresh.jwt", "access"] {
            guard let token = ProviderAuthentication.string(at: path, in: object) else { continue }
            let parts = token.split(separator: ".", omittingEmptySubsequences: false)
            if parts.count == 3, let claims = ProviderAuthentication.jwtObject(String(parts[1])),
               let subject = claims["sub"] as? String, !subject.isEmpty {
                evidence["subject"] = subject
                break
            }
        }
        guard !evidence.isEmpty else { return nil }
        guard let bytes = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]) else { return nil }
        return "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Enumerates only the referenced container. Every returned record is re-read through `read`.
    static func references(in reference: ProviderSourceReference) throws -> [ProviderSourceReference] {
        let file = URL(fileURLWithPath: (reference.path as NSString).expandingTildeInPath)
        func ref(_ id: String, _ provider: String, path: String? = nil) -> ProviderSourceReference {
            ProviderSourceReference(source: reference.source, path: path ?? reference.path, recordId: id,
                providerId: provider, collection: reference.collection, credentialProviderId: reference.credentialProviderId)
        }
        switch reference.source {
        case "9router":
            return try ReadonlySQLite.query(path: file.path, sql: "SELECT id, provider FROM providerConnections").map { row in
                guard let id = row["id"] as? String, let provider = row["provider"] as? String else {
                    throw failure("9router 来源记录身份格式无效")
                }
                return ref(id, provider)
            }
        case "cc-switch":
            return try ReadonlySQLite.query(path: file.path, sql: "SELECT id, app_type FROM providers").map { row in
                guard let id = row["id"] as? String, let provider = row["app_type"] as? String else {
                    throw failure("cc-switch 来源记录身份格式无效")
                }
                return ref(id, provider)
            }
        case "cpamp":
            let directory = file.deletingLastPathComponent()
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.map { item in
                    let object = try json(Data(contentsOf: item))
                    guard let type = object["type"] as? String else { throw failure("CPA 来源文件类型无效") }
                    return ref(item.lastPathComponent, type, path: item.path)
                }
        case "magpie":
            if reference.collection == "logins" {
                guard file.lastPathComponent == "logins.json",
                      let records = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]] else {
                    throw failure("Magpie 原生登录列表格式无效")
                }
                return try records.map { item in
                    guard let id = item["id"] as? String, !id.isEmpty, let agent = item["agent"] as? String else {
                        throw failure("Magpie 原生登录记录身份无效")
                    }
                    return ref(id, agent)
                }
            }
            let object = try json(Data(contentsOf: file))
            if reference.collection == "plugin-auth" {
                return object.keys.sorted().map { ref($0, reference.providerId ?? "") }
            }
            guard let records = object["providers"] as? [[String: Any]] else { throw failure("Magpie 来源供应商列表无效") }
            return try records.map { item in
                guard let id = item["id"] as? String else { throw failure("Magpie 来源记录身份无效") }
                return ref(id, id)
            }
        default: throw failure("不支持的导入来源同步")
        }
    }

    static func magpieRenameIDs(_ reference: ProviderSourceReference) throws -> [String] {
        let file = URL(fileURLWithPath: (reference.path as NSString).expandingTildeInPath)
        guard let records = try json(Data(contentsOf: file))["providers"] as? [[String: Any]] else {
            throw failure("Magpie 来源供应商列表无效")
        }
        return records.compactMap { item in
            let aliases = item["was"] as? [String] ?? (item["was"] as? String).map { [$0] } ?? []
            return aliases.contains(reference.providerId ?? reference.recordId) ? item["id"] as? String : nil
        }
    }

    private static func jsonString(_ raw: Any?) throws -> [String: Any] {
        guard let raw = raw as? String else { throw failure("导入来源记录缺少 JSON") }
        return try json(Data(raw.utf8))
    }

    private static func json(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw failure("导入来源不是 JSON 对象")
        }
        return object
    }

    static func failure(_ message: String) -> ProviderAuthenticationError {
        ProviderAuthenticationError(message: message)
    }
}

/// Native SQLite avoids Process.waitUntilExit(), which pumps a nested AppKit run loop on the main thread.
/// Connections and statements are read-only; lock waits, VM execution, rows and result size are bounded.
enum ReadonlySQLite {
    static func literal(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private final class Deadline {
        let end: UInt64
        init(timeout: TimeInterval) {
            end = DispatchTime.now().uptimeNanoseconds + UInt64(min(timeout, 30) * 1_000_000_000)
        }
        var expired: Bool { DispatchTime.now().uptimeNanoseconds >= end }
    }

    static func query(path: String, sql: String, timeout: TimeInterval = 3) throws -> [[String: Any]] {
        guard !path.isEmpty, !path.contains("\0"), !sql.contains("\0"), timeout.isFinite, timeout > 0 else {
            throw ImportedSource.failure("导入来源查询参数无效")
        }
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        defer { if let database { sqlite3_close(database) } }
        guard opened == SQLITE_OK, let database else {
            throw ImportedSource.failure("导入来源数据库读取失败或超时")
        }
        let maximumBytes = 16 * 1_024 * 1_024
        sqlite3_limit(database, SQLITE_LIMIT_LENGTH, Int32(maximumBytes))
        sqlite3_busy_timeout(database, Int32(min(timeout * 1_000, 1_000)))
        sqlite3_set_authorizer(database, { _, action, _, function, _, _ in
            switch action {
            case SQLITE_SELECT, SQLITE_READ, SQLITE_RECURSIVE: return SQLITE_OK
            case SQLITE_FUNCTION:
                if let function, String(cString: function).lowercased() == "load_extension" { return SQLITE_DENY }
                return SQLITE_OK
            default: return SQLITE_DENY
            }
        }, nil)
        let context = Unmanaged.passRetained(Deadline(timeout: timeout)).toOpaque()
        sqlite3_progress_handler(database, 1_000, { pointer in
            guard let pointer else { return 1 }
            return Unmanaged<Deadline>.fromOpaque(pointer).takeUnretainedValue().expired ? 1 : 0
        }, context)
        defer {
            sqlite3_progress_handler(database, 0, nil, nil)
            Unmanaged<Deadline>.fromOpaque(context).release()
        }
        var statement: OpaquePointer?
        defer { if let statement { sqlite3_finalize(statement) } }
        let prepared = sql.withCString { text -> Bool in
            var tail: UnsafePointer<CChar>?
            guard sqlite3_prepare_v2(database, text, -1, &statement, &tail) == SQLITE_OK else { return false }
            return tail.map { String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true
        }
        guard prepared else { throw ImportedSource.failure("导入来源数据库读取失败或超时") }
        guard let statement else { return [] }
        guard sqlite3_stmt_readonly(statement) != 0 else { throw ImportedSource.failure("导入来源数据库只允许读取") }
        var rows: [[String: Any]] = []
        var bytes = 0
        while true {
            guard !Unmanaged<Deadline>.fromOpaque(context).takeUnretainedValue().expired else {
                throw ImportedSource.failure("导入来源数据库读取失败或超时")
            }
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw ImportedSource.failure("导入来源数据库读取失败或超时") }
            var row: [String: Any] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row[name] = NSNumber(value: sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: row[name] = NSNumber(value: sqlite3_column_double(statement, column))
                case SQLITE_NULL: row[name] = NSNull()
                case SQLITE_TEXT:
                    guard let pointer = sqlite3_column_text(statement, column) else { throw ImportedSource.failure("导入来源数据库返回格式无效") }
                    let count = Int(sqlite3_column_bytes(statement, column))
                    guard count <= maximumBytes - bytes else { throw ImportedSource.failure("导入来源数据库结果过大") }
                    bytes += count
                    guard let value = String(data: Data(bytes: pointer, count: count), encoding: .utf8) else {
                        throw ImportedSource.failure("导入来源数据库返回格式无效")
                    }
                    row[name] = value
                default: throw ImportedSource.failure("导入来源数据库返回格式无效")
                }
            }
            guard rows.count < 100_000, bytes <= maximumBytes else {
                throw ImportedSource.failure("导入来源数据库结果过大")
            }
            rows.append(row)
        }
    }
}
