//
//  TrackersSettingsView.swift
//  Eclipse
//
//  Created by Soupy-dev
//

import SwiftUI
import Foundation
import Kingfisher

struct TrackersSettingsView: View {
    @StateObject private var trackerManager = TrackerManager.shared
    @StateObject private var catalogManager = CatalogManager.shared
    @StateObject private var profileManager = ProfileManager.shared
    @StateObject private var accentColorManager = AccentColorManager.shared

    @State private var showImportConfirmation = false
    @State private var showMALImportConfirmation = false
    @State private var showTraktImportConfirmation = false
    @State private var showSyncTools = false
    @State private var showTVSignInHelp = false

    private var accent: Color { accentColorManager.currentAccentColor }

    private var isAdministrable: Bool {
        profileManager.activeProfile?.isKidsProfile != true
    }

    private func account(for service: TrackerService) -> TrackerAccount? {
        trackerManager.trackerState.getAccount(for: service)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if let error = trackerManager.authError {
                    noticeSection(
                        icon: "exclamationmark.triangle.fill",
                        color: .orange,
                        title: "Tracker Sign-In Problem",
                        message: error
                    )
                }

                if !isAdministrable {
                    noticeSection(
                        icon: "person.2.fill",
                        color: .mint,
                        title: "Kids Profile",
                        message: "This profile cannot connect or disconnect trackers or run sync tools. Switch to a grown-up profile to make those changes."
                    )
                }

                syncSection
                accountsSection

                if account(for: .anilist) != nil {
                    aniListSection
                }

                if account(for: .myAnimeList) != nil {
                    malSection
                }

                if account(for: .trakt) != nil {
                    traktSection
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
            .frame(maxWidth: isIPad ? 700 : .infinity)
            .frame(maxWidth: .infinity)
        }
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipsePageTitle("Trackers")
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .eclipseDarkToolbar()
        .alert("Import AniList Library", isPresented: $showImportConfirmation) {
            Button("Import", role: .none) {
                trackerManager.importAniListToLibrary()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(aniListImportConfirmationMessage)
        }
        .alert("Import MAL Library", isPresented: $showMALImportConfirmation) {
            Button("Import", role: .none) {
                trackerManager.importMALToLibrary()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(malImportConfirmationMessage)
        }
        .alert("Import Trakt Library", isPresented: $showTraktImportConfirmation) {
            Button("Import", role: .none) {
                trackerManager.importTraktToLibrary()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will import your Trakt watchlist and watched progress as Eclipse collections without deleting or downgrading anything.")
        }
        .sheet(isPresented: $showSyncTools) {
            TrackerSyncToolsSheet(trackerManager: trackerManager)
        }
#if os(tvOS)
        .alert("Connect on iPhone or iPad", isPresented: $showTVSignInHelp) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Nearby-device sign-in requires a physical Apple TV. \(TrackerManager.tvTrackerSyncInstructions)")
        }
#endif
    }

    private var syncSection: some View {
        VStack(spacing: 8) {
            GlassSection(header: "Sync") {
                VStack(spacing: 0) {
                    GlassDetailRow(
                        icon: "arrow.triangle.2.circlepath",
                        iconColor: .blue,
                        title: "Media Sync",
                        subtitle: isTvOS
                            ? "Keep watched progress in step with every connected account."
                            : "Keep watch and read progress in step with every connected account."
                    ) {
                        Toggle("", isOn: Binding(
                            get: { trackerManager.trackerState.syncEnabled },
                            set: { trackerManager.setSyncEnabled($0) }
                        ))
                        .labelsHidden()
                        .accessibilityLabel("Media Sync")
                        .tint(accent)
                    }

                    GlassDivider(leadingInset: 16)

                    GlassDetailRow(
                        icon: "star.fill",
                        iconColor: .yellow,
                        title: "Auto Sync Ratings",
                        subtitle: "Send the ratings you give in Eclipse to your connected accounts."
                    ) {
                        Toggle("", isOn: Binding(
                            get: { trackerManager.trackerState.autoSyncRatings },
                            set: { trackerManager.setAutoSyncRatings($0) }
                        ))
                        .labelsHidden()
                        .accessibilityLabel("Auto Sync Ratings")
                        .tint(accent)
                    }

                    if isAdministrable {
                        GlassDivider(leadingInset: 16)

                        Button(action: presentSyncTools) {
                            GlassDetailRow(
                                icon: "slider.horizontal.3",
                                iconColor: .purple,
                                title: "Sync Tools",
                                subtitle: "Preview imports, pushes, and AniList/MAL ports before running them."
                            ) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(isTvOS ? Color.secondary : Color.white.opacity(0.3))
                            }
                        }
#if os(tvOS)
                        .buttonStyle(TVGlassRowButtonStyle())
#else
                        .buttonStyle(.plain)
#endif
                    }
                }
            }

            GlassSectionFooter("Sync never deletes entries or downgrades progress. Sync Tools always shows a preview before it writes anything.")
        }
    }

    private var accountsSection: some View {
        VStack(spacing: 8) {
            GlassSection(header: "Accounts") {
                VStack(spacing: 0) {
                    trackerRow(
                        service: .anilist,
                        onConnect: { trackerManager.startAniListAuth() },
                        onDisconnect: { trackerManager.disconnectTracker(.anilist) }
                    )

                    GlassDivider(leadingInset: 16)

                    trackerRow(
                        service: .myAnimeList,
                        onConnect: { trackerManager.startMALAuth() },
                        onDisconnect: { trackerManager.disconnectTracker(.myAnimeList) }
                    )

                    GlassDivider(leadingInset: 16)

                    trackerRow(
                        service: .trakt,
                        onConnect: { trackerManager.startTraktAuth() },
                        onDisconnect: { trackerManager.disconnectTracker(.trakt) }
                    )
                }
            }

            GlassSectionFooter("Connecting an account lets Eclipse read your lists and send progress back. Disconnecting leaves your Eclipse library untouched.")
#if os(tvOS)
            GlassSectionFooter("AniList and MyAnimeList use a nearby iPhone or iPad to sign in on a physical Apple TV. Trakt can connect using a code on any phone or computer.")
#endif
        }
    }



    private var aniListSection: some View {
        VStack(spacing: 8) {
            GlassSection(header: "AniList") {
                importRow(
                    title: "Import Library",
                    subtitle: "Bring your Watching, Planning, and Completed lists in as collections.",
                    isImporting: trackerManager.isImportingAniList,
                    progress: trackerManager.aniListImportProgress,
                    error: trackerManager.aniListImportError,
                    action: { showImportConfirmation = true }
                )
            }
        }
    }

    private var malSection: some View {
        VStack(spacing: 8) {
            GlassSection(header: "MyAnimeList") {
                importRow(
                    title: "Import Library",
                    subtitle: malImportDescription,
                    isImporting: trackerManager.isImportingMAL,
                    progress: trackerManager.malImportProgress,
                    error: trackerManager.malImportError,
                    action: { showMALImportConfirmation = true }
                )
            }
        }
    }

    private var traktSection: some View {
        VStack(spacing: 8) {
            GlassSection(header: "Trakt") {
                VStack(spacing: 0) {
                    traktToggleRow(
                        icon: "dot.radiowaves.left.and.right",
                        iconColor: .red,
                        title: "Live Scrobbling",
                        subtitle: "Tell Trakt what you are watching while you watch it.",
                        isOn: Binding(
                            get: { trackerManager.trackerState.liveTraktScrobbling },
                            set: { trackerManager.setLiveTraktScrobbling($0) }
                        )
                    )

                    GlassDivider(leadingInset: 16)

                    traktToggleRow(
                        icon: "number",
                        iconColor: .teal,
                        title: "Anime Episode Mapping",
                        subtitle: "When seasons don't line up, match anime episodes to Trakt using absolute numbering so scrobbles still land.",
                        isOn: Binding(
                            get: { trackerManager.trackerState.traktAnimeEpisodeMapping },
                            set: { trackerManager.setTraktAnimeEpisodeMapping($0) }
                        )
                    )

                    GlassDivider(leadingInset: 16)

                    traktToggleRow(
                        icon: "bubble.left.and.bubble.right.fill",
                        iconColor: .orange,
                        title: "Detail Reviews",
                        subtitle: "Show non-spoiler Trakt comments and reviews on media detail pages.",
                        isOn: Binding(
                            get: { trackerManager.trackerState.traktCommentsEnabled },
                            set: { trackerManager.setTraktCommentsEnabled($0) }
                        )
                    )

                    GlassDivider(leadingInset: 16)

                    traktToggleRow(
                        icon: "bookmark.fill",
                        iconColor: .pink,
                        title: "Sync Watchlist",
                        subtitle: "Mirror the \u{201C}Trakt Watchlist\u{201D} collection with your Trakt watchlist. Adds you make sync both ways; pulled items are only ever added, never deleted.",
                        isOn: Binding(
                            get: { trackerManager.trackerState.traktWatchlistSync },
                            set: { trackerManager.setTraktWatchlistSync($0) }
                        )
                    )

                    GlassDivider(leadingInset: 16)

                    traktToggleRow(
                        icon: "rectangle.stack.fill",
                        iconColor: .indigo,
                        title: "Public List Catalogs",
                        subtitle: "Add Trakt public lists to the Home catalog system.",
                        isOn: Binding(
                            get: { trackerManager.trackerState.traktPublicCatalogsEnabled },
                            set: { trackerManager.setTraktPublicCatalogsEnabled($0) }
                        )
                    )

                    if trackerManager.trackerState.traktPublicCatalogsEnabled {
                        GlassDivider(leadingInset: 16)

                        NavigationLink(destination: TraktPublicListCatalogsView(catalogManager: catalogManager)) {
                            GlassDetailRow(
                                icon: "list.bullet",
                                iconColor: .indigo,
                                title: "Public Lists",
                                subtitle: "Add, name, and sort the Trakt lists that appear in Catalogs."
                            ) {
                                HStack(spacing: 6) {
                                    Text("\(catalogManager.traktPublicListCatalogs.count)")
                                        .font(.subheadline)
                                        .foregroundColor(isTvOS ? Color.secondary : Color.white.opacity(0.5))

                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(isTvOS ? Color.secondary : Color.white.opacity(0.3))
                                }
                            }
                        }
#if os(tvOS)
                        .buttonStyle(TVGlassRowButtonStyle())
#else
                        .buttonStyle(.plain)
#endif
                    }

                    GlassDivider(leadingInset: 16)

                    importRow(
                        title: "Import Library",
                        subtitle: "Bring your watchlist and watched progress in as collections.",
                        isImporting: trackerManager.isImportingTrakt,
                        progress: trackerManager.traktImportProgress,
                        error: trackerManager.traktImportError,
                        action: { showTraktImportConfirmation = true }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func traktToggleRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        GlassDetailRow(icon: icon, iconColor: iconColor, title: title, subtitle: subtitle) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .accessibilityLabel(title)
                .tint(accent)
        }
    }

    @ViewBuilder
    private func importRow(
        title: String,
        subtitle: String,
        isImporting: Bool,
        progress: String?,
        error: String?,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassDetailRow(
                icon: "square.and.arrow.down",
                iconColor: .blue,
                title: title,
                subtitle: subtitle
            ) {
                if isImporting {
                    EclipseLoadingIndicator(tint: .white)
                } else {
                    Button(action: action) {
                        Text("Import")
#if os(tvOS)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .frame(minHeight: 54)
#else
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(accent.opacity(0.85)))
#endif
                    }
#if !os(tvOS)
                    .buttonStyle(.plain)
#endif
                }
            }

            if let progress {
                rowStatusText(progress, color: isTvOS ? Color.secondary : Color.white.opacity(0.5))
            }

            if let error {
                rowStatusText(error, color: .orange)
            }
        }
    }

    private func rowStatusText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
    }

    @ViewBuilder
    private func trackerRow(
        service: TrackerService,
        onConnect: @escaping () -> Void,
        onDisconnect: @escaping () -> Void
    ) -> some View {
        let account = account(for: service)

        HStack(spacing: 12) {
            trackerLogo(service)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(service.displayName)
                        .font(ExperimentalFeatureState.isEnabledAtLaunch ? .body.weight(.medium) : .body)
                        .foregroundColor(isTvOS ? Color.primary : Color.white)

                    if account != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: isTvOS ? 20 : 12, weight: .semibold))
                            .foregroundColor(.green)
                    }
                }

                Text(account?.username ?? "Not connected")
                    .font(.caption)
                    .foregroundColor(isTvOS ? Color.secondary : Color.white.opacity(0.5))
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if isAdministrable {
                if account != nil {
                    Button(action: { administer(onDisconnect) }) {
                        Text("Disconnect")
#if os(tvOS)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .frame(minHeight: 54)
#else
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.red)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.red.opacity(0.18)))
#endif
                    }
#if !os(tvOS)
                    .buttonStyle(.plain)
#else
                    .buttonStyle(TVGlassRowButtonStyle())
#endif
                } else {
                    Button(action: {
#if os(tvOS)
                        if service != .trakt && !TrackerManager.supportsNearbyDeviceSignIn {
                            showTVSignInHelp = true
                        } else {
                            administer(onConnect)
                        }
#else
                        administer(onConnect)
#endif
                    }) {
                        Text(trackerConnectTitle(service))
#if os(tvOS)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .frame(minHeight: 54)
#else
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(accent.opacity(0.85)))
#endif
                    }
#if !os(tvOS)
                    .buttonStyle(.plain)
#else
                    .buttonStyle(TVGlassRowButtonStyle())
                    .disabled(trackerManager.isAuthenticating)
#endif
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, isTvOS ? 14 : 12)
    }

    private func trackerConnectTitle(_ service: TrackerService) -> String {
#if os(tvOS)
        if service == .trakt { return "Connect with Code" }
        return TrackerManager.supportsNearbyDeviceSignIn ? "Use iPhone or iPad" : "How to Connect"
#else
        return "Connect"
#endif
    }

    @ViewBuilder
    private func trackerLogo(_ service: TrackerService) -> some View {
        let size: CGFloat = ExperimentalFeatureState.isEnabledAtLaunch ? 36 : 32

        if let logoURL = service.logoURL {
            KFImage(logoURL)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            GlassRowIcon(icon: "person.crop.circle", iconColor: .pink)
        }
    }

    private func noticeSection(icon: String, color: Color, title: String, message: String) -> some View {
        GlassSection {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: isTvOS ? 28 : 18, weight: .semibold))
                    .foregroundColor(color)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(isTvOS ? Color.primary : Color.white)

                    Text(message)
                        .font(.caption)
                        .foregroundColor(isTvOS ? Color.secondary : Color.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }

    private func administer(_ action: () -> Void) {
        guard isAdministrable else { return }
        action()
    }

    private func presentSyncTools() {
        guard isAdministrable else { return }
        showSyncTools = true
    }

    private var aniListImportConfirmationMessage: String {
#if os(tvOS)
        "This will import your AniList anime lists as Eclipse collections and fill local watched progress without deleting or downgrading anything."
#else
        "This will import your AniList lists as Eclipse collections and fill local watch/read progress without deleting or downgrading anything."
#endif
    }

    private var malImportConfirmationMessage: String {
#if os(tvOS)
        "This will import your MAL anime lists as Eclipse collections and fill local watched progress without deleting or downgrading anything."
#else
        "This will import your MAL lists as Eclipse collections and fill local watch/read progress without deleting or downgrading anything."
#endif
    }

    private var malImportDescription: String {
#if os(tvOS)
        "Bring your MAL anime lists in as collections and watched progress."
#else
        "Bring your MAL lists in as collections and reader progress."
#endif
    }
}

#if os(tvOS)
struct TVTraktSignInView: View {
    let presentation: TVTraktSignInPresentation
    @ObservedObject var trackerManager: TrackerManager

    var body: some View {
        VStack(spacing: 28) {
            Text("Connect Trakt")
                .font(.title2.bold())
            Text("On your phone or computer, visit")
                .foregroundStyle(.secondary)
            Text(presentation.verificationURL.absoluteString)
                .font(.title3.weight(.semibold))
            Text("Enter this code")
                .foregroundStyle(.secondary)
            Text(presentation.userCode)
                .font(.system(size: 54, weight: .semibold, design: .monospaced))
                .accessibilityLabel("Trakt sign-in code")
                .accessibilityValue(presentation.userCode)
            HStack(spacing: 12) {
                ProgressView()
                Text("Waiting for you to approve sign-in…")
                    .foregroundStyle(.secondary)
            }
            Button {
                trackerManager.cancelTVTrackerSignIn(authenticationID: presentation.id)
            } label: {
                Text("Cancel Sign-In")
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .frame(minHeight: 64)
            }
            .buttonStyle(TVGlassRowButtonStyle())
        }
        .padding(56)
        .frame(width: 1000, height: 700)
        .background(Color(red: 0.055, green: 0.06, blue: 0.075))
    }
}
#endif

private struct TraktPublicListCatalogsView: View {
    private struct TraktListSortOption: Identifiable {
        let id: String
        let name: String
    }

    private struct ParsedTraktList {
        let id: Int?
        let user: String?
        let slug: String?
    }

    @ObservedObject var catalogManager: CatalogManager
    @StateObject private var accentColorManager = AccentColorManager.shared

    @State private var traktListInput = ""
    @State private var traktListName = ""
    @State private var traktListMediaType = "shows"
    @State private var traktListSortBy = "rank"
    @State private var traktListSortHow = "asc"
    @State private var traktListError: String?

    private var accent: Color { accentColorManager.currentAccentColor }

    private let traktListSortOptions: [TraktListSortOption] = [
        TraktListSortOption(id: "rank", name: "List Rank"),
        TraktListSortOption(id: "added", name: "Recently Added"),
        TraktListSortOption(id: "title", name: "Title"),
        TraktListSortOption(id: "released", name: "Release Date"),
        TraktListSortOption(id: "popularity", name: "Popularity"),
        TraktListSortOption(id: "votes", name: "Votes")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                addListSection
                installedListsSection
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
            .frame(maxWidth: isIPad ? 700 : .infinity)
            .frame(maxWidth: .infinity)
        }
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipsePageTitle("Public Lists")
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .eclipseDarkToolbar()
    }

    private var addListSection: some View {
        VStack(spacing: 8) {
            GlassSection(header: "Add a List") {
                VStack(spacing: 0) {
                    listTextField("Trakt list URL or ID", text: $traktListInput)

                    GlassDivider(leadingInset: 16)

                    listTextField("Catalog name (optional)", text: $traktListName)

                    GlassDivider(leadingInset: 16)

                    GlassDetailRow(title: "Media Type") {
                        Picker("", selection: $traktListMediaType) {
                            Text("Shows").tag("shows")
                            Text("Movies").tag("movies")
                        }
                        .pickerStyle(.menu)
                        .tint(.white.opacity(0.7))
                    }

                    GlassDivider(leadingInset: 16)

                    GlassDetailRow(title: "Sort By") {
                        Picker("", selection: $traktListSortBy) {
                            ForEach(traktListSortOptions) { option in
                                Text(option.name).tag(option.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.white.opacity(0.7))
                    }

                    GlassDivider(leadingInset: 16)

                    GlassDetailRow(title: "Direction") {
                        Picker("", selection: $traktListSortHow) {
                            Text("Ascending").tag("asc")
                            Text("Descending").tag("desc")
                        }
                        .pickerStyle(.menu)
                        .tint(.white.opacity(0.7))
                    }

                    GlassDivider(leadingInset: 16)

                    Button(action: addTraktPublicCatalog) {
                        GlassDetailRow(
                            icon: "plus.circle.fill",
                            iconColor: .green,
                            title: "Add Catalog"
                        ) {
                            EmptyView()
                        }
                    }
#if os(tvOS)
                    .buttonStyle(TVGlassRowButtonStyle())
#else
                    .buttonStyle(.plain)
#endif
                    .disabled(traktListInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let traktListError {
                        Text(traktListError)
                            .font(.caption)
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 12)
                    }
                }
            }

            GlassSectionFooter("Paste a Trakt list URL, a username/list slug URL, or a numeric list ID. Added lists appear in Catalogs for ordering and per-row toggles.")
        }
    }

    @ViewBuilder
    private var installedListsSection: some View {
        if catalogManager.traktPublicListCatalogs.isEmpty {
            GlassSection(header: "Lists") {
                EclipseEmptyState(
                    icon: "rectangle.stack",
                    title: "No Public Lists",
                    message: "Lists you add show up here and on Home once Catalogs enables their row."
                )
            }
        } else {
            GlassSection(header: "Lists") {
                VStack(spacing: 0) {
                    ForEach(Array(catalogManager.traktPublicListCatalogs.enumerated()), id: \.element.id) { index, catalog in
                        if index > 0 {
                            GlassDivider(leadingInset: 16)
                        }

                        GlassDetailRow(
                            title: catalog.name,
                            subtitle: listSubtitle(for: catalog)
                        ) {
                            Button(role: .destructive) {
                                catalogManager.removeTraktPublicListCatalog(id: catalog.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.red)
                                    .frame(width: 32, height: 32)
                            }
#if os(tvOS)
                            .buttonStyle(.bordered)
#else
                            .buttonStyle(.plain)
#endif
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func listTextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
#if !os(tvOS)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .foregroundColor(.white)
            .tint(accent)
#endif
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
    }

    private func listSubtitle(for catalog: Catalog) -> String? {
        guard let listIdentifier = catalog.traktListDisplayIdentifier else { return nil }
        let mediaType = Catalog.normalizedTraktListMediaType(catalog.traktListMediaType) == "movies" ? "Movies" : "Shows"
        return "List \(listIdentifier) - \(mediaType)"
    }

    private func addTraktPublicCatalog() {
        guard let parsedList = parseTraktList(from: traktListInput) else {
            traktListError = "Enter a Trakt public list URL, username/list slug URL, or numeric list ID."
            return
        }

        catalogManager.addTraktPublicListCatalog(
            name: traktListName,
            listId: parsedList.id,
            listUser: parsedList.user,
            listSlug: parsedList.slug,
            mediaType: traktListMediaType,
            sortBy: traktListSortBy,
            sortHow: traktListSortHow
        )
        traktListInput = ""
        traktListName = ""
        traktListError = nil
    }

    private func parseTraktList(from input: String) -> ParsedTraktList? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let components = URLComponents(string: trimmed),
           let parsed = parseTraktUserSlugPath(components.path) {
            return parsed
        }

        if let parsed = parseTraktUserSlugPath(trimmed) {
            return parsed
        }

        let numericId = trimmed
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
            .last
        return numericId.map { ParsedTraktList(id: $0, user: nil, slug: nil) }
    }

    private func parseTraktUserSlugPath(_ path: String) -> ParsedTraktList? {
        let parts = path
            .split(separator: "/")
            .map(String.init)

        guard let usersIndex = parts.firstIndex(where: { $0.lowercased() == "users" }),
              usersIndex + 3 < parts.count,
              parts[usersIndex + 2].lowercased() == "lists" else {
            return nil
        }

        let user = parts[usersIndex + 1]
        let slug = parts[usersIndex + 3]
        guard !user.isEmpty, !slug.isEmpty else { return nil }
        return ParsedTraktList(id: nil, user: user, slug: slug)
    }
}

private struct TrackerSyncToolsSheet: View {
    @ObservedObject var trackerManager: TrackerManager
    @Environment(\.dismiss) private var dismiss
    @State private var confirmationAction: TrackerSyncToolAction?

    private var fillActions: [TrackerSyncToolAction] {
        TrackerSyncToolAction.allCases.filter { $0 == .fillEclipseFromAniList || $0 == .fillEclipseFromMAL }
    }

    private var pushActions: [TrackerSyncToolAction] {
        TrackerSyncToolAction.allCases.filter { $0 == .pushEclipseToAniList || $0 == .pushEclipseToMAL }
    }

    private var portActions: [TrackerSyncToolAction] {
        TrackerSyncToolAction.allCases.filter { $0.isProviderPort }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 22) {
                    if let status = trackerManager.syncToolStatus {
                        syncStatusSection(status)
                    }

                    actionSection(
                        header: "Fill Eclipse",
                        footer: "Reads from the tracker and fills local progress. Nothing is deleted or downgraded.",
                        actions: fillActions
                    )

                    actionSection(
                        header: "Push to Tracker",
                        footer: "Sends progress you already have in Eclipse up to the tracker.",
                        actions: pushActions
                    )

                    actionSection(
                        header: "Port Between Trackers",
                        footer: "Copies one tracker's progress into the other. These always ask for confirmation after the preview.",
                        actions: portActions
                    )

                    #if os(tvOS)
                    Button("Done") { dismiss() }
                        .buttonStyle(.bordered)
                        .disabled(trackerManager.syncToolIsLocked)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityIdentifier("tv.trackerSyncTools.done")
                    #endif
                }
                .padding(.top, 16)
                .padding(.bottom, 32)
                .frame(maxWidth: isIPad ? 700 : .infinity)
                .frame(maxWidth: .infinity)
            }
            .background(SettingsGradientBackground().ignoresSafeArea())
            .eclipsePageTitle("Sync Tools")
#if os(tvOS)
            .eclipseDarkToolbar()
#endif
            #if !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(trackerManager.syncToolIsLocked)
            .eclipseDarkToolbar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .disabled(trackerManager.syncToolIsLocked)
                }
            }
            #endif
            .alert("Run Sync Tool?", isPresented: Binding(
                get: { confirmationAction != nil },
                set: { if !$0 { confirmationAction = nil } }
            )) {
                Button("Run", role: .none) {
                    if let action = confirmationAction {
                        trackerManager.runSyncTool(action)
                    }
                    confirmationAction = nil
                }
                Button("Cancel", role: .cancel) {
                    confirmationAction = nil
                }
            } message: {
                Text("This writes progress to the selected destination but never deletes entries or downgrades progress.")
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    @ViewBuilder
    private func actionSection(header: String, footer: String, actions: [TrackerSyncToolAction]) -> some View {
        if !actions.isEmpty {
            VStack(spacing: 8) {
                GlassSection(header: header) {
                    VStack(spacing: 0) {
                        ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                            if index > 0 {
                                GlassDivider(leadingInset: 16)
                            }
                            syncToolRows(action)
                        }
                    }
                }

                GlassSectionFooter(footer)
            }
        }
    }

    private func syncStatusSection(_ status: String) -> some View {
        GlassSection(header: "Status") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if trackerManager.isRunningSyncTool {
                        EclipseLoadingIndicator(tint: .white)
                    }

                    Text(status)
                        .font(.caption)
                        .foregroundColor(isTvOS ? Color.secondary : Color.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)

                    if trackerManager.isRunningSyncTool {
                        Button(role: .destructive) {
                            trackerManager.cancelSyncTool()
                        } label: {
                            Label("Cancel", systemImage: "xmark.circle")
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                }

                if trackerManager.syncToolProgressTotal > 0 {
                    ProgressView(
                        value: Double(trackerManager.syncToolProgressCompleted),
                        total: Double(max(trackerManager.syncToolProgressTotal, 1))
                    )
                    .tint(.blue)

                    HStack {
                        Text("\(trackerManager.syncToolProgressCompleted) / \(trackerManager.syncToolProgressTotal)")
                        Spacer()
                        if trackerManager.syncToolIsLocked {
                            Text("Stay here while this large sync runs")
                        }
                    }
                    .font(.caption2)
                    .foregroundColor(isTvOS ? Color.secondary : Color.white.opacity(0.5))
                }

                if let detail = trackerManager.syncToolProgressDetail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundColor(isTvOS ? Color.secondary : Color.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
    }

    private func icon(for action: TrackerSyncToolAction) -> String {
        if action.isProviderPort {
            return "arrow.left.arrow.right"
        }
        return pushActions.contains(action) ? "tray.and.arrow.up.fill" : "tray.and.arrow.down.fill"
    }

    @ViewBuilder
    private func syncToolRows(_ action: TrackerSyncToolAction) -> some View {
        let preview = trackerManager.syncToolPreview?.action == action ? trackerManager.syncToolPreview : nil

        GlassDetailRow(
            icon: icon(for: action),
            iconColor: action.isProviderPort ? .orange : .blue,
            title: action.title,
            subtitle: action.subtitle
        ) {
            EmptyView()
        }

        if let preview {
            VStack(alignment: .leading, spacing: 6) {
                previewMetric("Add", preview.itemsToAdd)
                previewMetric("Advance", preview.itemsToAdvance)
                previewMetric("Skipped", preview.skipped)
                previewMetric("Unmapped", preview.unmapped)
                previewMetric("API calls", preview.estimatedAPICalls)

                if preview.estimatedAPICalls >= 90 {
                    Label("Large sync: Eclipse will show progress, honor rate limits, and keep this sheet open until it finishes or you cancel.", systemImage: "hourglass")
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(preview.notes, id: \.self) { note in
                    Text(note)
                        .font(.caption2)
                        .foregroundColor(isTvOS ? Color.secondary : Color.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.18))
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
        }

        HStack(spacing: 12) {
            Button("Preview") {
                trackerManager.previewSyncTool(action)
            }
            .disabled(trackerManager.isRunningSyncTool)

            Spacer(minLength: 0)

            Button(action.isProviderPort ? "Confirm & Run" : "Run") {
                if action.isProviderPort {
                    confirmationAction = action
                } else {
                    trackerManager.runSyncTool(action)
                }
            }
            .disabled(trackerManager.isRunningSyncTool || preview == nil)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func previewMetric(_ title: String, _ value: Int) -> some View {
        HStack {
            Text(title)
                .foregroundColor(isTvOS ? Color.secondary : Color.white.opacity(0.5))
            Spacer()
            Text("\(value)")
                .foregroundColor(isTvOS ? Color.primary : Color.white)
        }
        .font(.caption2)
    }
}
