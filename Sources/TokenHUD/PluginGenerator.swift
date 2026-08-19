import Foundation

enum PluginGenerator {
    /// 小写；空格/下划线→"-"；非法字符逐个→"-"（连续非法→连续"-"，不 trim）；空则 "custom"
    static func slugify(_ name: String) -> String {
        let s = String(name.lowercased().map { ch -> Character in
            (ch.isLetter && ch.isLowercase) || ch.isNumber || ch == "-" ? ch : "-"
        })
        return s.isEmpty ? "custom" : s
    }

    static func oneAPIManifest(label: String, intervalSec: Int = 60) -> ProviderManifest {
        ProviderManifest(name: label, label: label, fetch: "./fetch.sh",
                         intervalSec: intervalSec, buckets: ["seven_day": "周"],
                         cacheFile: nil, enabled: true)
    }

    static func oneAPIFetchScript(baseURL: String, apiKey: String) -> String {
        // baseURL 去尾斜杠; key 内嵌明文 (与 .glm-usage-auth.json 同级安全，不做 Keychain)
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return """
        #!/bin/zsh
        # TokenHUD 生成: one-api / OpenAI 兼容模板
        set -eu
        BASE='\(base)'
        KEY='\(apiKey)'
        AUTH="Authorization: Bearer $KEY"
        START=$(date +%Y-%m-01)
        END=$(date -v+1d +%Y-%m-%d)
        SUB=$(curl -s --max-time 10 -H "$AUTH" "$BASE/v1/dashboard/billing/subscription")
        USAGE=$(curl -s --max-time 10 -H "$AUTH" "$BASE/v1/dashboard/billing/usage?start_date=$START&end_date=$END")
        printf '%s\\n%s\\n' "$SUB" "$USAGE" | python3 -c '
        import json, sys
        lines = sys.stdin.read().split("\\n")
        sub = json.loads(lines[0])
        usage = json.loads(lines[1])
        quota = sub.get("hard_quota") or sub.get("total_granted") or 0
        total = usage.get("total_usage") or 0
        if not quota or quota <= 0:
            print(json.dumps({"error": "quota"})); raise SystemExit(1)
        pct = round(total / quota * 100, 1)
        print(json.dumps({"seven_day": {"used_percentage": pct}}))
        '
        """
    }

    static func writePlugin(slug: String, manifest: ProviderManifest, script: String, into root: URL) throws {
        let dir = root.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(manifest).write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
        try script.write(to: dir.appendingPathComponent("fetch.sh"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: dir.appendingPathComponent("fetch.sh").path)
    }

    static func removePlugin(slug: String, in root: URL) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(slug, isDirectory: true))
    }
}
