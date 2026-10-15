import Foundation
import Testing
@testable import CodexBarCore

struct GeminiWebUsageTests {
    private static let usageResponse = """
    )]}'
    [{
      "data": {
        "viewer": {
          "rpcs": {
            "getUsageInfo": {
              "subscriptionTier": "TIER1",
              "pools": [
                {
                  "poolType": "GXU_FIVE_HOURLY",
                  "percentageUsed": 0.24,
                  "gxu": { "windowRefreshesAt": "2026-10-15T05:43:53.558200Z" }
                },
                {
                  "poolType": "GXU_WEEKLY",
                  "percentageUsed": 0.375,
                  "gxu": { "windowRefreshesAt": "2026-10-21T04:43:53.558273Z" }
                }
              ],
              "advancedSettings": null,
              "useOverageAiCredits": false
            }
          }
        }
      },
      "errors": [{ "message": "Request contains an invalid argument.", "path": ["viewer", "getG1Interventions"] }],
      "path": []
    }]
    """

    @Test
    func `parses five hour and weekly pools from usage page query`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = try GeminiWebUsageParser.parse(data: Data(Self.usageResponse.utf8), now: now)

        #expect(snapshot.subscriptionTier == "TIER1")
        #expect(snapshot.fiveHour?.usedPercent == 24)
        #expect(snapshot.weekly?.usedPercent == 37.5)
        #expect(snapshot.updatedAt == now)

        let fiveHourReset = try #require(snapshot.fiveHour?.resetsAt)
        #expect(abs(fiveHourReset.timeIntervalSince1970 - 1_792_043_033.558) < 0.01)
        let weeklyReset = try #require(snapshot.weekly?.resetsAt)
        #expect(abs(weeklyReset.timeIntervalSince1970 - 1_792_557_833.558) < 0.01)
    }

    @Test
    func `percentage used is a fraction that the usage page multiplies by one hundred`() throws {
        // Live page showed "71% used" / "4% used" for these values.
        let body = """
        [{"data":{"viewer":{"rpcs":{"getUsageInfo":{"pools":[\
        {"poolType":"GXU_FIVE_HOURLY","percentageUsed":0.71,"gxu":{"windowRefreshesAt":"2026-10-15T05:43:53Z"}},\
        {"poolType":"GXU_WEEKLY","percentageUsed":1.2,"gxu":{"windowRefreshesAt":"2026-10-21T04:43:53Z"}}]}}}}}]
        """
        let snapshot = try GeminiWebUsageParser.parse(data: Data(body.utf8))
        #expect(abs((snapshot.fiveHour?.usedPercent ?? 0) - 71) < 0.0001)
        #expect(snapshot.weekly?.usedPercent == 100)
    }

    @Test
    func `maps web snapshot to five hour primary and weekly secondary windows`() throws {
        let snapshot = try GeminiWebUsageParser.parse(data: Data(Self.usageResponse.utf8))
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 24)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.secondary?.usedPercent == 37.5)
        #expect(usage.secondary?.windowMinutes == 10080)
        #expect(usage.tertiary == nil)
        #expect(usage.loginMethod(for: .gemini) == "Pro")
    }

    @Test
    func `labels web windows by duration and keeps model labels for OAuth snapshots`() throws {
        let metadata = GeminiProviderDescriptor.descriptor.metadata
        let web = try GeminiWebUsageParser.parse(data: Data(Self.usageResponse.utf8)).toUsageSnapshot()
        let webLabels = GeminiProviderDescriptor.rateWindowLabels(metadata: metadata, snapshot: web)
        #expect(webLabels.primary == "5-hour")
        #expect(webLabels.secondary == "Weekly")
        #expect(webLabels.showsTertiary == false)

        let oauth = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 1440, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: Date())
        let oauthLabels = GeminiProviderDescriptor.rateWindowLabels(metadata: metadata, snapshot: oauth)
        #expect(oauthLabels.primary == metadata.sessionLabel)
        #expect(oauthLabels.secondary == metadata.weeklyLabel)
    }

    @Test
    func `signed out viewer is reported as not logged in`() {
        let body = """
        [{"data":{"viewer":null},"errors":[{"message":"Internal error encountered.",\
        "errorType":"DATA_FETCHING_EXCEPTION","path":["viewer"]}],"path":[]}]
        """
        #expect(throws: GeminiWebUsageError.notLoggedIn) {
            try GeminiWebUsageParser.parse(data: Data(body.utf8))
        }
    }

    @Test
    func `rejected query is reported as unavailable instead of signed out`() {
        let body = """
        [{"data":null,"errors":[{"message":"no value for non-null variable $g1Request",\
        "errorType":"VALIDATION_ERROR"}],"path":[]}]
        """
        #expect(throws: GeminiWebUsageError.usageUnavailable("no value for non-null variable $g1Request")) {
            try GeminiWebUsageParser.parse(data: Data(body.utf8))
        }
    }

    @Test
    func `html sign in page is reported as not logged in`() {
        #expect(throws: GeminiWebUsageError.notLoggedIn) {
            try GeminiWebUsageParser.parse(data: Data("<!doctype html><html></html>".utf8))
        }
    }

    @Test
    func `missing pools is reported as unavailable usage`() {
        let body = #"[{"data":{"viewer":{"rpcs":{"getUsageInfo":{"subscriptionTier":"TIER1","pools":[]}}}}}]"#
        #expect(throws: GeminiWebUsageError.noUsageWindows) {
            try GeminiWebUsageParser.parse(data: Data(body.utf8))
        }
    }

    @Test
    func `request targets the persisted usage page query with the session cookie`() throws {
        let request = GeminiWebUsageFetcher.makeRequest(cookieHeader: "SID=synthetic", timeout: 5)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(url.host == "gemini.google.com")
        #expect(url.path == "/_/BardChatUi/graphql/schemas/GEMINI_WEB_GRAPHQL/executeQuery")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "SID=synthetic")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(components.percentEncodedQuery?.contains("2%2FdWbCvkVB0X16r9NPnxifeOAAqdCqMf0xeWvau9yPy7g%3D") == true)
        let signature = components.queryItems?.first { $0.name == "query_signature" }?.value
        #expect(signature == GeminiWebUsageFetcher.usagePageQuerySignature)
        let variables = try #require(components.queryItems?.first { $0.name == "variables" }?.value)
        let decoded = try JSONSerialization.jsonObject(with: Data(variables.utf8)) as? [String: Any]
        #expect(decoded?["g1Request"] != nil)
        #expect(decoded?["workspaceRequest"] != nil)
    }

    @Test
    func `fetcher maps unauthorized status to not logged in`() async {
        let transport = ProviderHTTPTransportHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }
        let fetcher = GeminiWebUsageFetcher(transport: transport)
        await #expect(throws: GeminiWebUsageError.notLoggedIn) {
            try await fetcher.fetch(cookieHeader: "SID=synthetic")
        }
    }

    @Test
    func `fetcher parses a successful response`() async throws {
        let body = Data(Self.usageResponse.utf8)
        let transport = ProviderHTTPTransportHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
        let snapshot = try await GeminiWebUsageFetcher(transport: transport).fetch(cookieHeader: "SID=synthetic")
        #expect(snapshot.weekly?.usedPercent == 37.5)
    }

    @Test
    func `cookie header keeps only google session cookies sent to gemini`() throws {
        let cookies = try [
            Self.cookie(name: "__Secure-1PSID", domain: ".google.com"),
            Self.cookie(name: "NID", domain: ".google.com"),
            Self.cookie(name: "COMPASS", domain: "gemini.google.com"),
            Self.cookie(name: "ACCOUNT_CHOOSER", domain: "accounts.google.com"),
        ]
        let header = try #require(GeminiWebCookieHeader.header(from: cookies))
        #expect(header.contains("__Secure-1PSID=v"))
        #expect(header.contains("NID=v"))
        #expect(header.contains("COMPASS=v"))
        #expect(!header.contains("ACCOUNT_CHOOSER"))
    }

    @Test
    func `cookie header requires a google sign in cookie`() throws {
        let cookies = try [Self.cookie(name: "NID", domain: ".google.com")]
        #expect(GeminiWebCookieHeader.header(from: cookies) == nil)
    }

    @Test
    func `browser records keep only cookies sent to gemini`() throws {
        let records = try [
            Self.cookie(name: "__Secure-1PSID", domain: ".google.com"),
            Self.cookie(name: "ACCOUNT_CHOOSER", domain: "accounts.google.com"),
        ].map(ProviderPluginCookieRecord.init(cookie:))
        let header = try #require(GeminiWebCookieHeader.header(from: records))
        #expect(header == "__Secure-1PSID=v")
    }

    @Test
    func `manual cookie header accepts a pasted header with a google sign in cookie`() {
        #expect(GeminiWebCookieHeader.manualHeader("Cookie: NID=n; __Secure-1PSID=s") == "NID=n; __Secure-1PSID=s")
        #expect(GeminiWebCookieHeader.manualHeader("NID=n") == nil)
        #expect(GeminiWebCookieHeader.manualHeader(nil) == nil)
    }

    @Test
    func `browser pin is optional and narrows to one profile when set`() {
        #expect(GeminiWebCookieSettings.selectedBrowser(in: nil) == nil)

        var config = ProviderConfig(id: .gemini)
        #expect(GeminiWebCookieSettings.selectedBrowser(in: config) == nil)

        config.browserID = "chromeCanary"
        #expect(GeminiWebCookieSettings.selectedBrowser(in: config)
            == ProviderBrowserProfile(browserID: "chromeCanary", profileID: ""))

        config.browserProfileID = "Profile 3"
        let settings = GeminiWebCookieSettings.settings(cookieSettings: CookieProviderSettings(), config: config)
        #expect(settings.selectedBrowserProfile
            == ProviderBrowserProfile(browserID: "chromeCanary", profileID: "Profile 3"))
        #expect(settings.cookieSource == .auto)
    }

    @Test
    func `gemini settings section resolves cookie source and browser pin from config`() throws {
        var config = ProviderConfig(id: .gemini)
        config.cookieSource = .manual
        config.cookieHeader = "__Secure-1PSID=synthetic"
        config.browserID = "chromeCanary"
        let contribution = try #require(GeminiProviderDescriptor.descriptor.settingsSection.credentialContribution(
            context: ProviderCredentialSettingsContext(config: config, account: nil)))
        var builder = ProviderSettingsSnapshotBuilder()
        builder.apply(contribution)
        let settings = try #require(builder.build().gemini)
        #expect(settings.cookieSource == .manual)
        #expect(settings.manualCookieHeader == "__Secure-1PSID=synthetic")
        #expect(settings.selectedBrowserProfile?.browserID == "chromeCanary")
    }

    @Test
    func `profile picker title uses the chromium display name from local state`() {
        let root = "/Users/me/Library/Application Support/Google/Chrome Canary"
        let localState = Data(#"{"profile":{"info_cache":{"Profile 19":{"name":"Work"}}}}"#.utf8)
        let read: (URL) -> Data? = { url in url.path == root + "/Local State" ? localState : nil }

        #expect(ProviderBrowserProfile.pickerTitle(
            profileID: root + "/Profile 19", fallbackName: "Profile 19", readFile: read) == "Work (Profile 19)")
        #expect(ProviderBrowserProfile.pickerTitle(
            profileID: root + "/Profile 2", fallbackName: "Profile 2", readFile: read) == "Profile 2")
        #expect(ProviderBrowserProfile.pickerTitle(
            profileID: "safari.default", fallbackName: "Default", readFile: read) == "Default")
    }

    @Test
    func `profile traversal skips signed in accounts without usage windows`() async throws {
        let usable = try GeminiWebUsageParser.parse(data: Data(Self.usageResponse.utf8))
        let calls = CallLog()
        let (snapshot, session) = try await GeminiWebFetchStrategy.firstUsableSession(
            ["free-account", "signed-out", "pro-account"],
            cookieHeader: \.self)
        { header in
            await calls.append(header)
            switch header {
            case "free-account": throw GeminiWebUsageError.noUsageWindows
            case "signed-out": throw GeminiWebUsageError.notLoggedIn
            default: return usable
            }
        }
        #expect(session == "pro-account")
        #expect(snapshot == usable)
        #expect(await calls.values == ["free-account", "signed-out", "pro-account"])
    }

    @Test
    func `profile traversal stops on failures shared by every session`() async {
        let calls = CallLog()
        await #expect(throws: GeminiWebUsageError.usageUnavailable("rotated query")) {
            _ = try await GeminiWebFetchStrategy.firstUsableSession(["a", "b"], cookieHeader: \.self) { header in
                await calls.append(header)
                throw GeminiWebUsageError.usageUnavailable("rotated query")
            }
        }
        #expect(await calls.values == ["a"])
    }

    @Test
    func `cached session without usage windows lets discovery continue`() async throws {
        let usable = try GeminiWebUsageParser.parse(data: Data(Self.usageResponse.utf8))
        let lostSubscription = try await GeminiWebFetchStrategy.cachedSessionSnapshot("cached") { _ in
            throw GeminiWebUsageError.noUsageWindows
        }
        #expect(lostSubscription == nil)
        let signedOut = try await GeminiWebFetchStrategy.cachedSessionSnapshot("cached") { _ in
            throw GeminiWebUsageError.notLoggedIn
        }
        #expect(signedOut == nil)
        let cached = try await GeminiWebFetchStrategy.cachedSessionSnapshot("cached") { _ in usable }
        #expect(cached == usable)
        await #expect(throws: GeminiWebUsageError.usageUnavailable("rotated query")) {
            _ = try await GeminiWebFetchStrategy.cachedSessionSnapshot("cached") { _ in
                throw GeminiWebUsageError.usageUnavailable("rotated query")
            }
        }
    }

    @Test
    func `profile traversal reports the last account specific failure`() async {
        await #expect(throws: GeminiWebUsageError.notLoggedIn) {
            _ = try await GeminiWebFetchStrategy.firstUsableSession(["a"], cookieHeader: \.self) { _ in
                throw GeminiWebUsageError.notLoggedIn
            }
        }
        await #expect(throws: GeminiWebUsageError.noSessionCookie) {
            _ = try await GeminiWebFetchStrategy.firstUsableSession([String](), cookieHeader: \.self) { _ in
                throw GeminiWebUsageError.notLoggedIn
            }
        }
    }

    @Test
    func `existing gemini configs keep their source and gain no browser pin after upgrade`() throws {
        let legacy = #"""
        {"version":1,"providers":[{"id":"gemini","enabled":true,"source":"api"},{"id":"codex","enabled":true}]}
        """#
        let config = try JSONDecoder().decode(CodexBarConfig.self, from: Data(legacy.utf8))
        let gemini = try #require(config.providerConfig(for: .gemini))
        #expect(gemini.source == .api)
        #expect(gemini.browserID == nil)
        #expect(GeminiProviderDescriptor.resolveStrategies(sourceMode: gemini.source ?? .auto).map(\.id)
            == ["gemini.api"])

        let contribution = try #require(GeminiProviderDescriptor.descriptor.settingsSection.credentialContribution(
            context: ProviderCredentialSettingsContext(config: gemini, account: nil)))
        var builder = ProviderSettingsSnapshotBuilder()
        builder.apply(contribution)
        let settings = try #require(builder.build().gemini)
        #expect(settings.cookieSource == .auto)
        #expect(settings.manualCookieHeader == nil)
        #expect(settings.selectedBrowserProfile == nil)

        let reencoded = try JSONDecoder().decode(
            CodexBarConfig.self,
            from: JSONEncoder().encode(config))
        #expect(reencoded.providerConfig(for: .gemini)?.source == .api)
    }

    @Test
    func `auto mode keeps Gemini CLI OAuth before web usage`() {
        let auto = GeminiProviderDescriptor.resolveStrategies(sourceMode: .auto).map(\.id)
        #expect(auto == ["gemini.api", "gemini.web"])
        #expect(GeminiProviderDescriptor.resolveStrategies(sourceMode: .web).map(\.id) == ["gemini.web"])
        #expect(GeminiProviderDescriptor.resolveStrategies(sourceMode: .api).map(\.id) == ["gemini.api"])
    }

    private static func cookie(name: String, domain: String) throws -> HTTPCookie {
        try #require(HTTPCookie(properties: [
            .name: name,
            .value: "v",
            .domain: domain,
            .path: "/",
        ]))
    }
}

private actor CallLog {
    private(set) var values: [String] = []

    func append(_ value: String) {
        self.values.append(value)
    }
}
