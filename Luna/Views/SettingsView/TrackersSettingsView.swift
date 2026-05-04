//
//  TrackersSettingsView.swift
//  Luna
//
//  Created by Soupy-dev
//

import SwiftUI
import Kingfisher

struct TrackersSettingsView: View {
    @StateObject private var trackerManager = TrackerManager.shared
    @State private var showImportConfirmation = false
    @State private var showMALImportConfirmation = false
    @State private var showSyncTools = false

    @State private var scrollOffset: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Trackers")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal)

                VStack(spacing: 12) {
                    // Sync Toggle
                    Toggle("Enable Sync", isOn: $trackerManager.trackerState.syncEnabled)
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(12)

                    Button(action: { showSyncTools = true }) {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundColor(.blue)
                                .frame(width: 32, height: 32)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Sync Tools")
                                    .font(.headline)
                                    .foregroundColor(.white)

                                Text("Preview imports, pushes, and AniList/MAL ports")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)

                    // AniList Section
                    trackerRow(
                        service: .anilist,
                        isConnected: trackerManager.trackerState.getAccount(for: .anilist) != nil,
                        username: trackerManager.trackerState.getAccount(for: .anilist)?.username,
                        onConnect: { trackerManager.startAniListAuth() },
                        onDisconnect: { trackerManager.disconnectTracker(.anilist) }
                    )

                    // AniList Import Section
                    if trackerManager.trackerState.getAccount(for: .anilist) != nil {
                        aniListImportSection
                    }

                    // MyAnimeList Section
                    trackerRow(
                        service: .myAnimeList,
                        isConnected: trackerManager.trackerState.getAccount(for: .myAnimeList) != nil,
                        username: trackerManager.trackerState.getAccount(for: .myAnimeList)?.username,
                        onConnect: { trackerManager.startMALAuth() },
                        onDisconnect: { trackerManager.disconnectTracker(.myAnimeList) }
                    )

                    if trackerManager.trackerState.getAccount(for: .myAnimeList) != nil {
                        malImportSection
                    }

                    // Trakt Section
                    trackerRow(
                        service: .trakt,
                        isConnected: trackerManager.trackerState.getAccount(for: .trakt) != nil,
                        username: trackerManager.trackerState.getAccount(for: .trakt)?.username,
                        onConnect: { trackerManager.startTraktAuth() },
                        onDisconnect: { trackerManager.disconnectTracker(.trakt) }
                    )
                }
                .padding(.horizontal)

                if let error = trackerManager.authError {
                    VStack {
                        HStack {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundColor(.orange)
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                    .padding()
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                    .padding(.horizontal)
                }

                Spacer()
            }
            .padding(.vertical)
            .frame(maxWidth: isIPad ? 700 : .infinity)
            .frame(maxWidth: .infinity)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ScrollOffsetPreferenceKey.self,
                        value: -geo.frame(in: .named("trackersScroll")).origin.y
                    )
                }
            )
        }
        .coordinateSpace(name: "trackersScroll")
        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { scrollOffset = $0 }
        .background(SettingsGradientBackground(scrollOffset: scrollOffset).ignoresSafeArea())
        .navigationTitle("Trackers")
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("Import AniList Library", isPresented: $showImportConfirmation) {
            Button("Import", role: .none) {
                trackerManager.importAniListToLibrary()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will import your AniList lists as Eclipse collections and fill local watch/read progress without deleting or downgrading anything.")
        }
        .alert("Import MAL Library", isPresented: $showMALImportConfirmation) {
            Button("Import", role: .none) {
                trackerManager.importMALToLibrary()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will import your MAL lists as Eclipse collections and fill local watch/read progress without deleting or downgrading anything.")
        }
        .sheet(isPresented: $showSyncTools) {
            TrackerSyncToolsSheet(trackerManager: trackerManager)
        }
    }

    // MARK: - AniList Import Section

    @ViewBuilder
    private var aniListImportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import AniList Library")
                        .font(.headline)
                        .foregroundColor(.white)

                    Text("Import your Watching, Planning, and Completed lists as collections")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if trackerManager.isImportingAniList {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                } else {
                    Button(action: { showImportConfirmation = true }) {
                        Text("Import")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.blue)
                            .cornerRadius(6)
                    }
                }
            }

            if let progress = trackerManager.aniListImportProgress {
                Text(progress)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if let error = trackerManager.aniListImportError {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }

    @ViewBuilder
    private func trackerRow(
        service: TrackerService,
        isConnected: Bool,
        username: String?,
        onConnect: @escaping () -> Void,
        onDisconnect: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if let logoURL = service.logoURL {
                    KFImage(logoURL)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 40, height: 40)
                        .cornerRadius(8)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(service.displayName)
                        .font(.headline)
                        .foregroundColor(.white)

                    if let username = username {
                        Text(username)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if isConnected {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)

                        Button(action: onDisconnect) {
                            Text("Disconnect")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                } else {
                    Button(action: onConnect) {
                        Text("Connect")
                            .font(.caption)
                            .foregroundColor(.blue)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.blue.opacity(0.2))
                            .cornerRadius(6)
                    }
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }
}

private struct TrackerSyncToolsSheet: View {
    @ObservedObject var trackerManager: TrackerManager
    @Environment(\.dismiss) private var dismiss
    @State private var confirmationAction: TrackerSyncToolAction?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let status = trackerManager.syncToolStatus {
                        HStack(spacing: 8) {
                            if trackerManager.isRunningSyncTool {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            }

                            Text(status)
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Spacer()
                        }
                        .padding()
                        .background(Color.gray.opacity(0.12))
                        .cornerRadius(12)
                    }

                    ForEach(TrackerSyncToolAction.allCases) { action in
                        syncToolCard(action)
                    }
                }
                .padding()
            }
            .background(SettingsGradientBackground(scrollOffset: 0).ignoresSafeArea())
            .navigationTitle("Sync Tools")
            #if !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
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
    }

    @ViewBuilder
    private func syncToolCard(_ action: TrackerSyncToolAction) -> some View {
        let preview = trackerManager.syncToolPreview?.action == action ? trackerManager.syncToolPreview : nil

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: action.isProviderPort ? "arrow.left.arrow.right.circle.fill" : "tray.and.arrow.down.fill")
                    .foregroundColor(action.isProviderPort ? .orange : .blue)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(action.title)
                        .font(.headline)
                        .foregroundColor(.white)

                    Text(action.subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }

            if let preview {
                VStack(alignment: .leading, spacing: 6) {
                    previewMetric("Add", preview.itemsToAdd)
                    previewMetric("Advance", preview.itemsToAdvance)
                    previewMetric("Skipped", preview.skipped)
                    previewMetric("Unmapped", preview.unmapped)
                    previewMetric("API calls", preview.estimatedAPICalls)

                    ForEach(preview.notes, id: \.self) { note in
                        Text(note)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(10)
                .background(Color.black.opacity(0.18))
                .cornerRadius(8)
            }

            HStack {
                Button("Preview") {
                    trackerManager.previewSyncTool(action)
                }
                .disabled(trackerManager.isRunningSyncTool)

                Spacer()

                Button(action.isProviderPort ? "Confirm & Run" : "Run") {
                    if action.isProviderPort {
                        confirmationAction = action
                    } else {
                        trackerManager.runSyncTool(action)
                    }
                }
                .disabled(trackerManager.isRunningSyncTool || preview == nil)
            }
            .font(.caption.weight(.medium))
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }

    @ViewBuilder
    private var malImportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import MAL Library")
                        .font(.headline)
                        .foregroundColor(.white)

                    Text("Import MAL lists as Eclipse collections and reader progress")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if trackerManager.isImportingMAL {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                } else {
                    Button(action: { showMALImportConfirmation = true }) {
                        Text("Import")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.blue)
                            .cornerRadius(6)
                    }
                }
            }

            if let progress = trackerManager.malImportProgress {
                Text(progress)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if let error = trackerManager.malImportError {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }

    @ViewBuilder
    private func previewMetric(_ title: String, _ value: Int) -> some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text("\(value)")
                .foregroundColor(.white)
        }
        .font(.caption2)
    }
}
