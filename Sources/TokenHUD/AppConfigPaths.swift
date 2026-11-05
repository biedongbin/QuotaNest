import Foundation

/// Claude 配置路径只解析一次，HUD 与设置文件始终来自同一个根目录。
struct AppConfigPaths {
    let configDir: URL
    let userProvidersDir: URL
    var hudDir: URL { configDir.appendingPathComponent("hud", isDirectory: true) }
    var settingsURL: URL { configDir.appendingPathComponent("settings.json") }

    init(environment: [String: String], userHome: URL, workingDirectory: URL) {
        userProvidersDir = userHome.appendingPathComponent("Library/Application Support/QuotaNest/providers", isDirectory: true)
        let configured = environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let root: URL
        if configured.isEmpty {
            root = userHome.appendingPathComponent(".claude", isDirectory: true)
        } else if configured == "~" {
            root = userHome
        } else if configured.hasPrefix("~/") {
            root = userHome.appendingPathComponent(String(configured.dropFirst(2)), isDirectory: true)
        } else if configured.hasPrefix("/") {
            root = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            // 相对路径按进程工作目录解析；~ 仅支持当前用户，不猜测 ~otheruser。
            root = workingDirectory.appendingPathComponent(configured, isDirectory: true)
        }
        configDir = root.standardizedFileURL
    }
}

/// 诊断启动先分流；任何诊断模式都不启动后台查询、模型计划或状态栏控制器。
enum AppLaunchMode: Equatable {
    case normal
    case render(String)
    case debugSettings
    case importScan
    case repairHud
    case migrateConfiguration

    init(environment: [String: String]) {
        if let destination = environment["QUOTANEST_RENDER"] ?? environment["TOKENHUD_RENDER"] {
            self = .render(destination)
        } else if environment["QUOTANEST_MIGRATE_ONLY"] == "1" {
            self = .migrateConfiguration
        } else if environment["QUOTANEST_DEBUG_SETTINGS"] == "1" || environment["TOKENHUD_DEBUG_SETTINGS"] == "1" {
            self = .debugSettings
        } else if environment["TOKENHUD_IMPORT_SCAN"] == "1" {
            self = .importScan
        } else if environment["TOKENHUD_ENVS_FIX"] == "1" {
            self = .repairHud
        } else {
            self = .normal
        }
    }

    var startsBackgroundEngine: Bool { self == .normal }
}
