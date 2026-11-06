import Foundation
import Testing
@testable import QuotaNest

@Suite struct QuotaPresentationTests {
    private func state(error: String? = nil, stale: Bool = false) -> ProviderState {
        ProviderState(slug: "fixture", manifest: ProviderManifest(name: "Fixture", label: "Fixture"),
            cache: UsageCache(generatedAt: 1_000, fiveHour: Bucket(usedPercentage: 25), error: error, stale: stale), isStale: stale)
    }
    @Test func refreshingKeepsSnapshotAndItsOriginalSuccessTime() {
        let original = state()
        let presentation = QuotaPresentation(state: original, isRefreshing: true)
        #expect(!presentation.isOld)
        #expect(presentation.status == L10n.tr("正在刷新，显示上次成功快照"))
        #expect(presentation.metrics.first?.percentage == 25)
        #expect(presentation.state?.cache?.generatedAt == 1_000)
    }
    @Test func retryNeverHidesPreviousFailureOrMakesOldValuesFresh() {
        let presentation = QuotaPresentation(state: state(error: "network", stale: true), isRefreshing: true)
        #expect(presentation.isOld)
        #expect(presentation.status == L10n.tr("正在重试；上次查询失败：%@", QuotaErrorPresentation.message(for: "network")))
        #expect(presentation.metrics.first?.percentage == 25)
    }
    @Test func longExpiredSnapshotStaysOldEvenWhileRefreshing() {
        #expect(QuotaPresentation(state: state(stale: true), isRefreshing: true).isOld)
    }
    @Test func noSnapshotDoesNotPretendToHaveOldQuotaValues() {
        let empty = ProviderState(slug: "empty", manifest: ProviderManifest(name: "Empty", label: "Empty"), cache: nil, isStale: true)
        let presentation = QuotaPresentation(state: empty, isRefreshing: true)
        #expect(!presentation.isOld && presentation.metrics.isEmpty)
        #expect(presentation.status == L10n.tr("正在查询额度…"))
    }
}
