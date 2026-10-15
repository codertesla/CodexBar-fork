import Foundation

public enum GeminiProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .gemini,
            menuBarMetrics: ProviderMenuBarMetricCapabilities(
                supported: [.automatic, .primary, .secondary, .average]),
            metadata: ProviderMetadata(
                id: .gemini,
                displayName: "Gemini",
                sessionLabel: "Pro",
                weeklyLabel: "Flash",
                opusLabel: "Flash Lite",
                supportsOpus: true,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Gemini usage",
                cliName: "gemini",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                sharePlanLabels: [
                    "free": "Free", "paid": "Paid", "plus": "Plus", "workspace": "Workspace",
                    "legacy": "Legacy", "gemini code assist in google one ai pro": "Google One AI Pro",
                ],
                debugLogUnavailableMessage: "Gemini debug log not yet implemented",
                debugPane: ProviderDebugPaneCapabilities(errorSimulationOrder: 2),
                dashboardURL: "https://gemini.google.com",
                changelogURL: "https://github.com/google-gemini/gemini-cli/releases",
                statusPageURL: nil,
                statusLinkURL: "https://www.google.com/appsstatus/dashboard/products/npdyhgECDJ6tB66MxXyo/history",
                statusWorkspaceProductID: "npdyhgECDJ6tB66MxXyo"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .gemini),
                iconResourceName: "ProviderIcon-gemini",
                color: ProviderColor(red: 171 / 255, green: 135 / 255, blue: 234 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x4285F4),
                    ProviderColor(hex: 0xA142F4),
                    ProviderColor(hex: 0xD96570),
                ],
                burnDownWidgetColor: ProviderColor(red: 0.420, green: 0.440, blue: 0.900)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Gemini cost summary is not supported." }),
            presentation: ProviderUsagePresentation(
                rateWindowLabeler: { metadata, snapshot, _ in
                    Self.rateWindowLabels(metadata: metadata, snapshot: snapshot)
                },
                identityPresenter: { provider, snapshot in
                    guard let plan = snapshot.loginMethod(for: provider), !plan.isEmpty else {
                        return ProviderIdentityPresentation(badge: nil, plan: nil)
                    }
                    let display = UsageFormatter.cleanPlanName(plan)
                    return ProviderIdentityPresentation(badge: display, plan: display)
                },
                iconDecorations: [.gemini]),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { context in
                    Self.resolveStrategies(sourceMode: context.sourceMode)
                })),
            cli: ProviderCLIConfig(
                name: "gemini",
                binaryLocator: { BinaryLocator.resolveGeminiBinary(env: $0) },
                versionDetector: { _ in ProviderVersionDetector.geminiVersion() }))
    }

    /// Auto prefers the Gemini app's web usage limits (5-hour and weekly windows), then falls back to the
    /// Gemini CLI OAuth quota API that Workspace, education, and Code Assist accounts still use.
    static func resolveStrategies(sourceMode: ProviderSourceMode) -> [any ProviderFetchStrategy] {
        switch sourceMode {
        case .auto:
            [GeminiWebFetchStrategy(), GeminiStatusFetchStrategy()]
        case .web:
            [GeminiWebFetchStrategy()]
        case .api, .oauth:
            [GeminiStatusFetchStrategy()]
        case .cli:
            []
        }
    }

    /// Web snapshots carry 5-hour/weekly windows; CLI OAuth snapshots keep the per-model-tier labels.
    static func rateWindowLabels(metadata: ProviderMetadata, snapshot: UsageSnapshot) -> ProviderRateWindowLabels {
        let isWebSnapshot = snapshot.primary?.windowMinutes == GeminiWebUsageSnapshot.fiveHourWindowMinutes
            || snapshot.secondary?.windowMinutes == GeminiWebUsageSnapshot.weeklyWindowMinutes
        if isWebSnapshot {
            return ProviderRateWindowLabels(
                primary: "5-hour",
                secondary: "Weekly",
                tertiary: metadata.opusLabel ?? "",
                showsTertiary: false)
        }
        return ProviderRateWindowLabels(
            primary: metadata.sessionLabel,
            secondary: metadata.weeklyLabel,
            tertiary: metadata.opusLabel ?? "",
            showsTertiary: metadata.supportsOpus)
    }
}

struct GeminiWebFetchStrategy: ProviderFetchStrategy {
    static let sourceLabel = "web"

    let id: String = "gemini.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        #if os(macOS)
        let logger: ((String) -> Void)? = context.verbose
            ? { message in CodexBarLog.logger(LogCategories.provider(.gemini)).verbose(message) }
            : nil
        let fetcher = GeminiWebUsageFetcher(timeout: context.webTimeout)

        if let cached = CookieHeaderCache.load(provider: .gemini) {
            do {
                let snapshot = try await fetcher.fetch(cookieHeader: cached.cookieHeader)
                return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: Self.sourceLabel)
            } catch GeminiWebUsageError.notLoggedIn {
                _ = CookieHeaderCache.clearIfCurrent(provider: .gemini, expected: cached)
            }
        }

        var lastError: Error = GeminiWebUsageError.noSessionCookie
        for session in try GeminiWebCookieImporter.importSessions(
            browserDetection: context.browserDetection,
            logger: logger)
        {
            do {
                let snapshot = try await fetcher.fetch(cookieHeader: session.cookieHeader)
                CookieHeaderCache.store(
                    provider: .gemini,
                    cookieHeader: session.cookieHeader,
                    sourceLabel: session.sourceLabel)
                return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: Self.sourceLabel)
            } catch GeminiWebUsageError.notLoggedIn {
                // Another browser profile may still hold a live Google session.
                lastError = GeminiWebUsageError.notLoggedIn
            }
        }
        throw lastError
        #else
        throw GeminiWebUsageError.noSessionCookie
        #endif
    }

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        context.sourceMode == .auto
    }
}

struct GeminiStatusFetchStrategy: ProviderFetchStrategy {
    static let sourceLabel = "oauth-api"

    let id: String = "gemini.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = GeminiStatusProbe()
        let snap = try await probe.fetch()
        return self.makeResult(
            usage: snap.toUsageSnapshot(),
            sourceLabel: Self.sourceLabel)
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
