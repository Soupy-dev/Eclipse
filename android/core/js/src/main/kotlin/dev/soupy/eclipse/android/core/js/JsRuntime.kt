package dev.soupy.eclipse.android.core.js

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

interface JsEngine {
    suspend fun execute(request: ScriptExecutionRequest): Result<ScriptExecutionResult>
}

interface WebViewSessionBroker {
    suspend fun fetch(request: WebViewBridgeRequest): Result<WebViewBridgeResponse>
}

interface ServiceRuntime {
    suspend fun load(source: ServiceRuntimeSource): Result<Unit>
    suspend fun search(request: ServiceSearchRequest): Result<List<ServiceSearchResult>>
    suspend fun details(source: ServiceRuntimeSource, href: String): Result<JsonObject>
    suspend fun episodes(source: ServiceRuntimeSource, href: String): Result<List<ServiceEpisodeLink>>
    suspend fun stream(source: ServiceRuntimeSource, href: String, softSub: Boolean = false): Result<ServiceStreamResult>
    fun parseSettings(script: String): List<ServiceSettingDescriptor>
}

interface KanzenModuleRuntime {
    suspend fun load(module: ModuleManifest, script: String, isNovel: Boolean = false): Result<Unit>
    suspend fun search(module: ModuleManifest, query: String, page: Int = 0): Result<List<ServiceSearchResult>>
    suspend fun details(module: ModuleManifest, params: JsonElement): Result<JsonObject>
    suspend fun chapters(module: ModuleManifest, params: JsonElement): Result<List<ServiceEpisodeLink>>
    suspend fun images(module: ModuleManifest, params: JsonElement): Result<List<String>>
    suspend fun text(module: ModuleManifest, params: JsonElement): Result<String>
}

class NoopJsEngine : JsEngine {
    override suspend fun execute(request: ScriptExecutionRequest): Result<ScriptExecutionResult> =
        Result.success(
            ScriptExecutionResult(
                logs = listOf(
                    "No JS runtime has been plugged in yet.",
                    "This boundary is ready for a sideload-first runtime such as QuickJS plus a dedicated WebView helper layer.",
                ),
            ),
        )
}

data class ServiceSettingDescriptor(
    val key: String,
    val label: String,
    val type: ServiceSettingType,
    val defaultValue: String,
    val comment: String? = null,
    val options: List<String> = emptyList(),
)

enum class ServiceSettingType {
    TEXT,
    BOOLEAN,
    NUMBER,
    SELECT,
}

