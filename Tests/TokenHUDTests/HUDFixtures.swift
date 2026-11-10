import Foundation

/// Shared HUD runtime fixture for tests: the four HUD entry points plus the generic adapter.
/// Exports validate these files, so metadata-only unit tests need a real (stub) runtime.
enum HUDFixtures {
    static let runtimeScriptNames = ["statusline.mjs", "ref-usage-provider.mjs",
                                     "source-readers.mjs", "hud-runtime.mjs",
                                     "generic-usage-provider.mjs"]

    static let runtime: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tokenhud-mjs-fixture", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in runtimeScriptNames {
            let url = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                try? Data("// fixture runtime".utf8).write(to: url)
            }
        }
        return dir
    }()

    /// A wrapper that resolves its adapter from the HUD runtime, like the shipped templates.
    static func writeWrapper(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = """
        #!/bin/zsh
        set -eu
        export TOKENHUD_HUD_DIR="${TOKENHUD_HUD_DIR:-$HOME/.claude/hud}"
        "${TOKENHUD_NODE:-node}" "$TOKENHUD_HUD_DIR/generic-usage-provider.mjs"
        """
        try? script.write(to: dir.appendingPathComponent("fetch.sh"), atomically: true, encoding: .utf8)
    }
}
