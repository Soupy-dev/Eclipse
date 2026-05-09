package dev.soupy.eclipse.android.core.js

import android.annotation.SuppressLint
import android.content.Context
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.webkit.WebViewClient
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.Charset
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

private const val ServiceRuntimeTimeoutMs = 20_000L
private const val ServiceFetchMaxBytes = 10_000_000

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
                val rawComment = trimmed.substringAfter("//", "").trim()
                val options = optionRegex.find(rawComment)
                    ?.groupValues
                    ?.getOrNull(1)
                    ?.split(',')
                    ?.map { it.trim().trim('"', '\'') }
                    ?.filter { it.isNotBlank() }
                    .orEmpty()
                val comment = rawComment
                    .replace(optionRegex, "")
                    .trim()
                    .takeIf { it.isNotBlank() }
                add(
                    ServiceSettingDescriptor(
                        key = key,
                        label = key.replace('_', ' ').replaceFirstChar(Char::titlecase),
                        type = rawValue.toSettingType(options),
                        defaultValue = rawValue.trim('"', '\''),
                        comment = comment,
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
                bridge.attach(this)
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
                bridge.close()
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
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val json = Json { ignoreUnknownKeys = true }
    private var webView: WebView? = null

    fun attach(webView: WebView) {
        this.webView = webView
    }

    fun close() {
        webView = null
        scope.cancel()
    }

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

    @JavascriptInterface
    fun nativeFetch(
        requestId: String,
        url: String?,
        headersJson: String?,
        method: String?,
        body: String?,
        followRedirects: Boolean,
        encoding: String?,
    ) {
        scope.launch {
            val fetchResult = runCatching {
                performNativeFetch(
                    url = requireNotNull(url?.takeIf { it.isNotBlank() }) { "Missing fetch URL." },
                    headers = parseHeaders(headersJson),
                    method = method?.takeIf { it.isNotBlank() } ?: "GET",
                    body = body?.takeUnless { it == "null" || it == "undefined" },
                    followRedirects = followRedirects,
                    encoding = encoding?.takeIf { it.isNotBlank() } ?: "utf-8",
                )
            }
            fetchResult
                .onSuccess { response ->
                    dispatchToWebView(
                        "window.__eclipseNativeFetchResolve && window.__eclipseNativeFetchResolve(${requestId.jsQuoted()}, ${response.jsQuoted()});",
                    )
                }
                .onFailure { error ->
                    dispatchToWebView(
                        "window.__eclipseNativeFetchReject && window.__eclipseNativeFetchReject(${requestId.jsQuoted()}, ${(error.message ?: "Native fetch failed.").jsQuoted()});",
                    )
                }
        }
    }

    private fun parseHeaders(headersJson: String?): Map<String, String> =
        runCatching {
            val element = json.parseToJsonElement(headersJson.orEmpty())
            element.jsonObject.mapValues { (_, value) -> value.jsonPrimitive.contentOrNull.orEmpty() }
                .filterValues { it.isNotBlank() }
        }.getOrDefault(emptyMap())

    private fun performNativeFetch(
        url: String,
        headers: Map<String, String>,
        method: String,
        body: String?,
        followRedirects: Boolean,
        encoding: String,
    ): String {
        val connection = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = method.uppercase()
            instanceFollowRedirects = followRedirects
            connectTimeout = 20_000
            readTimeout = 20_000
            headers.forEach { (key, value) -> setRequestProperty(key, value) }
            if (!body.isNullOrEmpty() && requestMethod != "GET") {
                doOutput = true
                outputStream.use { stream -> stream.write(body.toByteArray(Charsets.UTF_8)) }
            }
        }

        return connection.useResponse { status, headerMap, bytes ->
            val charset = runCatching { Charset.forName(encoding) }.getOrDefault(Charsets.UTF_8)
            val text = runCatching { bytes.toString(charset) }
                .getOrElse { bytes.toString(Charsets.UTF_8) }
            json.encodeToString(
                buildJsonObject {
                    put("status", status)
                    put("headers", buildJsonObject {
                        headerMap.forEach { (key, value) -> put(key, value) }
                    })
                    put("body", text)
                    put("url", url)
                },
            )
        }
    }

    private fun dispatchToWebView(script: String) {
        val target = webView ?: return
        target.post {
            webView?.evaluateJavascript(script, null)
        }
    }
}

private fun HttpURLConnection.useResponse(
    block: (status: Int, headers: Map<String, String>, bytes: ByteArray) -> String,
): String {
    try {
        val status = responseCode
        val stream = if (status >= 400) errorStream ?: inputStream else inputStream
        val bytes = stream?.use(::readAtMostServiceFetchMaxBytes) ?: ByteArray(0)
        val headers = headerFields.orEmpty()
            .mapNotNull { (key, values) ->
                key?.let { headerName ->
                    values?.joinToString(", ")?.takeIf { it.isNotBlank() }?.let { value ->
                        headerName to value
                    }
                }
            }
            .toMap()
        return block(status, headers, bytes)
    } finally {
        disconnect()
    }
}

private fun readAtMostServiceFetchMaxBytes(input: InputStream): ByteArray {
    val buffer = ByteArrayOutputStream()
    val chunk = ByteArray(DEFAULT_BUFFER_SIZE)
    var total = 0
    while (true) {
        val read = input.read(chunk)
        if (read == -1) break
        total += read
        require(total <= ServiceFetchMaxBytes) { "Response exceeds maximum size." }
        buffer.write(chunk, 0, read)
    }
    return buffer.toByteArray()
}

private fun ServiceRuntimeSource.toInvocationScript(
    callId: String,
    invocation: String,
): String {
    val settingsJson = settings.toString()
    val configuredScript = script.withServiceSettings(settings)
    return """
        (async function() {
          try {
            const module = {};
            const exports = module.exports = {};
            const serviceSettings = $settingsJson;
            window.serviceSettings = serviceSettings;
            ${serviceRuntimeBridgeScript()}
            $configuredScript
            const value = await (async function() { $invocation })();
            const encoded = typeof value === 'string' ? value : JSON.stringify(value ?? null);
            EclipseAndroidBridge.resolve(${callId.jsQuoted()}, String(encoded ?? ''));
          } catch (error) {
            EclipseAndroidBridge.reject(${callId.jsQuoted()}, String((error && (error.stack || error.message)) || error));
          }
        })();
    """.trimIndent()
}

private fun String.withServiceSettings(settings: JsonObject): String {
    if (settings.isEmpty()) return this
    val settingRegex = Regex("""^(\s*)const\s+(\w+)\s*=\s*([^;]+);(.*)$""")
    var inSettings = false
    return lineSequence()
        .map { line ->
            val trimmed = line.trim()
            when {
                trimmed.contains("// Settings start", ignoreCase = true) -> {
                    inSettings = true
                    line
                }
                trimmed.contains("// Settings end", ignoreCase = true) -> {
                    inSettings = false
                    line
                }
                inSettings && trimmed.startsWith("const ") -> {
                    val match = settingRegex.find(line) ?: return@map line
                    val key = match.groupValues[2]
                    val value = settings[key] ?: return@map line
                    "${match.groupValues[1]}const $key = ${value.toJavaScriptLiteral()};${match.groupValues[4]}"
                }
                else -> line
            }
        }
        .joinToString("\n")
}

private fun JsonElement.toJavaScriptLiteral(): String = when (this) {
    JsonNull -> "null"
    is JsonPrimitive -> when {
        isString -> content.jsQuoted()
        booleanOrNull != null -> booleanOrNull.toString()
        doubleOrNull != null -> content
        else -> content.jsQuoted()
    }
    else -> toString()
}

private fun serviceRuntimeBridgeScript(): String = """
    (function() {
      const nativeFetchCallbacks = {};

      window.__eclipseNativeFetchResolve = function(id, payload) {
        const callback = nativeFetchCallbacks[id];
        if (!callback) return;
        delete nativeFetchCallbacks[id];
        try {
          callback.resolve(JSON.parse(payload || '{}'));
        } catch (error) {
          callback.reject(error);
        }
      };

      window.__eclipseNativeFetchReject = function(id, message) {
        const callback = nativeFetchCallbacks[id];
        if (!callback) return;
        delete nativeFetchCallbacks[id];
        callback.reject(new Error(String(message || 'Native fetch failed.')));
      };

      window.__eclipseNativeFetch = function(url, options) {
        options = options || {};
        const id = Math.random().toString(36).slice(2) + Date.now().toString(36);
        const absoluteUrl = new URL(String(url), window.location.href).href;
        const headers = options.headers && typeof options.headers === 'object' ? options.headers : {};
        const body = options.body == null ? null : (typeof options.body === 'string' ? options.body : JSON.stringify(options.body));
        const method = options.method || 'GET';
        const redirect = options.redirect !== false;
        const encoding = options.encoding || 'utf-8';
        return new Promise(function(resolve, reject) {
          nativeFetchCallbacks[id] = { resolve: resolve, reject: reject };
          EclipseAndroidBridge.nativeFetch(
            id,
            absoluteUrl,
            JSON.stringify(headers),
            String(method),
            body,
            !!redirect,
            String(encoding)
          );
        });
      };

      window.fetch = function(url, headers) {
        return window.__eclipseNativeFetch(url, { headers: headers || {}, method: 'GET' })
          .then(function(response) { return response.body || ''; });
      };

      window.fetchv2 = function(url, headers, method, body, redirect, encoding) {
        const finalMethod = method || 'GET';
        const processedBody = finalMethod === 'GET' ? null : (body && typeof body === 'object' ? JSON.stringify(body) : body);
        return window.__eclipseNativeFetch(url, {
          headers: headers || {},
          method: finalMethod,
          body: processedBody,
          redirect: redirect !== false,
          encoding: encoding || 'utf-8'
        }).then(function(raw) {
          const responseBody = raw.body || '';
          return {
            headers: raw.headers || {},
            status: raw.status || 0,
            _data: responseBody,
            text: function() { return Promise.resolve(responseBody); },
            json: function() {
              try {
                return Promise.resolve(JSON.parse(responseBody));
              } catch (error) {
                return Promise.reject('JSON parse error: ' + error.message);
              }
            }
          };
        });
      };

      function fetchHtmlLike(url, options) {
        options = options || {};
        return window.fetchv2(url, options.headers || {}, 'GET', null, options.redirect !== false, options.encoding || 'utf-8')
          .then(function(response) {
            return response.text().then(function(body) {
              return {
                originalUrl: String(url),
                requests: [String(url)],
                html: options.returnHTML === false ? null : body,
                cookies: null,
                success: response.status >= 200 && response.status < 400,
                status: response.status,
                error: response.status >= 400 ? ('HTTP ' + response.status) : null,
                htmlCaptured: options.returnHTML !== false,
                cookiesCaptured: false,
                elementsClicked: [],
                waitResults: {}
              };
            });
          });
      }

      window.networkFetchSimple = function(url, options) {
        return fetchHtmlLike(url, options || {});
      };

      window.networkFetch = function(url, options) {
        return fetchHtmlLike(url, options || {});
      };

      window.getElementsByTag = function(html, tag) {
        const regex = new RegExp('<' + tag + '[^>]*>([\\s\\S]*?)<\\/' + tag + '>', 'gi');
        const result = [];
        let match;
        while ((match = regex.exec(html)) !== null) result.push(match[1]);
        return result;
      };
      window.getAttribute = function(html, tag, attr) {
        const regex = new RegExp('<' + tag + '[^>]*' + attr + '=["\\']?([^"\\' >]+)["\\']?[^>]*>', 'i');
        const match = regex.exec(html);
        return match ? match[1] : null;
      };
      window.getInnerText = function(html) {
        return String(html || '').replace(/<[^>]+>/g, '').replace(/\s+/g, ' ').trim();
      };
      window.extractBetween = function(str, start, end) {
        const value = String(str || '');
        const s = value.indexOf(start);
        if (s === -1) return '';
        const e = value.indexOf(end, s + start.length);
        if (e === -1) return '';
        return value.substring(s + start.length, e);
      };
      window.stripHtml = function(html) { return String(html || '').replace(/<[^>]+>/g, ''); };
      window.normalizeWhitespace = function(str) { return String(str || '').replace(/\s+/g, ' ').trim(); };
      window.urlEncode = function(str) { return encodeURIComponent(str); };
      window.urlDecode = function(str) {
        try { return decodeURIComponent(str); } catch (error) { return str; }
      };
      window.htmlEntityDecode = function(str) {
        return String(str || '').replace(/&([a-zA-Z]+);/g, function(match, entity) {
          const entities = { quot: '"', apos: "'", amp: '&', lt: '<', gt: '>' };
          return entities[entity] || match;
        });
      };
      window.transformResponse = function(response, fn) {
        try { return fn(response); } catch (error) { return response; }
      };
    })();
""".trimIndent()

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
