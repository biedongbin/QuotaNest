import Foundation

/// A private, short-lived compatibility input for existing supplier scripts.
/// The account's configuration remains unchanged, including local Auth tokens.
struct ProviderQuerySnapshot {
    let file: URL
    let queryURL: String
    let secrets: [String]
    private let directory: URL

    static func make(config: ProviderConfig, manifest: ProviderManifest, originalAuth: URL) throws -> ProviderQuerySnapshot {
        let resolved = try ProviderAuthentication.resolveQuota(config)
        var object = (try? Data(contentsOf: originalAuth)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        } ?? [:]
        object = ProviderConfigStore.removingQueryCredentials(from: object, manifest: manifest)
        object["authMode"] = config.authMode
        object["tokenhudResolvedAuth"] = true
        object["queryKey"] = resolved.queryKey
        object["apiKey"] = resolved.queryKey
        object["refreshApiKey"] = resolved.queryKey
        object["apiUrl"] = resolved.queryUrl
        object["queryUrl"] = resolved.queryUrl
        if let field = manifest.queryKeyField { object[field] = resolved.queryKey }
        var request = URLRequest(url: URL(string: resolved.queryUrl) ?? URL(fileURLWithPath: "/"))
        RefreshTrigger.applyHeaders(&request, resolved.queryHeader, key: resolved.queryKey, protocol: resolved.refreshProtocol)
        let headers = request.allHTTPHeaderFields ?? [:]
        object["headers"] = headers
        object["accountId"] = headers.first(where: { $0.key.lowercased() == "chatgpt-account-id" })?.value
        if let key = config.credentialSource?.fileConfigKey,
           let source = ProviderAuthentication.credentialFileURL(for: config) { object[key] = source.path }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tokenhud-query-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("auth.json")
        do {
            try JSONSerialization.data(withJSONObject: object).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return ProviderQuerySnapshot(file: file, queryURL: resolved.queryUrl,
                                     secrets: [resolved.refreshKey, resolved.queryKey], directory: directory)
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}
