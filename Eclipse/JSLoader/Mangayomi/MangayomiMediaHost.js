globalThis.self = globalThis;
globalThis.location = { href: "https://runtime.eclipse.invalid/" };
globalThis.__eclipseMangayomiPreferences = Object.create(null);
globalThis.__eclipseMangayomiPreferenceWrites = Object.create(null);
globalThis.__eclipseMangayomiSource = Object.create(null);

globalThis.__eclipseMangayomiDartHostAsync = async function(method, argumentJSON) {
    const args = JSON.parse(argumentJSON);
    if (method === "evalJs") {
        const result = await Promise.resolve((0, eval)(String(Array.isArray(args) ? args[0] : args.code)));
        return JSON.stringify(result === undefined ? null : result);
    }
    if (method !== "http") throw new Error("Unsupported host operation: " + method);
    return new Promise(function(resolve, reject) {
        __mangayomi_native_fetch(
            String(args.url), String(args.method || "GET"), args.headers || {},
            args.bodyBase64 || null, args.followRedirects !== false, 30000,
            function(response) {
                resolve(JSON.stringify({
                    statusCode: response.status,
                    headers: response.headers || {},
                    body: response.body || "",
                    bodyBase64: response.bodyBase64,
                    url: response.url,
                    requestHeaders: args.headers || {},
                    isRedirect: response.status >= 300 && response.status < 400
                }));
            }, reject
        );
    });
};

globalThis.__eclipseMangayomiDartHostSync = function(method, argumentJSON) {
    const args = JSON.parse(argumentJSON);
    if (method === "evalJsSync") {
        const result = (0, eval)(String(Array.isArray(args) ? args[0] : args.code));
        return JSON.stringify(result === undefined ? null : result);
    }
    throw new Error("Unsupported host operation: " + method);
};

class MProvider {
    get source() { return globalThis.__eclipseMangayomiSource; }
    get supportsLatest() { return true; }
    getHeaders() { return {}; }
    getFilterList() { return []; }
    getSourcePreferences() { return []; }
}

class Client {
    constructor(options) { this.options = options || {}; }
    async send(method, url, headers, body) {
        const requestHeaders = Object.assign({}, headers || {});
        let text = body;
        const contentTypeKey = Object.keys(requestHeaders).find(key => key.toLowerCase() === "content-type");
        const isJSON = contentTypeKey && String(requestHeaders[contentTypeKey]).toLowerCase().includes("application/json");
        let binary = Array.isArray(body) && !isJSON ? body : null;
        if (isJSON && body !== undefined) text = JSON.stringify(body);
        else if (text !== null && typeof text === "object" && !binary) {
            text = Object.keys(text).map(key => encodeURIComponent(key) + "=" + encodeURIComponent(text[key])).join("&").replace(/%20/g, "+");
            if (!Object.keys(requestHeaders).some(key => key.toLowerCase() === "content-type")) {
                requestHeaders["Content-Type"] = "application/x-www-form-urlencoded";
            }
        }
        const response = JSON.parse(await __eclipseMangayomiDartHostAsync("http", JSON.stringify({
            url: String(url), method: method, headers: requestHeaders,
            bodyBase64: binary ? btoa(binary.map(value => String.fromCharCode(Number(value) & 255)).join("")) : text == null ? null : btoa(unescape(encodeURIComponent(String(text)))),
            followRedirects: this.options.followRedirects !== false
        })));
        response.request = {
            url: response.url || String(url), method: method, headers: response.requestHeaders || requestHeaders,
            followRedirects: this.options.followRedirects !== false, maxRedirects: this.options.maxRedirects || 5,
            persistentConnection: true, finalized: true
        };
        response.persistentConnection = true;
        response.bodyBytes = response.bodyBase64 ? Array.from(atob(response.bodyBase64), c => c.charCodeAt(0)) : [];
        return response;
    }
    get(url, headers) { return this.send("GET", url, headers); }
    head(url, headers) { return this.send("HEAD", url, headers); }
    post(url, headers, body) { return this.send("POST", url, headers, body); }
    put(url, headers, body) { return this.send("PUT", url, headers, body); }
    patch(url, headers, body) { return this.send("PATCH", url, headers, body); }
    delete(url, headers, body) { return this.send("DELETE", url, headers, body); }
}

class SharedPreferences {
    get(key, fallback) {
        return Object.prototype.hasOwnProperty.call(__eclipseMangayomiPreferences, key)
            ? __eclipseMangayomiPreferences[key] : (fallback === undefined ? null : fallback);
    }
    getString(key, fallback) { return this.get(key, fallback); }
    setString(key, value) {
        key = String(key);
        value = String(value);
        if (!key.length || key.length > 256 || value.length > 8192) throw new Error("Mangayomi preference exceeds its limit");
        if (!Object.prototype.hasOwnProperty.call(__eclipseMangayomiPreferenceWrites, key) && Object.keys(__eclipseMangayomiPreferenceWrites).length >= 128) throw new Error("Too many Mangayomi preference writes");
        __eclipseMangayomiPreferenceWrites[key] = value;
        if (JSON.stringify(__eclipseMangayomiPreferenceWrites).length > 1024 * 1024) throw new Error("Mangayomi preference writes exceed their limit");
        __eclipseMangayomiPreferences[key] = value;
        return true;
    }
}

function mangayomiDOM(operation, argumentsList) {
    return JSON.parse(__eclipseMangayomiDOM(operation, JSON.stringify(argumentsList)));
}
class Element {
    constructor(handle) { this.handle = handle; }
    value(operation, parameter) { return mangayomiDOM(operation, [this.handle, parameter]); }
    select(selector) { return this.value("select", String(selector)).map(value => new Element(value)); }
    selectFirst(selector) { return new Element(this.value("selectFirst", String(selector))); }
    attr(name) { return this.value("attr", String(name)); }
    hasAttr(name) { return this.value("hasAttr", String(name)); }
    xpath(query) { return this.value("xpath", String(query)); }
    xpathFirst(query) { return this.value("xpathFirst", String(query)); }
    get text() { return this.value("text"); }
    get innerHtml() { return this.value("innerHtml"); }
    get outerHtml() { return this.value("outerHtml"); }
    get className() { return this.value("className"); }
    get localName() { return this.value("localName"); }
    get namespaceUri() { return this.value("namespaceUri"); }
    get getHref() { return this.value("getHref"); }
    get getSrc() { return this.value("getSrc"); }
    get getImg() { return this.value("getImg"); }
    get getDataSrc() { return this.value("getDataSrc"); }
    get children() { return this.value("children").map(value => new Element(value)); }
    get nextElementSibling() { return new Element(this.value("nextElementSibling")); }
    get previousElementSibling() { return new Element(this.value("previousElementSibling")); }
    get parent() { return new Element(this.value("parent")); }
    getElementById(id) { return new Element(this.value("getElementById", String(id))); }
    getElementsByClassName(name) { return this.value("getElementsByClassName", String(name)).map(value => new Element(value)); }
    getElementsByTagName(name) { return this.value("getElementsByTagName", String(name)).map(value => new Element(value)); }
}
class Document extends Element {
    constructor(html) {
        super(mangayomiDOM("parse", [String(html)]));
        this.html = String(html);
    }
    get body() { return new Element(this.value("body")); }
    get head() { return new Element(this.value("head")); }
    get documentElement() { return new Element(this.value("documentElement")); }
}
function parseHtml(html) { return new Document(html); }

String.prototype.substringAfter = function(pattern) { const i = this.indexOf(pattern); return i < 0 ? String(this) : this.substring(i + String(pattern).length); };
String.prototype.substringAfterLast = function(pattern) { const i = this.lastIndexOf(pattern); return i < 0 ? String(this) : this.substring(i + String(pattern).length); };
String.prototype.substringBefore = function(pattern) { const i = this.indexOf(pattern); return i < 0 ? String(this) : this.substring(0, i); };
String.prototype.substringBeforeLast = function(pattern) { const i = this.lastIndexOf(pattern); return i < 0 ? String(this) : this.substring(0, i); };
function substringAfter(value, pattern) { return String(value).substringAfter(pattern); }
function substringAfterLast(value, pattern) { return String(value).substringAfterLast(pattern); }
function substringBefore(value, pattern) { return String(value).substringBefore(pattern); }
function substringBeforeLast(value, pattern) { return String(value).substringBeforeLast(pattern); }

String.prototype.substringBetween = function(left, right) {
    const start = this.indexOf(left);
    if (start < 0) return "";
    const end = this.indexOf(right, start + String(left).length);
    return end < 0 ? "" : this.substring(start + String(left).length, end);
};
for (const name of ["cryptoHandler", "encryptAESCryptoJS", "decryptAESCryptoJS", "decryptAESGCM", "deobfuscateJsPassword", "unpackJsAndCombine", "unpackJs", "parseDates"]) {
    globalThis[name] = function() {
        return JSON.parse(__eclipseMangayomiUtility(name, JSON.stringify(Array.from(arguments))));
    };
}
async function evaluateJavascriptViaWebview() { throw new Error("Mangayomi browser evaluation is unavailable"); }
async function parseEpub() { throw new Error("Mangayomi EPUB parsing is unavailable in Media mode"); }
async function parseEpubChapter() { throw new Error("Mangayomi EPUB parsing is unavailable in Media mode"); }

for (const name of [
    "sibnetExtractor", "myTvExtractor", "okruExtractor", "voeExtractor",
    "vidBomExtractor", "streamlareExtractor", "sendVidExtractor", "yourUploadExtractor",
    "gogoCdnExtractor", "doodExtractor", "streamTapeExtractor", "mp4UploadExtractor",
    "streamWishExtractor", "filemoonExtractor", "quarkVideosExtractor", "ucVideosExtractor",
    "quarkFilesExtractor", "ucFilesExtractor"
]) {
    globalThis[name] = async function() {
        return JSON.parse(await __eclipseMangayomiExtract(name, JSON.stringify(Array.from(arguments))));
    };
}

globalThis.__eclipseMangayomiJSRun = async function(requestJSON) {
    const request = JSON.parse(requestJSON);
    Object.assign(globalThis.__eclipseMangayomiSource, request.source);
    Object.assign(globalThis.__eclipseMangayomiPreferences, request.preferences || {});
    const extension = new __eclipseMangayomiExtension();
    let schema;
    try { schema = await Promise.resolve(extension.getSourcePreferences()) || []; }
    catch (error) {
        if (String(error && error.message || error).trim() !== "getSourcePreferences not implemented") throw error;
        schema = [];
    }
    if (!Array.isArray(schema) || schema.length > 200) throw new Error("Invalid source preferences");
    for (const row of schema) {
        if (!row || typeof row.key !== "string" || Object.prototype.hasOwnProperty.call(__eclipseMangayomiPreferences, row.key)) continue;
        const list = row.listPreference;
        if (list && Array.isArray(list.entryValues)) __eclipseMangayomiPreferences[row.key] = list.entryValues[list.valueIndex || 0];
        else if (row.multiSelectListPreference) __eclipseMangayomiPreferences[row.key] = row.multiSelectListPreference.values || [];
        else if (row.checkBoxPreference) __eclipseMangayomiPreferences[row.key] = !!row.checkBoxPreference.value;
        else if (row.switchPreferenceCompat) __eclipseMangayomiPreferences[row.key] = !!row.switchPreferenceCompat.value;
        else if (row.editTextPreference) __eclipseMangayomiPreferences[row.key] = row.editTextPreference.value == null ? row.editTextPreference.text || "" : row.editTextPreference.value;
    }
    const args = request.arguments || {};
    let result;
    switch (request.operation) {
    case "validate":
        for (const name of ["search", "getDetail", "getVideoList"]) {
            if (typeof extension[name] !== "function") throw new Error("Missing source method: " + name);
        }
        result = { valid: true, preferences: schema, defaults: __eclipseMangayomiPreferences }; break;
    case "preferences": result = schema; break;
    case "filters": result = await extension.getFilterList(); break;
    case "search": result = await extension.search(args.query || "", args.page || 1, args.filters || await extension.getFilterList()); break;
    case "popular": result = await extension.getPopular(args.page || 1); break;
    case "latest": result = await extension.getLatestUpdates(args.page || 1); break;
    case "detail": result = await extension.getDetail(args.url); break;
    case "videos": result = await extension.getVideoList(args.url); break;
    default: throw new Error("Unsupported source operation");
    }
    const encoded = JSON.stringify(result);
    if (typeof encoded !== "string") throw new Error("Mangayomi returned no result");
    if (encoded.length > 4 * 1024 * 1024) throw new Error("Mangayomi result is too large");
    return encoded;
};
