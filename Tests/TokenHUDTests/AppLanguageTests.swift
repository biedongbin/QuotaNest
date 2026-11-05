import Foundation
import Observation
import Testing
@testable import TokenHUD

@Suite(.serialized)
@MainActor
struct AppLanguageTests {
    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let name = "tokenhud.language-tests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test func defaultsToSimplifiedChineseAndIgnoresUnsupportedPreference() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AppLanguageSettings(defaults: defaults).selection == .simplifiedChinese)
        defaults.set("unsupported", forKey: AppLanguageSettings.defaultsKey)
        #expect(AppLanguageSettings(defaults: defaults).selection == .simplifiedChinese)
        #expect(AppLanguage.simplifiedChinese.rawValue == "zh-Hans")
        #expect(AppLanguage.english.rawValue == "en")
    }

    @Test func selectionPersistsAndResourcesSwitchImmediatelyInBothDirections() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppLanguageSettings(defaults: defaults)
        #expect(L10n.tr("设置与外观", language: settings.selection) == "设置与外观")
        settings.selection = .english
        #expect(defaults.string(forKey: AppLanguageSettings.defaultsKey) == "en")
        #expect(AppLanguageSettings(defaults: defaults).selection == .english)
        #expect(settings.locale.identifier == "en")
        #expect(L10n.tr("设置与外观", language: settings.selection) == "Settings & Appearance")
        settings.selection = .simplifiedChinese
        #expect(L10n.tr("设置与外观", language: settings.selection) == "设置与外观")
        #expect(defaults.string(forKey: AppLanguageSettings.defaultsKey) == "zh-Hans")
        let labels = [("设置与外观", "Settings & Appearance"), ("额度", "Quota"), ("账号状态", "Account status")]
        for language in [AppLanguage.english, .simplifiedChinese, .english, .simplifiedChinese] {
            settings.selection = language
            for (chinese, english) in labels {
                #expect(L10n.tr(chinese, language: settings.selection) == (language == .english ? english : chinese))
            }
        }
    }

    @Test func nativeResourcesRetainArgumentsWhileLocaleChanges() {
        let name = "我的账户 / %@ / Alice 🍵"
        let resource = L10n.resource("打开账号 \(name)")
        #expect(L10n.string(resource, language: .english) == "Open account \(name)")
        #expect(L10n.string(resource, language: .simplifiedChinese) == "打开账号 \(name)")
        #expect(L10n.tr("打开账号 %@", language: .english, arguments: [name]) == "Open account \(name)")
    }

    @Test func observableSelectionInvalidatesViewsWithoutReplacingTheSettingsObject() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppLanguageSettings(defaults: defaults)
        let changes = ChangeCounter()
        withObservationTracking {
            _ = settings.selection
        } onChange: {
            changes.increment()
        }
        settings.selection = .english
        #expect(changes.value == 1)
        #expect(settings.selection == .english)
    }

    private func table(_ language: AppLanguage) throws -> [String: String] {
        let bundle = try #require(L10n.bundle(for: language))
        #expect(bundle.bundleURL.lastPathComponent.lowercased() == language.rawValue.lowercased() + ".lproj")
        let url = try #require(bundle.url(forResource: "Localizable", withExtension: "strings"))
        let data = try Data(contentsOf: url)
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    @Test func everyResourceKeyExistsInBothLanguagesAndFormatsMatch() throws {
        let chinese = try table(.simplifiedChinese)
        let english = try table(.english)
        #expect(chinese.count > 500)
        #expect(Set(chinese.keys) == Set(english.keys))
        #expect(chinese["设置与外观"] == "设置与外观")
        #expect(english["设置与外观"] == "Settings & Appearance")
        let placeholders = try NSRegularExpression(pattern: #"%(?:\d+\$)?[-+ #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|h|l|z|t|j)?[@diuoxXfFeEgGaAcCsSp%]"#)
        func formats(_ value: String) -> [String] {
            placeholders.matches(in: value, range: NSRange(value.startIndex..., in: value))
                .compactMap { Range($0.range, in: value).map { String(value[$0]) } }.sorted()
        }
        for (key, value) in chinese {
            let translation = try #require(english[key])
            #expect(!translation.isEmpty)
            #expect(formats(key) == formats(value), "Chinese format differs for \(key)")
            #expect(formats(value) == formats(translation), "English format differs for \(key)")
            #expect(L10n.tr(key, language: .english) == translation)
            #expect(L10n.tr(key, language: .simplifiedChinese) == value)
        }
        #expect(english["简体中文"] == "简体中文")
        #expect(chinese["English"] == "English")
    }

    @Test func dynamicNamesAndRawRuntimeErrorsRemainVerbatim() {
        let name = "账号 / 中文 English %1$@"
        #expect(L10n.tr("启用 %@", language: .english, arguments: [name]) == "Enable \(name)")
        let raw = "HTTP 503: 服务端原文 / upstream network problem %@"
        let error = NSError(domain: "fixture.runtime", code: 503, userInfo: [NSLocalizedDescriptionKey: raw])
        #expect(L10n.errorDescription(error, language: .english) == raw)
        #expect(QuotaErrorPresentation.message(for: raw) == raw)
        let server = ModelCatalogError.http(status: 503, body: raw)
        #expect(L10n.errorDescription(server, language: .english).hasSuffix(raw))
        #expect(WindowBucket(label: "自定义窗口 / Raw Window").localizedLabel(language: .english) == "自定义窗口 / Raw Window")
        #expect(WindowBucket(label: "本周").localizedLabel(language: .english) == "This week")
    }

    @Test func sourceSyncSummaryUsesNativeStringArgumentsInBothLanguages() {
        let clean = DataEngine.sourceSyncSummary(updated: 2, registered: 3, unchanged: 4, issues: 0)
        let issues = DataEngine.sourceSyncSummary(updated: 2, registered: 3, unchanged: 4, issues: 1)
        #expect(L10n.string(clean, language: .english) == "Source check complete: 2 corrected, 3 registered, 4 unchanged")
        #expect(L10n.string(issues, language: .english) == "Source check complete: 2 corrected, 3 registered, 4 unchanged, 1 need attention")
        #expect(L10n.string(clean, language: .simplifiedChinese) == "来源检查完成：订正 2，登记 3，未变 4")
        #expect(L10n.string(issues, language: .simplifiedChinese) == "来源检查完成：订正 2，登记 3，未变 4，需处理 1")
    }

    @Test func nativeMenuObserverIsRemovedWhenItsOwnerIsReleased() {
        let center = NotificationCenter()
        var calls = 0
        var observation: AppLanguageObservation? = AppLanguageObservation(center: center) { calls += 1 }
        weak var weakObservation = observation
        center.post(name: AppLanguageSettings.didChange, object: nil)
        #expect(calls == 1)
        observation = nil
        #expect(weakObservation == nil)
        center.post(name: AppLanguageSettings.didChange, object: nil)
        #expect(calls == 1)
    }
}

private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
}
