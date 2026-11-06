import Foundation
import Testing
@testable import QuotaNest

@Suite
struct ImportVerificationTests {
    @Test func requiresActualUsageInsteadOfEmptyBucketsOrMetadata() {
        #expect(ImportVerification.cacheStatus(UsageCache()) == .empty)
        #expect(ImportVerification.cacheStatus(UsageCache(fiveHour: Bucket())) == .empty)
        #expect(ImportVerification.cacheStatus(UsageCache(windows: [WindowBucket(label: "window", limit: 10)])) == .empty)
        #expect(ImportVerification.cacheStatus(UsageCache(fiveHour: Bucket(usedPercentage: 0))) == .success)
        #expect(ImportVerification.cacheStatus(UsageCache(windows: [WindowBucket(amount: 0, period: "balance")])) == .success)
    }

    @Test func rejectsNonFiniteOrNegativeUsage() {
        #expect(!ImportVerification.hasUsage(UsageCache(fiveHour: Bucket(usedPercentage: .infinity))))
        #expect(!ImportVerification.hasUsage(UsageCache(windows: [WindowBucket(amount: -.infinity)])))
        #expect(!ImportVerification.hasUsage(UsageCache(windows: [WindowBucket(usedPercentage: -1)])))
    }

    @Test func serviceRejectionsRequireComparisonAndDoNotProveBadSourceCredentials() {
        #expect(ImportVerification.cacheStatus(UsageCache(error: "auth")) == .serviceRejected)
        #expect(ImportVerification.classify("HTTP 403", fallback: .network) == .serviceRejected)
        #expect(ImportVerification.cacheStatus(UsageCache(error: "parse")) == .responseSchema)
        #expect(ImportVerification.cacheStatus(UsageCache(error: "no-subscription")) == .noSubscription)
        #expect(ImportVerification.classify("来源授权结构未匹配该类型声明的 Auth 格式", fallback: .applyFailed) == .authSchema)
    }

    @Test func errorOverridesOtherwiseValidUsageAndUntrustedTextDoesNotEscape() throws {
        let cache = UsageCache(fiveHour: Bucket(usedPercentage: 0), error: "auth")
        #expect(ImportVerification.cacheStatus(cache) == .serviceRejected)
        let status = ImportVerification.classify("unrecognized external response", fallback: .responseSchema)
        let encoded = try JSONEncoder().encode(status)
        #expect(String(decoding: encoded, as: UTF8.self) == "\"response-schema-needs-comparison\"")
    }

    @Test func summaryOnlyEncodesFixedStatusesAndAggregateCounts() throws {
        var summary = ImportVerification.Summary()
        summary.total = 2
        summary.counts = [ImportVerification.Source.router.rawValue: 2]
        summary.outcomes = [ImportVerification.Status.success.rawValue: 1]
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as? [String: Any])
        #expect(Set(object.keys) == Set(["status", "total", "counts", "outcomes", "queried", "succeeded", "sourceFilesUnchanged", "reportWritten"]))
    }
}
