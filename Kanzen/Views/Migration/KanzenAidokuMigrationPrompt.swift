//
//  KanzenAidokuMigrationPrompt.swift
//  Kanzen
//
//  Created by Eclipse on 2026.
//

import SwiftUI

#if !os(tvOS)
enum KanzenAidokuLibraryStatus {
    static func legacySourceID(for item: MangaLibraryItem) -> String? {
        guard let route = item.route, case .aidoku(let sourceId, _) = route else { return nil }
        let trimmed = sourceId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func usesLegacySource(_ item: MangaLibraryItem) -> Bool {
        legacySourceID(for: item) != nil
    }
}

struct KanzenAidokuUnavailableBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 9, weight: .bold))
            Text("Unavailable")
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Color.secondary.opacity(0.92))
        )
        .padding(5)
        .accessibilityLabel("Legacy source unavailable")
    }
}

struct KanzenAidokuLibraryUnavailableView: View {
    let title: String

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
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#endif
