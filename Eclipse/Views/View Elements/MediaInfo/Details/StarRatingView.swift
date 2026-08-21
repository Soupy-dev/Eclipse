import Foundation
import SwiftUI

struct StarRatingView: View {
    let mediaId: Int
    let isAnime: Bool
    let usesIPadAtmosphereStyle: Bool

    @StateObject private var trackerManager = TrackerManager.shared
    @State private var isExpanded = false
    @State private var currentRating: Double = 0
    @State private var noteText = ""
    @State private var syncMessage: String?

    init(mediaId: Int, isAnime: Bool = false, usesIPadAtmosphereStyle: Bool = false) {
        self.mediaId = mediaId
        self.isAnime = isAnime
        self.usesIPadAtmosphereStyle = usesIPadAtmosphereStyle
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
                        Text("\(ratingDisplayText)/10")
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
                .background(ratingControlBackground)
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
                .background(expandedRatingBackground)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .onAppear {
            currentRating = UserRatingManager.shared.rating(for: mediaId) ?? 0
            noteText = UserRatingManager.shared.note(for: mediaId)
        }
        .onChangeComp(of: noteText) { _, value in
            UserRatingManager.shared.setNote(value, for: mediaId)
        }
    }

    @ViewBuilder
    private var ratingControlBackground: some View {
        if usesIPadAtmosphereStyle {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.07))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.13), lineWidth: 1)
                }
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.18))
        }
    }

    @ViewBuilder
    private var expandedRatingBackground: some View {
        if usesIPadAtmosphereStyle {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.055))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.11), lineWidth: 1)
                }
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.14))
        }
    }

    @ViewBuilder
    private var ratingStars: some View {
        HStack(spacing: 4) {
            ForEach(1...10, id: \.self) { star in
#if os(tvOS)
                Button {
                    updateRating(Double(star))
                } label: {
                    Image(systemName: starSymbol(for: star))
                        .font(.body)
                        .foregroundColor(starTint(for: star))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(star) out of 10")
#else
                let starImage = Image(systemName: starSymbol(for: star))
                    .font(.body)
                    .foregroundColor(starTint(for: star))

                GeometryReader { proxy in
                    starImage
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { value in
                                    let isLeftHalf = value.location.x < proxy.size.width / 2
                                    updateRating(Double(star) - (isLeftHalf ? 0.5 : 0))
                                }
                        )
                }
                .frame(width: 20, height: 22)
                .animation(.easeInOut(duration: 0.15), value: currentRating)
#endif
            }

            Spacer(minLength: 8)

            Text(currentRating > 0 ? "\(ratingDisplayText)/10" : "No rating")
                .font(.caption)
                .foregroundColor(.white.opacity(0.55))
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var notesEditor: some View {
#if os(tvOS)
        TextField("Private notes", text: $noteText)
            .textFieldStyle(.plain)
            .padding(12)
            .foregroundColor(.white)
            .background(Color.black.opacity(0.2))
            .cornerRadius(8)
#else
        TextEditor(text: $noteText)
            .frame(minHeight: 82)
            .padding(8)
            .foregroundColor(.white)
            .background(Color.black.opacity(0.2))
            .cornerRadius(8)
            .eclipseHideScrollBackground()
#endif
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

    private func updateRating(_ value: Double) {
        let rating = Self.normalizedRating(value)
        withAnimation(.easeInOut(duration: 0.15)) {
            if Self.ratingsAreEqual(currentRating, rating) {
                currentRating = 0
                UserRatingManager.shared.removeRating(for: mediaId)
            } else {
                currentRating = rating
                UserRatingManager.shared.setRating(rating, for: mediaId)
                TrackerManager.shared.syncUserRating(tmdbId: mediaId, ratingOutOf10: rating, isAnime: isAnime)
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

    private var ratingDisplayText: String {
        Self.ratingDisplayString(currentRating)
    }

    private func starSymbol(for star: Int) -> String {
        let fullValue = Double(star)
        if currentRating >= fullValue {
            return "star.fill"
        }
        if currentRating >= fullValue - 0.5 {
            return "star.leadinghalf.filled"
        }
        return "star"
    }

    private func starTint(for star: Int) -> Color {
        currentRating >= Double(star) - 0.5 ? .yellow : .white.opacity(0.3)
    }

    private static func normalizedRating(_ value: Double) -> Double {
        let finiteValue = value.isFinite ? value : 0.5
        let halfStepValue = (finiteValue * 2).rounded() / 2
        return max(0.5, min(10, halfStepValue))
    }

    private static func ratingsAreEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.001
    }

    private static func ratingDisplayString(_ rating: Double) -> String {
        let normalized = normalizedRating(rating)
        if normalized.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(normalized))
        }
        return String(format: "%.1f", normalized)
    }
}

#if !os(tvOS)
struct ReaderRatingNotesView: View {
    let itemId: Int
    let title: String
    let progressItemId: Int?
    let routeKey: String?
    let knownAniListId: Int?
    let knownMALId: Int?
    let totalChapters: Int?
    let format: String?

    @StateObject private var trackerManager = TrackerManager.shared
    @State private var isExpanded = false
    @State private var currentRating: Double = 0
    @State private var noteText = ""
    @State private var syncMessage: String?

    init(
        itemId: Int,
        title: String,
        progressItemId: Int? = nil,
        routeKey: String? = nil,
        knownAniListId: Int? = nil,
        knownMALId: Int? = nil,
        totalChapters: Int? = nil,
        format: String? = nil
    ) {
        self.itemId = itemId
        self.title = title
        self.progressItemId = progressItemId
        self.routeKey = routeKey
        self.knownAniListId = knownAniListId
        self.knownMALId = knownMALId
        self.totalChapters = totalChapters
        self.format = format
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
                        .foregroundColor(currentRating > 0 ? .yellow : .secondary)

                    Text("Rating & Notes")
                        .font(.headline)
                        .foregroundColor(.primary)

                    if currentRating > 0 {
                        Text("\(ratingDisplayText)/10")
                            .font(.caption.weight(.medium))
                            .foregroundColor(.secondary)
                    }

                    if !noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Image(systemName: "text.bubble")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.secondary.opacity(0.12))
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
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear {
            currentRating = UserRatingManager.shared.rating(for: itemId) ?? 0
            noteText = UserRatingManager.shared.note(for: itemId)
        }
        .onChange(of: noteText) { value in
            UserRatingManager.shared.setNote(value, for: itemId)
        }
    }

    @ViewBuilder
    private var ratingStars: some View {
        HStack(spacing: 4) {
            ForEach(1...10, id: \.self) { star in
                let starImage = Image(systemName: starSymbol(for: star))
                    .font(.body)
                    .foregroundColor(starTint(for: star))

                GeometryReader { proxy in
                    starImage
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { value in
                                    let isLeftHalf = value.location.x < proxy.size.width / 2
                                    updateRating(Double(star) - (isLeftHalf ? 0.5 : 0))
                                }
                        )
                }
                .frame(width: 20, height: 22)
                .animation(.easeInOut(duration: 0.15), value: currentRating)
            }

            Spacer(minLength: 8)

            Text(currentRating > 0 ? "\(ratingDisplayText)/10" : "No rating")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var notesEditor: some View {
        TextEditor(text: $noteText)
            .frame(minHeight: 82)
            .padding(8)
            .foregroundColor(.primary)
            .background(Color.secondary.opacity(0.12))
            .cornerRadius(8)
            .eclipseHideScrollBackground()
            .overlay(alignment: .topLeading) {
                if noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Private notes for \(title)")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.8))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private var trackerButtons: some View {
        let hasAniList = trackerManager.hasConnectedAccount(.anilist)
        let hasMAL = trackerManager.hasConnectedAccount(.myAnimeList)
        let canWrite = trackerManager.trackerState.readerSyncEnabled && currentRating > 0

        if hasAniList || hasMAL {
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

    private func updateRating(_ value: Double) {
        let rating = Self.normalizedRating(value)
        withAnimation(.easeInOut(duration: 0.15)) {
            if Self.ratingsAreEqual(currentRating, rating) {
                currentRating = 0
                UserRatingManager.shared.removeRating(for: itemId)
            } else {
                currentRating = rating
                UserRatingManager.shared.setRating(rating, for: itemId)
                TrackerManager.shared.syncReaderMangaRating(
                    localMangaId: progressLookupId,
                    title: title,
                    ratingOutOf10: rating,
                    note: nil,
                    totalChapters: totalChapters,
                    format: format,
                    routeKey: routeKey,
                    knownAniListId: resolvedKnownAniListId,
                    knownMALId: resolvedKnownMALId,
                    isAutomatic: true
                )
            }
        }
    }

    private func syncRatingAndNote(to service: TrackerService) {
        UserRatingManager.shared.setNote(noteText, for: itemId)
        let trimmedNote = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        TrackerManager.shared.syncReaderMangaRating(
            localMangaId: progressLookupId,
            title: title,
            ratingOutOf10: currentRating,
            note: trimmedNote.isEmpty ? nil : noteText,
            service: service,
            totalChapters: totalChapters,
            format: format,
            routeKey: routeKey,
            knownAniListId: resolvedKnownAniListId,
            knownMALId: resolvedKnownMALId,
            isAutomatic: false
        )
        syncMessage = "Syncing to \(service.displayName)..."
    }

    private var resolvedKnownAniListId: Int? {
        knownAniListId ?? MangaReadingProgressManager.shared.progress(for: progressLookupId)?.trackerAniListId
    }

    private var resolvedKnownMALId: Int? {
        knownMALId ?? MangaReadingProgressManager.shared.progress(for: progressLookupId)?.trackerMALId
    }

    private var progressLookupId: Int {
        progressItemId ?? itemId
    }

    private var ratingDisplayText: String {
        Self.ratingDisplayString(currentRating)
    }

    private func starSymbol(for star: Int) -> String {
        let fullValue = Double(star)
        if currentRating >= fullValue {
            return "star.fill"
        }
        if currentRating >= fullValue - 0.5 {
            return "star.leadinghalf.filled"
        }
        return "star"
    }

    private func starTint(for star: Int) -> Color {
        currentRating >= Double(star) - 0.5 ? .yellow : .secondary.opacity(0.45)
    }

    private static func normalizedRating(_ value: Double) -> Double {
        let finiteValue = value.isFinite ? value : 0.5
        let halfStepValue = (finiteValue * 2).rounded() / 2
        return max(0.5, min(10, halfStepValue))
    }

    private static func ratingsAreEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.001
    }

    private static func ratingDisplayString(_ rating: Double) -> String {
        let normalized = normalizedRating(rating)
        if normalized.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(normalized))
        }
        return String(format: "%.1f", normalized)
    }
}
#endif
