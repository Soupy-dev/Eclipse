package dev.soupy.eclipse.android.data

import dev.soupy.eclipse.android.core.model.SimilarityAlgorithm
import kotlin.test.Test
import kotlin.test.assertTrue

class StreamMatchScorerTest {
    @Test
    fun hybridScoreKeepsIosReleaseTitleBehavior() {
        val cleanScore = titleMatchScore(
            expectedTitles = listOf("Frieren Beyond Journeys End"),
            candidateText = "Frieren Beyond Journeys End",
            algorithm = SimilarityAlgorithm.HYBRID,
        )
        val releaseTitleScore = titleMatchScore(
            expectedTitles = listOf("Frieren Beyond Journeys End"),
            candidateText = "Frieren Beyond Journeys End S01E01 1080p WEB DL x265",
            algorithm = SimilarityAlgorithm.HYBRID,
        )

        assertTrue(cleanScore > releaseTitleScore)
    }

    @Test
    fun algorithmChoiceCanChangeTitleScoring() {
        val expected = listOf("The Office")
        val candidate = "Office Space 1999 1080p"

        val jaroScore = titleMatchScore(expected, candidate, SimilarityAlgorithm.JARO_WINKLER)
        val levenshteinScore = titleMatchScore(expected, candidate, SimilarityAlgorithm.LEVENSHTEIN)

        assertTrue(jaroScore != levenshteinScore)
    }
}
