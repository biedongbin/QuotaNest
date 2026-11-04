import Foundation
import CoreFoundation

/// Account validity is independent of monitoring and the latest transport failure.
enum AccountHealth: Equatable {
    case healthy
    case issue(reason: String)

    var isHealthy: Bool {
        if case .healthy = self { return true }
        return false
    }

    var issueReason: String? {
        if case .issue(let reason) = self { return reason }
        return nil
    }
}

enum AccountStatusFilter: String, Identifiable, CaseIterable {
    case all, enabled, disabled, abnormal, healthyEnabled
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "全部"
        case .enabled: return "启用"
        case .disabled: return "关闭"
        case .abnormal: return "账号异常"
        case .healthyEnabled: return "启用且正常"
        }
    }

    func includes(_ row: AccountRow) -> Bool {
        switch self {
        case .all: return true
        case .enabled: return row.enabled
        case .disabled: return !row.enabled
        case .abnormal: return !row.health.isHealthy
        case .healthyEnabled: return row.enabled && row.health.isHealthy
        }
    }
}

/// Offline readiness plus explicit runtime evidence; never probes an API.
enum AccountHealthAssessment {
    static func configuration(manifest: ProviderManifest, config: ProviderConfig,
                              now: Date = Date(), scheduleEnabled: Bool = false,
                              resolve: (ProviderConfig) throws -> ProviderConfig = ProviderAuthentication.resolveQuota) -> AccountHealth {
        guard ["none", "endpoint", "script"].contains(config.quotaMode) else {
            return .issue(reason: "不支持的额度查询模式")
        }
        if config.quotaMode != "none" && !manifest.supportsQuota {
            return .issue(reason: "该类型不支持所选额度查询模式")
        }
        if config.quotaMode == "script", manifest.template == nil,
           manifest.quotaMode == "endpoint" {
            return .issue(reason: "该类型未提供脚本额度查询适配")
        }
        // With quota disabled only resolve the base identity, without requiring a call adapter.
        var input = config
        if config.quotaMode == "none" {
            input.quotaAuthModes = nil
            input.queryAuth = nil
        }
        let resolved: ProviderConfig
        do { resolved = try resolve(input) }
        catch { return .issue(reason: error.localizedDescription) }
        if config.authMode == "auth", jwtExpired(resolved.refreshKey, now: now) {
            return .issue(reason: "Auth 凭证已过期，请重新登录")
        }
        for address in [config.apiBaseURL, config.refreshUrl, config.authMode == "auth" ? (config.authCallURL ?? "") : ""]
            where !address.isEmpty {
            if !SettingsValidation.isValidURL(address) { return .issue(reason: "基础接入地址无效") }
        }
        if config.quotaMode != "none" {
            // Script adapters may derive their route from declared Auth context.
            if config.quotaMode == "endpoint" || !resolved.queryUrl.isEmpty {
                guard SettingsValidation.isValidURL(resolved.queryUrl) else {
                    return .issue(reason: "额度查询地址缺失或无效")
                }
            }
        } else if config.authMode == "apikey" && config.apiBaseURL.isEmpty && config.refreshUrl.isEmpty {
            return .issue(reason: "请填写基础接入的服务地址")
        }
        if scheduleEnabled && !config.scheduleTimes.isEmpty {
            let callURL = config.authMode == "auth" ? (config.authCallURL ?? "") : config.refreshUrl
            if !SettingsValidation.isValidURL(callURL) { return .issue(reason: "调用计划缺少有效调用地址") }
            if config.testModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .issue(reason: "调用计划未配置模型")
            }
        }
        return .healthy
    }

    static func assess(configuration: AccountHealth, cache: UsageCache?, callResult: CallTestResult?,
                       lastSuccess: Date? = nil) -> AccountHealth {
        guard configuration.isHealthy else { return configuration }
        var issues: [(date: Date, reason: String)] = []
        if let cache, let error = cache.error, let reason = persistentIssue(error) {
            let attempt = Date(timeIntervalSince1970: (cache.lastAttemptAt ?? cache.generatedAt ?? 0) / 1000)
            let snapshot = cache.generatedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
            // A successful model call cannot prove a separate quota endpoint works.
            let queryRecovered = lastSuccess.map { $0 >= attempt } == true
                || snapshot.map { $0 > attempt } == true
            if !queryRecovered { issues.append((attempt, reason)) }
        }
        // This is the latest saved-call evidence; only a newer call success replaces its issue.
        if let result = callResult, result.phase == .failure,
           let reason = persistentIssue(result.message) {
            issues.append((result.date, reason))
        }
        guard let latest = issues.max(by: { $0.date < $1.date }) else { return .healthy }
        return .issue(reason: latest.reason)
    }

    /// Only stable, explicit error categories are evidence of account damage.
    static func persistentIssue(_ message: String) -> String? {
        let text = message.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // The actual response status outranks words quoted in its body.
        if matches(#"^http(?:/\d(?:\.\d)?)?\s+401\b"#, in: text) {
            return "凭证无效或已过期，请检查基础认证"
        }
        if matches(#"^http(?:/\d(?:\.\d)?)?\s+(?:429|5\d\d)\b"#, in: text) { return nil }
        let transient = ["timeout", "timed out", "network", "dns", "disconnect", "connection", "超时", "断连", "网络", "no-query", "parse", "busy", "繁忙", "uncertain"]
        if transient.contains(where: text.contains) { return nil }
        if ["auth", "no-auth", "expired", "authfail", "auth-failed", "invalid-api-key", "invalid_api_key"].contains(text)
            || ["unauthorized", "authentication failed", "authentication_error", "invalid api key", "invalid_api_key", "invalid token", "invalid_token", "token expired", "token_expired", "token has expired", "credential expired", "凭证无效", "凭证已过期", "认证失败", "授权已过期"].contains(where: text.contains) {
            return "凭证无效或已过期，请检查基础认证"
        }
        if ["insufficient permissions", "permission denied", "missing entitlement", "not entitled"].contains(where: text.contains) {
            return "账号缺少所需权限或套餐授权"
        }
        if ["invalid model", "invalid_model", "model_not_found", "invalid baseurl", "invalid base url", "invalid_base_url", "endpoint not found", "not found endpoint", "unknown endpoint", "模型不存在", "调用地址无效"].contains(where: text.contains) {
            return "API 模型或接口地址配置错误"
        }
        return nil
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// Decode only the standard numeric JWT expiry; opaque credentials remain valid candidates.
    static func jwtExpired(_ token: String, now: Date) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[1].count <= 65_536 else { return false }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expiry = object["exp"] as? NSNumber,
              CFGetTypeID(expiry) != CFBooleanGetTypeID() else { return false }
        return expiry.doubleValue <= now.timeIntervalSince1970
    }
}
