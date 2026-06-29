import SwiftUI
#if canImport(StoreKit)
import StoreKit
#endif

struct SettingsView: View {
    @AppStorage("tmdbLanguage") private var selectedLanguage = "en-US"
    @AppStorage("githubReleaseAutoCheckEnabled") private var autoCheckGitHubReleases = true
    @AppStorage("githubReleaseUpdateAvailable") private var githubReleaseUpdateAvailable = false
    @AppStorage("githubReleaseLatestVersion") private var githubReleaseLatestVersion = ""
    @AppStorage("githubReleaseURL") private var githubReleaseURL = ""
    @AppStorage("defaultScheduleMode") private var defaultScheduleModeRaw = ScheduleMode.anime.rawValue
    @AppStorage(PerformanceModeSettings.skipAniListTraversalForAnimeDetailsKey) private var skipAniListTraversalForAnimeDetails = false

    @StateObject private var catalogManager = CatalogManager.shared
    @AppStorage("showKanzen") private var showKanzen: Bool = false
    @State private var isCheckingGitHubRelease = false

    private let patreonURL = URL(string: "https://www.patreon.com/c/soupy698")!
    private let koFiURL = URL(string: "https://ko-fi.com/soupydev")!
    private let discordURL = URL(string: "https://discord.gg/UjHgGaEbn")!
    private let sourceCodeURL = URL(string: "https://github.com/Soupy-dev/Eclipse")!
    private let originalProjectURL = URL(string: "https://github.com/cranci1/Luna")!
    private let licenseURL = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!
    private let privacyPolicyURL = URL(string: "https://soupy-dev.github.io/Eclipse/privacy-policy/")!

    private var defaultScheduleMode: ScheduleMode {
        ScheduleMode.sanitized(defaultScheduleModeRaw)
    }

    private var supportsGitHubReleaseUpdates: Bool {
        GitHubReleaseChecker.isGitHubReleaseUpdatesAvailable
    }

    let languages = [
        ("en-US", "English (US)"),
        ("en-GB", "English (UK)"),
        ("es-ES", "Spanish (Spain)"),
        ("es-MX", "Spanish (Mexico)"),
        ("fr-FR", "French"),
        ("de-DE", "German"),
        ("it-IT", "Italian"),
        ("pt-BR", "Portuguese (Brazil)"),
        ("ja-JP", "Japanese"),
        ("ko-KR", "Korean"),
        ("zh-CN", "Chinese (Simplified)"),
        ("zh-TW", "Chinese (Traditional)"),
        ("ru-RU", "Russian"),
        ("ar-SA", "Arabic"),
        ("hi-IN", "Hindi"),
        ("th-TH", "Thai"),
        ("tr-TR", "Turkish"),
        ("pl-PL", "Polish"),
        ("nl-NL", "Dutch"),
        ("sv-SE", "Swedish"),
        ("da-DK", "Danish"),
        ("no-NO", "Norwegian"),
        ("fi-FI", "Finnish")
    ]

    var body: some View {
        #if os(tvOS)
            HStack(spacing: 0) {
                VStack(spacing: 30) {
                    Image("Eclipse")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 500, height: 500)
                        .clipShape(RoundedRectangle(cornerRadius: 100, style: .continuous))
                        .shadow(radius: 10)

                    VStack(spacing: 15) {
                        Text("Version \(Bundle.main.appVersion) (\(Bundle.main.buildNumber))")
                            .font(.footnote)
                            .fontWeight(.regular)
                            .foregroundColor(.secondary)

                        Text("Copyright © \(String(Calendar.current.component(.year, from: Date()))) Eclipse by Soupy-dev")
                            .font(.footnote)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                    }
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                NavigationStack {
                    settingsContent
                        // prevent row clipping
                        .padding(.horizontal, 20)
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        #else
            if #available(iOS 16.0, *) {
                NavigationStack {
                    settingsContent
                }
            } else {
                NavigationView {
                    settingsContent
                }
                .navigationViewStyle(StackNavigationViewStyle())
            }
        #endif
    }

    private var settingsContent: some View {
        #if os(tvOS)
        List {
            settingsListContent
        }
        .listStyle(.grouped)
        .scrollClipDisabled()
        #else
        ScrollView {
            VStack(spacing: ExperimentalFeatureState.isEnabledAtLaunch ? 22 : 28) {
                // MARK: - Support
                GlassSection(header: "Support") {
                    VStack(spacing: 0) {
                        if Bundle.main.allowsExternalDonationLinks {
                            Text("Help support the app. Any amount helps keep the app free for everyone. Thanks for using the app and supporting development!")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.62))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)

                            GlassDivider(leadingInset: 14)

                            Link(destination: patreonURL) {
                                GlassSettingsRow(icon: "heart.fill", iconColor: .pink, title: "Support on Patreon") {
                                    Text("Optional")
                                        .font(.subheadline)
                                        .foregroundColor(.white.opacity(0.5))
                                }
                            }
                            .buttonStyle(.plain)

                            GlassDivider()

                            Link(destination: koFiURL) {
                                GlassSettingsRow(icon: "cup.and.saucer.fill", iconColor: .cyan, title: "Support on Ko-fi") {
                                    Text("Optional")
                                        .font(.subheadline)
                                        .foregroundColor(.white.opacity(0.5))
                                }
                            }
                            .buttonStyle(.plain)

                            GlassDivider()
                        } else {
                            #if canImport(StoreKit)
                            NavigationLink(destination: StoreKitSupportView()) {
                                GlassSettingsRow(icon: "heart.fill", iconColor: .pink, title: "Support Eclipse") {
                                    HStack(spacing: 4) {
                                        Text("Tips & subscription")
                                            .font(.subheadline)
                                            .foregroundColor(.white.opacity(0.5))
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.white.opacity(0.3))
                                    }
                                }
                            }
                            .buttonStyle(.plain)

                            GlassDivider()
                            #endif
                        }

                        Link(destination: discordURL) {
                            GlassSettingsRow(icon: "bubble.left.and.bubble.right.fill", iconColor: .indigo, title: "Join Discord") {
                                Text("Community")
                                    .font(.subheadline)
                                    .foregroundColor(.white.opacity(0.5))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                // MARK: - Basic
                GlassSection(header: "Basic") {
                    VStack(spacing: 0) {
                        NavigationLink(destination: LanguageSelectionView(selectedLanguage: $selectedLanguage, languages: languages)) {
                            GlassSettingsRow(icon: "globe", iconColor: .blue, title: "Language") {
                                HStack(spacing: 4) {
                                    Text(languages.first { $0.0 == selectedLanguage }?.1 ?? "English (US)")
                                        .font(.subheadline)
                                        .foregroundColor(.white.opacity(0.5))
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.3))
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        GlassDivider()

                        NavigationLink(destination: PerformanceModeSettingsView()) {
                            GlassSettingsRow(icon: "bolt.fill", iconColor: .yellow, title: "Performance Mode") {
                                HStack(spacing: 4) {
                                    Text(catalogManager.performanceModeEnabled || skipAniListTraversalForAnimeDetails ? "On" : "Off")
                                        .font(.subheadline)
                                        .foregroundColor(.white.opacity(0.5))
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.3))
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        GlassDivider()

                        NavigationLink(destination: PlayerSettingsView()) {
                            GlassSettingsRow(icon: "play.fill", iconColor: .white, title: "Media Player")
                        }
                        .buttonStyle(.plain)

                        GlassDivider()

                        NavigationLink(destination: AlternativeUIView()) {
                            GlassSettingsRow(icon: "paintbrush.fill", iconColor: .purple, title: "Appearance")
                        }
                        .buttonStyle(.plain)

                        GlassDivider()

                        NavigationLink(destination: ScheduleSettingsView()) {
                            GlassSettingsRow(icon: "calendar", iconColor: .red, title: "Schedule") {
                                HStack(spacing: 4) {
                                    Text(defaultScheduleMode.displayName)
                                        .font(.subheadline)
                                        .foregroundColor(.white.opacity(0.5))
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.3))
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        GlassDivider()

                        NavigationLink(destination: CatalogsSettingsView()) {
                            GlassSettingsRow(icon: "square.grid.2x2", iconColor: .green, title: "Catalogs")
                        }
                        .buttonStyle(.plain)

                        GlassDivider()

                        NavigationLink(destination: ServicesView()) {
                            GlassSettingsRow(icon: "server.rack", iconColor: .indigo, title: "Services")
                        }
                        .buttonStyle(.plain)

                        if Bundle.main.allowsNuvioPlugins {
                            GlassDivider()

                            NavigationLink(destination: NuvioPluginsView()) {
                                GlassSettingsRow(icon: "puzzlepiece.extension", iconColor: .mint, title: "Plugins")
                            }
                            .buttonStyle(.plain)
                        }

                        GlassDivider()

                        NavigationLink(destination: TrackersSettingsView()) {
                            GlassSettingsRow(icon: "chart.bar.fill", iconColor: .pink, title: "Trackers")
                        }
                        .buttonStyle(.plain)
                    }
                }

                // MARK: - Data
                GlassSection(header: "Data") {
                    VStack(spacing: 0) {
                        NavigationLink(destination: StorageView()) {
                            GlassSettingsRow(icon: "internaldrive", iconColor: .gray, title: "Storage")
                        }
                        .buttonStyle(.plain)

                        GlassDivider()

                        NavigationLink(destination: BackupManagementView()) {
                            GlassSettingsRow(icon: "arrow.triangle.2.circlepath", iconColor: .teal, title: "Backup & Restore")
                        }
                        .buttonStyle(.plain)

                        if ExperimentalFeatureState.isEnabledAtLaunch {
                            GlassDivider()

                            NavigationLink(destination: ExperimentalCloudSyncView()) {
                                GlassSettingsRow(icon: "icloud", iconColor: .blue, title: "iCloud Sync") {
                                    Text(ExperimentalCloudSyncAvailability.current.isAvailable ? "Available" : "Unavailable")
                                        .font(.subheadline)
                                        .foregroundColor(.white.opacity(0.5))
                                }
                            }
                            .buttonStyle(.plain)
                        }

                        GlassDivider()

                        NavigationLink(destination: LoggerView()) {
                            GlassSettingsRow(icon: "doc.text", iconColor: .yellow, title: "Logger")
                        }
                        .buttonStyle(.plain)
                    }
                }

                // MARK: - Others
                GlassSection(header: "Others") {
                    VStack(spacing: 0) {
                        Button {
                            showKanzen = true
                        } label: {
                            GlassSettingsRow(icon: "book.fill", iconColor: .orange, title: "Switch to Reader Mode")
                        }
                        .buttonStyle(.plain)

                        GlassDivider()

                        NavigationLink(destination: LegalNoticeView(
                            sourceCodeURL: sourceCodeURL,
                            originalProjectURL: originalProjectURL,
                            licenseURL: licenseURL,
                            privacyPolicyURL: privacyPolicyURL
                        )) {
                            GlassSettingsRow(icon: "scroll.fill", iconColor: .cyan, title: "Legal & Source")
                        }
                        .buttonStyle(.plain)
                    }
                }

                // MARK: - Updates
                if supportsGitHubReleaseUpdates {
                    GlassSection(header: "Updates") {
                        VStack(spacing: 0) {
                            GlassSettingsRow(icon: "arrow.triangle.2.circlepath", iconColor: .mint, title: "Auto-check GitHub Releases") {
                                Toggle("", isOn: $autoCheckGitHubReleases)
                                    .labelsHidden()
                                    .tint(.mint)
                            }

                            GlassDivider()

                            Button {
                                performManualGitHubReleaseCheck()
                            } label: {
                                GlassSettingsRow(icon: "arrow.clockwise", iconColor: .cyan, title: "Check for Updates") {
                                    if isCheckingGitHubRelease {
                                        ProgressView()
                                            .progressViewStyle(.circular)
                                            .tint(.white.opacity(0.6))
                                    } else {
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.white.opacity(0.3))
                                    }
                                }
                            }
                            .disabled(isCheckingGitHubRelease)
                            .buttonStyle(.plain)

                            if githubReleaseUpdateAvailable {
                                GlassDivider()

                                if let releaseURL = URL(string: githubReleaseURL), !githubReleaseURL.isEmpty {
                                    Link(destination: releaseURL) {
                                        GlassSettingsRow(icon: "arrow.down.circle.fill", iconColor: .green, title: "Open Latest Release") {
                                            Text(githubReleaseLatestVersion.isEmpty ? "Update Available" : githubReleaseLatestVersion)
                                                .font(.subheadline)
                                                .foregroundColor(.green.opacity(0.9))
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }

                // MARK: - Version Info
                VStack(spacing: 4) {
                    Text("Eclipse v\(Bundle.main.appVersion) (\(Bundle.main.buildNumber))")
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.3))

                    if supportsGitHubReleaseUpdates && githubReleaseUpdateAvailable {
                        Text(githubReleaseLatestVersion.isEmpty ? "Update available on GitHub" : "Update available: \(githubReleaseLatestVersion)")
                            .font(.footnote)
                            .foregroundColor(.green.opacity(0.85))
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
            .padding(.top, ExperimentalFeatureState.isEnabledAtLaunch ? 12 : 16)
        }
        .navigationTitle("Settings")
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
        #endif
    }

    // Keep tvOS list-based layout as fallback
    @ViewBuilder
    private var settingsListContent: some View {
        Section {
            if Bundle.main.allowsExternalDonationLinks {
                Text("Help support the app. Any amount helps keep the app free for everyone")
                Link("Support on Patreon", destination: patreonURL)
                Link("Support on Ko-fi", destination: koFiURL)
            }
            #if canImport(StoreKit)
            if !Bundle.main.allowsExternalDonationLinks {
                NavigationLink("Support Eclipse", destination: StoreKitSupportView())
            }
            #endif
            Link("Join Discord", destination: discordURL)
        } header: {
            Text("Support")
        }

        Section {
            NavigationLink(destination: LanguageSelectionView(selectedLanguage: $selectedLanguage, languages: languages)) {
                HStack {
                    Text("Informations Language")
                    Spacer()
                    Text(languages.first { $0.0 == selectedLanguage }?.1 ?? "English (US)")
                        .foregroundColor(.secondary)
                }
            }
            NavigationLink(destination: PerformanceModeSettingsView()) {
                Text("Performance Mode")
            }
        } header: {
            Text("TMDB Settings")
        }

        Section {
            NavigationLink(destination: PlayerSettingsView()) { Text("Media Player") }
            NavigationLink(destination: AlternativeUIView()) { Text("Appearance") }
            NavigationLink(destination: ScheduleSettingsView()) { Text("Schedule") }
            NavigationLink(destination: CatalogsSettingsView()) { Text("Catalogs") }
            NavigationLink(destination: ServicesView()) { Text("Services") }
            if Bundle.main.allowsNuvioPlugins {
                NavigationLink(destination: NuvioPluginsView()) { Text("Plugins") }
            }
            NavigationLink(destination: TrackersSettingsView()) { Text("Trackers") }
        }

        Section {
            NavigationLink(destination: StorageView()) { Text("Storage") }
#if os(iOS)
            if ExperimentalFeatureState.isEnabledAtLaunch {
                NavigationLink(destination: ExperimentalCloudSyncView()) { Text("iCloud Sync") }
            }
#endif
            NavigationLink(destination: BackupManagementView()) { Text("Backup & Restore") }
            NavigationLink(destination: LoggerView()) { Text("Logger") }
        } header: {
            Text("Data")
        }

        if supportsGitHubReleaseUpdates {
            Section {
                Toggle("Auto-check GitHub Releases", isOn: $autoCheckGitHubReleases)

                Button(isCheckingGitHubRelease ? "Checking..." : "Check for Updates") {
                    performManualGitHubReleaseCheck()
                }
                .disabled(isCheckingGitHubRelease)

                if githubReleaseUpdateAvailable,
                   let releaseURL = URL(string: githubReleaseURL),
                   !githubReleaseURL.isEmpty {
                    Link("Open Latest Release (\(githubReleaseLatestVersion.isEmpty ? "Update Available" : githubReleaseLatestVersion))", destination: releaseURL)
                }
            } header: {
                Text("App Updates")
            }
        }

        Section {
            Text("Switch to Reader Mode")
                .onTapGesture { showKanzen = true }

            NavigationLink(destination: LegalNoticeView(
                sourceCodeURL: sourceCodeURL,
                originalProjectURL: originalProjectURL,
                licenseURL: licenseURL,
                privacyPolicyURL: privacyPolicyURL
            )) {
                Text("Legal & Source")
            }
        } header: {
            Text("Others")
        }
    }

    private func performManualGitHubReleaseCheck() {
        guard supportsGitHubReleaseUpdates, !isCheckingGitHubRelease else { return }
        Task {
            await MainActor.run {
                isCheckingGitHubRelease = true
            }
            await GitHubReleaseChecker.checkForUpdates(force: true)
            await MainActor.run {
                isCheckingGitHubRelease = false
            }
        }
    }
}

#if canImport(StoreKit)
private enum SupportProductKind {
    case tip
    case subscription
}

private struct SupportProductDefinition {
    let id: String
    let fallbackName: String
    let fallbackDescription: String
    let icon: String
    let color: Color
    let kind: SupportProductKind

    var isConfigured: Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private enum SupportPurchaseCatalog {
    static let definitions: [SupportProductDefinition] = [
        SupportProductDefinition(
            id: "idkbruh",
            fallbackName: "Tip",
            fallbackDescription: "One-time tip. Unlocks nothing.",
            icon: "heart.fill",
            color: .pink,
            kind: .tip
        ),
        SupportProductDefinition(
            id: "idkbruh2",
            fallbackName: "Bigger Tip",
            fallbackDescription: "One-time tip. Unlocks nothing.",
            icon: "heart.circle.fill",
            color: .purple,
            kind: .tip
        ),
        SupportProductDefinition(
            id: "idkbruh3",
            fallbackName: "Huge Tip",
            fallbackDescription: "One-time tip. Unlocks nothing.",
            icon: "sparkles",
            color: .orange,
            kind: .tip
        ),
        SupportProductDefinition(
            id: "idkbruh4",
            fallbackName: "Monthly Support",
            fallbackDescription: "Optional recurring support. Unlocks nothing.",
            icon: "arrow.triangle.2.circlepath.circle.fill",
            color: .cyan,
            kind: .subscription
        )
    ]

    static var productIDs: [String] {
        definitions
            .map(\.id)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static var configuredProductCount: Int {
        productIDs.count
    }

    static func definition(for productID: String) -> SupportProductDefinition? {
        definitions.first { $0.id == productID }
    }

    static func order(for productID: String) -> Int {
        definitions.firstIndex { $0.id == productID } ?? Int.max
    }
}

@MainActor
private final class SupportPurchaseStore: ObservableObject {
    @Published private(set) var products: [Product] = []
    @Published private(set) var isLoading = false
    @Published private(set) var purchasingProductID: String?
    @Published private(set) var message: String?

    var hasConfiguredProducts: Bool {
        SupportPurchaseCatalog.configuredProductCount > 0
    }

    func loadProducts() async {
        guard !isLoading, hasConfiguredProducts else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let loadedProducts = try await Product.products(for: SupportPurchaseCatalog.productIDs)
            products = loadedProducts.sorted {
                SupportPurchaseCatalog.order(for: $0.id) < SupportPurchaseCatalog.order(for: $1.id)
            }
            if products.isEmpty {
                message = "Support purchases are not available yet."
            }
        } catch {
            message = "Unable to load support purchases."
        }
    }

    func purchase(_ product: Product) async {
        purchasingProductID = product.id
        message = nil
        defer { purchasingProductID = nil }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try verifiedTransaction(from: verification)
                await transaction.finish()
                message = "Thanks for supporting Eclipse."
            case .pending:
                message = "Purchase pending approval."
            case .userCancelled:
                message = nil
            @unknown default:
                message = "Purchase could not be completed."
            }
        } catch {
            message = "Purchase could not be completed."
        }
    }

    func restorePurchases() async {
        message = nil
        do {
            try await AppStore.sync()
            message = "Purchases restored."
        } catch {
            message = "Restore could not be completed."
        }
    }

    private func verifiedTransaction(
        from result: VerificationResult<StoreKit.Transaction>
    ) throws -> StoreKit.Transaction {
        switch result {
        case .verified(let transaction):
            return transaction
        case .unverified(_, _):
            throw SupportPurchaseError.unverifiedTransaction
        }
    }
}

private enum SupportPurchaseError: Error {
    case unverifiedTransaction
}

private struct StoreKitSupportView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                GlassSection(header: "Support") {
                    StoreKitSupportSection()
                }

                GlassSectionFooter("Tips and subscriptions are optional App Store purchases. They help support development and do not unlock features.")
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("Support Eclipse")
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
    }
}

private struct StoreKitSupportSection: View {
    @StateObject private var store = SupportPurchaseStore()

    var body: some View {
        VStack(spacing: 0) {
            Text("Tips are optional App Store purchases. They help support development and do not unlock features.")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            GlassDivider(leadingInset: 14)

            if !store.hasConfiguredProducts {
                SupportPurchaseStatusRow(
                    icon: "exclamationmark.triangle.fill",
                    color: .orange,
                    title: "Tips Unavailable",
                    subtitle: "Product IDs need to be configured."
                )
            } else if store.isLoading && store.products.isEmpty {
                SupportPurchaseStatusRow(
                    icon: "hourglass",
                    color: .blue,
                    title: "Loading Tips",
                    subtitle: "Checking App Store availability."
                )
            } else if store.products.isEmpty {
                SupportPurchaseStatusRow(
                    icon: "cart.badge.questionmark",
                    color: .orange,
                    title: "Tips Unavailable",
                    subtitle: "Please try again later."
                )
            } else {
                ForEach(Array(store.products.enumerated()), id: \.element.id) { index, product in
                    StoreKitSupportButton(product: product, store: store)

                    if index < store.products.count - 1 {
                        GlassDivider()
                    }
                }

                GlassDivider()

                Button {
                    Task { await store.restorePurchases() }
                } label: {
                    GlassSettingsRow(icon: "arrow.clockwise.circle.fill", iconColor: .green, title: "Restore Purchases") {
                        Text("Optional")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                .buttonStyle(.plain)
            }

            if let message = store.message, !message.isEmpty {
                GlassDivider(leadingInset: 14)
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.56))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
        .task {
            await store.loadProducts()
        }
    }
}

private struct StoreKitSupportButton: View {
    let product: Product
    @ObservedObject var store: SupportPurchaseStore

    private var definition: SupportProductDefinition? {
        SupportPurchaseCatalog.definition(for: product.id)
    }

    private var isPurchasing: Bool {
        store.purchasingProductID == product.id
    }

    var body: some View {
        Button {
            Task { await store.purchase(product) }
        } label: {
            GlassSettingsRow(
                icon: definition?.icon ?? "heart.fill",
                iconColor: definition?.color ?? .pink,
                title: product.displayName.isEmpty ? (definition?.fallbackName ?? "Tip") : product.displayName
            ) {
                HStack(spacing: 6) {
                    if isPurchasing {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Text(isPurchasing ? "Purchasing" : product.displayPrice)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.5))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isPurchasing || store.purchasingProductID != nil)
    }
}

private struct SupportPurchaseStatusRow: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String

    var body: some View {
        GlassSettingsRow(icon: icon, iconColor: color, title: title) {
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.5))
        }
    }
}

#endif

struct ScheduleSettingsView: View {
    @AppStorage("defaultScheduleMode") private var defaultScheduleModeRaw = ScheduleMode.anime.rawValue
    @StateObject private var accentColorManager = AccentColorManager.shared

    private var selectedMode: ScheduleMode {
        ScheduleMode.sanitized(defaultScheduleModeRaw)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                GlassSection(header: "Schedule Tab") {
                    VStack(spacing: 0) {
                        ForEach(Array(ScheduleMode.allCases.enumerated()), id: \.element.id) { index, mode in
                            GlassSelectionRow(
                                title: mode.displayName,
                                subtitle: mode.description,
                                isSelected: selectedMode == mode,
                                accent: accentColorManager.currentAccentColor
                            ) {
                                defaultScheduleModeRaw = mode.rawValue
                            }

                            if index < ScheduleMode.allCases.count - 1 {
                                GlassDivider(leadingInset: 16)
                            }
                        }
                    }
                }

                GlassSectionFooter("Choose which schedule opens first when you select the Schedule tab. You can still switch modes inside the tab.")
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("Schedule")
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
    }
}

struct LegalNoticeView: View {
    let sourceCodeURL: URL
    let originalProjectURL: URL
    let licenseURL: URL
    let privacyPolicyURL: URL

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                GlassSection(header: "License") {
                    VStack(spacing: 0) {
                        infoText("Eclipse is released under the GNU General Public License version 3.")
                        GlassDivider(leadingInset: 16)
                        linkRow(title: "View GPLv3 License", icon: "doc.plaintext.fill", color: .blue, url: licenseURL)
                    }
                }

                GlassSection(header: "Privacy") {
                    VStack(spacing: 0) {
                        infoText("Eclipse's privacy policy explains what data the app stores locally and how optional third-party services are handled.")
                        GlassDivider(leadingInset: 16)
                        linkRow(title: "Privacy Policy", icon: "hand.raised.fill", color: .teal, url: privacyPolicyURL)
                    }
                }

                GlassSection(header: "Source") {
                    VStack(spacing: 0) {
                        infoText("Eclipse is a GPL-licensed media app with substantial original changes by Soupy-dev.")
                        GlassDivider(leadingInset: 16)
                        linkRow(title: "Eclipse Source Code", icon: "chevron.left.forwardslash.chevron.right", color: .cyan, url: sourceCodeURL)
                        GlassDivider()
                        linkRow(title: "Original Upstream Project", icon: "arrow.up.right.square.fill", color: .indigo, url: originalProjectURL)
                    }
                }

                GlassSection(header: "Credits") {
                    VStack(spacing: 0) {
                        infoText("Reader mode includes Aidoku source compatibility work inspired by the Aidoku project.")
                        GlassDivider(leadingInset: 16)
                        linkRow(title: "Aidoku/Aidoku", icon: "book.fill", color: .orange, url: URL(string: "https://github.com/Aidoku/Aidoku")!)
                    }
                }

                GlassSection(header: "Warranty") {
                    infoText("This program comes with no warranty, to the extent permitted by law.")
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("Legal & Source")
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
    }

    private func infoText(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundColor(.white.opacity(0.7))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }

    private func linkRow(title: String, icon: String, color: Color, url: URL) -> some View {
        Link(destination: url) {
            GlassDetailRow(icon: icon, iconColor: color, title: title) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
        .buttonStyle(.plain)
    }
}

struct PerformanceModeSettingsView: View {
    @ObservedObject private var catalogManager = CatalogManager.shared
    @AppStorage(PerformanceModeSettings.skipAniListTraversalForAnimeDetailsKey) private var skipAniListTraversalForAnimeDetails = false
    @StateObject private var accentColorManager = AccentColorManager.shared

    private var accent: Color { accentColorManager.currentAccentColor }

    private var performanceModeBinding: Binding<Bool> {
        Binding(
            get: { catalogManager.performanceModeEnabled },
            set: { catalogManager.setPerformanceModeEnabled($0) }
        )
    }

    private var animeCatalogs: [Catalog] {
        catalogManager.catalogs.filter { PerformanceModeSettings.isAnimeCatalog($0) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                GlassSection {
                    GlassDetailRow(icon: "bolt.fill", iconColor: .yellow, title: "Performance Mode") {
                        Toggle("", isOn: performanceModeBinding)
                            .labelsHidden()
                            .tint(accent)
                    }
                }
                GlassSectionFooter("Performance Mode keeps anime-heavy home catalogs on the faster AniList-backed path and locks those anime catalog rows to their performance-safe source. Detail pages still load full metadata when opened.")

                GlassSection {
                    GlassDetailRow(icon: "hare.fill", iconColor: .orange, title: "Skip AniList Traversal for Anime Details") {
                        Toggle("", isOn: $skipAniListTraversalForAnimeDetails)
                            .labelsHidden()
                            .tint(accent)
                    }
                }
                GlassSectionFooter("Some anime services, season mappings, specials, OVAs, and tracker matching may be less accurate or unavailable.")

                if !animeCatalogs.isEmpty {
                    GlassSection(header: "Affected Catalogs") {
                        VStack(spacing: 0) {
                            ForEach(Array(animeCatalogs.enumerated()), id: \.element.id) { index, catalog in
                                GlassDetailRow(icon: "bolt.fill", iconColor: .yellow, title: catalog.name) {
                                    Text(catalogManager.isCatalogEffectivelyEnabled(catalog) ? "Enabled" : "Hidden")
                                        .font(.caption)
                                        .foregroundColor(.white.opacity(0.5))
                                }

                                if index < animeCatalogs.count - 1 {
                                    GlassDivider()
                                }
                            }
                        }
                    }
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("Performance Mode")
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
    }
}

struct ExperimentalCloudSyncView: View {
    @AppStorage(ExperimentalFeatureState.iCloudSyncEnabledKey) private var iCloudSyncEnabled = false
    @StateObject private var cloudSyncManager = ExperimentalCloudSyncManager.shared
    @StateObject private var accentColorManager = AccentColorManager.shared

    private var availability: ExperimentalCloudSyncAvailability {
        ExperimentalCloudSyncAvailability.current
    }

    private var accent: Color { accentColorManager.currentAccentColor }

    private var includedData: [(String, String)] {
        [
            ("Settings", "gearshape"),
            ("Libraries and collections", "books.vertical"),
            ("Watch and read progress", "play.rectangle"),
            (Bundle.main.allowsNuvioPlugins ? "Catalogs, services, addons, and plugins" : "Catalogs, services, and addons", "server.rack"),
            ("Tracker connections and preferences", "chart.bar")
        ]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                GlassSection {
                    HStack(spacing: 14) {
                        Image(systemName: availability.isAvailable ? "checkmark.circle.fill" : "slash.circle")
                            .font(.title2)
                            .foregroundColor(availability.isAvailable ? .green : .orange)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(availability.statusTitle)
                                .font(.headline)
                                .foregroundColor(.white)
                            Text(availability.statusMessage)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.55))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }

                GlassSection(header: "Experimental") {
                    VStack(spacing: 0) {
                        GlassDetailRow(icon: "icloud.fill", iconColor: .blue, title: "Sync with iCloud") {
                            Toggle("", isOn: $iCloudSyncEnabled)
                                .labelsHidden()
                                .tint(accent)
                                .disabled(!availability.isAvailable)
                        }

                        GlassDivider()

                        Button {
                            cloudSyncManager.syncSnapshot(reason: "manual")
                        } label: {
                            GlassDetailRow(icon: "icloud.and.arrow.up", iconColor: .cyan, title: "Sync Now") {
                                if cloudSyncManager.isSyncing {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .tint(.white.opacity(0.6))
                                } else {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.3))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!availability.isAvailable || !iCloudSyncEnabled || cloudSyncManager.isSyncing)

                        GlassDivider()

                        Button {
                            cloudSyncManager.restoreRemoteSnapshot()
                        } label: {
                            GlassDetailRow(icon: "icloud.and.arrow.down", iconColor: .indigo, title: "Restore from iCloud") {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.3))
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!availability.isAvailable || !iCloudSyncEnabled || cloudSyncManager.isSyncing)

                        if !cloudSyncManager.lastStatusMessage.isEmpty {
                            GlassDivider(leadingInset: 16)
                            Text(cloudSyncManager.lastStatusMessage)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.55))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                        }
                    }
                }

                if availability.isAvailable {
                    GlassSectionFooter("Downloaded media, preload caches, images, logs, temporary files, and unsafe source secrets are excluded.")
                } else {
                    GlassSectionFooter("This build will keep settings, libraries, progress, and source definitions local.")
                }

                GlassSection(header: "Included Data") {
                    VStack(spacing: 0) {
                        ForEach(Array(includedData.enumerated()), id: \.offset) { index, item in
                            GlassDetailRow(icon: item.1, iconColor: .blue, title: item.0) {
                                EmptyView()
                            }

                            if index < includedData.count - 1 {
                                GlassDivider()
                            }
                        }
                    }
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("iCloud Sync")
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
        .onAppear {
            if !availability.isAvailable, iCloudSyncEnabled {
                iCloudSyncEnabled = false
            }
        }
        .onChange(of: iCloudSyncEnabled) { enabled in
            if enabled {
                cloudSyncManager.syncSnapshot(reason: "enabled")
            }
        }
    }
}

struct LanguageSelectionView: View {
    @StateObject private var accentColorManager = AccentColorManager.shared
    @Binding var selectedLanguage: String
    let languages: [(String, String)]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                GlassSection {
                    VStack(spacing: 0) {
                        ForEach(Array(languages.enumerated()), id: \.element.0) { index, language in
                            Button {
                                selectedLanguage = language.0
                            } label: {
                                HStack {
                                    Text(language.1)
                                        .foregroundColor(.white)
                                    Spacer()
                                    if selectedLanguage == language.0 {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(accentColorManager.currentAccentColor)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 13)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if index < languages.count - 1 {
                                Rectangle()
                                    .fill(EclipseTheme.shared.separatorColor)
                                    .frame(height: 0.5)
                                    .padding(.leading, 16)
                            }
                        }
                    }
                }
            }
            .padding(.top, 16)
            .background(EclipseScrollTracker())
        }
        .navigationTitle("Language")
        .eclipseGradientBackground()
        .eclipseDarkToolbar()
    }
}
