import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct KimiGiftBalanceMenuTests {
    static let now = Date(timeIntervalSince1970: 1_788_000_000)
    static let inviteID = "kimi-gift-invite"

    static func snapshot(monthlyRatio: Double) throws -> UsageSnapshot {
        let iso = ISO8601DateFormatter()
        let stats = try JSONDecoder().decode(KimiSubscriptionStatsResponse.self, from: Data("""
        {
          "subscriptionBalance": {
            "feature": "FEATURE_OMNI", "type": "SUBSCRIPTION", "amountUsedRatio": \(monthlyRatio),
            "expireTime": "\(iso.string(from: self.now.addingTimeInterval(9 * 3600)))"
          },
          "giftBalances": [
            {
              "id": "reservation", "feature": "FEATURE_OMNI", "type": "GIFT", "amountUsedRatio": 1,
              "expireTime": "\(iso.string(from: self.now.addingTimeInterval(33 * 3600)))",
              "displayName": "Reservation Bonus"
            },
            {
              "id": "invite", "feature": "FEATURE_OMNI", "type": "GIFT", "amountUsedRatio": 0.2524,
              "expireTime": "\(iso.string(from: self.now.addingTimeInterval(71 * 86400)))",
              "displayName": "Invite to Earn Credit"
            }
          ]
        }
        """.utf8))
        let session = KimiUsageDetail(
            limit: "100",
            used: "40",
            remaining: "60",
            resetTime: iso.string(from: self.now.addingTimeInterval(3600)))
        return KimiUsageSnapshot(
            weekly: nil,
            rateLimit: session,
            subscriptionBalance: stats.subscriptionBalance,
            giftBalances: stats.giftBalances,
            updatedAt: self.now).toUsageSnapshot()
    }

    static func model(
        _ snapshot: UsageSnapshot,
        style: ResetTimeDisplayStyle = .countdown) throws -> UsageMenuCardView.Model
    {
        let metadata = try #require(ProviderDefaults.metadata[.kimi])
        return UsageMenuCardView.Model.make(.init(
            provider: .kimi,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: style,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: self.now))
    }

    @Test
    func `exhausted monthly pool does not mask remaining gift balance`() throws {
        let model = try Self.model(Self.snapshot(monthlyRatio: 1))

        let invite = try #require(model.metrics.first { $0.id == Self.inviteID })
        #expect(abs(invite.percent - 74.76) < 0.0001)
        #expect(invite.statusText == nil)
        #expect(invite.resetText == "Expires in 71d")
        let session = try #require(model.metrics.first { $0.id == "secondary" })
        #expect(session.statusText == "Blocked by monthly limit")
    }

    @Test
    func `gift rows render expiry instead of reset wording`() throws {
        let snapshot = try Self.snapshot(monthlyRatio: 0.8103)

        let countdown = try Self.model(snapshot, style: .countdown)
        #expect(countdown.metrics.first { $0.id == "kimi-gift-reservation" }?.resetText == "Expires in 1d 9h")
        #expect(countdown.metrics.first { $0.id == "kimi-monthly" }?.resetText?.hasPrefix("Resets") == true)

        let absolute = try Self.model(snapshot, style: .absolute)
        let expiresAt = Self.now.addingTimeInterval(71 * 86400)
        #expect(absolute.metrics.first { $0.id == Self.inviteID }?.resetText
            == "Expires \(UsageFormatter.resetDescription(from: expiresAt, now: Self.now))")
    }
}
