package dev.soupy.eclipse.android.core.model

import kotlinx.serialization.Serializable

@Serializable
enum class SimilarityAlgorithm(
    val id: String,
    val displayName: String,
    val description: String,
) {
    HYBRID(
        id = "hybrid",
        displayName = "Hybrid",
        description = "Combines both algorithms for optimal matching across different string types and lengths.",
    ),
    JARO_WINKLER(
        id = "jaro_winkler",
        displayName = "Jaro-Winkler Similarity",
        description = "When matching names, titles, or short strings where prefix similarity are important.",
    ),
    LEVENSHTEIN(
        id = "levenshtein",
        displayName = "Levenshtein Distance",
        description = "When you need precise differences across all text available.",
    );

    companion object {
        fun fromId(value: String?): SimilarityAlgorithm {
            val normalized = value?.trim().orEmpty()
            return entries.firstOrNull { algorithm ->
                algorithm.id.equals(normalized, ignoreCase = true) ||
                    algorithm.name.equals(normalized, ignoreCase = true)
            } ?: HYBRID
        }
    }
}
