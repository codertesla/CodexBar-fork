import CodexBarCore
import Foundation

extension SettingsStore {
    var geminiCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .gemini, fallback: .auto) }
        set { self.setCookieSource(newValue, provider: .gemini) }
    }

    var geminiCookieHeader: String {
        get { self[providerConfig: .gemini, field: .cookieHeader] }
        set { self[providerConfig: .gemini, field: .cookieHeader] = newValue }
    }
}
