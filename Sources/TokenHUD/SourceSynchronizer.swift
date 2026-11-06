import Foundation
import CryptoKit

extension ProviderSourceReference {
    /// Persisted evidence may evolve without creating a second imported account.
    func sameSourceRecord(as other: ProviderSourceReference) -> Bool {
        source == other.source && normalizedPath == other.normalizedPath && recordId == other.recordId
            && providerId == other.providerId && collection == other.collection
            && credentialProviderId == other.credentialProviderId
    }

    private var normalizedPath: String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }
}

/// Produces local reference metadata only. Never writes a source or resolves network credentials.
enum SourceSynchronizer {
    enum Result: Equatable, Sendable {
        case correctedRef(ProviderSourceReference)
        case unchanged(ProviderSourceReference)
        case unavailable(String)
        case ambiguous(String)

        var reference: ProviderSourceReference? {
            switch self {
            case .correctedRef(let reference), .unchanged(let reference): return reference
            case .unavailable, .ambiguous: return nil
            }
        }
    }

    static func reconcile(reference: ProviderSourceReference, template: PluginProvider? = nil,
                          authMode: String, protocolName: String? = nil) -> Result {
        scan(reference: reference, template: template, authMode: authMode, protocolName: protocolName)
    }

    static func scan(reference: ProviderSourceReference, template: PluginProvider? = nil,
                     authMode: String, protocolName: String? = nil) -> Result {
        do {
            let records = try ImportedSource.references(in: reference)
            let current = records.filter { $0.recordId == reference.recordId &&
                (reference.source != "cc-switch" || $0.providerId == reference.providerId) }
            if !current.isEmpty {
                guard current.count == 1 else { return .ambiguous("原来源记录主键不唯一，同步未修改引用") }
                let record = try ImportedSource.read(reference)
                try validate(record, reference: reference, template: template, authMode: authMode,
                             protocolName: protocolName)
                return .unchanged(register(reference, record: record, template: template))
            }
            guard let anchor = reference.identityAnchor, anchor.hasPrefix("sha256:"), anchor.count == 71 else {
                return .unavailable("原来源记录已不存在且没有可信身份摘要，请重新扫描导入；不会按名称或供应商猜测")
            }
            var renameIDs: [String] = []
            if reference.source == "magpie", reference.collection?.hasPrefix("providers") == true {
                renameIDs = try ImportedSource.magpieRenameIDs(reference)
                guard renameIDs.count <= 1 else { return .ambiguous("Magpie was 包含原 ID 的候选不唯一，同步未修改引用") }
            }
            var matches: [ProviderSourceReference] = []
            for candidate in records where inScope(candidate, original: reference) {
                let record = try ImportedSource.read(candidate)
                let sameAnchor = credentialAnchor(record, template: template) == anchor
                let renamed = renameIDs == [candidate.recordId]
                guard sameAnchor || renamed else { continue }
                // A rename assertion alone is accepted only with the saved type and exact endpoint evidence.
                guard compatibleIdentity(record, reference: reference) else {
                    throw ImportedSource.failure("来源候选的类型、接口或协议已变化，请重新扫描确认")
                }
                try validate(record, reference: candidate, template: template, authMode: authMode,
                             protocolName: protocolName)
                matches.append(register(candidate, record: record, template: template, original: reference))
            }
            guard matches.count <= 1 else { return .ambiguous("多个来源记录具有相同可信身份摘要，同步未修改引用") }
            guard let corrected = matches.first else {
                return .unavailable("原来源记录已不存在，未找到唯一且兼容的身份；令牌与 ID 同时变化时请重新扫描")
            }
            return .correctedRef(corrected)
        } catch { return .unavailable(error.localizedDescription) }
    }

    /// Called only after the original record has passed its normal read and adapter validation.
    static func register(_ reference: ProviderSourceReference, record: SourceRecord,
                         template: PluginProvider? = nil, original: ProviderSourceReference? = nil) -> ProviderSourceReference {
        var result = reference
        let trace = original ?? reference
        result.originalRecordId = trace.originalRecordId ?? trace.recordId
        result.originalProviderId = trace.originalProviderId ?? trace.providerId
        result.identityAnchor = credentialAnchor(record, template: template)
        result.identityProtocol = record.protocolName
        result.identityEndpoint = digest(record.baseURL)
        result.identityProviderType = providerType(record)
        if reference.source == "magpie", ["logins", "plugin-auth"].contains(reference.collection ?? "") {
            result.identityAccount = trace.identityAccount ?? ImportedSource.accountIdentity(record.object)
        }
        return result
    }

    private static func inScope(_ candidate: ProviderSourceReference, original: ProviderSourceReference) -> Bool {
        guard candidate.source == original.source, candidate.collection == original.collection,
              candidate.credentialProviderId == original.credentialProviderId else { return false }
        if original.source == "magpie", original.collection?.hasPrefix("providers") == true { return true }
        if original.source == "magpie", original.collection == "plugin-auth" {
            let provider = original.credentialProviderId ?? original.providerId ?? ""
            return candidate.providerId == original.providerId && !provider.isEmpty &&
                (candidate.recordId == provider || candidate.recordId.hasPrefix(provider + "#"))
        }
        return candidate.providerId == original.providerId
    }

    private static func compatibleIdentity(_ record: SourceRecord, reference: ProviderSourceReference) -> Bool {
        guard let proto = reference.identityProtocol, normalized(proto) == normalized(record.protocolName) else { return false }
        if reference.source == "magpie", reference.collection?.hasPrefix("providers") == true {
            return reference.identityEndpoint == digest(record.baseURL) &&
                reference.identityProviderType == providerType(record)
        }
        return true
    }

    static func validate(_ record: SourceRecord, reference: ProviderSourceReference,
                                 template: PluginProvider?, authMode: String, protocolName: String?) throws {
        guard record.authMode == authMode else { throw ImportedSource.failure("来源认证模式已变化，请重新扫描") }
        if let expectedType = reference.identityProviderType, providerType(record) != expectedType {
            throw ImportedSource.failure("来源供应商类型已变化，请重新扫描")
        }
        if reference.identityAnchor != nil, reference.source == "magpie",
           reference.collection?.hasPrefix("providers") == true,
           reference.identityProviderType != providerType(record) {
            throw ImportedSource.failure("来源供应商类型已变化，请重新扫描")
        }
        for expectedProtocol in [reference.identityProtocol, protocolName].compactMap({ $0 }) where !expectedProtocol.isEmpty {
            guard normalized(expectedProtocol) == normalized(record.protocolName) else {
                throw ImportedSource.failure("来源调用协议已变化，请重新扫描")
            }
        }
        if record.authMode == "apikey" {
            guard !record.key.isEmpty, record.key.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw ImportedSource.failure("来源缺少有效 API Key")
            }
        }
        guard let template else {
            guard record.authMode == "apikey", let url = URLComponents(string: record.baseURL),
                  ["http", "https"].contains(url.scheme ?? ""), url.host != nil, url.user == nil,
                  ["openai", "chat", "responses", "anthropic"].contains(record.protocolName) else {
                throw ImportedSource.failure("来源缺少兼容的模板或通用接口")
            }
            return
        }
        if record.authMode == "auth" {
            guard credentialAnchor(record, template: template) != nil else {
                throw ImportedSource.failure("来源授权结构不匹配当前模板")
            }
        }
        if reference.source == "magpie", reference.collection?.hasPrefix("providers") == true {
            let templates = ProviderImporter.bundledTemplates()
            let identity = record.object["preset"] as? String ?? record.object["catalog"] as? String
                ?? record.object["id"] as? String ?? ""
            let declared = ProviderImporter.matchingTemplate(provider: identity, base: "", templates: templates)
            let endpoint = ProviderImporter.matchingTemplate(provider: "", base: record.baseURL, templates: templates)
            guard (declared == nil || declared?.slug == template.slug), endpoint?.slug == template.slug else {
                throw ImportedSource.failure("导入来源供应商类型或固定接口已变化，请重新导入")
            }
        }
    }

    private static func credentialAnchor(_ record: SourceRecord, template: PluginProvider?) -> String? {
        if record.authMode == "apikey" { return record.key.isEmpty ? nil : digest(record.key) }
        if let source = template?.manifest.credentialSource {
            let formats = ProviderAuthentication.formats(source)
            for format in formats where ProviderAuthentication.accepts(format, object: record.object) {
                if let token = string(format.tokenPath, in: record.object), !token.isEmpty { return digest(token) }
            }
            return nil
        }
        // Exact source token layouts only; never hash email, display names, or arbitrary JSON blobs.
        for path in ["accessToken", "access_token", "access", "token.access_token", "tokens.access_token"] {
            if let token = string(path, in: record.object), !token.isEmpty { return digest(token) }
        }
        return nil
    }

    private static func string(_ path: String, in object: [String: Any]) -> String? {
        ProviderAuthentication.string(at: path, in: object)
    }

    private static func providerType(_ record: SourceRecord) -> String? {
        record.object["preset"] as? String ?? record.object["catalog"] as? String ?? record.object["type"] as? String
    }

    private static func digest(_ value: String) -> String {
        "sha256:" + SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalized(_ value: String) -> String { value == "chat" ? "openai" : value }
}
