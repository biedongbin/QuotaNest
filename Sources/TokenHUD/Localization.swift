import Foundation
import Observation
import SwiftUI

/// Stable persisted identifiers; language names remain in their own language.
enum AppLanguage: String, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }
    var label: String { self == .simplifiedChinese ? "简体中文" : "English" }
    var locale: Locale { Locale(identifier: rawValue) }
}

@Observable
final class AppLanguageSettings {
    static let shared = AppLanguageSettings()
    static let defaultsKey = "quotanest.appLanguage"
    static let didChange = Notification.Name("QuotaNest.AppLanguageDidChange")

    private let defaults: UserDefaults
    var selection: AppLanguage {
        didSet {
            guard selection != oldValue else { return }
            defaults.set(selection.rawValue, forKey: Self.defaultsKey)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }
    var locale: Locale { selection.locale }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = defaults.string(forKey: Self.defaultsKey).flatMap(AppLanguage.init(rawValue:)) ?? .simplifiedChinese
    }
}

/// Uses Foundation's native .lproj and Localizable.strings lookup. Arguments are
/// user data and are passed to the format only after the app-owned key resolves.
enum L10n {
    static var locale: Locale { AppLanguageSettings.shared.locale }

    static func bundle(for language: AppLanguage) -> Bundle? {
        // SwiftPM normalizes folder names (for example, zh-Hans → zh-hans).
        // Open the selected directory directly; resource lookup on the parent
        // bundle can otherwise resolve its preferred language instead.
        guard let localization = Bundle.appResources.localizations.first(where: {
            $0.caseInsensitiveCompare(language.rawValue) == .orderedSame
        }), let directory = Bundle.appResources.resourceURL?.appendingPathComponent(localization + ".lproj", isDirectory: true) else {
            return nil
        }
        return Bundle(url: directory)
    }

    static func tr(_ key: String, _ arguments: CVarArg...) -> String {
        tr(key, language: AppLanguageSettings.shared.selection, arguments: arguments)
    }

    static func tr(_ key: String, language: AppLanguage, arguments: [CVarArg] = []) -> String {
        // A missing selected resource falls back to its source key, never to a
        // different language chosen from the parent bundle's preferences.
        let format = bundle(for: language)?.localizedString(forKey: key, value: key, table: "Localizable") ?? key
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: language.locale, arguments: arguments)
    }

    static func resource(_ value: String.LocalizationValue) -> LocalizedStringResource {
        LocalizedStringResource(value, bundle: .atURL(Bundle.appResources.bundleURL))
    }

    static func string(_ resource: LocalizedStringResource, language: AppLanguage = AppLanguageSettings.shared.selection) -> String {
        var resource = resource
        resource.locale = language.locale
        return String(localized: resource)
    }

    /// Only app-owned typed failures are localization keys; arbitrary runtime
    /// errors and server response bodies are always returned verbatim.
    static func errorDescription(_ error: Error) -> String {
        errorDescription(error, language: AppLanguageSettings.shared.selection)
    }

    static func errorDescription(_ error: Error, language: AppLanguage) -> String {
        func text(_ key: String, _ arguments: CVarArg...) -> String {
            tr(key, language: language, arguments: arguments)
        }
        if let error = error as? ProviderAuthenticationError { return text(error.message) }
        guard let error = error as? ModelCatalogError else { return error.localizedDescription }
        switch error {
        case .http(let status, let body):
            let explanation: String
            switch status {
            case 401: explanation = text("模型列表认证失败（HTTP 401），请检查当前调用凭证。")
            case 403: explanation = text("供应商拒绝访问模型列表（HTTP 403），请检查当前调用凭证的权限。")
            case 404: explanation = text("供应商未提供此标准模型列表接口（HTTP 404），可手动填写测试模型。")
            case 429: explanation = text("模型列表请求受到限流（HTTP 429），请稍后重试。")
            case 300..<400: explanation = text("模型列表接口要求重定向（HTTP %@），已停止请求；请核对 API Base URL。", String(status))
            default: explanation = text("拉取模型列表失败（HTTP %@）。", String(status))
            }
            return body.isEmpty ? explanation : explanation + text("\n\n服务端响应：\n") + body
        case .invalidConnection(let message), .invalidResponse(let message):
            return text(message)
        case .transport(let message):
            return message
        case .responseTooLarge, .emptyModels:
            return text(error.localizedDescription)
        }
    }

    static func number(_ value: Double, fractionLength: ClosedRange<Int> = 0...2) -> String {
        value.formatted(.number.precision(.fractionLength(fractionLength)).locale(locale))
    }

    /// Input is a percentage already in the 0...100 domain.
    static func percent(_ value: Double, fractionLength: ClosedRange<Int> = 0...1) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(fractionLength)).locale(locale))
    }
}

private struct AppLanguageEnvironment: ViewModifier {
    @State private var settings = AppLanguageSettings.shared
    func body(content: Content) -> some View {
        content.environment(\.locale, settings.locale)
    }
}

extension View {
    func appLanguageEnvironment() -> some View { modifier(AppLanguageEnvironment()) }
}

/// Owns an AppKit observer and removes it when its owner goes away.
final class AppLanguageObservation {
    private let center: NotificationCenter
    private var token: NSObjectProtocol?

    init(center: NotificationCenter = .default, onChange: @escaping () -> Void) {
        self.center = center
        token = center.addObserver(forName: AppLanguageSettings.didChange, object: nil, queue: .main) { _ in onChange() }
    }
    deinit { if let token { center.removeObserver(token) } }
}
