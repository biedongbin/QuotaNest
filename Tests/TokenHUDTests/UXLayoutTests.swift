import Testing
@testable import QuotaNest

@Suite
struct UXLayoutTests {
    @Test func emptyQuotaDoesNotInventWindows() {
        #expect(QuotaTabView.rows(from: nil).isEmpty)
        #expect(QuotaTabView.rows(from: UsageCache(error: "auth", stale: true)).isEmpty)
        #expect(QuotaTabView.rows(from: UsageCache(fiveHour: Bucket(), sevenDay: Bucket())).isEmpty)
    }

    @Test func legacyQuotaShowsOnlyMeasuredWindows() {
        let rows = QuotaTabView.rows(from: UsageCache(sevenDay: Bucket(usedPercentage: 0, resetsAt: 1_793_776_498)))
        #expect(rows.count == 1)
        #expect(rows.first?.label == "本周")
        #expect(rows.first?.pct == 0)
    }

    @Test func dynamicQuotaKeepsRealWindowsWithoutEmptyCards() {
        let cache = UsageCache(windows: [
            WindowBucket(label: "无数据"),
            WindowBucket(label: "7天", usedPercentage: 19, period: "7天"),
            WindowBucket(label: "调用量", amount: 0, limit: 100, unit: "次")
        ])
        let rows = QuotaTabView.rows(from: cache)
        #expect(rows.map(\.label) == ["7天", "调用量"])
        #expect(rows.first?.pct == 19)
        #expect(rows.last?.amount == 0)
    }
}
