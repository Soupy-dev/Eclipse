package dev.soupy.eclipse.android.core.storage

import android.content.Context
import dev.soupy.eclipse.android.core.model.CatalogSnapshot
import kotlinx.serialization.json.Json

class CatalogStore(
    context: Context,
    json: Json,
) {
    private val store = JsonFileStore(
        context = context,
        relativePath = "catalog/catalogs.json",
        serializer = CatalogSnapshot.serializer(),
        json = json,
    )

    suspend fun read(): CatalogSnapshot = store.read() ?: CatalogSnapshot()

    suspend fun write(snapshot: CatalogSnapshot) {
        store.write(snapshot)
    }
}

