//
//  MangaDetailView.swift
//  Kanzen
//
//  Created by Luna on 2025.
//

import SwiftUI
import Kingfisher

#if !os(tvOS)
struct MangaDetailView: View {
    let manga: AniListManga
    @EnvironmentObject var moduleManager: ModuleManager
    @StateObject private var sourceFinder = MangaSourceFinder()
    @AppStorage("kanzenAutoMode") private var autoModeEnabled: Bool = false
    @State private var expandedDescription: Bool = false
    @State private var navigateToAutoMatch: Bool = false

    private let coverWidth: CGFloat = isIPad ? 150 * iPadScaleSmall : 150

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection

                Divider()

                if let description = manga.description, !description.isEmpty {
                    descriptionSection(description)
                }

                Divider()

                if let genres = manga.genres, !genres.isEmpty {
                    genresSection(genres)
                }

                Divider()

                sourcesSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .navigationTitle(manga.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !moduleManager.modules.isEmpty else { return }
            sourceFinder.searchAllModules(for: manga)
        }
        .onChange(of: sourceFinder.hasFinished) { finished in
            guard finished, autoModeEnabled else { return }
            // In auto mode, refine top matches with chapter counts then navigate
            sourceFinder.refineTopMatchesWithChapterCounts(for: manga)
        }
        .onChange(of: sourceFinder.autoPickedMatch?.id) { _ in
            // After refinement, if auto mode auto-navigate
            if autoModeEnabled, sourceFinder.hasFinished, sourceFinder.autoPickedMatch != nil {
                // Small delay so the user briefly sees what was picked
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    navigateToAutoMatch = true
                }
            }
        }
        .background(
            Group {
                if let match = sourceFinder.autoPickedMatch {
                    NavigationLink(
                        destination: AutoMatchDestination(match: match),
                        isActive: $navigateToAutoMatch
                    ) { EmptyView() }
                    .hidden()
                }
            }
        )
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        HStack(alignment: .top, spacing: 14) {
            KFImage(URL(string: manga.coverURL ?? ""))
                .placeholder { ProgressView() }
                .resizable()
                .scaledToFill()
                .frame(width: coverWidth, height: coverWidth * 1.5)
                .clipped()
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 6) {
                Text(manga.displayTitle)
                    .font(.title2)
                    .fontWeight(.bold)
                    .lineLimit(3)

                if let format = manga.format {
                    Text(formatLabel(format))
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2))
                        .cornerRadius(4)
                }

                if let status = manga.status {
                    Label(statusLabel(status), systemImage: statusIcon(status))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 12) {
                    if let chapters = manga.chapters {
                        Label("\(chapters) ch", systemImage: "book.pages")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if let volumes = manga.volumes {
                        Label("\(volumes) vol", systemImage: "books.vertical")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if let score = manga.averageScore {
                        Label("\(score)%", systemImage: "star.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if let year = manga.startYear {
                        Label("\(String(year))", systemImage: "calendar")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: - Description

    @ViewBuilder
    private func descriptionSection(_ text: String) -> some View {
        let cleaned = text
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        VStack(alignment: .leading, spacing: 4) {
            Text("Synopsis")
                .font(.headline)

            Text(cleaned)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(expandedDescription ? nil : 4)
                .onTapGesture {
                    withAnimation { expandedDescription.toggle() }
                }

            if !expandedDescription {
                Text("Show more")
                    .font(.caption)
                    .foregroundColor(.accentColor)
                    .onTapGesture {
                        withAnimation { expandedDescription.toggle() }
                    }
            }
        }
    }

    // MARK: - Genres

    @ViewBuilder
    private func genresSection(_ genres: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Genres")
                .font(.headline)

            FlowLayout(spacing: 6) {
                ForEach(genres, id: \.self) { genre in
                    Text(genre)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.15))
                        .cornerRadius(6)
                }
            }
        }
    }

    // MARK: - Sources Section

    @ViewBuilder
    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sources")
                    .font(.headline)
                Spacer()
                if autoModeEnabled {
                    Text("Auto Mode")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2))
                        .cornerRadius(4)
                }
            }

            if moduleManager.modules.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("No modules installed. Add one from the Browse tab.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else if sourceFinder.isSearching {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Searching modules…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else if sourceFinder.matches.isEmpty && sourceFinder.hasFinished {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("No matching sources found")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                ForEach(sourceFinder.matches) { match in
                    NavigationLink(destination: AutoMatchDestination(match: match)) {
                        sourceMatchRow(match)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private func sourceMatchRow(_ match: SourceMatch) -> some View {
        HStack(spacing: 12) {
            if let iconURL = URL(string: match.module.moduleData.iconURL) {
                KFImage(iconURL)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                    .cornerRadius(8)
            } else {
                Image(systemName: "puzzlepiece.extension")
                    .frame(width: 36, height: 36)
                    .foregroundColor(.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(match.manga.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    confidenceBadge(match.confidence)
                }

                HStack(spacing: 8) {
                    Text(match.module.moduleData.sourceName)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let ch = match.chapterCount {
                        Text("·  \(ch) ch")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Text("·  \(Int(match.titleScore * 100))% match")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func confidenceBadge(_ confidence: SourceMatch.SourceMatchConfidence) -> some View {
        let (text, color): (String, Color) = {
            switch confidence {
            case .high: return ("High", .green)
            case .medium: return ("Med", .orange)
            case .low: return ("Low", .red)
            }
        }()

        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(3)
    }

    // MARK: - Helpers

    private func formatLabel(_ format: String) -> String {
        switch format {
        case "MANGA": return "Manga"
        case "NOVEL": return "Light Novel"
        case "ONE_SHOT": return "One Shot"
        default: return format.capitalized
        }
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "RELEASING": return "Publishing"
        case "FINISHED": return "Completed"
        case "NOT_YET_RELEASED": return "Upcoming"
        case "CANCELLED": return "Cancelled"
        case "HIATUS": return "Hiatus"
        default: return status.capitalized
        }
    }

    private func statusIcon(_ status: String) -> String {
        switch status {
        case "RELEASING": return "clock.arrow.circlepath"
        case "FINISHED": return "checkmark.circle"
        case "NOT_YET_RELEASED": return "calendar"
        case "CANCELLED": return "xmark.circle"
        case "HIATUS": return "pause.circle"
        default: return "questionmark.circle"
        }
    }
}

// MARK: - Auto Match Destination

/// Loads a module and navigates directly to the content view for a matched manga.
struct AutoMatchDestination: View {
    let match: SourceMatch
    @StateObject private var kanzen = KanzenEngine()
    @EnvironmentObject var moduleManager: ModuleManager
    @State private var moduleLoaded = false

    var body: some View {
        Group {
            if moduleLoaded {
                contentView(
                    parentModule: match.module,
                    title: match.manga.title,
                    imageURL: match.manga.imageURL,
                    params: match.manga.mangaId
                )
                .environmentObject(kanzen)
            } else {
                ProgressView("Loading module…")
                    .task { loadModule() }
            }
        }
    }

    private func loadModule() {
        do {
            let content = try ModuleManager.shared.getModuleScript(module: match.module)
            try kanzen.loadScript(content)
            moduleLoaded = true
        } catch {
            Logger.shared.log("AutoMatchDestination: Failed to load module: \(error.localizedDescription)", type: "Error")
        }
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Module Search Bridge (kept for per-module search fallback)

struct ModuleSearchBridge: View {
    let module: ModuleDataContainer
    let searchQuery: String
    @StateObject private var kanzen = KanzenEngine()
    @EnvironmentObject var moduleManager: ModuleManager
    @State private var moduleLoaded = false

    var body: some View {
        Group {
            if moduleLoaded {
                KanzenSearchView(module: module, searchText: searchQuery)
                    .environmentObject(kanzen)
                    .environmentObject(moduleManager)
            } else {
                ProgressView("Loading module…")
                    .task { loadModule() }
            }
        }
    }

    private func loadModule() {
        do {
            let content = try ModuleManager.shared.getModuleScript(module: module)
            try kanzen.loadScript(content)
            moduleLoaded = true
        } catch {
            Logger.shared.log("ModuleSearchBridge: Failed to load module: \(error.localizedDescription)", type: "Error")
        }
    }
}
#endif
