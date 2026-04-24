package dev.soupy.eclipse.android.data

import dev.soupy.eclipse.android.core.model.AniListMedia
import dev.soupy.eclipse.android.core.model.DetailTarget
import dev.soupy.eclipse.android.core.model.TMDBSearchResult
import dev.soupy.eclipse.android.core.model.TMDBSeason
import dev.soupy.eclipse.android.core.model.TMDBTVShowDetail
import dev.soupy.eclipse.android.core.model.displayDate
import dev.soupy.eclipse.android.core.model.displayTitle
import dev.soupy.eclipse.android.core.model.isMovie
import dev.soupy.eclipse.android.core.model.isTVShow
import dev.soupy.eclipse.android.core.model.relationEdges
import dev.soupy.eclipse.android.core.network.TmdbService
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

data class AnimeTmdbMatch(
    val target: DetailTarget,
    val tmdbId: Int,
    val mediaType: String,
    val title: String,
    val matchedQuery: String,
    val confidence: Double,
    val sourceAniListId: Int,
    val sourceTitle: String,
    val sourceRelationType: String? = null,
    val tmdbSeasonNumber: Int? = null,
    val tmdbEpisodeOffset: Int = 0,
)

internal data class AnimeTmdbSeasonMatch(
    val seasonNumber: Int,
    val episodeOffset: Int = 0,
    val confidence: Double,
)

class AnimeTmdbMapper(
    private val tmdbService: TmdbService,
) {
    suspend fun findBestMatch(media: AniListMedia): AnimeTmdbMatch? = coroutineScope {
        val searchSeeds = media.matchSearchSeeds()
        if (searchSeeds.isEmpty()) return@coroutineScope null

        val preferredMediaType = if (media.format.equals("MOVIE", ignoreCase = true)) "movie" else "tv"
        val preliminaryMatches = mutableListOf<AnimeTmdbMatch>()

        searchSeeds.forEach { seed ->
            seed.media.titleCandidates().take(6).forEach { query ->
                (1..2).forEach { page ->
                    val results = tmdbService.searchMulti(query = query, page = page)
                        .orNull()
                        ?.results
                        .orEmpty()
                        .filter { result -> result.isMovie || result.isTVShow }

                    results.mapNotNullTo(preliminaryMatches) { result ->
                        result.toAnimeTmdbMatch(
                            query = query,
                            sourceMedia = media,
                            searchMedia = seed.media,
                            sourceRelationType = seed.relationType,
                            preferredMediaType = preferredMediaType,
                        )
                    }
                }
            }
        }

        val uniqueMatches = preliminaryMatches
            .groupBy { "${it.mediaType}:${it.tmdbId}" }
            .mapNotNull { (_, matches) -> matches.maxByOrNull(AnimeTmdbMatch::confidence) }
            .sortedWith(
                compareByDescending<AnimeTmdbMatch> { it.confidence }
                    .thenBy { if (it.mediaType == preferredMediaType) 0 else 1 },
            )
            .take(10)

        uniqueMatches
            .map { match ->
                async {
                    match.withHydratedTvConfidence(
                        sourceMedia = media,
                        preferredMediaType = preferredMediaType,
                    )
                }
            }
            .awaitAll()
            .maxWithOrNull(
                compareBy<AnimeTmdbMatch> { it.confidence }
                    .thenBy { if (it.mediaType == preferredMediaType) 1 else 0 }
                    .thenBy { if (it.tmdbSeasonNumber != null) 1 else 0 },
            )
            ?.takeIf { it.confidence >= 0.48 }
    }

    private suspend fun AnimeTmdbMatch.withHydratedTvConfidence(
        sourceMedia: AniListMedia,
        preferredMediaType: String,
    ): AnimeTmdbMatch {
        if (mediaType != "tv") {
            val movieBoost = if (preferredMediaType == "movie") 0.06 else 0.0
            return copy(confidence = (confidence + movieBoost).coerceIn(0.0, 1.0))
        }

        val show = tmdbService.tvShowDetail(tmdbId).orNull() ?: return this
        val seasonMatch = sourceMedia.bestTmdbSeasonMatch(show)
        val showEpisodeScore = sourceMedia.totalEpisodeAlignmentScore(show)
        val hydratedConfidence = (confidence + max(seasonMatch?.confidence ?: 0.0, showEpisodeScore)).coerceIn(0.0, 1.0)

        return copy(
            confidence = hydratedConfidence,
            tmdbSeasonNumber = seasonMatch?.seasonNumber,
            tmdbEpisodeOffset = seasonMatch?.episodeOffset ?: 0,
        )
    }
}

private data class AnimeSearchSeed(
    val media: AniListMedia,
    val relationType: String?,
)

private fun AniListMedia.matchSearchSeeds(): List<AnimeSearchSeed> {
    val seeds = mutableListOf(AnimeSearchSeed(this, null))
    val relationPriority = mapOf(
        "PARENT" to 0,
        "SOURCE" to 1,
        "PREQUEL" to 2,
        "SEQUEL" to 3,
        "SEASON" to 4,
    )
    val allowedRelationTypes = relationPriority.keys

    relationEdges
        .asSequence()
        .filter { edge -> edge.relationType in allowedRelationTypes }
        .sortedBy { edge -> relationPriority[edge.relationType] ?: Int.MAX_VALUE }
        .mapNotNull { edge ->
            val node = edge.node ?: return@mapNotNull null
            if (!node.type.equals("ANIME", ignoreCase = true) && node.type != null) {
                return@mapNotNull null
            }
            AnimeSearchSeed(node, edge.relationType)
        }
        .take(8)
        .forEach(seeds::add)

    return seeds.distinctBy { "${it.relationType}:${it.media.id}" }
}

private fun TMDBSearchResult.toAnimeTmdbMatch(
    query: String,
    sourceMedia: AniListMedia,
    searchMedia: AniListMedia,
    sourceRelationType: String?,
    preferredMediaType: String,
): AnimeTmdbMatch? {
    val resultMediaType = when {
        isMovie -> "movie"
        isTVShow -> "tv"
        else -> return null
    }
    val queryScore = titleSimilarity(query, displayTitle)
    val searchTitleScore = searchMedia.titleCandidates()
        .maxOfOrNull { title -> titleSimilarity(title, displayTitle) }
        ?: queryScore
    val sourceTitleScore = sourceMedia.titleCandidates()
        .maxOfOrNull { title -> titleSimilarity(title, displayTitle) }
        ?: queryScore
    val titleScore = maxOf(queryScore, searchTitleScore, sourceTitleScore)
    val expectedYear = sourceMedia.seasonYear ?: searchMedia.seasonYear
    val yearScore = yearScore(expectedYear, displayDate?.take(4)?.toIntOrNull())
    val formatScore = when {
        resultMediaType == preferredMediaType -> 0.12
        preferredMediaType == "movie" && resultMediaType == "tv" -> -0.08
        else -> -0.03
    }
    val animationHint = if (16 in genreIds) 0.04 else 0.0
    val relationScore = relationScore(
        sourceRelationType = sourceRelationType,
        sourceMedia = sourceMedia,
        relatedMedia = searchMedia,
    )
    val confidence = (titleScore + yearScore + formatScore + animationHint + relationScore).coerceIn(0.0, 1.0)

    return AnimeTmdbMatch(
        target = if (resultMediaType == "movie") {
            DetailTarget.TmdbMovie(id)
        } else {
            DetailTarget.TmdbShow(id)
        },
        tmdbId = id,
        mediaType = resultMediaType,
        title = displayTitle,
        matchedQuery = query,
        confidence = confidence,
        sourceAniListId = sourceMedia.id,
        sourceTitle = searchMedia.displayTitle,
        sourceRelationType = sourceRelationType,
    )
}

internal fun AniListMedia.bestTmdbSeasonMatch(show: TMDBTVShowDetail): AnimeTmdbSeasonMatch? {
    val playableSeasons = show.seasons
        .filter { season -> season.seasonNumber > 0 && season.episodeCount > 0 }
        .sortedBy(TMDBSeason::seasonNumber)
    if (playableSeasons.isEmpty()) return null

    val expectedEpisodes = effectiveEpisodeCount()
    val expectedYear = seasonYear
    val hintedSeason = seasonNumberHint()

    val scoredSeasons = playableSeasons.map { season ->
        val episodeScore = episodeCountAlignmentScore(expectedEpisodes, season.episodeCount)
        val yearScore = seasonYearScore(expectedYear, season.airDate?.take(4)?.toIntOrNull())
        val hintScore = when {
            hintedSeason == null -> 0.0
            hintedSeason == season.seasonNumber -> 0.18
            else -> -0.04
        }
        val singleSeasonScore = if (playableSeasons.size == 1) 0.08 else 0.0
        val firstSeasonScore = if (hintedSeason == null && season.seasonNumber == 1 && expectedYear == null) 0.03 else 0.0
        val total = episodeScore + yearScore + hintScore + singleSeasonScore + firstSeasonScore
        season to total
    }

    val (season, score) = scoredSeasons.maxByOrNull { (_, score) -> score } ?: return null
    return AnimeTmdbSeasonMatch(
        seasonNumber = season.seasonNumber,
        confidence = score.coerceIn(0.0, 0.24),
    ).takeIf { score >= 0.08 }
}

private fun AniListMedia.totalEpisodeAlignmentScore(show: TMDBTVShowDetail): Double {
    val expectedEpisodes = effectiveEpisodeCount() ?: return 0.0
    val totalEpisodes = show.seasons
        .filter { season -> season.seasonNumber > 0 }
        .sumOf(TMDBSeason::episodeCount)
        .takeIf { it > 0 }
        ?: return 0.0
    return episodeCountAlignmentScore(expectedEpisodes, totalEpisodes).coerceAtMost(0.12)
}

internal fun AniListMedia.titleCandidates(): List<String> {
    val ordered = buildList {
        add(title.userPreferred)
        add(title.english)
        add(title.romaji)
        add(title.native)
        addAll(synonyms)
    }

    return ordered
        .filterNotNull()
        .flatMap { title ->
            listOf(
                title,
                title.withoutSeasonSuffix(),
                title.substringBefore(':').trim(),
            )
        }
        .map { it.trim().trim('[', ']') }
        .filter { it.length > 1 }
        .distinctBy { it.normalizedTitle() }
}

internal fun titleSimilarity(left: String, right: String): Double {
    val a = left.normalizedTitle()
    val b = right.normalizedTitle()
    if (a.isEmpty() || b.isEmpty()) return 0.0
    if (a == b) return 0.72
    if (a.contains(b) || b.contains(a)) return 0.56

    val tokenScore = tokenOverlap(a, b) * 0.42
    val editScore = normalizedLevenshtein(a, b) * 0.28
    val jaroScore = jaroWinkler(a, b) * 0.18
    return tokenScore + editScore + jaroScore
}

private fun relationScore(
    sourceRelationType: String?,
    sourceMedia: AniListMedia,
    relatedMedia: AniListMedia,
): Double = when {
    sourceRelationType == null -> 0.02
    sourceMedia.isLikelySpecialEntry() && sourceRelationType in setOf("PARENT", "SOURCE", "PREQUEL") -> 0.05
    relatedMedia.effectiveEpisodeCount() != null && relatedMedia.effectiveEpisodeCount()!! > (sourceMedia.effectiveEpisodeCount() ?: 0) -> 0.01
    else -> -0.03
}

private fun AniListMedia.isLikelySpecialEntry(): Boolean {
    val normalizedFormat = format?.uppercase()
    return normalizedFormat in setOf("OVA", "ONA", "SPECIAL", "MUSIC") || (effectiveEpisodeCount() ?: Int.MAX_VALUE) <= 3
}

private fun AniListMedia.effectiveEpisodeCount(): Int? =
    episodes?.takeIf { it > 0 }
        ?: nextAiringEpisode?.episode?.minus(1)?.takeIf { it > 0 }

private fun AniListMedia.seasonNumberHint(): Int? =
    titleCandidates()
        .asSequence()
        .mapNotNull { title -> title.extractSeasonNumberHint() }
        .firstOrNull()

private fun episodeCountAlignmentScore(expectedEpisodes: Int?, actualEpisodes: Int): Double {
    if (expectedEpisodes == null || expectedEpisodes <= 0 || actualEpisodes <= 0) return 0.0
    val diff = abs(expectedEpisodes - actualEpisodes)
    val maxEpisodes = max(expectedEpisodes, actualEpisodes).toDouble()
    return when {
        diff == 0 -> 0.18
        diff == 1 -> 0.14
        diff == 2 -> 0.10
        diff.toDouble() / maxEpisodes <= 0.15 -> 0.06
        diff.toDouble() / maxEpisodes <= 0.35 -> 0.02
        else -> -min(0.08, diff.toDouble() / maxEpisodes * 0.08)
    }
}

private fun yearScore(animeYear: Int?, tmdbYear: Int?): Double {
    if (animeYear == null || tmdbYear == null) return 0.0
    val diff = abs(animeYear - tmdbYear)
    return when (diff) {
        0 -> 0.15
        1 -> 0.08
        else -> 0.0
    }
}

private fun seasonYearScore(animeYear: Int?, tmdbYear: Int?): Double {
    if (animeYear == null || tmdbYear == null) return 0.0
    val diff = abs(animeYear - tmdbYear)
    return when (diff) {
        0 -> 0.14
        1 -> 0.08
        2 -> 0.04
        else -> 0.0
    }
}

private fun tokenOverlap(left: String, right: String): Double {
    val leftTokens = left.split(' ').filter(String::isNotBlank).toSet()
    val rightTokens = right.split(' ').filter(String::isNotBlank).toSet()
    if (leftTokens.isEmpty() || rightTokens.isEmpty()) return 0.0
    val shared = leftTokens.intersect(rightTokens).size.toDouble()
    val total = leftTokens.union(rightTokens).size.toDouble()
    return shared / total
}

private fun normalizedLevenshtein(left: String, right: String): Double {
    val maxLength = max(left.length, right.length)
    if (maxLength == 0) return 1.0

    val previous = IntArray(right.length + 1) { it }
    val current = IntArray(right.length + 1)

    left.forEachIndexed { leftIndex, leftChar ->
        current[0] = leftIndex + 1
        right.forEachIndexed { rightIndex, rightChar ->
            val deletion = previous[rightIndex + 1] + 1
            val insertion = current[rightIndex] + 1
            val substitution = previous[rightIndex] + if (leftChar == rightChar) 0 else 1
            current[rightIndex + 1] = minOf(deletion, insertion, substitution)
        }
        for (index in previous.indices) {
            previous[index] = current[index]
        }
    }

    return 1.0 - (previous[right.length].toDouble() / maxLength.toDouble())
}

private fun jaroWinkler(left: String, right: String): Double {
    if (left == right) return 1.0
    if (left.isEmpty() || right.isEmpty()) return 0.0

    val matchDistance = (max(left.length, right.length) / 2 - 1).coerceAtLeast(0)
    val leftMatches = BooleanArray(left.length)
    val rightMatches = BooleanArray(right.length)
    var matches = 0

    left.indices.forEach { leftIndex ->
        val start = (leftIndex - matchDistance).coerceAtLeast(0)
        val end = (leftIndex + matchDistance + 1).coerceAtMost(right.length)
        for (rightIndex in start until end) {
            if (rightMatches[rightIndex] || left[leftIndex] != right[rightIndex]) continue
            leftMatches[leftIndex] = true
            rightMatches[rightIndex] = true
            matches++
            break
        }
    }

    if (matches == 0) return 0.0

    var transpositions = 0
    var rightIndex = 0
    left.indices.forEach { leftIndex ->
        if (!leftMatches[leftIndex]) return@forEach
        while (!rightMatches[rightIndex]) {
            rightIndex++
        }
        if (left[leftIndex] != right[rightIndex]) transpositions++
        rightIndex++
    }

    val m = matches.toDouble()
    val jaro = (m / left.length + m / right.length + (m - transpositions / 2.0) / m) / 3.0
    val prefixLength = left.zip(right).takeWhile { (a, b) -> a == b }.take(4).count()
    return jaro + prefixLength * 0.1 * (1.0 - jaro)
}

private fun String.normalizedTitle(): String = lowercase()
    .replace(Regex("[^a-z0-9\\s]"), " ")
    .replace(Regex("\\b(the|a|an)\\b"), " ")
    .replace(Regex("\\s+"), " ")
    .trim()

private fun String.withoutSeasonSuffix(): String = replace(
    Regex("\\s+(season|part)\\s+([0-9]+|[ivx]+)$", RegexOption.IGNORE_CASE),
    "",
).replace(
    Regex("\\s+([0-9]+)(st|nd|rd|th)\\s+season$", RegexOption.IGNORE_CASE),
    "",
).trim()

private fun String.extractSeasonNumberHint(): Int? {
    val patterns = listOf(
        Regex("\\bseason\\s+([0-9]+|[ivx]+)\\b", RegexOption.IGNORE_CASE),
        Regex("\\b([0-9]+|[ivx]+)(st|nd|rd|th)?\\s+season\\b", RegexOption.IGNORE_CASE),
    )
    return patterns
        .asSequence()
        .mapNotNull { pattern -> pattern.find(this)?.groupValues?.getOrNull(1) }
        .mapNotNull { value -> value.toIntOrNull() ?: value.romanNumeralToIntOrNull() }
        .firstOrNull { it > 0 }
}

private fun String.romanNumeralToIntOrNull(): Int? {
    val values = mapOf('i' to 1, 'v' to 5, 'x' to 10)
    val normalized = lowercase()
    if (normalized.any { it !in values }) return null
    var total = 0
    var previous = 0
    normalized.reversed().forEach { char ->
        val value = values[char] ?: return null
        if (value < previous) {
            total -= value
        } else {
            total += value
            previous = value
        }
    }
    return total.takeIf { it > 0 }
}
