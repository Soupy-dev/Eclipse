//
//  MovieDetails.swift
//  Sora
//
//  Created by Francesco on 07/08/25.
//

import SwiftUI

struct MovieDetailsSection: View {
    let movie: TMDBMovieDetail?
    var compactHeroMetadata: Bool = false
    @AppStorage(MediaDetailAgeRatingSettings.enabledKey) private var showsAgeRating = MediaDetailAgeRatingSettings.defaultEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let movie = movie {
                Text("Details")
                    .font(.title2)
                    .fontWeight(.bold)
                    .padding(.horizontal)
                    .padding(.top)
                    .foregroundColor(.white)

                VStack(spacing: 12) {
                    if let runtime = movie.runtime, runtime > 0 {
                        DetailRow(title: "Runtime", value: movie.runtimeFormatted)
                    }

                    if !compactHeroMetadata && !movie.genres.isEmpty {
                        DetailRow(title: "Genres", value: movie.genres.map { $0.name }.joined(separator: ", "))
                    }

                    if !compactHeroMetadata, let releaseDate = movie.releaseDate, !releaseDate.isEmpty {
                        DetailRow(title: "Release Date", value: releaseDate)
                    }

                    if !compactHeroMetadata && movie.voteAverage > 0 {
                        DetailRow(title: "Rating", value: String(format: "%.1f/10", movie.voteAverage))
                    }

                    if showsAgeRating, let ageRating = getAgeRating(from: movie.releaseDates) {
                        DetailRow(title: "Age Rating", value: ageRating)
                    }

                    if let tagline = movie.tagline, !tagline.isEmpty {
                        DetailRow(title: "Tagline", value: tagline)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 16)
                .applyLiquidGlassBackground(cornerRadius: 16)
                .padding(.horizontal)
            }
        }
    }

    private func getAgeRating(from releaseDates: TMDBReleaseDates?) -> String? {
        releaseDates?.preferredCertification?.value
    }
}
