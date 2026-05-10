package dev.soupy.eclipse.android.data

import dev.soupy.eclipse.android.core.model.SimilarityAlgorithm
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

internal fun titleMatchScore(
    expectedTitles: List<String>,
    candidateText: String,
    algorithm: SimilarityAlgorithm,
): Double {
    val candidate = candidateText.normalizedForMatching()
    if (candidate.isBlank()) return 0.0

    return expectedTitles
        .asSequence()
        .map(String::normalizedForMatching)
        .filter(String::isNotBlank)
        .map { expected -> expected.similarityTo(candidate, algorithm) }
        .maxOrNull()
        ?.coerceIn(0.0, 1.0)
        ?: 0.0
}

private fun String.similarityTo(other: String, algorithm: SimilarityAlgorithm): Double =
    when (algorithm) {
        SimilarityAlgorithm.JARO_WINKLER -> jaroWinkler(this, other)
        SimilarityAlgorithm.LEVENSHTEIN -> normalizedLevenshtein(this, other)
        SimilarityAlgorithm.HYBRID -> hybridSimilarity(this, other)
    }

private fun hybridSimilarity(left: String, right: String): Double {
    val jaroScore = jaroWinkler(left, right)
    val editScore = normalizedLevenshtein(left, right)
    val averageLength = (left.length + right.length) / 2.0
    val lengthDifference = abs(left.length - right.length)
    val lengthRatio = if (averageLength > 0.0) lengthDifference / averageLength else 0.0
    val prefixSimilarity = prefixSimilarity(left, right)

    val (jaroWeight, editWeight) = when {
        averageLength < 10.0 || prefixSimilarity > 0.7 -> 0.7 to 0.3
        averageLength > 50.0 -> 0.3 to 0.7
        lengthRatio > 0.5 -> 0.4 to 0.6
        else -> 0.5 to 0.5
    }
    val weighted = jaroScore * jaroWeight + editScore * editWeight
    val agreementBonus = if (1.0 - abs(jaroScore - editScore) > 0.8) 0.05 else 0.0
    val averageScore = (jaroScore + editScore) / 2.0
    val lowScorePenalty = if (averageScore < 0.3) 0.05 else 0.0

    return (weighted + agreementBonus - lowScorePenalty).coerceIn(0.0, 1.0)
}

private fun String.normalizedForMatching(): String =
    trim()
        .lowercase()
        .replace(Regex("[^a-z0-9\\s]"), "")

private fun prefixSimilarity(left: String, right: String): Double {
    val minLength = min(left.length, right.length)
    if (minLength == 0) return 0.0
    var commonPrefixLength = 0
    for (index in 0 until min(minLength, 10)) {
        if (left[index] == right[index]) {
            commonPrefixLength += 1
        } else {
            break
        }
    }
    return commonPrefixLength.toDouble() / min(minLength, 10).toDouble()
}

private fun normalizedLevenshtein(left: String, right: String): Double {
    if (left == right) return 1.0
    if (left.isBlank() || right.isBlank()) return 0.0

    val distance = levenshteinDistance(left, right)
    val maxLength = max(left.length, right.length).coerceAtLeast(1)
    return (1.0 - distance.toDouble() / maxLength).coerceIn(0.0, 1.0)
}

private fun levenshteinDistance(left: String, right: String): Int {
    val previous = IntArray(right.length + 1) { it }
    val current = IntArray(right.length + 1)

    for (leftIndex in 1..left.length) {
        current[0] = leftIndex
        for (rightIndex in 1..right.length) {
            val substitutionCost = if (left[leftIndex - 1] == right[rightIndex - 1]) 0 else 1
            current[rightIndex] = min(
                min(current[rightIndex - 1] + 1, previous[rightIndex] + 1),
                previous[rightIndex - 1] + substitutionCost,
            )
        }
        for (index in previous.indices) {
            previous[index] = current[index]
        }
    }

    return previous[right.length]
}

private fun jaroWinkler(left: String, right: String): Double {
    if (left == right) return 1.0
    if (left.isBlank() || right.isBlank()) return 0.0

    val matchDistance = (max(left.length, right.length) / 2 - 1).coerceAtLeast(0)
    val leftMatches = BooleanArray(left.length)
    val rightMatches = BooleanArray(right.length)
    var matches = 0

    for (leftIndex in left.indices) {
        val start = max(0, leftIndex - matchDistance)
        val end = min(leftIndex + matchDistance + 1, right.length)
        for (rightIndex in start until end) {
            if (rightMatches[rightIndex] || left[leftIndex] != right[rightIndex]) continue
            leftMatches[leftIndex] = true
            rightMatches[rightIndex] = true
            matches += 1
            break
        }
    }

    if (matches == 0) return 0.0

    var rightIndex = 0
    var transpositions = 0
    for (leftIndex in left.indices) {
        if (!leftMatches[leftIndex]) continue
        while (!rightMatches[rightIndex]) rightIndex += 1
        if (left[leftIndex] != right[rightIndex]) transpositions += 1
        rightIndex += 1
    }

    val matchCount = matches.toDouble()
    val jaro = (
        matchCount / left.length +
            matchCount / right.length +
            (matchCount - transpositions / 2.0) / matchCount
        ) / 3.0
    val prefixLength = left.zip(right).takeWhile { (a, b) -> a == b }.take(4).size

    return if (jaro < 0.7) {
        jaro
    } else {
        (jaro + prefixLength * 0.1 * (1.0 - jaro)).coerceIn(0.0, 1.0)
    }
}
