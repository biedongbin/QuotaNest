import Foundation
import CryptoKit

/// Conservative matching of locally supplied authorization evidence, not server-side ownership verification.
/// Missing or conflicting identity fields never count as duplicates; no raw evidence is written to disk.
enum ProviderAccountIdentity {
    static func fingerprint(record: SourceRecord, template: PluginProvider?) -> String? {
        guard record.authMode == "auth", let source = template?.manifest.credentialSource,
              let rule = source.accountIdentity,
              let format = ProviderAuthentication.formats(source).first(where: {
                  ProviderAuthentication.accepts($0, object: record.object)
              }), let token = ProviderAuthentication.string(at: format.tokenPath, in: record.object) else { return nil }
        let path = format.headerPaths?.first(where: {
            $0.key.caseInsensitiveCompare(rule.workspaceHeader) == .orderedSame
        })?.value
        let workspace = path.flatMap { ProviderAuthentication.string(at: $0, in: record.object) }
        return fingerprint(token: token, workspace: workspace, rule: rule)
    }

    static func fingerprint(provider: PluginProvider, templates: [PluginProvider]) -> String? {
        let declaration = provider.manifest.credentialSource?.accountIdentity
            ?? templates.first(where: { $0.slug == provider.manifest.template })?.manifest.credentialSource?.accountIdentity
        guard let rule = declaration, let file = provider.manifest.authFile else { return nil }
        let config = ProviderConfigStore.read(authFile: PluginGenerator.expandPath(file), manifest: provider.manifest)
        guard let resolved = try? ProviderAuthentication.resolveBase(config), resolved.authMode == "auth" else { return nil }
        let values = resolved.refreshHeader.split(separator: "\n").compactMap { line -> String? in
            let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2,
                  pieces[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(rule.workspaceHeader) == .orderedSame else { return nil }
            return pieces[1].trimmingCharacters(in: .whitespaces)
        }
        guard values.count <= 1 else { return nil }
        return fingerprint(token: resolved.refreshKey, workspace: values.first, rule: rule)
    }

    static func index(providers: [PluginProvider], templates: [PluginProvider]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: providers.compactMap { provider in
            fingerprint(provider: provider, templates: templates).map { (provider.slug, $0) }
        })
    }

    static func duplicateGroups(providers: [PluginProvider], templates: [PluginProvider]) -> [[PluginProvider]] {
        let identities = index(providers: providers, templates: templates)
        return Dictionary(grouping: providers.filter { identities[$0.slug] != nil }, by: { identities[$0.slug] ?? "" })
            .values.filter { $0.count > 1 }.map { $0.sorted { $0.slug < $1.slug } }
            .sorted { ($0.first?.slug ?? "") < ($1.first?.slug ?? "") }
    }

    private static func fingerprint(token: String, workspace: String?, rule: ProviderAccountIdentityRule) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let claims = ProviderAuthentication.jwtObject(String(parts[1])),
              let issuer = claims["iss"] as? String,
              let subject = ProviderAuthentication.string(at: rule.subjectClaim, in: claims),
              valid(rule.namespace), valid(subject), valid(issuer) else { return nil }
        let claimedWorkspace = rule.workspaceClaim.flatMap { ProviderAuthentication.string(at: $0, in: claims) }
        guard let workspace = workspace ?? claimedWorkspace, valid(workspace) else { return nil }
        let canonicalIssuer = issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let allowed = rule.allowedIssuers,
           !allowed.map({ $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }).contains(canonicalIssuer) { return nil }
        if let claimedWorkspace, claimedWorkspace != workspace { return nil }
        let fields = ["version": "1", "namespace": rule.namespace, "issuer": canonicalIssuer,
                      "subject": subject, "workspace": workspace]
        guard let bytes = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return nil }
        return "account-sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1_024
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }
}
