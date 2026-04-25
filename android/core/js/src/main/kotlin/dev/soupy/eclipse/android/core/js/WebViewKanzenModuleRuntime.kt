package dev.soupy.eclipse.android.core.js

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.webkit.WebViewClient
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import kotlin.coroutines.resume
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.json.JSONObject

private const val RuntimeTimeoutMs = 20_000L

class WebViewKanzenModuleRuntime(
    context: Context,
) : KanzenModuleRuntime {
    private val appContext = context.applicationContext
    private val sessions = ConcurrentHashMap<String, KanzenWebViewSession>()

    override suspend fun load(
        module: ModuleManifest,
        script: String,
        isNovel: Boolean,
    ): Result<Unit> = runCatching {
        val session = KanzenWebViewSession(
            context = appContext,
            module = module,
        )
        session.load(script = script)
        sessions[module.id]?.destroy()
        sessions[module.id] = session
    }

    override suspend fun search(
        module: ModuleManifest,
        query: String,
        page: Int,
    ): Result<List<ServiceSearchResult>> = runCatching {
        session(module).callFunction("searchResults", listOf(query, page))
            .asSearchResults()
    }

    override suspend fun details(
        module: ModuleManifest,
        params: JsonElement,
    ): Result<JsonObject> = runCatching {
        session(module).callFunction("extractDetails", listOf(params))
            .asObjectOrEmpty()
    }

    override suspend fun chapters(
        module: ModuleManifest,
        params: JsonElement,
    ): Result<List<ServiceEpisodeLink>> = runCatching {
        session(module).callFunction("extractChapters", listOf(params))
            .asChapterLinks()
    }

    override suspend fun images(
        module: ModuleManifest,
        params: JsonElement,
    ): Result<List<String>> = runCatching {
        session(module).callFunction("extractImages", listOf(params))
            .asStringList()
    }

    override suspend fun text(
        module: ModuleManifest,
        params: JsonElement,
    ): Result<String> = runCatching {
        session(module).callFunction("extractText", listOf(params))
            .asText()
    }

    private fun session(module: ModuleManifest): KanzenWebViewSession =
        sessions[module.id] ?: error("Kanzen module ${module.name} has not been loaded.")
}

private class KanzenWebViewSession(
    private val context: Context,
    private val module: ModuleManifest,
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val pendingCalls = ConcurrentHashMap<String, CompletableDeferred<String>>()
    private val fetchExecutor = Executors.newCachedThreadPool()
    private var webView: WebView? = null

    @SuppressLint("SetJavaScriptEnabled")
    suspend fun load(script: String) {
        withContext(Dispatchers.Main.immediate) {
            val view = WebView(context)
            webView = view
            view.settings.javaScriptEnabled = true
            view.settings.domStorageEnabled = true
            view.addJavascriptInterface(ResultBridge(pendingCalls), "__AndroidKanzenResult")
            view.addJavascriptInterface(
                FetchBridge(
                    webViewProvider = { webView },
                    mainHandler = mainHandler,
                    executor = fetchExecutor,
                ),
                "__AndroidKanzenFetch",
            )
            view.awaitBlankPage()
            view.evaluateRaw(fetchBootstrap())
            view.evaluateRaw(script)
            val readiness = callFunction("(() => ({ search: typeof searchResults, chapters: typeof extractChapters, images: typeof extractImages, text: typeof extractText, details: typeof extractDetails }))")
                .asObjectOrEmpty()
            require(readiness.string("search") == "function") {
                "Kanzen module ${module.name} did not expose searchResults."
            }
        }
    }

    suspend fun callFunction(
        functionName: String,
        args: List<Any?>,
    ): JsonElement {
        val expression = "$functionName(${args.joinToString(",") { it.toJsLiteral() }})"
        return callFunction("(() => $expression)")
    }

    suspend fun callFunction(expression: String): JsonElement = withTimeout(RuntimeTimeoutMs) {
        val id = UUID.randomUUID().toString()
        val deferred = CompletableDeferred<String>()
        pendingCalls[id] = deferred
        val submitted = withContext(Dispatchers.Main.immediate) {
            val script = """
                (function() {
                  const __id = ${id.jsQuote()};
                  try {
                    Promise.resolve(($expression)()).then(function(value) {
                      __AndroidKanzenResult.resolve(__id, JSON.stringify({ ok: true, value: value == null ? null : value }));
                    }).catch(function(error) {
                      __AndroidKanzenResult.resolve(__id, JSON.stringify({ ok: false, error: String((error && (error.stack || error.message)) || error) }));
                    });
                  } catch (error) {
                    __AndroidKanzenResult.resolve(__id, JSON.stringify({ ok: false, error: String((error && (error.stack || error.message)) || error) }));
                  }
                  return "submitted";
                })();
            """.trimIndent()
            webView?.evaluateRaw(script) ?: error("Kanzen WebView has been destroyed.")
        }
        require(submitted != "null") { "Kanzen WebView rejected a runtime call." }
        val raw = deferred.await()
        pendingCalls.remove(id)
        val envelope = RuntimeJson.parseToJsonElement(raw).jsonObject
        val ok = envelope["ok"]?.jsonPrimitiveOrNull()?.booleanOrNull == true
        if (!ok) {
            error(envelope.string("error") ?: "Kanzen module call failed.")
        }
        envelope["value"] ?: JsonObject(emptyMap())
    }

    fun destroy() {
        pendingCalls.values.forEach { pending ->
            pending.cancel()
        }
        pendingCalls.clear()
        fetchExecutor.shutdownNow()
        mainHandler.post {
            webView?.destroy()
            webView = null
        }
    }
}

private class ResultBridge(
    private val pendingCalls: ConcurrentHashMap<String, CompletableDeferred<String>>,
) {
    @JavascriptInterface
    fun resolve(id: String, payload: String) {
        pendingCalls.remove(id)?.complete(payload)
    }
}

private class FetchBridge(
    private val webViewProvider: () -> WebView?,
    private val mainHandler: Handler,
    private val executor: java.util.concurrent.ExecutorService,
) {
    @JavascriptInterface
    fun request(
        id: String,
        url: String,
        method: String,
        headersJson: String,
        body: String?,
    ) {
        executor.execute {
            val payload = runCatching {
                executeRequest(
                    url = url,
                    method = method,
                    headersJson = headersJson,
                    body = body,
                )
            }.getOrElse { error ->
                buildJsonObject {
                    put("ok", JsonPrimitive(false))
                    put("error", JsonPrimitive(error.message ?: error::class.java.simpleName))
                }
            }.toString()
            mainHandler.post {
                val view = webViewProvider() ?: return@post
                view.evaluateJavascript(
                    "window.__androidKanzenResolveFetch(${id.jsQuote()}, $payload);",
                    null,
                )
            }
        }
    }

    private fun executeRequest(
        url: String,
        method: String,
        headersJson: String,
        body: String?,
    ): JsonObject {
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            connection.instanceFollowRedirects = true
            connection.requestMethod = method.uppercase().takeIf { it.isNotBlank() } ?: "GET"
            connection.connectTimeout = 20_000
            connection.readTimeout = 30_000
            parseHeaders(headersJson).forEach { (name, value) ->
                connection.setRequestProperty(name, value)
            }
            if (body != null && connection.requestMethod != "GET") {
                connection.doOutput = true
                connection.outputStream.use { output ->
                    output.write(body.toByteArray(Charsets.UTF_8))
                }
            }
            val status = connection.responseCode
            val responseBody = (if (status in 200..399) connection.inputStream else connection.errorStream)
                ?.bufferedReader()
                ?.use { it.readText() }
                .orEmpty()
            val headers = connection.headerFields.orEmpty()
                .filterKeys { key -> key != null }
                .mapKeys { (key, _) -> key!!.lowercase() }
                .mapValues { (_, values) -> values.orEmpty().joinToString(",") }
            return buildJsonObject {
                put("ok", JsonPrimitive(true))
                put("status", JsonPrimitive(status))
                put("url", JsonPrimitive(url))
                put("body", JsonPrimitive(responseBody))
                put(
                    "headers",
                    JsonObject(headers.mapValues { (_, value) -> JsonPrimitive(value) }),
                )
            }
        } finally {
            connection.disconnect()
        }
    }
}

private suspend fun WebView.awaitBlankPage() {
    suspendCancellableCoroutine { continuation ->
        webViewClient = object : WebViewClient() {
            override fun onPageFinished(
                view: WebView?,
                url: String?,
            ) {
                if (continuation.isActive) continuation.resume(Unit)
            }
        }
        loadDataWithBaseURL(
            "https://kanzen.android.local/",
            "<!doctype html><html><head></head><body></body></html>",
            "text/html",
            "UTF-8",
            null,
        )
    }
}

private suspend fun WebView.evaluateRaw(script: String): String =
    suspendCancellableCoroutine { continuation ->
        evaluateJavascript(script) { raw ->
            if (continuation.isActive) {
                continuation.resume(raw?.decodeJsResultString() ?: "null")
            }
        }
    }

private fun fetchBootstrap(): String = """
    (function() {
      window.__androidKanzenFetchCallbacks = {};
      window.__androidKanzenResolveFetch = function(id, payload) {
        const callback = window.__androidKanzenFetchCallbacks[id];
        if (!callback) return;
        delete window.__androidKanzenFetchCallbacks[id];
        if (!payload || payload.ok === false) {
          callback.reject(new Error((payload && payload.error) || "Fetch failed."));
          return;
        }
        const headers = payload.headers || {};
        callback.resolve({
          ok: payload.status >= 200 && payload.status < 300,
          status: payload.status,
          url: payload.url || "",
          headers: {
            get: function(name) { return headers[String(name).toLowerCase()] || null; }
          },
          text: function() { return Promise.resolve(payload.body || ""); },
          json: function() { return Promise.resolve(JSON.parse(payload.body || "null")); }
        });
      };
      window.fetch = function(input, init) {
        init = init || {};
        const id = String(Date.now()) + "-" + String(Math.random()).slice(2);
        const url = typeof input === "string" ? input : String(input && input.url || input);
        const method = String(init.method || "GET");
        const headers = init.headers || {};
        const normalizedHeaders = {};
        if (Array.isArray(headers)) {
          headers.forEach(function(pair) { normalizedHeaders[String(pair[0])] = String(pair[1]); });
        } else if (headers && typeof headers.forEach === "function") {
          headers.forEach(function(value, key) { normalizedHeaders[String(key)] = String(value); });
        } else {
          Object.keys(headers || {}).forEach(function(key) { normalizedHeaders[String(key)] = String(headers[key]); });
        }
        const body = init.body == null ? null : String(init.body);
        return new Promise(function(resolve, reject) {
          window.__androidKanzenFetchCallbacks[id] = { resolve: resolve, reject: reject };
          __AndroidKanzenFetch.request(id, url, method, JSON.stringify(normalizedHeaders), body);
        });
      };
    })();
""".trimIndent()

private fun List<ServiceSearchResult>.takeDistinct(): List<ServiceSearchResult> =
    distinctBy { result -> result.href.ifBlank { result.title } }

private fun JsonElement.asSearchResults(): List<ServiceSearchResult> {
    val array = when (this) {
        is JsonArray -> this
        else -> jsonPrimitiveOrNull()?.contentOrNull
            ?.let { raw -> runCatching { RuntimeJson.parseToJsonElement(raw).jsonArray }.getOrNull() }
            ?: JsonArray(emptyList())
    }
    return array.mapNotNull { element ->
        val obj = element as? JsonObject ?: return@mapNotNull null
        val title = obj.string("title")
            ?: obj.string("name")
            ?: obj.string("chapterName")
            ?: return@mapNotNull null
        val href = obj.string("id")
            ?: obj.string("href")
            ?: obj.string("url")
            ?: obj.string("mangaId")
            ?: return@mapNotNull null
        ServiceSearchResult(
            title = title,
            href = href,
            image = obj.string("imageURL") ?: obj.string("image") ?: obj.string("cover") ?: obj.string("coverURL"),
            subtitle = obj.string("subtitle") ?: obj.string("description"),
            metadata = obj,
        )
    }.takeDistinct()
}

private fun JsonElement.asChapterLinks(): List<ServiceEpisodeLink> = when (this) {
    is JsonArray -> mapIndexedNotNull { index, element ->
        val obj = element as? JsonObject ?: return@mapIndexedNotNull null
        val href = obj.string("href") ?: obj.string("id") ?: obj.string("url") ?: return@mapIndexedNotNull null
        val number = obj.int("number") ?: obj.int("chapter") ?: index + 1
        ServiceEpisodeLink(
            title = obj.string("title") ?: obj.string("name") ?: "Chapter $number",
            href = href,
            episodeNumber = number,
            metadata = obj,
        )
    }
    is JsonObject -> flattenKanzenChapterObject()
    else -> jsonPrimitiveOrNull()?.contentOrNull
        ?.let { raw -> runCatching { RuntimeJson.parseToJsonElement(raw).asChapterLinks() }.getOrNull() }
        ?: emptyList()
}

private fun JsonObject.flattenKanzenChapterObject(): List<ServiceEpisodeLink> =
    values.flatMap { value ->
        (value as? JsonArray).orEmpty().flatMapIndexed { index, chapterElement ->
            val chapterArray = chapterElement as? JsonArray ?: return@flatMapIndexed emptyList()
            val title = chapterArray.getOrNull(0)?.jsonPrimitiveOrNull()?.contentOrNull ?: "Chapter ${index + 1}"
            val sources = chapterArray.getOrNull(1) as? JsonArray ?: JsonArray(emptyList())
            sources.mapNotNull { sourceElement ->
                val source = sourceElement as? JsonObject ?: return@mapNotNull null
                val href = source.string("id") ?: source.string("href") ?: source.string("url") ?: return@mapNotNull null
                ServiceEpisodeLink(
                    title = listOfNotNull(title, source.string("scanlation_group")).joinToString(" - "),
                    href = href,
                    episodeNumber = index + 1,
                    metadata = source,
                )
            }
        }
    }

private fun JsonElement.asStringList(): List<String> = when (this) {
    is JsonArray -> mapNotNull { it.jsonPrimitiveOrNull()?.contentOrNull }
    else -> jsonPrimitiveOrNull()?.contentOrNull?.let { raw ->
        runCatching {
            RuntimeJson.parseToJsonElement(raw).jsonArray.mapNotNull { it.jsonPrimitiveOrNull()?.contentOrNull }
        }.getOrElse { listOf(raw) }
    }.orEmpty()
}

private fun JsonElement.asText(): String =
    jsonPrimitiveOrNull()?.contentOrNull ?: toString()

private fun JsonElement.asObjectOrEmpty(): JsonObject =
    this as? JsonObject
        ?: jsonPrimitiveOrNull()?.contentOrNull
            ?.let { raw -> runCatching { RuntimeJson.parseToJsonElement(raw) as? JsonObject }.getOrNull() }
        ?: JsonObject(emptyMap())

private fun Any?.toJsLiteral(): String = when (this) {
    null -> "null"
    is Number, is Boolean -> toString()
    is JsonObject -> toString()
    is JsonElement -> toString()
    else -> toString().jsQuote()
}

private fun parseHeaders(raw: String): Map<String, String> =
    runCatching {
        RuntimeJson.parseToJsonElement(raw).jsonObject.mapNotNull { (key, value) ->
            value.jsonPrimitiveOrNull()?.contentOrNull?.let { key to it }
        }.toMap()
    }.getOrDefault(emptyMap())

private fun JsonObject.string(key: String): String? =
    this[key]?.jsonPrimitiveOrNull()?.contentOrNull

private fun JsonObject.int(key: String): Int? =
    this[key]?.jsonPrimitiveOrNull()?.intOrNull
        ?: this[key]?.jsonPrimitiveOrNull()?.contentOrNull?.toIntOrNull()

private fun JsonElement.jsonPrimitiveOrNull() =
    this as? JsonPrimitive

private fun String.jsQuote(): String = JSONObject.quote(this)

private fun String.decodeJsResultString(): String =
    runCatching { RuntimeJson.decodeFromString(String.serializer(), this) }.getOrDefault(this)

private val RuntimeJson = Json {
    ignoreUnknownKeys = true
    isLenient = true
}
