import Foundation
import CoreFoundation

struct ProviderAuthenticationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Resolves the selected account's base authentication. Resolved tokens are request snapshots only.
enum ProviderAuthentication {
    static func credentialFileURL(for config: ProviderConfig,
                                  environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard let source = config.credentialSource else { return nil }
        let path: String
        if !config.authCredentialFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            path = config.authCredentialFile
        } else {
            guard !source.file.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            if let variable = source.environmentDirectory, let directory = environment[variable], !directory.isEmpty {
                path = URL(fileURLWithPath: directory).appendingPathComponent(URL(fileURLWithPath: source.file).lastPathComponent).path
            } else { path = source.file }
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    static func sourceDescription(_ config: ProviderConfig) -> String {
        guard config.credentialSource != nil else { return "该供应商尚未声明本机 Auth 授权来源" }
        return credentialFileURL(for: config)?.path ?? "请选择本机 Auth 授权文件"
    }

    static func resolveCall(_ config: ProviderConfig) throws -> ProviderConfig {
        var resolved = try resolveBase(config)
        if resolved.authMode == "auth" {
            guard let url = config.authCallURL, !url.isEmpty,
                  let proto = config.authCallProtocol, ["openai", "anthropic", "responses"].contains(proto) else {
                throw ProviderAuthenticationError(message: "该供应商尚未声明受支持的 Auth 模型调用接口；不会把授权令牌发送到 API Key 接口")
            }
            resolved.refreshUrl = url
            resolved.apiBaseURL = APIEndpoint.baseURL(from: url)
            resolved.refreshProtocol = proto
        }
        return resolved
    }

    /// Quota can use an existing login even when its model-call adapter is unavailable.
    static func resolveQuota(_ config: ProviderConfig) throws -> ProviderConfig {
        var resolved = try resolveBase(config)
        if let modes = config.quotaAuthModes, !modes.contains(resolved.authMode) {
            throw ProviderAuthenticationError(message: "此供应商用量接口不支持当前基础认证模式")
        }
        if config.queryAuth == "header" && resolved.authMode != "auth" {
            throw ProviderAuthenticationError(message: "此用量接口需要 Auth 登录，不能使用 API Key 查询订阅额度")
        }
        if ["jwt", "cookie"].contains(config.queryAuth ?? "") && config.inheritQueryURL == nil {
            throw ProviderAuthenticationError(message: "此类型暂未声明继承基础认证的用量接口")
        }
        resolved.queryUrl = config.inheritQueryURL ?? config.queryUrl
        resolved.queryKey = resolved.refreshKey
        resolved.queryHeader = config.inheritQueryHeader ?? resolved.refreshHeader
        return resolved
    }

    static func resolveBase(_ config: ProviderConfig) throws -> ProviderConfig {
        if config.credentialsResolved { return config }
        guard !config.isSourceConfigurationReadOnly || config.sourceReference != nil else {
            throw ProviderAuthenticationError(message: "旧导入账号缺少实时来源引用，请重新导入；不会使用旧复制凭证")
        }
        var resolved = config
        var sourceObject: [String: Any]?
        if let reference = config.sourceReference {
            let record = try ImportedSource.read(reference)
            if reference.source == "magpie", reference.collection?.hasPrefix("providers") == true,
               let template = config.sourceTemplate {
                let templates = ProviderImporter.bundledTemplates()
                let identity = record.object["preset"] as? String ?? record.object["catalog"] as? String
                    ?? record.object["id"] as? String ?? ""
                let declared = ProviderImporter.matchingTemplate(provider: identity, base: "", templates: templates)
                let endpoint = ProviderImporter.matchingTemplate(provider: "", base: record.baseURL, templates: templates)
                guard (declared == nil || declared?.slug == template), endpoint?.slug == template else {
                    throw ProviderAuthenticationError(message: "导入来源供应商类型或固定接口已变化，请重新导入")
                }
            }
            sourceObject = record.object
            resolved.authMode = record.authMode
            resolved.refreshKey = record.key
            resolved.sourceRevision = record.revision
            if !config.sourceEndpointIsFixed {
                guard !record.baseURL.isEmpty else {
                    throw ProviderAuthenticationError(message: "导入来源缺少可用接口地址")
                }
                resolved.apiBaseURL = record.baseURL
                resolved.refreshProtocol = record.protocolName
                resolved.refreshUrl = APIEndpoint.requestURL(baseURL: record.baseURL, protocolName: record.protocolName)
                resolved.refreshHeader = record.protocolName == "anthropic"
                    ? "x-api-key: <key>\nanthropic-version: 2023-06-01" : "Authorization: Bearer <key>"
            }
            if !record.model.isEmpty { resolved.testModel = record.model }
        }
        switch resolved.authMode {
        case "apikey":
            guard !resolved.refreshKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  resolved.refreshKey.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw ProviderAuthenticationError(message: "请填写基础接入的 API Key")
            }
        case "auth":
            guard let source = config.credentialSource else {
                throw ProviderAuthenticationError(message: "此供应商未提供本机 Auth 适配，请选择 API Key 或使用支持 Auth 的类型")
            }
            let object: [String: Any]
            if let sourceObject {
                object = sourceObject
            } else {
                guard let file = credentialFileURL(for: config) else {
                    throw ProviderAuthenticationError(message: "未指定本机 Auth 授权文件，请选择文件")
                }
                guard let data = try? Data(contentsOf: file),
                      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw ProviderAuthenticationError(message: "无法读取本机授权文件，请先在对应客户端登录")
                }
                object = parsed
            }
            guard let format = formats(source).first(where: { accepts($0, object: object) }),
                  let token = validString(at: format.tokenPath, in: object) else {
                throw ProviderAuthenticationError(message: "本机授权文件缺少受支持登录格式的有效访问令牌，请重新登录")
            }
            resolved.refreshKey = token
            resolved.authContext = [:]
            for (key, path) in format.contextPaths ?? [:] {
                if let value = contextString(at: path, in: object), !value.isEmpty {
                    guard value.rangeOfCharacter(from: .controlCharacters) == nil else {
                        throw ProviderAuthenticationError(message: "授权身份字段格式无效，请重新登录")
                    }
                    resolved.authContext[key] = value
                }
            }
            resolved.refreshHeader = config.authCallHeader ?? "Authorization: Bearer <key>"
            for (header, path) in (format.headerPaths ?? [:]).sorted(by: { $0.key < $1.key }) {
                if let value = string(at: path, in: object), !value.isEmpty {
                    guard value.rangeOfCharacter(from: .controlCharacters) == nil else {
                        throw ProviderAuthenticationError(message: "授权身份字段格式无效，请重新登录")
                    }
                    resolved.refreshHeader += "\n\(header): \(value)"
                }
            }
        default:
            throw ProviderAuthenticationError(message: "基础接入模式必须是 Auth 或 API Key")
        }
        resolved.credentialsResolved = true
        return resolved
    }

    private static func validString(at path: String, in object: [String: Any]) -> String? {
        guard let value = string(at: path, in: object),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return value
    }

    static func formats(_ source: ProviderCredentialSource) -> [ProviderCredentialFormat] {
        [ProviderCredentialFormat(tokenPath: source.tokenPath, headerPaths: source.headerPaths,
            requiredValues: source.requiredValues, contextPaths: source.contextPaths,
            tokenEncoding: source.tokenEncoding)] + (source.alternatives ?? [])
    }

    static func accepts(_ format: ProviderCredentialFormat, object: [String: Any]) -> Bool {
        guard (format.requiredValues ?? [:]).allSatisfy({ string(at: $0.key, in: object) == $0.value }),
              let token = validString(at: format.tokenPath, in: object) else { return false }
        guard let encoding = format.tokenEncoding else { return true }
        guard encoding == "jwt" else { return false }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy({ !$0.isEmpty })
            && jwtObject(String(parts[0])) != nil && jwtObject(String(parts[1])) != nil
    }

    static func jwtObject(_ segment: String) -> [String: Any]? {
        var encoded = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func string(at path: String, in object: [String: Any]) -> String? {
        value(at: path, in: object) as? String
    }

    private static func contextString(at path: String, in object: [String: Any]) -> String? {
        if let text = string(at: path, in: object) { return text }
        if let number = value(at: path, in: object) as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite { return number.stringValue }
        return nil
    }

    private static func value(at path: String, in object: [String: Any]) -> Any? {
        let keys = path.hasPrefix("/")
            ? path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map {
                String($0).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~") }
            : path.split(separator: ".").map(String.init)
        return keys.reduce(object as Any?) { current, key in
            if let dictionary = current as? [String: Any] { return dictionary[key] }
            // Some source formats embed a JSON object in a string. Decode only along the declared path.
            guard let text = current as? String, let data = text.data(using: .utf8),
                  let dictionary = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            return dictionary[key]
        }
    }
}
