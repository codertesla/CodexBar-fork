import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct KimiGiftBalanceCLITests {
    private static let now = Date(timeIntervalSince1970: 1_788_000_000)

    private static var snapshot: UsageSnapshot {
        UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "kimi-monthly",
                    title: "Total usage",
                    window: RateWindow(
                        usedPercent: 81,
                        windowMinutes: ProviderPaceCapability.monthlyWindowSentinelMinutes,
                        resetsAt: now.addingTimeInterval(9 * 3600),
                        resetDescription: nil)),
                NamedRateWindow(
                    id: "kimi-gift-invite",
                    title: "Invite to Earn Credit",
                    window: RateWindow(
                        usedPercent: 29,
                        windowMinutes: nil,
                        resetsAt: now.addingTimeInterval(71 * 86400),
                        resetDescription: nil)),
            ],
            updatedAt: now)
    }

    @Test(arguments: [ResetTimeDisplayStyle.countdown, .absolute])
    func `text output labels gift deadlines as expirations`(style: ResetTimeDisplayStyle) throws {
        let output = CLIRenderer.renderText(
            provider: .kimi,
            snapshot: Self.snapshot,
            credits: nil,
            context: RenderContext(header: "Kimi Code", status: nil, useColor: false, resetStyle: style),
            now: Self.now)
        let lines = output.components(separatedBy: "\n")

        let gift = try #require(lines.firstIndex { $0.contains("Invite to Earn Credit") })
        let monthly = try #require(lines.firstIndex { $0.contains("Total usage") })
        let expiry = UsageFormatter.expiryLine(
            for: Self.now.addingTimeInterval(71 * 86400),
            style: style,
            now: Self.now)
        #expect(lines[gift + 1].contains(expiry))
        #expect(!lines[gift + 1].contains("Resets"))
        #expect(lines[monthly + 1].contains("Resets"))
    }

    @Test(arguments: [ResetTimeDisplayStyle.countdown, .absolute])
    func `card metrics label gift deadlines as expirations`(style: ResetTimeDisplayStyle) throws {
        let metrics = CLIRenderer.collectCardMetrics(
            provider: .kimi,
            snapshot: Self.snapshot,
            resetStyle: style,
            now: Self.now)

        let gift = try #require(metrics.first { $0.label == "Invite to Earn Credit" })
        let expiry = UsageFormatter.expiryLine(
            for: Self.now.addingTimeInterval(71 * 86400),
            style: style,
            now: Self.now)
        #expect(gift.resetText == "⏳ \(expiry)")
        let monthly = try #require(metrics.first { $0.label == "Total usage" })
        #expect(monthly.resetText?.contains("Resets") == true)
    }
}
