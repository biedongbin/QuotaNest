import Foundation

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
        if config.authMode == "auth" {
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
        if let modes = config.quotaAuthModes, !modes.contains(config.authMode) {
            throw ProviderAuthenticationError(message: "此供应商用量接口不支持当前基础认证模式")
        }
        if config.queryAuth == "header" && config.authMode != "auth" {
            throw ProviderAuthenticationError(message: "此用量接口需要 Auth 登录，不能使用 API Key 查询订阅额度")
        }
        if ["jwt", "cookie"].contains(config.queryAuth ?? "") && config.inheritQueryURL == nil {
            throw ProviderAuthenticationError(message: "此类型暂未声明继承基础认证的用量接口")
        }
        var resolved = try resolveBase(config)
        resolved.queryUrl = config.inheritQueryURL ?? config.queryUrl
        resolved.queryKey = resolved.refreshKey
        resolved.queryHeader = config.inheritQueryHeader ?? resolved.refreshHeader
        return resolved
    }

    private static func resolveBase(_ config: ProviderConfig) throws -> ProviderConfig {
        if config.credentialsResolved { return config }
        var resolved = config
        switch config.authMode {
        case "apikey":
            guard !config.refreshKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProviderAuthenticationError(message: "请填写基础接入的 API Key")
            }
        case "auth":
            guard let source = config.credentialSource else {
                throw ProviderAuthenticationError(message: "此供应商未提供本机 Auth 适配，请选择 API Key 或使用支持 Auth 的类型")
            }
            guard let file = credentialFileURL(for: config) else {
                throw ProviderAuthenticationError(message: "未指定本机 Auth 授权文件，请选择文件")
            }
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ProviderAuthenticationError(message: "无法读取本机授权文件，请先在对应客户端登录")
            }
            let formats = [ProviderCredentialFormat(tokenPath: source.tokenPath, headerPaths: source.headerPaths,
                requiredValues: source.requiredValues, contextPaths: source.contextPaths)] + (source.alternatives ?? [])
            guard let format = formats.first(where: { format in
                (format.requiredValues ?? [:]).allSatisfy { string(at: $0.key, in: object) == $0.value }
                    && validString(at: format.tokenPath, in: object) != nil
            }), let token = validString(at: format.tokenPath, in: object) else {
                throw ProviderAuthenticationError(message: "本机授权文件缺少受支持登录格式的有效访问令牌，请重新登录")
            }
            resolved.refreshKey = token
            resolved.authContext = [:]
            for (key, path) in format.contextPaths ?? [:] {
                if let value = string(at: path, in: object), !value.isEmpty {
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

    private static func string(at path: String, in object: [String: Any]) -> String? {
        let keys: [String]
        if path.hasPrefix("/") {
            keys = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map {
                String($0).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            }
        } else {
            keys = path.split(separator: ".").map(String.init)
        }
        return keys.reduce(object as Any?) { value, key in
            (value as? [String: Any])?[key]
        } as? String
    }
}
