import Foundation
import Testing
@testable import CodexBarCore

struct KimiGiftBalanceTests {
    private static let statsJSON = """
    {
      "ratelimitCode5h": { "ratio": 1, "enabled": true, "resetTime": "2026-10-21T16:07:58.323242Z" },
      "subscriptionBalance": {
        "id": "1a0c3a70-ca82-8b19-8000-000080dc2055",
        "feature": "FEATURE_OMNI",
        "type": "SUBSCRIPTION",
        "unit": "UNIT_CREDIT",
        "amountUsedRatio": 0.8103,
        "kimiCodeUsedRatio": 0.8103,
        "expireTime": "2026-10-22T00:00:00Z"
      },
      "giftBalances": [
        {
          "id": "1a0c3a70-cde2-894a-8000-0000e357f409",
          "feature": "FEATURE_OMNI",
          "type": "GIFT",
          "unit": "UNIT_CREDIT",
          "amountUsedRatio": 1,
          "kimiCodeUsedRatio": 1,
          "expireTime": "2026-10-23T00:00:00Z",
          "displayName": "Reservation Bonus"
        },
        {
          "id": "19f6dcfc-1962-8ff6-82b6-42115f9f4037",
          "feature": "FEATURE_OMNI",
          "type": "GIFT",
          "unit": "UNIT_CREDIT",
          "amountUsedRatio": 0.2524,
          "kimiCodeUsedRatio": 0.1465,
          "expireTime": "2026-12-31T15:59:59Z",
          "displayName": "Invite to Earn Credit"
        }
      ]
    }
    """

    private static func snapshot(
        stats: KimiSubscriptionStatsResponse,
        now: Date) -> KimiUsageSnapshot
    {
        KimiUsageSnapshot(
            weekly: nil,
            rateLimit: nil,
            subscriptionBalance: stats.subscriptionBalance,
            subscriptionCodeWeeklyLimit: stats.ratelimitCode7d,
            giftBalances: stats.giftBalances,
            updatedAt: now)
    }

    @Test
    func `decodes gift balances from subscription stats`() throws {
        let stats = try JSONDecoder().decode(KimiSubscriptionStatsResponse.self, from: Data(Self.statsJSON.utf8))

        let gifts = try #require(stats.giftBalances)
        #expect(gifts.count == 2)
        #expect(gifts[0].type == "GIFT")
        #expect(gifts[0].displayName == "Reservation Bonus")
        #expect(gifts[1].id == "19f6dcfc-1962-8ff6-82b6-42115f9f4037")
        #expect(gifts[1].amountUsedRatio == 0.2524)
        #expect(stats.subscriptionBalance?.amountUsedRatio == 0.8103)
    }

    @Test
    func `malformed gift balances do not reject the subscription balance`() throws {
        let json = """
        {
          "subscriptionBalance": { "feature": "FEATURE_OMNI", "type": "SUBSCRIPTION", "amountUsedRatio": 0.5 },
          "giftBalances": { "unexpected": true }
        }
        """

        let stats = try JSONDecoder().decode(KimiSubscriptionStatsResponse.self, from: Data(json.utf8))

        #expect(stats.subscriptionBalance?.amountUsedRatio == 0.5)
        #expect(stats.giftBalances == nil)
    }

    @Test
    func `converts gift balances to named extra windows after the monthly pool`() throws {
        let now = try #require(ISO8601DateParser.parse("2026-10-21T15:00:00Z"))
        let stats = try JSONDecoder().decode(KimiSubscriptionStatsResponse.self, from: Data(Self.statsJSON.utf8))

        let windows = try #require(Self.snapshot(stats: stats, now: now).toUsageSnapshot().extraRateWindows)

        #expect(windows.map(\.id) == [
            "kimi-monthly",
            "kimi-gift-1a0c3a70-cde2-894a-8000-0000e357f409",
            "kimi-gift-19f6dcfc-1962-8ff6-82b6-42115f9f4037",
        ])
        #expect(windows[1].title == "Reservation Bonus")
        #expect(windows[1].window.usedPercent == 100)
        #expect(windows[1].window.windowMinutes == nil)
        #expect(windows[1].window.resetsAt == ISO8601DateParser.parse("2026-10-23T00:00:00Z"))
        #expect(windows[2].title == "Invite to Earn Credit")
        #expect(abs(windows[2].window.usedPercent - 25.24) < 0.0001)
        #expect(windows[2].window.resetsAt == ISO8601DateParser.parse("2026-12-31T15:59:59Z"))
    }

    @Test
    func `skips expired and non gift balances`() throws {
        let now = try #require(ISO8601DateParser.parse("2026-11-01T00:00:00Z"))
        let gifts = [
            KimiSubscriptionBalance(
                id: "expired",
                feature: "FEATURE_OMNI",
                type: "GIFT",
                amountUsedRatio: 0.1,
                kimiCodeUsedRatio: nil,
                expireTime: "2026-10-23T00:00:00Z",
                displayName: "Reservation Bonus"),
            KimiSubscriptionBalance(
                id: "other-feature",
                feature: "FEATURE_CHAT",
                type: "GIFT",
                amountUsedRatio: 0.1,
                kimiCodeUsedRatio: nil,
                expireTime: nil),
            KimiSubscriptionBalance(
                id: nil,
                feature: nil,
                type: nil,
                amountUsedRatio: 0.3,
                kimiCodeUsedRatio: nil,
                expireTime: nil,
                displayName: "  "),
        ]

        let snapshot = KimiUsageSnapshot(
            weekly: nil,
            rateLimit: nil,
            subscriptionBalance: nil,
            giftBalances: gifts,
            updatedAt: now)
        let windows = try #require(snapshot.toUsageSnapshot().extraRateWindows)

        #expect(windows.count == 1)
        #expect(windows[0].id == "kimi-gift-2")
        #expect(windows[0].title == "Bonus credits")
        #expect(windows[0].window.resetsAt == nil)
    }

    @Test
    func `exhausted gift pool does not drive the automatic menu bar metric`() throws {
        let now = try #require(ISO8601DateParser.parse("2026-10-21T15:00:00Z"))
        let stats = try JSONDecoder().decode(KimiSubscriptionStatsResponse.self, from: Data(Self.statsJSON.utf8))
        let usageSnapshot = KimiUsageSnapshot(
            weekly: nil,
            rateLimit: KimiUsageDetail(limit: "100", used: "40", remaining: "60", resetTime: "2026-10-21T16:07:58Z"),
            subscriptionBalance: stats.subscriptionBalance,
            giftBalances: stats.giftBalances,
            updatedAt: now).toUsageSnapshot()
        let session = try #require(usageSnapshot.secondary)
        let exhaustedGift = usageSnapshot.extraRateWindows?.first { $0.id.hasPrefix("kimi-gift-") }
        #expect(exhaustedGift?.window.usedPercent == 100)

        let resolution = KimiProviderDescriptor.descriptor.presentation.menuBarWindow(context: .init(
            metric: .automatic,
            snapshot: usageSnapshot,
            supportsAverage: false,
            prioritizesExhaustedQuotas: true,
            now: now))
        guard case let .resolved(window) = resolution else {
            Issue.record("Kimi automatic usage should resolve the session lane")
            return
        }
        #expect(window == session)
    }
}

struct KimiWebLanguageTests {
    @Test(arguments: [
        ("zh-Hans", "zh-CN"),
        ("zh-Hant-TW", "zh-CN"),
        ("en-US", "en-US"),
        ("ja-JP", "en-US"),
        ("en_US_POSIX", "en-US"),
    ])
    func `requests Chinese gift names only for Chinese UI`(identifier: String, expected: String) {
        #expect(KimiUsageFetcher.webLanguage(for: Locale(identifier: identifier)) == expected)
    }
}
