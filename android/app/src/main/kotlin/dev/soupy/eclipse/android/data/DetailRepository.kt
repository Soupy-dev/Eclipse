package dev.soupy.eclipse.android.data

import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import dev.soupy.eclipse.android.core.model.AniListMedia
import dev.soupy.eclipse.android.core.model.DetailTarget
import dev.soupy.eclipse.android.core.model.TMDBCastMember
import dev.soupy.eclipse.android.core.model.displayTitle
import dev.soupy.eclipse.android.core.model.fullBackdropUrl
import dev.soupy.eclipse.android.core.model.fullProfileUrl
import dev.soupy.eclipse.android.core.model.fullPosterUrl
import dev.soupy.eclipse.android.core.model.fullStillUrl
import dev.soupy.eclipse.android.core.model.posterUrl
import dev.soupy.eclipse.android.core.model.relationEdges
import dev.soupy.eclipse.android.core.model.TMDBEpisode
import dev.soupy.eclipse.android.core.model.TMDBSeason
import dev.soupy.eclipse.android.core.model.TMDBSeasonDetail
import dev.soupy.eclipse.android.core.model.usCertification
import dev.soupy.eclipse.android.core.model.usRating
import dev.soupy.eclipse.android.core.model.TMDBTVShowDetail
import dev.soupy.eclipse.android.core.network.AniListService.AniMapSpecialMapping
import dev.soupy.eclipse.android.core.network.AniListService
import dev.soupy.eclipse.android.core.network.TmdbService
import kotlin.math.abs

data class DetailEpisodeEntry(
    val id: String,
    val title: String,
    val subtitle: String? = null,
    val imageUrl: String? = null,
    val overview: String? = null,
    val seasonNumber: Int? = null,
    val episodeNumber: Int? = null,
    val runtimeMinutes: Int? = null,
    val tmdbSeasonNumber: Int? = null,
    val tmdbEpisodeNumber: Int? = null,
    val isSpecial: Boolean = false,
    val titleOnlySearch: Boolean = false,
    val searchTitle: String? = null,
    val serviceHref: String? = null,
)

data class DetailCastEntry(
    val id: String,
    val name: String,
    val role: String? = null,
    val imageUrl: String? = null,
)

data class DetailFactEntry(
    val label: String,
    val value: String,
)

data class DetailContent(
    val title: String,
    val subtitle: String? = null,
    val overview: String? = null,
    val posterUrl: String? = null,
    val backdropUrl: String? = null,
    val metadataChips: List<String> = emptyList(),
    val detailFacts: List<DetailFactEntry> = emptyList(),
    val contentRating: String? = null,
    val cast: List<DetailCastEntry> = emptyList(),
    val episodesTitle: String? = null,
    val episodes: List<DetailEpisodeEntry> = emptyList(),
    val isMovie: Boolean = false,
    val progressTarget: DetailTarget? = null,
)

class DetailRepository(
    private val tmdbService: TmdbService,
    private val aniListService: AniListService,
    private val animeTmdbMapper: AnimeTmdbMapper,
    private val servicesRepository: ServicesRepository,
) {
    suspend fun load(target: DetailTarget): Result<DetailContent> = runCatching {
        when (target) {
            is DetailTarget.TmdbMovie -> loadMovieContent(target.id)

            is DetailTarget.TmdbShow -> loadShowContent(target.id)

            is DetailTarget.AniListMediaTarget -> {
                val media = aniListService.mediaById(target.id).orThrow()
                val tmdbMatch = animeTmdbMapper.findBestMatch(media)
                val tmdbShowTarget = tmdbMatch?.target as? DetailTarget.TmdbShow
                if (tmdbShowTarget != null) {
                    loadShowContent(
                        showId = tmdbShowTarget.id,
                        sourceAnime = media,
                    )
                } else {
                    media.toDetailContent(
                        tmdbMatch = tmdbMatch,
                        tmdbService = tmdbService,
                    )
                }
            }

            is DetailTarget.ServiceMedia -> {
                servicesRepository.loadServiceDetail(
                    id = target.serviceId,
                    href = target.href,
                    fallbackTitle = target.title,
                    fallbackImageUrl = target.imageUrl,
                ).getOrThrow().toDetailContent()
            }
        }
    }

    private suspend fun loadMovieContent(movieId: Int): DetailContent = coroutineScope {
        val movieDeferred = async { tmdbService.movieDetail(movieId).orThrow() }
        val creditsDeferred = async { tmdbService.movieCredits(movieId).orNull() }
        val releaseDatesDeferred = async { tmdbService.movieReleaseDates(movieId).orNull() }

        val movie = movieDeferred.await()
        val certification = releaseDatesDeferred.await()?.usCertification
        DetailContent(
            title = movie.title,
            subtitle = movie.releaseDate?.take(4)?.let { "Movie | $it" } ?: "Movie",
            overview = movie.overview,
            posterUrl = movie.fullPosterUrl,
            backdropUrl = movie.fullBackdropUrl,
            metadataChips = buildList {
                add("Movie")
                movie.releaseDate?.take(4)?.let(::add)
                movie.runtime?.takeIf { it > 0 }?.let { add(formatRuntime(it)) }
                certification?.let { add("Rated $it") }
                addAll(movie.genres.map { it.name }.take(3))
            },
            detailFacts = buildList {
                movie.runtime?.takeIf { it > 0 }?.let { add(DetailFactEntry("Runtime", formatRuntime(it))) }
                movie.releaseDate?.takeIf { it.isNotBlank() }?.let { add(DetailFactEntry("Release Date", it)) }
                certification?.let { add(DetailFactEntry("Age Rating", it)) }
                movie.genres.takeIf { it.isNotEmpty() }?.let { genres ->
                    add(DetailFactEntry("Genres", genres.joinToString(", ") { it.name }))
                }
            },
            contentRating = certification,
            cast = creditsDeferred.await().toDetailCastEntries(),
            isMovie = true,
            progressTarget = DetailTarget.TmdbMovie(movieId),
        )
    }

    private suspend fun loadShowContent(
        showId: Int,
        sourceAnime: AniListMedia? = null,
    ): DetailContent = coroutineScope {
        val showDeferred = async { tmdbService.tvShowDetail(showId).orThrow() }
        val creditsDeferred = async { tmdbService.tvCredits(showId).orNull() }
        val ratingsDeferred = async { tmdbService.tvContentRatings(showId).orNull() }

        val show = showDeferred.await()
        val contentRating = ratingsDeferred.await()?.usRating
        val animeBundle = if (sourceAnime != null || show.isIosAnimeCandidate()) {
            loadAnimeSeasonBundle(
                show = show,
                sourceAnime = sourceAnime,
            )
        } else {
            null
        }
        val seasonDetails = if (animeBundle == null) {
            tmdbService.playableSeasonDetails(
                showId = showId,
                seasons = show.seasons,
            )
        } else {
            emptyList()
        }
        val realSeasonCount = animeBundle?.seasonCount
            ?: show.numberOfSeasons
            ?: show.seasons.count { it.seasonNumber > 0 && it.episodeCount > 0 }
        val realEpisodeCount = animeBundle?.totalEpisodes
            ?: show.numberOfEpisodes
            ?: show.seasons.filter { it.seasonNumber > 0 }.sumOf(TMDBSeason::episodeCount)
        val primaryRuntime = show.episodeRunTime.firstOrNull { it > 0 }
        DetailContent(
            title = sourceAnime?.displayTitle ?: show.name,
            subtitle = show.firstAirDate?.take(4)?.let { "${if (animeBundle != null) "Anime" else "Series"} | $it" }
                ?: if (animeBundle != null) "Anime" else "Series",
            overview = show.overview,
            posterUrl = show.fullPosterUrl,
            backdropUrl = show.fullBackdropUrl,
            metadataChips = buildList {
                add(if (animeBundle != null) "Anime" else "Series")
                show.firstAirDate?.take(4)?.let(::add)
                realSeasonCount.takeIf { it > 0 }?.let { add("$it seasons") }
                primaryRuntime?.let { add(formatRuntime(it)) }
                contentRating?.let { add("Rated $it") }
                addAll(show.genres.map { it.name }.take(3))
            },
            detailFacts = buildList {
                realSeasonCount.takeIf { it > 0 }?.let { add(DetailFactEntry("Seasons", it.toString())) }
                realEpisodeCount.takeIf { it > 0 }?.let { add(DetailFactEntry("Episodes", it.toString())) }
                show.genres.takeIf { it.isNotEmpty() }?.let { genres ->
                    add(DetailFactEntry("Genres", genres.joinToString(", ") { it.name }))
                }
                contentRating?.let { add(DetailFactEntry("Age Rating", it)) }
                show.firstAirDate?.takeIf { it.isNotBlank() }?.let { add(DetailFactEntry("First Aired", it)) }
                show.lastAirDate?.takeIf { it.isNotBlank() }?.let { add(DetailFactEntry("Last Aired", it)) }
                show.status?.takeIf { it.isNotBlank() }?.let { add(DetailFactEntry("Status", it)) }
            },
            contentRating = contentRating,
            cast = creditsDeferred.await().toDetailCastEntries(),
            episodesTitle = animeBundle?.episodesTitle ?: seasonDetails.title(show.name),
            episodes = animeBundle?.episodes ?: seasonDetails.flatMap { seasonDetail ->
                seasonDetail.episodes.map { it.toDetailEpisodeEntry() }
            },
            progressTarget = DetailTarget.TmdbShow(showId),
        )
    }

    private suspend fun loadAnimeSeasonBundle(
        show: TMDBTVShowDetail,
        sourceAnime: AniListMedia?,
    ): AnimeSeasonBundle? = coroutineScope {
        val rootAnime = sourceAnime
            ?.let { source -> aniListService.mediaById(source.id).orNull() ?: source }
            ?: selectAniListRootForShow(show)
            ?: return@coroutineScope null

        val animeSeasons = if (sourceAnime != null) {
            listOf(rootAnime)
        } else {
            collectAniListSeasonEntries(rootAnime, show)
                .ifEmpty { listOf(rootAnime) }
                .sortedWith(
                    compareBy<AniListMedia> { it.seasonYear ?: Int.MAX_VALUE }
                        .thenBy { it.id },
                )
        }

        val tmdbEpisodesByAbsolute = tmdbService.allRealSeasonEpisodes(show.id, show.seasons)
            .flatMap { it.episodes.sortedBy(TMDBEpisode::episodeNumber) }
            .mapIndexed { index, episode -> index + 1 to episode }
            .toMap()

        var absoluteEpisode = 1
        val episodes = mutableListOf<DetailEpisodeEntry>()
        animeSeasons.forEachIndexed { index, anime ->
            val localSeason = index + 1
            val episodeCount = anime.effectiveEpisodeCount()
                ?: (tmdbEpisodesByAbsolute.size - absoluteEpisode + 1).takeIf { it > 0 }
                ?: 12
            (1..episodeCount.coerceIn(1, 200)).forEach { localEpisode ->
                val tmdbEpisode = tmdbEpisodesByAbsolute[absoluteEpisode]
                episodes += DetailEpisodeEntry(
                    id = "anime-tmdb-${show.id}-s$localSeason-e$localEpisode-tmdb-${tmdbEpisode?.seasonNumber ?: 0}-${tmdbEpisode?.episodeNumber ?: 0}",
                    title = tmdbEpisode?.name?.takeIf { it.isNotBlank() } ?: "Episode $localEpisode",
                    subtitle = buildList {
                        add("S$localSeason")
                        add("E$localEpisode")
                        if (tmdbEpisode != null && (tmdbEpisode.seasonNumber != localSeason || tmdbEpisode.episodeNumber != localEpisode)) {
                            add("TMDB S${tmdbEpisode.seasonNumber}E${tmdbEpisode.episodeNumber}")
                        }
                        tmdbEpisode?.runtime?.takeIf { it > 0 }?.let { add(formatRuntime(it)) }
                        tmdbEpisode?.airDate?.takeIf { it.isNotBlank() }?.let(::add)
                    }.joinToString(" | "),
                    imageUrl = tmdbEpisode?.fullStillUrl ?: anime.posterUrl,
                    overview = tmdbEpisode?.overview,
                    seasonNumber = localSeason,
                    episodeNumber = localEpisode,
                    runtimeMinutes = tmdbEpisode?.runtime,
                    tmdbSeasonNumber = tmdbEpisode?.seasonNumber,
                    tmdbEpisodeNumber = tmdbEpisode?.episodeNumber,
                )
                absoluteEpisode += 1
            }
        }
        val specialEpisodes = loadAnimeSpecialEpisodes(show)

        AnimeSeasonBundle(
            episodesTitle = "Episodes",
            seasonCount = animeSeasons.size,
            totalEpisodes = episodes.size + specialEpisodes.size,
            episodes = episodes + specialEpisodes,
        )
    }

    private suspend fun loadAnimeSpecialEpisodes(show: TMDBTVShowDetail): List<DetailEpisodeEntry> = coroutineScope {
        val mappings = aniListService.specialMappingsForTmdbShow(show.id)
            .orNull()
            .orEmpty()
            .filter { mapping -> mapping.anilistId != null }
            .distinctBy { mapping -> mapping.anilistId }
        if (mappings.isEmpty()) return@coroutineScope emptyList()

        val mediaById = mappings
            .mapNotNull { mapping -> mapping.anilistId }
            .associateWith { anilistId ->
                async { aniListService.mediaById(anilistId).orNull() }
            }
            .mapValues { (_, deferred) -> deferred.await() }

        val seasonDetailsByNumber = mappings
            .mapNotNull { mapping -> mapping.tmdbSeason ?: mapping.tvdbSeason }
            .distinct()
            .associateWith { seasonNumber ->
                async { tmdbService.seasonDetail(show.id, seasonNumber).orNull() }
            }
            .mapValues { (_, deferred) -> deferred.await() }

        mappings
            .sortedWith(
                compareBy<AniMapSpecialMapping> { it.tmdbSeason ?: it.tvdbSeason ?: 0 }
                    .thenBy { it.mediaType.orEmpty() }
                    .thenBy { it.anilistId ?: 0 },
            )
            .flatMap { mapping ->
                val anilistId = mapping.anilistId ?: return@flatMap emptyList()
                val media = mediaById[anilistId]
                val title = media?.displayTitle
                    ?.takeIf { it.isNotBlank() }
                    ?: "Special $anilistId"
                val episodeCount = (media?.effectiveEpisodeCount() ?: 1).coerceIn(1, 200)
                val mappedSeason = mapping.tmdbSeason
                val metadataSeason = mapping.tmdbSeason ?: mapping.tvdbSeason
                val episodeOffset = mapping.tvdbEpisodeOffset ?: 0
                val seasonDetail = metadataSeason?.let { seasonDetailsByNumber[it] }
                val formatLabel = mapping.mediaType.specialFormatLabel()
                (1..episodeCount).map { number ->
                    val mappedEpisodeNumber = mappedSeason?.let { episodeOffset + number }
                    val metadataEpisodeNumber = metadataSeason?.let { episodeOffset + number }
                    val tmdbEpisode = metadataEpisodeNumber?.let { episodeNumber ->
                        seasonDetail?.episodes?.firstOrNull { episode -> episode.episodeNumber == episodeNumber }
                    }
                    DetailEpisodeEntry(
                        id = "animap-special-${show.id}-$anilistId-$number",
                        title = tmdbEpisode?.name?.takeIf { it.isNotBlank() }
                            ?: if (episodeCount == 1) title else "Episode $number",
                        subtitle = buildList {
                            add(formatLabel)
                            add("E$number")
                            if (mappedSeason != null && mappedEpisodeNumber != null) {
                                add("TMDB S${mappedSeason}E$mappedEpisodeNumber")
                            }
                            tmdbEpisode?.runtime?.takeIf { it > 0 }?.let { add(formatRuntime(it)) }
                            tmdbEpisode?.airDate?.takeIf { it.isNotBlank() }?.let(::add)
                        }.joinToString(" | "),
                        imageUrl = tmdbEpisode?.fullStillUrl
                            ?: media?.posterUrl
                            ?: seasonDetail?.posterPath?.let(::tmdbPosterUrl)
                            ?: show.fullPosterUrl,
                        overview = tmdbEpisode?.overview ?: media?.description?.stripHtmlTags(),
                        seasonNumber = 0,
                        episodeNumber = number,
                        runtimeMinutes = tmdbEpisode?.runtime,
                        tmdbSeasonNumber = mappedSeason,
                        tmdbEpisodeNumber = mappedEpisodeNumber,
                        isSpecial = true,
                        titleOnlySearch = mappedSeason == null || mappedEpisodeNumber == null,
                        searchTitle = title,
                    )
                }
            }
    }

    private suspend fun selectAniListRootForShow(show: TMDBTVShowDetail): AniListMedia? {
        val candidates = aniListService.searchAnime(show.name, perPage = 6)
            .orNull()
            ?.media
            .orEmpty()
        if (candidates.isEmpty()) return null

        val tmdbYear = show.firstAirDate?.take(4)?.toIntOrNull()
        val tmdbEpisodeCount = show.numberOfEpisodes
            ?: show.seasons.filter { it.seasonNumber > 0 }.sumOf(TMDBSeason::episodeCount).takeIf { it > 0 }
        val bestCandidate = candidates.maxByOrNull { candidate ->
            val titleScore = candidate.titleCandidates()
                .maxOfOrNull { title -> titleSimilarity(title, show.name) }
                ?: 0.0
            val yearScore = animeYearAlignmentScore(candidate.seasonYear, tmdbYear)
            val episodeScore = animeEpisodeCountScore(candidate.effectiveEpisodeCount(), tmdbEpisodeCount)
            titleScore + yearScore + episodeScore
        } ?: return null

        return aniListService.mediaById(bestCandidate.id).orNull() ?: bestCandidate
    }

    private suspend fun collectAniListSeasonEntries(
        rootAnime: AniListMedia,
        show: TMDBTVShowDetail,
    ): List<AniListMedia> {
        val allowedRelationTypes = setOf("SEQUEL", "PREQUEL", "SEASON")
        val allowedFormats = setOf("TV", "TV_SHORT", "ONA")
        val seenIds = mutableSetOf(rootAnime.id)
        val entries = mutableListOf(rootAnime)
        val queue = ArrayDeque<AniListMedia>()
        queue.add(rootAnime)

        while (queue.isNotEmpty() && entries.size < 24) {
            val current = queue.removeFirst()
            val relatedNodes = current.relationEdges
                .filter { edge -> edge.relationType in allowedRelationTypes }
                .mapNotNull { it.node }
                .filter { node -> node.type == null || node.type.equals("ANIME", ignoreCase = true) }
                .filter { node -> node.format == null || node.format in allowedFormats }
            for (node in relatedNodes) {
                if (!seenIds.add(node.id)) continue
                val fullNode = aniListService.mediaById(node.id).orNull() ?: node
                entries += fullNode
                queue.add(fullNode)
            }
        }

        val tmdbBudget = show.numberOfEpisodes
            ?: show.seasons.filter { it.seasonNumber > 0 }.sumOf(TMDBSeason::episodeCount).takeIf { it > 0 }
            ?: return entries
        val totalAniEpisodes = entries.sumOf { it.effectiveEpisodeCount() ?: 0 }
        if (totalAniEpisodes <= (tmdbBudget * 1.25).toInt()) return entries

        val rootIndex = entries.indexOfFirst { it.id == rootAnime.id }.takeIf { it >= 0 } ?: 0
        val kept = mutableListOf(entries[rootIndex])
        var total = entries[rootIndex].effectiveEpisodeCount() ?: 0
        var left = rootIndex - 1
        var right = rootIndex + 1
        while ((left >= 0 || right < entries.size) && total < (tmdbBudget * 1.25).toInt()) {
            if (left >= 0) {
                val eps = entries[left].effectiveEpisodeCount() ?: 0
                if (total + eps <= (tmdbBudget * 1.25).toInt()) {
                    kept.add(0, entries[left])
                    total += eps
                }
                left--
            }
            if (right < entries.size) {
                val eps = entries[right].effectiveEpisodeCount() ?: 0
                if (total + eps <= (tmdbBudget * 1.25).toInt()) {
                    kept += entries[right]
                    total += eps
                }
                right++
            }
        }
        return kept
    }
}

private fun ServiceResolvedDetail.toDetailContent(): DetailContent = DetailContent(
    title = title,
    subtitle = serviceName,
    overview = description,
    posterUrl = imageUrl,
    backdropUrl = imageUrl,
    metadataChips = buildList {
        add("Service")
        airdate?.takeIf { it.isNotBlank() }?.let(::add)
        if (episodes.isNotEmpty()) add("${episodes.size} eps")
    },
    detailFacts = buildList {
        add(DetailFactEntry("Source", serviceName))
        airdate?.takeIf { it.isNotBlank() }?.let { add(DetailFactEntry("Airdate", it)) }
        aliases?.takeIf { it.isNotBlank() }?.let { add(DetailFactEntry("Aliases", it)) }
    },
    episodesTitle = episodes.takeIf { it.isNotEmpty() }?.let { "Episodes" },
    episodes = episodes.mapIndexed { index, episode ->
        val episodeNumber = episode.episodeNumber ?: index + 1
        DetailEpisodeEntry(
            id = "service-$serviceId-${episode.href.hashCode()}-$index",
            title = episode.title.ifBlank { "Episode $episodeNumber" },
            subtitle = buildList {
                episode.seasonNumber?.let { add("S$it") }
                add("E$episodeNumber")
            }.joinToString(" | "),
            seasonNumber = episode.seasonNumber ?: 1,
            episodeNumber = episodeNumber,
            tmdbSeasonNumber = null,
            tmdbEpisodeNumber = null,
            searchTitle = title,
            serviceHref = episode.href,
        )
    },
    isMovie = episodes.isEmpty(),
    progressTarget = DetailTarget.ServiceMedia(
        serviceId = serviceId,
        href = href,
        title = title,
        imageUrl = imageUrl,
    ),
)

private data class AnimeSeasonBundle(
    val episodesTitle: String,
    val seasonCount: Int,
    val totalEpisodes: Int,
    val episodes: List<DetailEpisodeEntry>,
)

private fun TMDBEpisode.toDetailEpisodeEntry(): DetailEpisodeEntry = DetailEpisodeEntry(
    id = "episode-$seasonNumber-$episodeNumber",
    title = name.ifBlank { "Episode $episodeNumber" },
    subtitle = buildList {
        add("S$seasonNumber")
        add("E$episodeNumber")
        runtime?.takeIf { it > 0 }?.let { add(formatRuntime(it)) }
        airDate?.takeIf { it.isNotBlank() }?.let(::add)
    }.joinToString(" | "),
    imageUrl = fullStillUrl,
    overview = overview,
    seasonNumber = seasonNumber,
    episodeNumber = episodeNumber,
    runtimeMinutes = runtime,
    tmdbSeasonNumber = seasonNumber,
    tmdbEpisodeNumber = episodeNumber,
)

private fun TMDBTVShowDetail.isIosAnimeCandidate(): Boolean {
    val asianAnimationCountries = setOf("JP", "CN", "KR", "TW")
    val isAsianAnimation = originCountry.any { country -> country in asianAnimationCountries }
    val isAnimation = genres.any { genre -> genre.id == 16 }
    return isAsianAnimation && isAnimation
}

private suspend fun AniListMedia.toDetailContent(
    tmdbMatch: AnimeTmdbMatch?,
    tmdbService: TmdbService,
): DetailContent {
    val tmdbShowMatch = tmdbMatch?.takeIf { it.target is DetailTarget.TmdbShow }
    val tmdbShowMetadata = tmdbShowMatch?.let { match ->
        val target = match.target as DetailTarget.TmdbShow
        runCatching {
            coroutineScope {
                val showDeferred = async { tmdbService.tvShowDetail(target.id).orThrow() }
                val creditsDeferred = async { tmdbService.tvCredits(target.id).orNull() }
                val ratingsDeferred = async { tmdbService.tvContentRatings(target.id).orNull() }
                val show = showDeferred.await()
                val preferredSeasonNumber = match.tmdbSeasonNumber
                    ?: match.episodeMappings.firstOrNull { mapping -> mapping.anilistMediaId == id }?.tmdbSeasonNumber
                val seasons = tmdbService.playableSeasonDetails(
                    showId = target.id,
                    seasons = show.seasons,
                    preferredSeasonNumber = preferredSeasonNumber,
                )
                val animeEpisodes = toAnimeDetailEpisodeEntries(
                    tmdbMatch = match,
                    seasonDetails = seasons,
                )
                HydratedTmdbShowMetadata(
                    episodesTitle = animeEpisodes
                        ?.takeIf { it.isNotEmpty() }
                        ?.let { displayTitle }
                        ?: seasons.title(show.name),
                    episodes = animeEpisodes ?: seasons.flatMap { seasonDetail ->
                        seasonDetail.episodes.map { it.toDetailEpisodeEntry() }
                    },
                    cast = creditsDeferred.await().toDetailCastEntries(),
                    contentRating = ratingsDeferred.await()?.usRating,
                )
            }
        }.getOrNull()
    }
    val syntheticEpisodes = if (tmdbShowMetadata == null) syntheticAnimeEpisodes() else emptyList()

    return DetailContent(
        title = displayTitle,
        subtitle = listOfNotNull(
            format?.replace('_', ' '),
            seasonYear?.toString(),
            tmdbMatch?.title?.let { "TMDB: $it" },
        ).joinToString(" | ").ifBlank { "Anime" },
        overview = description?.stripHtmlTags(),
        posterUrl = posterUrl,
        backdropUrl = bannerImage ?: posterUrl,
        metadataChips = buildList {
            add("Anime")
            format?.replace('_', ' ')?.let(::add)
            seasonYear?.toString()?.let(::add)
            episodes?.takeIf { it > 0 }?.let { add("$it eps") }
            status?.replace('_', ' ')?.let(::add)
            tmdbShowMetadata?.contentRating?.let { add("Rated $it") }
            tmdbMatch?.let { add("TMDB match ${(it.confidence * 100).toInt()}%") }
            tmdbMatch?.tmdbSeasonNumber?.let { add("TMDB S$it") }
            addAll(genres.take(3))
        },
        detailFacts = buildList {
            format?.replace('_', ' ')?.let { add(DetailFactEntry("Format", it)) }
            seasonYear?.let { add(DetailFactEntry("Year", it.toString())) }
            episodes?.takeIf { it > 0 }?.let { add(DetailFactEntry("Episodes", it.toString())) }
            status?.replace('_', ' ')?.let { add(DetailFactEntry("Status", it)) }
            genres.takeIf { it.isNotEmpty() }?.let { add(DetailFactEntry("Genres", it.joinToString(", "))) }
            tmdbMatch?.title?.let { add(DetailFactEntry("TMDB Match", it)) }
        },
        contentRating = tmdbShowMetadata?.contentRating,
        cast = tmdbShowMetadata?.cast.orEmpty(),
        episodesTitle = tmdbShowMetadata?.episodesTitle ?: syntheticEpisodes.takeIf { it.isNotEmpty() }?.let { "Episodes" },
        episodes = tmdbShowMetadata?.episodes ?: syntheticEpisodes,
        progressTarget = tmdbMatch?.target,
    )
}

private data class HydratedTmdbShowMetadata(
    val episodesTitle: String?,
    val episodes: List<DetailEpisodeEntry>,
    val cast: List<DetailCastEntry>,
    val contentRating: String?,
)

private suspend fun TmdbService.playableSeasonDetails(
    showId: Int,
    seasons: List<TMDBSeason>,
    preferredSeasonNumber: Int? = null,
): List<TMDBSeasonDetail> = coroutineScope {
    val selectedSeasons = preferredSeasonNumber
        ?.let { preferred -> seasons.filter { season -> season.seasonNumber == preferred && season.episodeCount > 0 } }
        .orEmpty()
    val fallbackSeasons = seasons
        .filter { season -> season.seasonNumber > 0 && season.episodeCount > 0 }
        .take(8)
    val seasonsToLoad = selectedSeasons.ifEmpty { fallbackSeasons }

    seasonsToLoad
        .map { season ->
            async { seasonDetail(showId, season.seasonNumber).orNull() }
        }
        .mapNotNull { deferred -> deferred.await() }
        .filter { season -> season.episodes.isNotEmpty() }
}

private suspend fun TmdbService.allRealSeasonEpisodes(
    showId: Int,
    seasons: List<TMDBSeason>,
): List<TMDBSeasonDetail> = coroutineScope {
    seasons
        .filter { season -> season.seasonNumber > 0 && season.episodeCount > 0 }
        .sortedBy(TMDBSeason::seasonNumber)
        .map { season -> async { seasonDetail(showId, season.seasonNumber).orNull() } }
        .mapNotNull { deferred -> deferred.await() }
        .filter { season -> season.episodes.isNotEmpty() }
        .sortedBy(TMDBSeasonDetail::seasonNumber)
}

private fun List<TMDBSeasonDetail>.title(showName: String): String? = when {
    isEmpty() -> null
    size == 1 -> first().name.ifBlank { "$showName Episodes" }
    else -> "Episodes"
}

private fun dev.soupy.eclipse.android.core.model.TMDBCreditsResponse?.toDetailCastEntries(): List<DetailCastEntry> =
    this?.cast.orEmpty()
        .sortedBy(TMDBCastMember::order)
        .take(12)
        .map { member ->
            DetailCastEntry(
                id = "cast-${member.id}-${member.order}",
                name = member.name,
                role = member.character.takeIf { it.isNotBlank() },
                imageUrl = member.fullProfileUrl,
            )
        }

private fun formatRuntime(minutes: Int): String =
    if (minutes < 60) {
        "${minutes}m"
    } else {
        val hours = minutes / 60
        val remainder = minutes % 60
        if (remainder > 0) "${hours}h ${remainder}m" else "${hours}h"
    }

private fun AniListMedia.syntheticAnimeEpisodes(): List<DetailEpisodeEntry> {
    val count = episodes ?: nextAiringEpisode?.episode?.minus(1) ?: 0
    return (1..count.coerceAtMost(24)).map { episode ->
        DetailEpisodeEntry(
            id = "anilist-$id-episode-$episode",
            title = "Episode $episode",
            subtitle = "Episode $episode",
            imageUrl = posterUrl,
            overview = null,
            seasonNumber = 1,
            episodeNumber = episode,
        )
    }
}

private fun AniListMedia.toAnimeDetailEpisodeEntries(
    tmdbMatch: AnimeTmdbMatch,
    seasonDetails: List<TMDBSeasonDetail>,
): List<DetailEpisodeEntry>? {
    val mappedEpisodes = tmdbMatch.episodeMappings
        .filter { mapping -> mapping.anilistMediaId == id }
        .ifEmpty { emptyList() }
    val tmdbSeasonNumber = tmdbMatch.tmdbSeasonNumber
        ?: mappedEpisodes.firstOrNull()?.tmdbSeasonNumber
        ?: return null
    val seasonDetail = seasonDetails.firstOrNull { it.seasonNumber == tmdbSeasonNumber } ?: return null
    val tmdbEpisodes = seasonDetail.episodes
        .filter { it.episodeNumber > 0 }
        .sortedBy(TMDBEpisode::episodeNumber)
    val expectedCount = effectiveEpisodeCount() ?: tmdbEpisodes.size
    if (expectedCount <= 0) return null

    val localSeasonNumber = tmdbSeasonNumber
    val offset = tmdbMatch.tmdbEpisodeOffset.coerceAtLeast(0)
    val mappingsByLocalEpisode = mappedEpisodes.associateBy(AnimeEpisodeMapping::localEpisodeNumber)
    return (1..expectedCount.coerceAtMost(200)).map { localEpisodeNumber ->
        val mapping = mappingsByLocalEpisode[localEpisodeNumber]
        val resolvedSeasonNumber = mapping?.tmdbSeasonNumber ?: tmdbSeasonNumber
        val resolvedTmdbEpisodeNumber = mapping?.tmdbEpisodeNumber ?: (localEpisodeNumber + offset)
        val tmdbEpisode = tmdbEpisodes.firstOrNull { episode ->
            episode.seasonNumber == resolvedSeasonNumber && episode.episodeNumber == resolvedTmdbEpisodeNumber
        } ?: tmdbEpisodes.getOrNull(localEpisodeNumber - 1 + offset)
        DetailEpisodeEntry(
            id = "anilist-$id-s$localSeasonNumber-e$localEpisodeNumber-tmdb-$resolvedSeasonNumber-$resolvedTmdbEpisodeNumber",
            title = tmdbEpisode?.name?.takeIf { it.isNotBlank() } ?: "Episode $localEpisodeNumber",
            subtitle = buildList {
                add("S$localSeasonNumber")
                add("E$localEpisodeNumber")
                if (resolvedSeasonNumber != localSeasonNumber || resolvedTmdbEpisodeNumber != localEpisodeNumber) {
                    add("TMDB S${resolvedSeasonNumber}E${resolvedTmdbEpisodeNumber}")
                }
                if (mapping?.isSpecial == true) add("Special")
                tmdbEpisode?.runtime?.takeIf { it > 0 }?.let { add(formatRuntime(it)) }
                tmdbEpisode?.airDate?.takeIf { it.isNotBlank() }?.let(::add)
            }.joinToString(" | "),
            imageUrl = tmdbEpisode?.fullStillUrl,
            overview = tmdbEpisode?.overview,
            seasonNumber = localSeasonNumber,
            episodeNumber = localEpisodeNumber,
            runtimeMinutes = tmdbEpisode?.runtime,
            tmdbSeasonNumber = resolvedSeasonNumber,
            tmdbEpisodeNumber = resolvedTmdbEpisodeNumber,
        )
    }
}

private fun AniListMedia.effectiveEpisodeCount(): Int? =
    episodes?.takeIf { it > 0 }
        ?: nextAiringEpisode?.episode?.minus(1)?.takeIf { it > 0 }

private fun String?.specialFormatLabel(): String =
    this
        ?.replace('_', ' ')
        ?.lowercase()
        ?.replaceFirstChar { char -> if (char.isLowerCase()) char.titlecase() else char.toString() }
        ?: "Special"

private fun tmdbPosterUrl(path: String): String = "https://image.tmdb.org/t/p/w780$path"

private fun animeYearAlignmentScore(animeYear: Int?, tmdbYear: Int?): Double {
    if (animeYear == null || tmdbYear == null) return 0.0
    return when (abs(animeYear - tmdbYear)) {
        0 -> 0.16
        1 -> 0.08
        2 -> 0.03
        else -> 0.0
    }
}

private fun animeEpisodeCountScore(animeEpisodes: Int?, tmdbEpisodes: Int?): Double {
    if (animeEpisodes == null || tmdbEpisodes == null || animeEpisodes <= 0 || tmdbEpisodes <= 0) {
        return 0.0
    }
    val diff = abs(animeEpisodes - tmdbEpisodes)
    val maxEpisodes = maxOf(animeEpisodes, tmdbEpisodes).toDouble()
    return when {
        diff == 0 -> 0.14
        diff <= 2 -> 0.10
        diff.toDouble() / maxEpisodes <= 0.15 -> 0.06
        diff.toDouble() / maxEpisodes <= 0.35 -> 0.02
        else -> -0.04
    }
}

