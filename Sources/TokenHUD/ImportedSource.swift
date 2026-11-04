import Foundation
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
            if reference.collection == "plugin-auth" {
                let credentialProvider = reference.credentialProviderId ?? expected
                guard file.lastPathComponent == "plugin-auth.json",
                      reference.recordId == credentialProvider || reference.recordId.hasPrefix(credentialProvider + "#") else {
                    throw failure("Magpie 插件来源引用类型不一致")
                }
                try validateMagpiePlugin(reference, file: file, credentialProvider: credentialProvider, expected: expected)
                let records = try json(bytes)
                guard let record = records[reference.recordId] as? [String: Any] else { throw failure("Magpie 来源记录已删除") }
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
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let revision = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return SourceRecord(object: object, authMode: mode, key: key, baseURL: base,
                            protocolName: proto, model: model, revision: revision)
    }

    private static func validateMagpiePlugin(_ reference: ProviderSourceReference, file: URL,
                                             credentialProvider: String, expected: String) throws {
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
        guard accounts.filter({ $0["key"] as? String == reference.recordId }).count == 1 else {
            throw failure("Magpie 插件来源账号已删除或归属变化")
        }
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

/// System SQLite only: read-only connection, escaped exact primary-key lookup, bounded lifetime.
enum ReadonlySQLite {
    static func literal(_ value: String) -> String {
        // SQLite text literals cannot contain NUL; reject it before constructing a query.
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    static func query(path: String, sql: String, timeout: TimeInterval = 3,
                      executable: URL = URL(fileURLWithPath: "/usr/bin/sqlite3")) throws -> [[String: Any]] {
        guard !path.contains("\0"), !sql.contains("\0"), timeout > 0 else {
            throw ImportedSource.failure("导入来源查询参数无效")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-readonly", "-batch", "-bail", "-json", "-cmd", ".timeout 1000", path, sql]
        let output = Pipe()
        process.standardOutput = output
        // Do not surface SQLite diagnostics: source SQL/errors may contain private fields.
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        timer.resume()
        defer { timer.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw ImportedSource.failure("导入来源数据库读取失败或超时")
        }
        if data.isEmpty { return [] }
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ImportedSource.failure("导入来源数据库返回格式无效")
        }
        return rows
    }
}
