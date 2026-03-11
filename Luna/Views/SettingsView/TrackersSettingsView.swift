//
//  TrackersSettingsView.swift
//  Luna
//
//  Created by Soupy-dev
//

import SwiftUI

struct TrackersSettingsView: View {
    @StateObject private var trackerManager = TrackerManager.shared
    @State private var selectedTracker: TrackerService?
    @State private var showImportConfirmation = false

    var body: some View {
        ZStack {
            SettingsGradientBackground()
                .ignoresSafeArea()

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
            }
        }
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
            Text("This will import your AniList Watching, Planning, and Completed lists as collections in your library. Existing items won't be duplicated.")
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
            HStack {
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
