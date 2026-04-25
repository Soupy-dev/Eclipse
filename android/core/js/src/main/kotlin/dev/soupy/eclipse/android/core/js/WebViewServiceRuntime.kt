package dev.soupy.eclipse.android.core.js

import android.annotation.SuppressLint
import android.content.Context
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.webkit.WebViewClient
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

private const val ServiceRuntimeTimeoutMs = 20_000L

class WebViewServiceRuntime(
    context: Context,
) : ServiceRuntime {
    private val appContext = context.applicationContext
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
    }

    override suspend fun load(source: ServiceRuntimeSource): Result<Unit> = runCatching {
        require(source.script.isNotBlank()) { "Service script is empty." }
    }

    override suspend fun search(request: ServiceSearchRequest): Result<List<ServiceSearchResult>> = runCatching {
        val raw = evaluate(
            source = request.source,
            invocation = "return searchResults(${request.query.jsQuoted()});",
        )
        parseSearchResults(raw)
    }

    override suspend fun details(source: ServiceRuntimeSource, href: String): Result<JsonObject> = runCatching {
        val raw = evaluate(
            source = source,
            invocation = "return extractDetails(${href.jsQuoted()});",
        )
        val element = parseJsonElement(raw)
        when (element) {
            is JsonObject -> element
            is JsonArray -> JsonObject(mapOf("items" to element))
            else -> JsonObject(mapOf("value" to element))
        }
    }

    override suspend fun episodes(source: ServiceRuntimeSource, href: String): Result<List<ServiceEpisodeLink>> = runCatching {
        val raw = evaluate(
            source = source,
            invocation = "return extractEpisodes(${href.jsQuoted()});",
        )
        parseEpisodeLinks(raw)
    }

    override suspend fun stream(
        source: ServiceRuntimeSource,
        href: String,
        softSub: Boolean,
    ): Result<ServiceStreamResult> = runCatching {
        val raw = evaluate(
            source = source,
            invocation = "return extractStreamUrl(${href.jsQuoted()}, ${softSub.toString()});",
        )
        parseStreamResult(raw)
    }

    override fun parseSettings(script: String): List<ServiceSettingDescriptor> {
        val lines = script.lineSequence().toList()
        val settingRegex = Regex("""const\s+(\w+)\s*=\s*([^;]+);""")
        val optionRegex = Regex("""\[(.*)]""")
        var inSettings = false
        return buildList {
            for (line in lines) {
                val trimmed = line.trim()
                when {
                    trimmed.contains("// Settings start", ignoreCase = true) -> {
                        inSettings = true
                        continue
                    }
                    trimmed.contains("// Settings end", ignoreCase = true) -> break
                    !inSettings || !trimmed.startsWith("const ") -> continue
                }
                val match = settingRegex.find(trimmed) ?: continue
                val key = match.groupValues[1]
                val rawValue = match.groupValues[2].trim()
                val comment = trimmed.substringAfter("//", "").trim()
                val options = optionRegex.find(comment)
                    ?.groupValues
                    ?.getOrNull(1)
                    ?.split(',')
                    ?.map { it.trim().trim('"', '\'') }
                    ?.filter { it.isNotBlank() }
                    .orEmpty()
                add(
                    ServiceSettingDescriptor(
                        key = key,
                        label = key.replace('_', ' ').replaceFirstChar(Char::titlecase),
                        type = rawValue.toSettingType(options),
                        defaultValue = rawValue.trim('"', '\''),
                        options = options,
                    ),
                )
            }
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private suspend fun evaluate(
        source: ServiceRuntimeSource,
        invocation: String,
    ): String = withContext(Dispatchers.Main) {
        val callId = UUID.randomUUID().toString()
        val result = CompletableDeferred<Result<String>>()
        lateinit var webView: WebView
        val bridge = ServiceBridge(callId, result)

        try {
            webView = WebView(appContext).apply {
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                addJavascriptInterface(bridge, "EclipseAndroidBridge")
                webViewClient = object : WebViewClient() {
                    override fun onPageFinished(view: WebView, url: String?) {
                        view.evaluateJavascript(source.toInvocationScript(callId, invocation), null)
                    }
                }
            }
            webView.loadDataWithBaseURL(
                source.baseUrl ?: "https://eclipse.local/",
                "<!doctype html><html><head><meta charset=\"utf-8\"></head><body></body></html>",
                "text/html",
                "UTF-8",
                null,
            )
            withTimeout(ServiceRuntimeTimeoutMs) {
                result.await().getOrThrow()
            }
        } finally {
            runCatching {
                webView.removeJavascriptInterface("EclipseAndroidBridge")
                webView.destroy()
            }
        }
    }

    private fun parseSearchResults(raw: String): List<ServiceSearchResult> {
        val element = parseJsonElement(raw)
        val array = when (element) {
            is JsonArray -> element
            is JsonObject -> element["results"] as? JsonArray ?: element["items"] as? JsonArray ?: JsonArray(emptyList())
            else -> JsonArray(emptyList())
        }
        return array.mapNotNull { item ->
            val obj = item as? JsonObject ?: return@mapNotNull null
            val title = obj.stringValue("title") ?: obj.stringValue("name") ?: return@mapNotNull null
            val href = obj.stringValue("href") ?: obj.stringValue("url") ?: return@mapNotNull null
            ServiceSearchResult(
                title = title,
                href = href,
                image = obj.stringValue("image") ?: obj.stringValue("imageUrl") ?: obj.stringValue("poster"),
                subtitle = obj.stringValue("subtitle") ?: obj.stringValue("description"),
                metadata = obj,
            )
        }
    }

    private fun parseEpisodeLinks(raw: String): List<ServiceEpisodeLink> {
        val element = parseJsonElement(raw)
        val array = when (element) {
            is JsonArray -> element
            is JsonObject -> element["episodes"] as? JsonArray ?: element["items"] as? JsonArray ?: JsonArray(emptyList())
            else -> JsonArray(emptyList())
        }
        return array.mapIndexedNotNull { index, item ->
            val obj = item as? JsonObject ?: return@mapIndexedNotNull null
            val href = obj.stringValue("href") ?: obj.stringValue("url") ?: return@mapIndexedNotNull null
            val number = obj.intValue("number") ?: obj.intValue("episode") ?: index + 1
            ServiceEpisodeLink(
                title = obj.stringValue("title") ?: "Episode $number",
                href = href,
                seasonNumber = obj.intValue("seasonNumber") ?: obj.intValue("season"),
                episodeNumber = number,
                metadata = obj,
            )
        }
    }

    private fun parseStreamResult(raw: String): ServiceStreamResult {
        val element = parseJsonElement(raw)
        return when (element) {
            is JsonObject -> {
                val streamStrings = buildList {
                    element["stream"]?.primitiveString()?.let(::add)
                    element["streams"]?.let { streams ->
                        when (streams) {
                            is JsonArray -> streams.forEach { stream ->
                                stream.primitiveString()?.let(::add)
                            }
                            else -> streams.primitiveString()?.let(::add)
                        }
                    }
                }
                val sourceObjects = buildList {
                    element["stream"]?.jsonObjectOrNull()?.let(::add)
                    element["streams"]?.let { streams ->
                        when (streams) {
                            is JsonArray -> streams.forEach { stream ->
                                stream.jsonObjectOrNull()?.let(::add)
                            }
                            else -> streams.jsonObjectOrNull()?.let(::add)
                        }
                    }
                    element["sources"]?.let { sources ->
                        (sources as? JsonArray)?.forEach { source -> source.jsonObjectOrNull()?.let(::add) }
                    }
                }
                ServiceStreamResult(
                    streams = streamStrings,
                    subtitles = element.subtitleStrings(),
                    sources = sourceObjects,
                    headers = element["headers"]?.jsonObjectOrNull()?.mapValues { (_, value) ->
                        value.jsonPrimitive.contentOrNull.orEmpty()
                    }.orEmpty(),
                    defaultSubtitle = element.stringValue("defaultSubtitle"),
                )
            }
            is JsonArray -> ServiceStreamResult(streams = element.mapNotNull(JsonElement::primitiveString))
            else -> ServiceStreamResult(streams = listOfNotNull(element.primitiveString()))
        }
    }

    private fun parseJsonElement(raw: String): JsonElement {
        val clean = raw.trim()
        if (clean.isBlank()) return JsonNull
        return runCatching { json.parseToJsonElement(clean) }
            .recoverCatching {
                val decodedString = json.decodeFromString<String>(clean)
                json.parseToJsonElement(decodedString)
            }
            .getOrElse {
                JsonPrimitive(clean)
            }
    }
}

private class ServiceBridge(
    private val callId: String,
    private val result: CompletableDeferred<Result<String>>,
) {
    @JavascriptInterface
    fun resolve(id: String, value: String?) {
        if (id == callId && !result.isCompleted) {
            result.complete(Result.success(value.orEmpty()))
        }
    }

    @JavascriptInterface
    fun reject(id: String, message: String?) {
        if (id == callId && !result.isCompleted) {
            result.complete(Result.failure(IllegalStateException(message ?: "JavaScript service failed.")))
        }
    }
}

private fun ServiceRuntimeSource.toInvocationScript(
    callId: String,
    invocation: String,
): String {
    val settingsJson = settings.toString()
    return """
        (async function() {
          try {
            const module = {};
            const exports = module.exports = {};
            const serviceSettings = $settingsJson;
            window.serviceSettings = serviceSettings;
            ${script}
            const value = await (async function() { $invocation })();
            const encoded = typeof value === 'string' ? value : JSON.stringify(value ?? null);
            EclipseAndroidBridge.resolve(${callId.jsQuoted()}, String(encoded ?? ''));
          } catch (error) {
            EclipseAndroidBridge.reject(${callId.jsQuoted()}, String((error && (error.stack || error.message)) || error));
          }
        })();
    """.trimIndent()
}

private fun JsonObject.stringValue(key: String): String? =
    this[key]?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotBlank() }

private fun JsonObject.intValue(key: String): Int? =
    this[key]?.jsonPrimitive?.intOrNull

private fun JsonElement.primitiveString(): String? =
    (this as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotBlank() }

private fun JsonElement.jsonObjectOrNull(): JsonObject? =
    this as? JsonObject

private fun JsonObject.subtitleStrings(): List<String> {
    val subtitles = this["subtitles"] ?: return emptyList()
    return when (subtitles) {
        is JsonArray -> subtitles.mapNotNull { subtitle ->
            when (subtitle) {
                is JsonObject -> subtitle.stringValue("url") ?: subtitle.stringValue("href")
                else -> subtitle.primitiveString()
            }
        }
        else -> listOfNotNull(subtitles.primitiveString())
    }
}

private fun String.jsQuoted(): String =
    buildString {
        append('"')
        this@jsQuoted.forEach { char ->
            when (char) {
                '\\' -> append("\\\\")
                '"' -> append("\\\"")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                else -> append(char)
            }
        }
        append('"')
    }

private fun String.toSettingType(options: List<String>): ServiceSettingType = when {
    options.isNotEmpty() -> ServiceSettingType.SELECT
    equals("true", ignoreCase = true) || equals("false", ignoreCase = true) -> ServiceSettingType.BOOLEAN
    trim().trim('"', '\'').toDoubleOrNull() != null -> ServiceSettingType.NUMBER
    else -> ServiceSettingType.TEXT
}
