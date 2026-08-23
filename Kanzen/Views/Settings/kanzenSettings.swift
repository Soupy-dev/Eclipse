//
//  kanzenSettings.swift
//  Kanzen
//
//  Created by Dawud Osman on 16/05/2025.
//

import SwiftUI

#if !os(tvOS)
struct KanzenSettingsView: View {
    @EnvironmentObject var moduleManager: ModuleManager
    @ObservedObject private var contentFilter = ReaderContentFilter.shared
    @State private var autoUpdateModules = ModuleManager.isAutoUpdateEnabled

    private var isAdministrable: Bool { !contentFilter.isKidsProfileActive }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 28) {
                    KanzenRootHeader("Settings")

                    GlassSection(header: "Profiles") {
                        VStack(spacing: 0) {
                            NavigationLink(destination: ProfilesSettingsView()) {
                                GlassSettingsRow(icon: "person.2.fill", iconColor: .mint, title: "Profiles") {
                                    Text(ProfileManager.shared.activeProfile?.name ?? "1 profile")
                                        .font(.subheadline)
                                        .foregroundColor(.white.opacity(0.5))
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    GlassSection(header: "General") {
                        VStack(spacing: 0) {
                            NavigationLink(destination: KanzenGeneralSettingsView()) {
                                GlassSettingsRow(icon: "paintbrush.fill", iconColor: .purple, title: "Appearance")
                            }
                            .buttonStyle(.plain)

                            if isAdministrable {
                                GlassDivider()

                                NavigationLink(destination: ReaderExtensionsSettingsView()) {
                                    GlassSettingsRow(icon: "shippingbox.fill", iconColor: .orange, title: "Reader Sources")
                                }
                                .buttonStyle(.plain)

                                GlassDivider()

                                NavigationLink(destination: MangaCatalogSettingsView().environmentObject(moduleManager)) {
                                    GlassSettingsRow(icon: "slider.horizontal.3", iconColor: .green, title: "Home Sources")
                                }
                                .buttonStyle(.plain)

                                GlassDivider()

                                NavigationLink(destination: KanzenTrackerSettingsView()) {
                                    GlassSettingsRow(icon: "chart.bar.fill", iconColor: .pink, title: "Trackers")
                                }
                                .buttonStyle(.plain)

                                GlassDivider()

                                NavigationLink(destination: ReaderDownloadsSettingsView()) {
                                    GlassSettingsRow(icon: "arrow.down.circle.fill", iconColor: .blue, title: "Downloads")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if isAdministrable {
                        GlassSection(header: "Legacy JS Modules") {
                            VStack(spacing: 0) {
                                NavigationLink(destination: KanzenModuleView().environmentObject(moduleManager)) {
                                    GlassSettingsRow(icon: "puzzlepiece.extension.fill", iconColor: .cyan, title: "Manage Legacy Modules")
                                }
                                .buttonStyle(.plain)

                                GlassDivider()

                                GlassSettingsRow(icon: "arrow.triangle.2.circlepath", iconColor: .teal, title: "Auto-Update Legacy Modules") {
                                    Toggle("", isOn: $autoUpdateModules)
                                        .labelsHidden()
                                        .onChange(of: autoUpdateModules) { newValue in
                                            ModuleManager.isAutoUpdateEnabled = newValue
                                        }
                                }
                            }
                        }
                    }

                    GlassSection(header: "Activity") {
                        NavigationLink(destination: ReaderLoggerView()) {
                            GlassSettingsRow(icon: "doc.text.fill", iconColor: .yellow, title: "Reader Logs")
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .background(GlobalGradientBackground().ignoresSafeArea())
            .eclipseDarkToolbar()
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

private struct KanzenTrackerSettingsView: View {
    @StateObject private var trackerManager = TrackerManager.shared
    @ObservedObject private var contentFilter = ReaderContentFilter.shared
    @State private var showAniListImportConfirmation = false
    @State private var showMALImportConfirmation = false

    var body: some View {
        Group {
            if contentFilter.isKidsProfileActive {
                restrictedContent
            } else {
                trackerContent
            }
        }
        .preferredColorScheme(.dark)
    }

    private var restrictedContent: some View {
        ScrollView {
            VStack(spacing: 24) {
                KanzenRootHeader("Trackers")
                    .padding(.horizontal, -20)

                GlassSection(header: "Accounts") {
                    Text("This is a kids profile, so it cannot connect or disconnect trackers or import libraries. Switch to a grown-up profile to make those changes.")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.68))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
            .frame(maxWidth: isIPad ? 760 : .infinity)
            .frame(maxWidth: .infinity)
        }
        .background(GlobalGradientBackground().ignoresSafeArea())
        .navigationTitle("Trackers")
        .navigationBarTitleDisplayMode(.inline)
        .eclipseDarkToolbar()
    }

    private var trackerContent: some View {
        ScrollView {
            VStack(spacing: 24) {
                KanzenRootHeader("Trackers")
                    .padding(.horizontal, -20)

                GlassSection(header: "Reader Sync") {
                    VStack(spacing: 0) {
                        GlassSettingsRow(icon: "arrow.triangle.2.circlepath", iconColor: .blue, title: "Enable Reader Sync") {
                            Toggle("", isOn: Binding(
                                get: { trackerManager.trackerState.readerSyncEnabled },
                                set: { trackerManager.setReaderSyncEnabled($0) }
                            ))
                            .labelsHidden()
                        }

                        GlassDivider()

                        GlassSettingsRow(icon: "star.fill", iconColor: .yellow, title: "Auto Sync Reader Ratings") {
                            Toggle("", isOn: Binding(
                                get: { trackerManager.trackerState.autoSyncReaderRatings },
                                set: { trackerManager.setAutoSyncReaderRatings($0) }
                            ))
                            .labelsHidden()
                        }

                        Text("Reader sync is independent from Media mode. Automatic Reader rating sync only sends the score after a confident AniList/MAL manga match. Notes sync only when you tap a tracker button on a Reader detail page.")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.68))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    }
                }

                GlassSection(header: "Accounts") {
                    VStack(spacing: 0) {
                        trackerRow(
                            service: .anilist,
                            username: trackerManager.trackerState.getAccount(for: .anilist)?.username,
                            onConnect: {
                                guard !contentFilter.isKidsProfileActive else { return }
                                trackerManager.startAniListAuth()
                            },
                            onDisconnect: {
                                guard !contentFilter.isKidsProfileActive else { return }
                                trackerManager.disconnectTracker(.anilist)
                            }
                        )

                        if trackerManager.trackerState.getAccount(for: .anilist) != nil {
                            GlassDivider()
                            importRow(
                                title: "Import AniList Library",
                                subtitle: trackerManager.aniListImportProgress ?? trackerManager.aniListImportError ?? "Import manga lists and reader progress.",
                                isLoading: trackerManager.isImportingAniList,
                                action: { showAniListImportConfirmation = true }
                            )
                        }

                        GlassDivider()

                        trackerRow(
                            service: .myAnimeList,
                            username: trackerManager.trackerState.getAccount(for: .myAnimeList)?.username,
                            onConnect: {
                                guard !contentFilter.isKidsProfileActive else { return }
                                trackerManager.startMALAuth()
                            },
                            onDisconnect: {
                                guard !contentFilter.isKidsProfileActive else { return }
                                trackerManager.disconnectTracker(.myAnimeList)
                            }
                        )

                        if trackerManager.trackerState.getAccount(for: .myAnimeList) != nil {
                            GlassDivider()
                            importRow(
                                title: "Import MAL Library",
                                subtitle: trackerManager.malImportProgress ?? trackerManager.malImportError ?? "Import manga lists and reader progress.",
                                isLoading: trackerManager.isImportingMAL,
                                action: { showMALImportConfirmation = true }
                            )
                        }
                    }
                }

                if let error = trackerManager.authError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.leading)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12))
                        .cornerRadius(12)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
            .frame(maxWidth: isIPad ? 760 : .infinity)
            .frame(maxWidth: .infinity)
        }
        .background(GlobalGradientBackground().ignoresSafeArea())
        .navigationTitle("Trackers")
        .navigationBarTitleDisplayMode(.inline)
        .eclipseDarkToolbar()
        .alert("Import AniList Library", isPresented: $showAniListImportConfirmation) {
            Button("Import", role: .none) {
                guard !contentFilter.isKidsProfileActive else { return }
                trackerManager.importAniListToLibrary()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This imports AniList manga lists into Reader collections and progress without deleting or downgrading local entries.")
        }
        .alert("Import MAL Library", isPresented: $showMALImportConfirmation) {
            Button("Import", role: .none) {
                guard !contentFilter.isKidsProfileActive else { return }
                trackerManager.importMALToLibrary()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This imports MAL manga lists into Reader collections and progress without deleting or downgrading local entries.")
        }
    }

    @ViewBuilder
    private func trackerRow(
        service: TrackerService,
        username: String?,
        onConnect: @escaping () -> Void,
        onDisconnect: @escaping () -> Void
    ) -> some View {
        let isConnected = username != nil
        HStack(spacing: 12) {
            Image(systemName: service == .anilist ? "a.circle.fill" : "m.circle.fill")
                .font(.title2)
                .foregroundColor(service == .anilist ? .blue : .indigo)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(service.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.white)

                Text(username ?? "Not connected")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
            }

            Spacer()

            if isConnected {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Button("Disconnect", action: onDisconnect)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            } else {
                Button("Connect", action: onConnect)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.blue)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func importRow(title: String, subtitle: String, isLoading: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down")
                .foregroundColor(.teal)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(2)
            }

            Spacer()

            if isLoading {
                EclipseLoadingIndicator()
            } else {
                Button("Import", action: action)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.blue)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
#endif
