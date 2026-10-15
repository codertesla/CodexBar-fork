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
                  "percentageUsed": 37.5,
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
        #expect(snapshot.fiveHour?.usedPercent == 0.24)
        #expect(snapshot.weekly?.usedPercent == 37.5)
        #expect(snapshot.updatedAt == now)

        let fiveHourReset = try #require(snapshot.fiveHour?.resetsAt)
        #expect(abs(fiveHourReset.timeIntervalSince1970 - 1_792_043_033.558) < 0.01)
        let weeklyReset = try #require(snapshot.weekly?.resetsAt)
        #expect(abs(weeklyReset.timeIntervalSince1970 - 1_792_557_833.558) < 0.01)
    }

    @Test
    func `maps web snapshot to five hour primary and weekly secondary windows`() throws {
        let snapshot = try GeminiWebUsageParser.parse(data: Data(Self.usageResponse.utf8))
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 0.24)
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
        #expect(throws: GeminiWebUsageError.usageUnavailable("No usage windows reported for this account.")) {
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
    func `auto mode tries web usage before Gemini CLI OAuth`() {
        let auto = GeminiProviderDescriptor.resolveStrategies(sourceMode: .auto).map(\.id)
        #expect(auto == ["gemini.web", "gemini.api"])
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
