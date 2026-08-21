//
//  KanzenAidokuMigrationPrompt.swift
//  Kanzen
//
//  Created by Eclipse on 2026.
//

import SwiftUI

#if !os(tvOS)
enum KanzenAidokuMigrationPromptRecord {
    static let storageBase = "kanzenReaderMigrationPromptOfferedV1"

    static func storageKey(for profileID: UUID) -> String {
        ProfileScopedStorage.defaultsKey(base: storageBase, profileID: profileID)
    }

    static func wasOffered(profileID: UUID, store: UserDefaults = .standard) -> Bool {
        store.bool(forKey: storageKey(for: profileID))
    }

    static func markOffered(profileID: UUID, store: UserDefaults = .standard) {
        store.set(true, forKey: storageKey(for: profileID))
    }

    static func clearOffer(profileID: UUID, store: UserDefaults = .standard) {
        store.removeObject(forKey: storageKey(for: profileID))
    }
}

enum KanzenAidokuLibraryStatus {
    static func legacySourceID(for item: MangaLibraryItem) -> String? {
        guard let route = item.route, case .aidoku(let sourceId, _) = route else { return nil }
        let trimmed = sourceId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func needsReconnecting(_ item: MangaLibraryItem) -> Bool {
        legacySourceID(for: item) != nil
    }

    /// A title the replacement source has already answered about cannot be
    /// reconnected by trying harder, so it must not carry the same actionable
    /// badge and context-menu entry as one that was never attempted.
    @MainActor
    static func isConfirmedAbsentOnReplacement(_ item: MangaLibraryItem) -> Bool {
        KanzenAidokuMigrationCoordinator.shared
            .mark(for: item)?
            .confirmedAbsentOnReplacement == true
    }

    @MainActor
    static func reconnectRequest(for item: MangaLibraryItem) -> KanzenAidokuReconnectRequest? {
        guard let sourceID = legacySourceID(for: item),
              !isConfirmedAbsentOnReplacement(item) else { return nil }
        return KanzenAidokuReconnectRequest(legacySourceID: sourceID, title: item.title)
    }
}

struct KanzenAidokuUnavailableBadge: View {
    var isConfirmedAbsent = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: isConfirmedAbsent ? "questionmark.circle.fill" : "link")
                .font(.system(size: 9, weight: .bold))
            Text(isConfirmedAbsent ? "Unavailable" : "Reconnect")
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(
                (isConfirmedAbsent ? Color.secondary : Color.orange).opacity(0.92)
            )
        )
        .padding(5)
        .accessibilityLabel(
            isConfirmedAbsent ? "Not on the replacement source" : "Needs a new source"
        )
    }
}

struct KanzenAidokuLibraryUnavailableView: View {
    let title: String
    let legacySourceID: String

    @ObservedObject private var contentFilter = ReaderContentFilter.shared

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "link")
                .font(.system(size: 40, weight: .regular))
                .foregroundColor(.orange)

            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)

            Text("This one came from an older source that Eclipse no longer uses, so it can't load chapters right now.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Text("It hasn't been deleted. Its cover, title and reading progress are all still saved.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if !contentFilter.isKidsProfileActive {
                NavigationLink(
                    destination: KanzenAidokuMigrationView(
                        focusedLegacySourceID: legacySourceID,
                        focusedTitle: title
                    )
                ) {
                    Label("Reconnect This", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct KanzenAidokuMigrationPromptView: View {
    let summary: KanzenAidokuMigrationSummary
    let onRemindLater: () -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 44, weight: .regular))
                        .foregroundColor(.orange)
                        .padding(.top, 20)

                    Text("Some saved manga needs a new source")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)

                    Text(KanzenAidokuMigrationCopy.headline(summary))
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.78))
                        .multilineTextAlignment(.center)

                    Text("They're all still here. They just can't load new chapters until they're pointed at a source you have installed.")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.62))
                        .multilineTextAlignment(.center)

                    Text(KanzenAidokuMigrationCopy.safetyLine)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                        .multilineTextAlignment(.center)

                    VStack(spacing: 12) {
                        NavigationLink(destination: KanzenAidokuMigrationView()) {
                            Text("See What's Affected")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Remind Me Later", action: onRemindLater)
                            .font(.subheadline.weight(.medium))

                        Button("Not Now", action: onClose)
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 34)
                .frame(maxWidth: isIPad ? 620 : .infinity)
                .frame(maxWidth: .infinity)
            }
            .background(GlobalGradientBackground().ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .eclipseDarkToolbar()
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close", action: onClose)
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .preferredColorScheme(.dark)
    }
}

struct KanzenAidokuMigrationPromptModifier: ViewModifier {
    @StateObject private var coordinator = KanzenAidokuMigrationCoordinator.shared
    @StateObject private var readerExtensionManager = ReaderExtensionManager.shared
    @State private var isPromptPresented = false
    @State private var evaluatedProfileID: UUID?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPromptPresented) {
                KanzenAidokuMigrationPromptView(
                    summary: coordinator.summary,
                    onRemindLater: {
                        remindLater()
                        isPromptPresented = false
                    },
                    onClose: { isPromptPresented = false }
                )
            }
            .task { await evaluate() }
            .onChange(of: installedSourceSignature) { _ in
                reevaluateAfterSourcesChanged()
            }
            .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in
                isPromptPresented = false
                evaluatedProfileID = nil
                Task { await evaluate() }
            }
    }

    private var installedSourceSignature: String {
        readerExtensionManager.installedSources
            .map { "\($0.id.rawValue):\($0.enabled ? 1 : 0)" }
            .sorted()
            .joined(separator: "|")
    }

    private func evaluate() async {
        let owner = ProfileManager.shared.activeProfileID
        guard evaluatedProfileID != owner else { return }
        evaluatedProfileID = owner
        guard !ProfileManager.shared.isKidsModeActive else { return }

        await coordinator.detectAtLaunchIfNeeded()
        guard coordinator.summary.hasLeftoverData else { return }
        await coordinator.markUnavailableEntries()

        guard !KanzenAidokuMigrationPromptRecord.wasOffered(profileID: owner),
              coordinator.shouldOfferMigrationPrompt,
              ProfileManager.shared.isStillActive(owner) else { return }

        try? await Task.sleep(nanoseconds: 900_000_000)
        guard ProfileManager.shared.isStillActive(owner),
              coordinator.shouldOfferMigrationPrompt else { return }

        KanzenAidokuMigrationPromptRecord.markOffered(profileID: owner)
        coordinator.dismissMigrationPrompt()
        isPromptPresented = true
    }

    private func reevaluateAfterSourcesChanged() {
        guard !ProfileManager.shared.isKidsModeActive else { return }
        guard coordinator.summary.hasLeftoverData || !coordinator.unavailableMarks.isEmpty else {
            return
        }
        Task {
            await coordinator.reevaluateAfterInstalledSourcesChanged(automaticallyReconnect: false)
        }
    }

    private func remindLater() {
        let owner = ProfileManager.shared.activeProfileID
        KanzenAidokuMigrationPromptRecord.clearOffer(profileID: owner)
        coordinator.restoreMigrationPrompt()
    }
}

extension View {
    func kanzenAidokuMigrationPrompt() -> some View {
        modifier(KanzenAidokuMigrationPromptModifier())
    }
}
#endif
