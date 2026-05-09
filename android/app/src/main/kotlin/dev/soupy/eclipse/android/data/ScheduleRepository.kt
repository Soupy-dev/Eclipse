package dev.soupy.eclipse.android.data

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import dev.soupy.eclipse.android.core.model.ScheduleDaySection
import dev.soupy.eclipse.android.core.network.AniListService

class ScheduleRepository(
    private val aniListService: AniListService,
) {
    suspend fun loadSchedule(
        daysAhead: Int = 7,
        localTimeZone: Boolean = true,
    ): Result<List<ScheduleDaySection>> = runCatching {
        val schedule = aniListService.fetchAiringSchedule(daysAhead = daysAhead).orThrow()
        val zoneId = if (localTimeZone) ZoneId.systemDefault() else ZoneId.of("UTC")
        val today = LocalDate.now(zoneId)
        val fullDateFormatter = DateTimeFormatter.ofPattern("EEEE, MMM d", Locale.US)

        schedule
            .groupBy { Instant.ofEpochSecond(it.airingAtEpochSeconds).atZone(zoneId).toLocalDate() }
            .toSortedMap()
            .map { (date, entries) ->
                val title = when (date) {
                    today -> "Today"
                    today.plusDays(1) -> "Tomorrow"
                    else -> date.format(DateTimeFormatter.ofPattern("EEEE", Locale.US))
                }
                ScheduleDaySection(
                    id = date.toString(),
                    title = title,
                    subtitle = date.format(fullDateFormatter),
                    items = entries.sortedBy { it.airingAtEpochSeconds }.map { it.toScheduleEntryCard(zoneId) },
                )
            }
    }
}


