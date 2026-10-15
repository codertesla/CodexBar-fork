import CodexBarCore
import Foundation
import SweetCookieKit
import SwiftUI

struct GeminiProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .gemini
    let supportsLoginFlow: Bool = true

    @MainActor
    func settingsActions(context: ProviderSettingsContext) -> [ProviderSettingsActionsDescriptor] {
        guard Self.showsAntigravityMigrationAction(context: context) else { return [] }
        return [
            ProviderSettingsActionsDescriptor(
                id: "gemini-antigravity-migration",
                title: "Gemini CLI migration",
                subtitle: GeminiConsumerTierMigration.deprecationError,
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "gemini-enable-antigravity",
                        title: "Enable Antigravity provider",
                        style: .bordered,
                        isVisible: nil,
                        perform: {
                            // Provider-specific by design: Gemini migration explicitly enables its Antigravity
                            // successor.
                            context.settings.setProviderEnabled(
                                provider: .antigravity,
                                metadata: ProviderDescriptorRegistry.descriptor(for: .antigravity).metadata,
                                enabled: true)
                            await context.store.refreshProvider(.antigravity, allowDisabled: true)
                        }),
                ],
                isVisible: nil),
        ]
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.geminiCookieSource
        _ = settings.geminiCookieHeader
        _ = settings.providerConfig(for: .gemini)?.browserID
        _ = settings.providerConfig(for: .gemini)?.browserProfileID
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        let settings = GeminiWebCookieSettings.settings(
            cookieSettings: context.settings.resolvedCookieSettings(
                provider: .gemini,
                tokenOverride: context.tokenOverride),
            config: context.settings.providerConfig(for: .gemini))
        return ProviderSettingsSnapshotContribution(settings, for: GeminiProviderSettingsKey.self)
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        [
            ProviderCookieSourceUI.picker(
                id: "gemini-cookie-source",
                context: context,
                source: \.geminiCookieSource,
                allowsOff: true,
                subtitles: {
                    .init(
                        auto: L("Automatic imports browser cookies."),
                        manual: L("Paste a Cookie header or cURL capture from %@.", "gemini.google.com/usage")
                            + " " + L("To read one browser profile, set Cookie source to Automatic."),
                        off: L("%@ cookies are disabled.", "Gemini"))
                },
                trailingText: {
                    if context.settings.geminiCookieSource == .manual,
                       context.settings.geminiCookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        return L("No cookie header pasted.")
                    }
                    return ProviderCookieRefreshAction.trailingText(
                        provider: .gemini,
                        cookieSource: context.settings.geminiCookieSource,
                        context: context)
                },
                trailingActions: [
                    ProviderCookieRefreshAction.descriptor(
                        provider: .gemini,
                        cookieSource: { context.settings.geminiCookieSource },
                        context: context),
                ]),
            self.browserPicker(context: context),
            self.browserProfilePicker(context: context),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "gemini-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: \u{2026}",
                binding: context.binding(\.geminiCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "gemini-open-usage",
                        title: "Open Usage Page",
                        url: URL(string: "https://gemini.google.com/usage")),
                ],
                isVisible: { context.settings.geminiCookieSource == .manual }),
        ]
    }

    @MainActor
    func runLoginFlow(context: ProviderLoginContext) async -> Bool {
        await context.controller.runGeminiLoginFlow()
        return false
    }

    /// Optional pin for people signed in to different Google accounts in several browsers or profiles.
    @MainActor
    private func browserPicker(context: ProviderSettingsContext) -> ProviderSettingsPickerDescriptor {
        let detection = BrowserDetection()
        let browsers = (ProviderDescriptorRegistry.descriptor(for: .gemini).metadata.browserCookieOrder ?? [])
            .filter { detection.isCookieSourceAvailable($0) }
        var options = [ProviderSettingsPickerOption(id: "", title: L("Automatic"))]
        options += browsers.map { ProviderSettingsPickerOption(id: $0.rawValue, title: $0.displayName) }
        if let saved = context.settings.providerConfig(for: .gemini)?.browserID,
           !saved.isEmpty, !browsers.contains(where: { $0.rawValue == saved })
        {
            options.append(.init(id: saved, title: Browser(rawValue: saved)?.displayName ?? saved))
        }
        return ProviderSettingsPickerDescriptor(
            id: "gemini-browser",
            title: L("Browser"),
            subtitle: "",
            binding: Binding(
                get: { context.settings.providerConfig(for: .gemini)?.browserID ?? "" },
                set: { value in
                    guard value != (context.settings.providerConfig(for: .gemini)?.browserID ?? "") else { return }
                    context.store.clearProviderState(.gemini)
                    context.settings.updateProviderConfig(provider: .gemini) {
                        $0.browserID = value.isEmpty ? nil : value
                        $0.browserProfileID = nil
                    }
                }),
            options: options,
            isVisible: { context.settings.geminiCookieSource == .auto },
            onChange: nil)
    }

    @MainActor
    private func browserProfilePicker(context: ProviderSettingsContext) -> ProviderSettingsPickerDescriptor {
        let browserID = context.settings.providerConfig(for: .gemini)?.browserID ?? ""
        let browser = Browser(rawValue: browserID)
        let profiles = browser.flatMap { try? BrowserCookieClient().codexBarStores(for: $0) }?
            .compactMap(ProviderBrowserProfile.selectableProfile) ?? []
        var seen = Set<String>()
        var options = [ProviderSettingsPickerOption(id: "", title: L("Automatic"))]
        options += profiles.filter { seen.insert($0.id).inserted }.map {
            ProviderSettingsPickerOption(
                id: $0.id,
                title: ProviderBrowserProfile.pickerTitle(profileID: $0.id, fallbackName: $0.name))
        }
        if let saved = context.settings.providerConfig(for: .gemini)?.browserProfileID,
           !saved.isEmpty, !seen.contains(saved)
        {
            options.append(.init(
                id: saved,
                title: L("Unavailable profile: %@", URL(fileURLWithPath: saved).lastPathComponent)))
        }
        return ProviderSettingsPickerDescriptor(
            id: "gemini-browser-profile",
            title: L("Browser profile"),
            subtitle: L(
                "Read only the selected %@ profile. Accounts are never selected automatically.",
                browser?.displayName ?? "browser"),
            binding: Binding(
                get: { context.settings.providerConfig(for: .gemini)?.browserProfileID ?? "" },
                set: { value in
                    guard value != (context.settings.providerConfig(for: .gemini)?.browserProfileID ?? "")
                    else { return }
                    context.store.clearProviderState(.gemini)
                    context.settings.updateProviderConfig(provider: .gemini) {
                        $0.browserProfileID = value.isEmpty ? nil : value
                    }
                }),
            options: options,
            isVisible: {
                context.settings.geminiCookieSource == .auto
                    && !(context.settings.providerConfig(for: .gemini)?.browserID ?? "").isEmpty
            },
            onChange: nil)
    }

    /// The Antigravity hand-off only helps when the Gemini web source is off; otherwise the fix is a signed-in
    /// gemini.google.com browser session, so a CLI OAuth fallback failure must not suggest switching providers.
    @MainActor
    private static func showsAntigravityMigrationAction(context: ProviderSettingsContext) -> Bool {
        context.store.geminiObservedConsumerTierDeprecation && context.settings.geminiCookieSource == .off
    }
}
