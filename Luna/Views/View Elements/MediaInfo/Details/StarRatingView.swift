//
//  StarRatingView.swift
//  Luna
//
//  Expandable 10-star rating and private notes control for media details.
//

import SwiftUI

struct StarRatingView: View {
    let mediaId: Int
    let isAnime: Bool

    @StateObject private var trackerManager = TrackerManager.shared
    @State private var isExpanded = false
    @State private var currentRating: Int = 0
    @State private var noteText = ""
    @State private var syncMessage: String?

    init(mediaId: Int, isAnime: Bool = false) {
        self.mediaId = mediaId
        self.isAnime = isAnime
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: currentRating > 0 ? "star.fill" : "star")
                        .foregroundColor(currentRating > 0 ? .yellow : .white.opacity(0.65))

                    Text("Rating & Notes")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white.opacity(0.85))

                    if currentRating > 0 {
                        Text("\(currentRating)/10")
                            .font(.caption.weight(.medium))
                            .foregroundColor(.white.opacity(0.6))
                    }

                    if !noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Image(systemName: "text.bubble")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.55))
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white.opacity(0.55))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.18))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    ratingStars
                    notesEditor
                    trackerButtons

                    if let syncMessage {
                        Text(syncMessage)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(12)
                .background(Color.black.opacity(0.14))
                .cornerRadius(8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .onAppear {
            currentRating = UserRatingManager.shared.rating(for: mediaId) ?? 0
            noteText = UserRatingManager.shared.note(for: mediaId)
        }
        .onChange(of: noteText) { value in
            UserRatingManager.shared.setNote(value, for: mediaId)
        }
    }

    @ViewBuilder
    private var ratingStars: some View {
        HStack(spacing: 4) {
            ForEach(1...10, id: \.self) { star in
                let starImage = Image(systemName: star <= currentRating ? "star.fill" : "star")
                    .font(.body)
                    .foregroundColor(star <= currentRating ? .yellow : .white.opacity(0.3))

                if #available(iOS 17.0, *) {
                    starImage
                        .contentTransition(.symbolEffect(.replace))
                        .onTapGesture {
                            updateRating(star)
                        }
                } else {
                    starImage
                        .animation(.easeInOut(duration: 0.15), value: currentRating)
                        .onTapGesture {
                            updateRating(star)
                        }
                }
            }

            Spacer(minLength: 8)

            Text(currentRating > 0 ? "\(currentRating)/10" : "No rating")
                .font(.caption)
                .foregroundColor(.white.opacity(0.55))
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var notesEditor: some View {
        TextEditor(text: $noteText)
            .frame(minHeight: 82)
            .padding(8)
            .foregroundColor(.white)
            .background(Color.black.opacity(0.2))
            .cornerRadius(8)
            .lunaHideScrollBackground()
    }

    @ViewBuilder
    private var trackerButtons: some View {
        let canWrite = isAnime && trackerManager.trackerState.syncEnabled && currentRating > 0
        let hasAniList = trackerManager.hasConnectedAccount(.anilist)
        let hasMAL = trackerManager.hasConnectedAccount(.myAnimeList)

        if isAnime && (hasAniList || hasMAL) {
            HStack(spacing: 10) {
                if hasAniList {
                    Button {
                        syncRatingAndNote(to: .anilist)
                    } label: {
                        Label("AniList", systemImage: "arrow.up.circle")
                    }
                    .disabled(!canWrite)
                }

                if hasMAL {
                    Button {
                        syncRatingAndNote(to: .myAnimeList)
                    } label: {
                        Label("MAL", systemImage: "arrow.up.circle")
                    }
                    .disabled(!canWrite)
                }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .tint(.blue)
        }
    }

    private func updateRating(_ star: Int) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if currentRating == star {
                currentRating = 0
                UserRatingManager.shared.removeRating(for: mediaId)
            } else {
                currentRating = star
                UserRatingManager.shared.setRating(star, for: mediaId)
                TrackerManager.shared.syncUserRating(tmdbId: mediaId, ratingOutOf10: star, isAnime: isAnime)
            }
        }
    }

    private func syncRatingAndNote(to service: TrackerService) {
        UserRatingManager.shared.setNote(noteText, for: mediaId)
        trackerManager.syncRatingAndNote(
            tmdbId: mediaId,
            ratingOutOf10: currentRating,
            note: noteText,
            service: service,
            isAnime: isAnime
        )
        syncMessage = "Syncing to \(service.displayName)..."
    }
}
