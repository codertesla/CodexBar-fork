import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(macOS)
import SweetCookieKit
#endif

// MARK: - Errors

public enum GeminiWebUsageError: LocalizedError, Sendable, Equatable {
    case noSessionCookie
    case notLoggedIn
    case usageUnavailable(String)
    case parseFailed(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .noSessionCookie:
            "No Google session cookie found for gemini.google.com. Sign in to Gemini in your browser."
        case .notLoggedIn:
            "Gemini web session is not signed in or has expired. Open gemini.google.com and sign in again."
        case let .usageUnavailable(message):
            "Gemini usage limits are unavailable: \(message)"
        case let .parseFailed(message):
            "Could not parse Gemini usage limits: \(message)"
        case let .networkError(message):
            "Gemini usage request failed: \(message)"
        }
    }
}

// MARK: - Snapshot

/// Usage limits shown on https://gemini.google.com/usage (the Gemini app's 5-hour and weekly windows).
public struct GeminiWebUsageSnapshot: Sendable, Equatable {
    public struct Window: Sendable, Equatable {
        /// 0...100. Gemini reports `percentageUsed` as a 0...1 fraction; the usage page multiplies it by 100.
        public let usedPercent: Double
        public let resetsAt: Date?
    }

    public static let fiveHourWindowMinutes = 300
    public static let weeklyWindowMinutes = 10080

    public let subscriptionTier: String?
    public let fiveHour: Window?
    public let weekly: Window?
    public let updatedAt: Date

    public func toUsageSnapshot() -> UsageSnapshot {
        let primary = self.fiveHour.map {
            RateWindow(
                usedPercent: $0.usedPercent,
                windowMinutes: Self.fiveHourWindowMinutes,
                resetsAt: $0.resetsAt,
                resetDescription: nil)
        }
        let secondary = self.weekly.map {
            RateWindow(
                usedPercent: $0.usedPercent,
                windowMinutes: Self.weeklyWindowMinutes,
                resetsAt: $0.resetsAt,
                resetDescription: nil)
        }
        let identity = ProviderIdentitySnapshot(
            providerID: .gemini,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: Self.planName(forTier: self.subscriptionTier))
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    /// Gemini reports opaque tiers; only map tiers confirmed against the usage page's plan badge.
    static func planName(forTier tier: String?) -> String? {
        switch tier?.uppercased() {
        case "TIER1": "Pro"
        default: nil
        }
    }
}

// MARK: - Parser

public enum GeminiWebUsageParser {
    private struct ExecutionResult: Decodable {
        let data: DataPayload?
        let errors: [ExecutionError]?
    }

    private struct ExecutionError: Decodable {
        let message: String?
    }

    private struct DataPayload: Decodable {
        let viewer: Viewer?
    }

    private struct Viewer: Decodable {
        let rpcs: Rpcs?
    }

    private struct Rpcs: Decodable {
        let getUsageInfo: UsageInfo?
    }

    private struct UsageInfo: Decodable {
        let subscriptionTier: String?
        let pools: [Pool]?
    }

    private struct Pool: Decodable {
        let poolType: String?
        let percentageUsed: Double?
        let gxu: GxuPool?
    }

    private struct GxuPool: Decodable {
        let windowRefreshesAt: String?
    }

    private static let xssiPrefix = ")]}'"

    /// Parses the `executeQuery` response: an XSSI-prefixed JSON array of GraphQL execution results.
    /// Errors from unrelated fields in the same query (upsell banners) are ignored when usage is present.
    public static func parse(data: Data, now: Date = Date()) throws -> GeminiWebUsageSnapshot {
        guard var text = String(data: data, encoding: .utf8) else {
            throw GeminiWebUsageError.parseFailed("Response is not UTF-8.")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix(Self.xssiPrefix) {
            text.removeFirst(Self.xssiPrefix.count)
        }
        if text.hasPrefix("<") {
            throw GeminiWebUsageError.notLoggedIn
        }

        let results: [ExecutionResult]
        do {
            results = try JSONDecoder().decode([ExecutionResult].self, from: Data(text.utf8))
        } catch {
            throw GeminiWebUsageError.parseFailed("Unexpected response shape.")
        }

        guard let result = results.first(where: { $0.data?.viewer != nil }) else {
            // Gemini answers signed-out requests with `viewer: null`; `data: null` means the query itself was
            // rejected (for example a rotated persisted-query ID).
            if results.contains(where: { $0.data != nil }) {
                throw GeminiWebUsageError.notLoggedIn
            }
            let message = results.lazy.compactMap { $0.errors?.first?.message }.first ?? "Empty GraphQL result."
            throw GeminiWebUsageError.usageUnavailable(message)
        }
        guard let usage = result.data?.viewer?.rpcs?.getUsageInfo else {
            throw GeminiWebUsageError.usageUnavailable("Missing getUsageInfo in response.")
        }

        let pools = usage.pools ?? []
        let fiveHour = pools.first { $0.poolType == "GXU_FIVE_HOURLY" }.flatMap(Self.window)
        let weekly = pools.first { $0.poolType == "GXU_WEEKLY" }.flatMap(Self.window)
        guard fiveHour != nil || weekly != nil else {
            throw GeminiWebUsageError.usageUnavailable("No usage windows reported for this account.")
        }

        return GeminiWebUsageSnapshot(
            subscriptionTier: usage.subscriptionTier,
            fiveHour: fiveHour,
            weekly: weekly,
            updatedAt: now)
    }

    private static func window(from pool: Pool) -> GeminiWebUsageSnapshot.Window? {
        guard let percentageUsed = pool.percentageUsed, percentageUsed >= 0 else { return nil }
        return GeminiWebUsageSnapshot.Window(
            usedPercent: min(percentageUsed * 100, 100),
            resetsAt: pool.gxu?.windowRefreshesAt.flatMap(Self.parseDate))
    }

    static func parseDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }
        // Gemini emits microseconds; ISO8601DateFormatter only accepts milliseconds on some OS versions.
        if let dot = raw.firstIndex(of: "."), let zone = raw[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" }) {
            let fraction = raw[raw.index(after: dot)..<zone].prefix(3)
            let trimmed = raw[..<dot] + "." + fraction + raw[zone...]
            if let date = fractional.date(from: String(trimmed)) {
                return date
            }
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

// MARK: - Fetcher

public struct GeminiWebUsageFetcher: Sendable {
    static let executeQueryURL =
        URL(string: "https://gemini.google.com/_/BardChatUi/graphql/schemas/GEMINI_WEB_GRAPHQL/executeQuery")!

    /// Relay persisted-query ID of `UsagePageQuery`, served by the gemini.google.com/usage page bundle.
    static let usagePageQuerySignature = "2/dWbCvkVB0X16r9NPnxifeOAAqdCqMf0xeWvau9yPy7g="
    static let usagePageQueryVariables =
        #"{"g1Request":{"entrypoints":["GEMINI_USAGE_SETTINGS_UPGRADE_BANNER"]},"#
            + #""workspaceRequest":{"recommendationsForSurfaceRequests":[]}}"#

    private let transport: any ProviderHTTPTransport
    private let timeout: TimeInterval

    public init(
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        timeout: TimeInterval = 20)
    {
        self.transport = transport
        self.timeout = timeout
    }

    public func fetch(cookieHeader: String, now: Date = Date()) async throws -> GeminiWebUsageSnapshot {
        let request = Self.makeRequest(cookieHeader: cookieHeader, timeout: self.timeout)
        let response: ProviderHTTPResponse
        do {
            response = try await self.transport.response(for: request, retryPolicy: .transientIdempotent)
        } catch {
            throw GeminiWebUsageError.networkError(error.localizedDescription)
        }
        switch response.statusCode {
        case 200:
            break
        case 401, 403:
            throw GeminiWebUsageError.notLoggedIn
        default:
            throw GeminiWebUsageError.networkError("HTTP \(response.statusCode)")
        }
        if let finalURL = response.response.url, finalURL.host != Self.executeQueryURL.host {
            // A redirect to accounts.google.com means the session cookies were rejected.
            throw GeminiWebUsageError.notLoggedIn
        }
        return try GeminiWebUsageParser.parse(data: response.data, now: now)
    }

    static func makeRequest(cookieHeader: String, timeout: TimeInterval) -> URLRequest {
        var components = URLComponents(url: self.executeQueryURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "query_signature", value: self.usagePageQuerySignature),
            URLQueryItem(name: "variables", value: self.usagePageQueryVariables),
        ]
        // URLComponents leaves `+`, `/` and `=` unescaped in query values; the signature is base64.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+/=&")
        components.percentEncodedQuery = components.queryItems?.map { item in
            let value = item.value?.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(item.name)=\(value)"
        }.joined(separator: "&")

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("https://gemini.google.com/usage", forHTTPHeaderField: "Referer")
        return request
    }
}

// MARK: - Settings

public enum GeminiProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.gemini
    public typealias Section = CookieProviderSettings
}

extension ProviderSettingsSnapshot {
    public var gemini: CookieProviderSettings? {
        self[GeminiProviderSettingsKey.self]
    }
}

public enum GeminiWebCookieSettings {
    public static let sectionRegistration = ProviderSettingsSectionRegistration(
        GeminiProviderSettingsKey.self,
        cookieSettings: { $0 },
        credentialSettings: { context in
            GeminiWebCookieSettings.settings(
                cookieSettings: context.cookieSettings(for: .gemini),
                config: context.config)
        })

    /// Adds the optional browser/profile pin to resolved cookie settings. Unlike selected-profile plugin
    /// providers, an empty selection keeps automatic discovery across every browser.
    public static func settings(
        cookieSettings: CookieProviderSettings,
        config: ProviderConfig?) -> CookieProviderSettings
    {
        var settings = cookieSettings
        settings.selectedBrowserProfile = self.selectedBrowser(in: config)
        return settings
    }

    /// `browserID` restricts discovery to one browser; a non-empty `browserProfileID` narrows it to one profile.
    public static func selectedBrowser(in config: ProviderConfig?) -> ProviderBrowserProfile? {
        guard let browserID = config?.browserID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !browserID.isEmpty
        else { return nil }
        return ProviderBrowserProfile(browserID: browserID, profileID: config?.browserProfileID ?? "")
    }
}

// MARK: - Cookie import

public enum GeminiWebCookieHeader {
    /// Google's sign-in cookies; any one of them identifies a signed-in browser session.
    static let sessionCookieNames: Set<String> = ["__Secure-1PSID", "__Secure-3PSID", "SID"]
    static let geminiURL = URL(string: "https://gemini.google.com/")!

    static func hasSessionCookie(names: some Sequence<String>) -> Bool {
        names.contains { self.sessionCookieNames.contains($0) }
    }

    /// Keeps only cookies a browser would send to gemini.google.com.
    static func header(from cookies: [HTTPCookie]) -> String? {
        let applicable = cookies.filter { self.appliesToGemini(domain: $0.domain) }
        return self.header(pairs: applicable.map { ($0.name, $0.value) })
    }

    static func header(from records: [ProviderPluginCookieRecord], now: Date = Date()) -> String? {
        let applicable = records.filter { $0.matches(self.geminiURL, now: now) }
        return self.header(pairs: applicable.map { ($0.name, $0.value) })
    }

    /// Normalizes a pasted `Cookie:` header or bare cookie string and requires a Google sign-in cookie.
    static func manualHeader(_ raw: String?) -> String? {
        guard let raw, let normalized = CookieHeaderNormalizer.normalize(raw) else { return nil }
        let names = normalized.split(separator: ";").compactMap { pair in
            pair.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return self.hasSessionCookie(names: names) ? normalized : nil
    }

    static func appliesToGemini(domain: String) -> Bool {
        let normalized = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized == "google.com" || normalized == "gemini.google.com"
    }

    private static func header(pairs: [(String, String)]) -> String? {
        guard self.hasSessionCookie(names: pairs.map(\.0)) else { return nil }
        return pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }
}

#if os(macOS)
public enum GeminiWebCookieImporter {
    private static let log = CodexBarLog.logger(LogCategories.provider(.gemini, scope: "cookie"))
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = ["gemini.google.com", "google.com"]

    public struct SessionInfo: Sendable {
        public let cookieHeader: String
        public let sourceLabel: String
    }

    public static func importSessions(
        browserDetection: BrowserDetection,
        selection: ProviderBrowserProfile? = nil,
        logger: ((String) -> Void)? = nil) throws -> AnySequence<SessionInfo>
    {
        let log: (String) -> Void = { message in
            logger?("[gemini-cookie] \(message)")
            self.log.debug(message)
        }
        if let selection, !selection.profileID.isEmpty {
            return try AnySequence([self.importSelectedProfile(selection, logger: log)])
        }
        let order: [Browser] = if let selection {
            Browser(rawValue: selection.browserID).map { [$0] } ?? []
        } else {
            BrowserCookieImportSupport.importOrder(for: .gemini)
        }
        return try BrowserCookieImportSupport.collectSessions(
            from: order.lazyCookieImportCandidates(using: browserDetection),
            missingError: GeminiWebUsageError.noSessionCookie,
            logger: log,
            load: { browser in
                let profiles = try BrowserCookieImportSupport.loadProfiles(
                    from: browser,
                    domains: self.cookieDomains,
                    client: self.cookieClient,
                    logger: log)
                return profiles.compactMap { profile in
                    guard let header = GeminiWebCookieHeader.header(from: profile.cookies) else { return nil }
                    log("Found Google session cookie in \(profile.label)")
                    return SessionInfo(cookieHeader: header, sourceLabel: profile.label)
                }
            })
    }

    /// Reads only the pinned profile, so a session from another Google account can never be picked instead.
    private static func importSelectedProfile(
        _ selection: ProviderBrowserProfile,
        logger: (String) -> Void) throws -> SessionInfo
    {
        let records = try ProviderBrowserProfile.read(selection, domains: Set(self.cookieDomains))
        guard let header = GeminiWebCookieHeader.header(from: records) else {
            throw GeminiWebUsageError.noSessionCookie
        }
        let label = "\(Browser(rawValue: selection.browserID)?.displayName ?? selection.browserID) selected profile"
        logger("Found Google session cookie in \(label)")
        return SessionInfo(cookieHeader: header, sourceLabel: label)
    }
}
#endif
