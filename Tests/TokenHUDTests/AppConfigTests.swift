import Foundation
import Testing
@testable import QuotaNest

@Suite
struct AppConfigTests {
    private let home = URL(fileURLWithPath: "/tmp/tokenhud-config-home", isDirectory: true)
    private let working = URL(fileURLWithPath: "/tmp/tokenhud-config-work", isDirectory: true)

    @Test func defaultConfigPathsShareOneRoot() {
        let paths = AppConfigPaths(environment: [:], userHome: home, workingDirectory: working)
        #expect(paths.configDir.path == home.appendingPathComponent(".claude").path)
        #expect(paths.hudDir == paths.configDir.appendingPathComponent("hud", isDirectory: true))
        #expect(paths.settingsURL == paths.configDir.appendingPathComponent("settings.json"))
        #expect(paths.userProvidersDir == home.appendingPathComponent("Library/Application Support/QuotaNest/providers", isDirectory: true))
    }

    @Test func explicitConfigDirectoryAppliesToHudAndSettings() {
        let paths = AppConfigPaths(environment: ["CLAUDE_CONFIG_DIR": "/tmp/tokenhud-custom-config"],
                                   userHome: home, workingDirectory: working)
        #expect(paths.hudDir.path == "/tmp/tokenhud-custom-config/hud")
        #expect(paths.settingsURL.path == "/tmp/tokenhud-custom-config/settings.json")
    }

    @Test func configDirectoryExpandsInjectedHomeAndRelativePaths() {
        let tilde = AppConfigPaths(environment: ["CLAUDE_CONFIG_DIR": "~/alternate"],
                                   userHome: home, workingDirectory: working)
        #expect(tilde.configDir.path == home.appendingPathComponent("alternate").path)
        let relative = AppConfigPaths(environment: ["CLAUDE_CONFIG_DIR": "config"],
                                      userHome: home, workingDirectory: working)
        #expect(relative.configDir.path == working.appendingPathComponent("config").path)
        let blank = AppConfigPaths(environment: ["CLAUDE_CONFIG_DIR": "   "],
                                   userHome: home, workingDirectory: working)
        #expect(blank.configDir == home.appendingPathComponent(".claude", isDirectory: true))
    }

    @Test func diagnosticModesNeverStartBackgroundEngine() {
        for environment in [
            ["TOKENHUD_RENDER": "/tmp/tokenhud-images"],
            ["TOKENHUD_RENDER": ""],
            ["TOKENHUD_DEBUG_SETTINGS": "1"],
            ["TOKENHUD_IMPORT_SCAN": "1"],
            ["QUOTANEST_DEBUG_STATUS_POPOVER": "1"],
            ["TOKENHUD_ENVS_FIX": "1"],
            ["QUOTANEST_MIGRATE_ONLY": "1"],
            ["QUOTANEST_RENDER": "/tmp/quotanest-images"]
        ] {
            #expect(!AppLaunchMode(environment: environment).startsBackgroundEngine)
        }
        #expect(AppLaunchMode(environment: [:]).startsBackgroundEngine)
    }

    @Test func renderTakesPrecedenceOverExplicitHudRepair() {
        let mode = AppLaunchMode(environment: ["TOKENHUD_RENDER": "/tmp/tokenhud-images",
                                                "TOKENHUD_ENVS_FIX": "1"])
        #expect(mode == .render("/tmp/tokenhud-images"))
        #expect(!mode.startsBackgroundEngine)
    }
}
