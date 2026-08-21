//
//  SearchResultCard.swift
//  Sora
//
//  Created by Francesco on 07/08/25.
//

import SwiftUI
import Kingfisher

struct SearchResultCard: View {
    let result: TMDBSearchResult
    @Environment(\.heroNamespace) private var heroNamespace
    private var heroID: String { "search-\(result.stableIdentity)" }

    var body: some View {
        NavigationLink(destination: MediaDetailView(searchResult: result)
            .heroDestination(id: heroID, namespace: heroNamespace)
        ) {
            VStack(spacing: 8) {
                posterArtwork
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
                    .heroSource(id: heroID, namespace: heroNamespace)

                Text(result.displayTitle)
                    .font(isTvOS ? .system(size: 28) : .caption)
                    .fontWeight(isTvOS ? .semibold : .medium)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(height: isTvOS ? 76 : 34)
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity)
        }
#if os(tvOS)
        .buttonStyle(.card)
#else
        .buttonStyle(PlainButtonStyle())
#endif
    }

    @ViewBuilder
    private var posterArtwork: some View {
        if isTvOS || isIPad {
            Color.clear
                .aspectRatio(2/3, contentMode: .fit)
                .overlay {
                    posterImage
                }
                .clipped()
        } else {
            posterImage
                .frame(height: 180 * iPadScale)
        }
    }

    private var posterImage: some View {
        KFImage(URL(string: result.fullPosterURL ?? ""))
            .placeholder {
                FallbackImageView(
                    isMovie: result.isMovie,
                    size: isTvOS ? CGSize(width: 260, height: 390) : CGSize(width: 120, height: 180)
                )
            }
            .resizable()
            .aspectRatio(2/3, contentMode: .fill)
    }
}
