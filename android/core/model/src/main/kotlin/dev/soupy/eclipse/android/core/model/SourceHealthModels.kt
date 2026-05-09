package dev.soupy.eclipse.android.core.model

import kotlinx.serialization.Serializable

@Serializable
enum class SourceHealthStatus {
    UNCHECKED,
    HEALTHY,
    UNHEALTHY,
}

@Serializable
data class SourceHealthRecord(
    val sourceId: String,
    val sourceName: String,
    val endpointStatus: SourceHealthStatus = SourceHealthStatus.UNCHECKED,
    val endpointReason: String? = null,
    val lastEndpointCheckedAt: Long? = null,
    val lastPlaybackSuccessAt: Long? = null,
    val lastPlaybackFailureAt: Long? = null,
    val playbackFailureReason: String? = null,
    val lastNoInternetSkipAt: Long? = null,
)

@Serializable
data class SourceHealthSnapshot(
    val records: Map<String, SourceHealthRecord> = emptyMap(),
    val lastDailyCheckAt: Long? = null,
)

enum class SourceHealthDisplayKind {
    UNCHECKED,
    HEALTHY,
    STALE,
    WARNING,
    PLAYBACK_ISSUE,
}

data class SourceHealthDisplayState(
    val kind: SourceHealthDisplayKind,
    val label: String,
    val warningText: String? = null,
)

fun SourceHealthSnapshot.displayStateFor(sourceId: String, now: Long = System.currentTimeMillis()): SourceHealthDisplayState {
    val record = records[sourceId] ?: return SourceHealthDisplayState(
        kind = SourceHealthDisplayKind.UNCHECKED,
        label = "Unchecked",
    )
    val endpointFresh = record.lastEndpointCheckedAt?.let { checkedAt ->
        now - checkedAt < EndpointFreshMillis
    } ?: false
    if (record.endpointStatus == SourceHealthStatus.UNHEALTHY && endpointFresh) {
        val reason = record.endpointReason ?: "Source endpoint is unreachable"
        return SourceHealthDisplayState(
            kind = SourceHealthDisplayKind.WARNING,
            label = "Unhealthy",
            warningText = reason,
        )
    }

    val failureDate = record.lastPlaybackFailureAt
    val successDate = record.lastPlaybackSuccessAt ?: Long.MIN_VALUE
    if (failureDate != null && now - failureDate < PlaybackIssueFreshMillis && successDate < failureDate) {
        val reason = record.playbackFailureReason ?: "Recent playback failed"
        return SourceHealthDisplayState(
            kind = SourceHealthDisplayKind.PLAYBACK_ISSUE,
            label = "Playback issue",
            warningText = reason,
        )
    }

    if (record.endpointStatus == SourceHealthStatus.HEALTHY && endpointFresh) {
        return SourceHealthDisplayState(
            kind = SourceHealthDisplayKind.HEALTHY,
            label = "Healthy",
        )
    }

    if (record.lastEndpointCheckedAt != null) {
        return SourceHealthDisplayState(
            kind = SourceHealthDisplayKind.STALE,
            label = "Stale",
        )
    }

    return SourceHealthDisplayState(
        kind = SourceHealthDisplayKind.UNCHECKED,
        label = "Unchecked",
    )
}

fun SourceHealthSnapshot.warningTextFor(sourceId: String): String? =
    displayStateFor(sourceId).warningText

fun SourceHealthSnapshot.shouldSkipForAutoMode(sourceId: String, now: Long = System.currentTimeMillis()): Boolean {
    val record = records[sourceId] ?: return false
    val checkedAt = record.lastEndpointCheckedAt ?: return false
    return record.endpointStatus == SourceHealthStatus.UNHEALTHY && now - checkedAt < EndpointFreshMillis
}

private const val EndpointFreshMillis = 36L * 60L * 60L * 1_000L
private const val PlaybackIssueFreshMillis = 24L * 60L * 60L * 1_000L
