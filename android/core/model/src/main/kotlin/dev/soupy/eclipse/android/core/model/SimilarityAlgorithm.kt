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
        description = "Balances prefix similarity and edit distance for mixed media titles.",
    ),
    JARO_WINKLER(
        id = "jaro_winkler",
        displayName = "Jaro-Winkler",
        description = "Prefers short names and titles that share the same beginning.",
    ),
    LEVENSHTEIN(
        id = "levenshtein",
        displayName = "Levenshtein",
        description = "Prefers titles with the fewest edits between them.",
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
