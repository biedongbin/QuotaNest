import Foundation

struct ProviderManifest: Codable {
    let name: String
    let label: String
    var fetch: String
    var intervalSec: Int?
    var buckets: [String: String]
    var cacheFile: String?
    var enabled: Bool?

    var isEnabled: Bool { enabled ?? true }
    var interval: Int { intervalSec ?? 60 }

    private enum CodingKeys: String, CodingKey {
        case name, label, fetch, intervalSec, buckets, cacheFile, enabled
    }

    init(name: String, label: String, fetch: String = "./fetch.sh", intervalSec: Int? = nil,
         buckets: [String: String] = [:], cacheFile: String? = nil, enabled: Bool? = true) {
        self.name = name
        self.label = label
        self.fetch = fetch
        self.intervalSec = intervalSec
        self.buckets = buckets
        self.cacheFile = cacheFile
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        label = try c.decode(String.self, forKey: .label)
        fetch = try c.decodeIfPresent(String.self, forKey: .fetch) ?? "./fetch.sh"
        intervalSec = try c.decodeIfPresent(Int.self, forKey: .intervalSec)
        buckets = try c.decodeIfPresent([String: String].self, forKey: .buckets) ?? [:]
        cacheFile = try c.decodeIfPresent(String.self, forKey: .cacheFile)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

struct Bucket: Codable {
    var usedPercentage: Double?
    var resetsAt: Int?

    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }
}

struct UsageCache: Codable {
    var generatedAt: Double?
    var fiveHour: Bucket?
    var sevenDay: Bucket?
    var monthly: Bucket?
    var error: String?
    var stale: Bool?

    enum CodingKeys: String, CodingKey {
        case generatedAt
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case monthly
        case error, stale
    }

    /// 解析 fetch.sh stdout（可缺 generatedAt/ttlMs 等字段），统一盖上框架字段
    static func make(body: Data, now: Double) -> UsageCache? {
        guard let raw = try? JSONDecoder().decode(UsageCache.self, from: body) else { return nil }
        var c = raw
        c.generatedAt = now
        c.stale = false
        if c.error == nil, c.fiveHour == nil, c.sevenDay == nil, c.monthly == nil { return nil }
        return c
    }
}

/// 一个已装载的插件（manifest + 所在目录）
struct PluginProvider {
    let slug: String
    let manifest: ProviderManifest
    let dir: URL
}
