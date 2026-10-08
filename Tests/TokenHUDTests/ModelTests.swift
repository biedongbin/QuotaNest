import Foundation
import Testing
@testable import TokenHUD

@Suite
struct ModelTests {
    @Test func manifestDecodesFull() throws {
        let json = """
        {"name":"CC-GLM","label":"GLM","fetch":"./fetch.sh","intervalSec":60,
         "buckets":{"five_hour":"5h","seven_day":"周"},
         "cacheFile":"/tmp/.glm-usage-cache.json","enabled":true}
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(ProviderManifest.self, from: json)
        #expect(m.name == "CC-GLM")
        #expect(m.label == "GLM")
        #expect(m.buckets["seven_day"] == "周")
        #expect(m.cacheFile == "/tmp/.glm-usage-cache.json")
    }

    @Test func manifestDecodesMinimal() throws {
        let json = #"{"name":"X","label":"x"}"#.data(using: .utf8)!
        let m = try JSONDecoder().decode(ProviderManifest.self, from: json)
        #expect(m.fetch == "./fetch.sh")
        #expect(m.intervalSec == nil)
        #expect(m.enabled == true) // 默认
        #expect(m.refreshModel == "") // 缺省空, 不默认任何私有模型
        #expect(m.isBuiltin == false)
    }

    @Test func manifestDecodesAccentAndBuiltin() throws {
        let json = #"{"name":"GPT","label":"GPT","builtin":true,"accent":"orange"}"#.data(using: .utf8)!
        let m = try JSONDecoder().decode(ProviderManifest.self, from: json)
        #expect(m.isBuiltin)
        #expect(m.accent == "orange")
    }

    @Test func cacheDecodesNodeProviderFormat() throws {
        // 与现有 node provider 写的缓存同构
        let json = """
        {"generatedAt":1755600000000,"ttlMs":60000,
         "five_hour":{"used_percentage":47.2,"resets_at":1755603600},
         "seven_day":{"used_percentage":34.0,"resets_at":null},
         "monthly":null,"error":null,"stale":false}
        """.data(using: .utf8)!
        let c = try JSONDecoder().decode(UsageCache.self, from: json)
        #expect(c.fiveHour?.usedPercentage == 47.2)
        #expect(c.sevenDay?.resetsAt == nil)
        #expect(c.error == nil)
    }

    @Test func bucketDecodesISO8601ResetsAt() throws {
        // ollama /api/balance 返回 ISO8601 字符串 (旧格式为整数) — 两者都要能解
        let json = """
        {"generatedAt":1755600000000,"ttlMs":60000,
         "five_hour":{"used_percentage":12.5,"resets_at":"2026-10-08T09:00:00Z"},
         "seven_day":{"used_percentage":3.0,"resets_at":null},
         "monthly":null,"error":null,"stale":false}
        """.data(using: .utf8)!
        let c = try JSONDecoder().decode(UsageCache.self, from: json)
        #expect(c.fiveHour?.usedPercentage == 12.5)
        #expect(c.fiveHour?.resetsAt == 1791450000)  // 2026-10-08T09:00:00Z epoch
    }

    @Test func makeStampsGeneratedAt() throws {
        let stdout = #"{"seven_day":{"used_percentage":28.2}}"#.data(using: .utf8)!
        let c = try #require(UsageCache.make(body: stdout, now: 1234))
        #expect(c.generatedAt == 1234)
        #expect(c.sevenDay?.usedPercentage == 28.2)
        #expect(!(c.stale ?? true))
    }

    @Test func makeRejectsGarbage() {
        let bad = "not json".data(using: .utf8)!
        #expect(UsageCache.make(body: bad, now: 0) == nil)
    }
}
