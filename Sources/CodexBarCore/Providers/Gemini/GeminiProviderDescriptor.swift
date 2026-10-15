import Foundation

public enum GeminiProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .gemini,
            menuBarMetrics: ProviderMenuBarMetricCapabilities(
                supported: [.automatic, .primary, .secondary, .average]),
            settingsSection: GeminiWebCookieSettings.sectionRegistration,
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
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
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

    /// Auto keeps the Gemini CLI OAuth quota API first, so a working CLI account (Workspace, education, Code
    /// Assist) is never replaced by whichever Google account a browser holds. Only when OAuth fails, as it does
    /// for consumer AI Pro/Ultra accounts after the CLI shutdown, does Auto read the Gemini app's web limits.
    static func resolveStrategies(sourceMode: ProviderSourceMode) -> [any ProviderFetchStrategy] {
        switch sourceMode {
        case .auto:
            [GeminiStatusFetchStrategy(), GeminiWebFetchStrategy()]
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

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        #if os(macOS)
        context.settings?.gemini?.cookieSource != .off
        #else
        context.settings?.gemini?.cookieSource == .manual
        #endif
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let settings = context.settings?.gemini ?? CookieProviderSettings()
        let fetcher = GeminiWebUsageFetcher(timeout: context.webTimeout)

        if settings.cookieSource == .manual {
            guard let header = GeminiWebCookieHeader.manualHeader(settings.manualCookieHeader) else {
                throw GeminiWebUsageError.noSessionCookie
            }
            let snapshot = try await fetcher.fetch(cookieHeader: header)
            return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: Self.sourceLabel)
        }

        #if os(macOS)
        let logger: ((String) -> Void)? = context.verbose
            ? { message in CodexBarLog.logger(LogCategories.provider(.gemini)).verbose(message) }
            : nil
        let selection = settings.selectedBrowserProfile

        // Observe before any network work so a late success cannot overwrite a session committed meanwhile.
        var observation = CookieHeaderCache.observeForConditionalMutation(provider: .gemini)
        // The cache is not keyed by profile, so a pinned profile always reads its own store.
        if selection == nil, let cached = observation.entry {
            let cachedSnapshot = try await Self.cachedSessionSnapshot(cached.cookieHeader) {
                try await fetcher.fetch(cookieHeader: $0)
            }
            if let snapshot = cachedSnapshot {
                return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: Self.sourceLabel)
            }
            if CookieHeaderCache.clearIfCurrent(provider: .gemini, expected: cached) {
                observation = observation.afterOwnedClear()
            }
        }

        let sessions = try GeminiWebCookieImporter.importSessions(
            browserDetection: context.browserDetection,
            selection: selection,
            logger: logger)
        let (snapshot, session) = try await Self.firstUsableSession(sessions, cookieHeader: \.cookieHeader) {
            try await fetcher.fetch(cookieHeader: $0)
        }
        if selection == nil {
            CookieHeaderCache.storeIfObservationCurrent(
                provider: .gemini,
                expected: observation,
                cookieHeader: session.cookieHeader,
                sourceLabel: session.sourceLabel)
        } else {
            // Lets `codexbar cookie refresh` report success without caching a pinned profile's cookies.
            CookieHeaderCache.markNonpersistentRefreshValidated(provider: .gemini)
        }
        return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: Self.sourceLabel)
        #else
        throw GeminiWebUsageError.noSessionCookie
        #endif
    }

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        context.sourceMode == .auto
    }

    /// Returns nil when the cached account signed out or lost its usage windows, so discovery can try other
    /// profiles; failures every session would share still propagate.
    static func cachedSessionSnapshot(
        _ cookieHeader: String,
        fetch: (String) async throws -> GeminiWebUsageSnapshot) async throws -> GeminiWebUsageSnapshot?
    {
        do {
            return try await fetch(cookieHeader)
        } catch let error as GeminiWebUsageError where error.isAccountSpecific {
            return nil
        }
    }

    /// Tries browser sessions in order. Account-specific failures (signed out, no usage windows) move on to the
    /// next profile; query rejections and transport failures stop, because every session would hit them.
    static func firstUsableSession<Session: Sendable>(
        _ sessions: some Sequence<Session>,
        cookieHeader: (Session) -> String,
        fetch: (String) async throws -> GeminiWebUsageSnapshot) async throws -> (GeminiWebUsageSnapshot, Session)
    {
        var lastError: Error = GeminiWebUsageError.noSessionCookie
        for session in sessions {
            do {
                return try await (fetch(cookieHeader(session)), session)
            } catch let error as GeminiWebUsageError where error.isAccountSpecific {
                lastError = error
            }
        }
        throw lastError
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

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        context.sourceMode == .auto
    }
}
