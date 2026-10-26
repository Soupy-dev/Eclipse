globalThis.global = globalThis;
globalThis.window = globalThis;
globalThis.self = globalThis;
globalThis.SCRAPER_ID = __eclipse_scraper_id;
globalThis.SCRAPER_SETTINGS = __eclipse_scraper_settings;

globalThis.atob = function(value) {
    var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=";
    var str = String(value).replace(/=+$/, "");
    if (str.length % 4 === 1) throw new Error("InvalidCharacterError");
    var output = "";
    var bc = 0, bs, buffer, idx = 0;
    while ((buffer = str.charAt(idx++))) {
        buffer = chars.indexOf(buffer);
        if (buffer === -1) continue;
        bs = bc % 4 ? bs * 64 + buffer : buffer;
        if (bc++ % 4) output += String.fromCharCode(255 & (bs >> ((-2 * bc) & 6)));
    }
    return output;
};
globalThis.btoa = function(value) {
    var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=";
    var str = String(value);
    var output = "";
    for (var block, charCode, idx = 0, map = chars;
         str.charAt(idx | 0) || (map = "=", idx % 1);
         output += map.charAt(63 & (block >> (8 - (idx % 1) * 8)))) {
        charCode = str.charCodeAt(idx += 3 / 4);
        if (charCode > 0xFF) throw new Error("InvalidCharacterError");
        block = (block << 8) | charCode;
    }
    return output;
};

if (!Array.prototype.flat) {
    Array.prototype.flat = function(depth) {
        depth = depth === undefined ? 1 : Math.floor(depth);
        if (depth < 1) return Array.prototype.slice.call(this);
        function flatten(items, level) {
            return items.reduce(function(output, item) {
                return output.concat(Array.isArray(item) && level > 0 ? flatten(item, level - 1) : item);
            }, []);
        }
        return flatten(this, depth);
    };
}
if (!Array.prototype.flatMap) {
    Array.prototype.flatMap = function(fn, thisArg) { return this.map(fn, thisArg).flat(1); };
}
if (!Object.entries) {
    Object.entries = function(obj) { var out = []; for (var k in obj) if (Object.prototype.hasOwnProperty.call(obj, k)) out.push([k, obj[k]]); return out; };
}
if (!Object.fromEntries) {
    Object.fromEntries = function(entries) { var out = {}; entries.forEach(function(pair) { out[pair[0]] = pair[1]; }); return out; };
}
if (!String.prototype.replaceAll) {
    String.prototype.replaceAll = function(search, replacement) { return this.split(search).join(replacement); };
}

function HeadersShim(headers) {
    this._headers = {};
    var self = this;
    function add(name, value) {
        if (name == null || value == null) return;
        self._headers[String(name)] = String(value);
    }
    if (headers instanceof HeadersShim) {
        headers.forEach(function(value, name) { add(name, value); });
    } else if (Array.isArray(headers)) {
        headers.forEach(function(pair) {
            if (pair && pair.length >= 2) add(pair[0], pair[1]);
        });
    } else if (headers && typeof headers.entries === "function" && !headers._pairs) {
        var entries = headers.entries();
        if (Array.isArray(entries)) {
            entries.forEach(function(pair) {
                if (pair && pair.length >= 2) add(pair[0], pair[1]);
            });
        }
    } else if (headers && typeof headers === "object") {
        Object.keys(headers).forEach(function(name) { add(name, headers[name]); });
    }
}
HeadersShim.prototype.get = function(name) {
    var needle = String(name).toLowerCase();
    for (var key in this._headers) {
        if (String(key).toLowerCase() === needle) return this._headers[key];
    }
    return null;
};
HeadersShim.prototype.set = function(name, value) { this._headers[String(name)] = String(value); };
HeadersShim.prototype.append = function(name, value) { this.set(name, value); };
HeadersShim.prototype.has = function(name) { return this.get(name) !== null; };
HeadersShim.prototype.delete = function(name) {
    var needle = String(name).toLowerCase();
    for (var key in this._headers) {
        if (String(key).toLowerCase() === needle) delete this._headers[key];
    }
};
HeadersShim.prototype.entries = function() {
    var self = this;
    return Object.keys(this._headers).map(function(key) { return [key, self._headers[key]]; });
};
HeadersShim.prototype.keys = function() { return Object.keys(this._headers); };
HeadersShim.prototype.values = function() {
    var self = this;
    return Object.keys(this._headers).map(function(key) { return self._headers[key]; });
};
HeadersShim.prototype.forEach = function(callback) {
    var self = this;
    Object.keys(this._headers).forEach(function(key) { callback(self._headers[key], key, self); });
};
if (typeof Symbol !== "undefined" && Symbol.iterator) {
    HeadersShim.prototype[Symbol.iterator] = function() { return this.entries()[Symbol.iterator](); };
}
globalThis.Headers = HeadersShim;

function headersToObject(headers) {
    var out = {};
    var shim = new HeadersShim(headers || {});
    shim.forEach(function(value, name) { out[name] = value; });
    return out;
}

function hasHeader(headers, name) {
    var needle = String(name).toLowerCase();
    for (var key in headers) {
        if (String(key).toLowerCase() === needle) return true;
    }
    return false;
}

function encodeRequestBody(body, headers) {
    if (body == null) return null;
    if (typeof globalThis.FormData === "function" && body instanceof globalThis.FormData) {
        var boundary = body.__multipartBoundary();
        if (!hasHeader(headers, "Content-Type")) {
            headers["Content-Type"] = "multipart/form-data; boundary=" + boundary;
        }
        return body.__multipartBody(boundary);
    }
    if (typeof globalThis.URLSearchParams === "function" && body instanceof globalThis.URLSearchParams) {
        if (!hasHeader(headers, "Content-Type")) {
            headers["Content-Type"] = "application/x-www-form-urlencoded;charset=UTF-8";
        }
        return body.toString();
    }
    if (typeof globalThis.Buffer === "function" && globalThis.Buffer.isBuffer && globalThis.Buffer.isBuffer(body)) {
        return body.toString("utf8");
    }
    return String(body);
}

globalThis.fetch = function(url, options) {
    options = options || {};
    var method = options.method || "GET";
    var headers = headersToObject(options.headers || {});
    var body = encodeRequestBody(options.body, headers);
    var redirect = options.redirect === "manual" ? false : true;
    var signal = options.signal;
    if (signal && signal.aborted) {
        return Promise.reject(signal.reason || new Error("AbortError"));
    }
    var timeoutMilliseconds = 30000;
    if (signal && Number.isFinite(Number(signal._eclipseTimeoutMilliseconds))) {
        timeoutMilliseconds = Math.min(Math.max(Number(signal._eclipseTimeoutMilliseconds), 250), 30000);
    }
    return new Promise(function(resolve, reject) {
        __native_fetch(String(url), String(method), headers, body, redirect, timeoutMilliseconds, function(raw) {
            var response = {
                ok: !!raw.ok,
                status: raw.status || 0,
                statusText: raw.statusText || "",
                url: raw.url || String(url),
                headers: new HeadersShim(raw.headers || {}),
                text: function() { return Promise.resolve(raw.body || ""); },
                json: function() {
                    try { return Promise.resolve(JSON.parse(raw.body || "null")); }
                    catch (error) { return Promise.reject(error); }
                }
            };
            resolve(response);
        }, reject);
    });
};

globalThis.AbortSignal = function() {
    this.aborted = false;
    this.reason = undefined;
    this._listeners = [];
};
globalThis.AbortSignal.prototype.addEventListener = function(type, listener) {
    if (type === "abort" && typeof listener === "function") this._listeners.push(listener);
};
globalThis.AbortSignal.prototype.removeEventListener = function(type, listener) {
    if (type !== "abort") return;
    this._listeners = this._listeners.filter(function(value) { return value !== listener; });
};
globalThis.AbortSignal.prototype.dispatchEvent = function(event) {
    if (!event || event.type !== "abort") return true;
    this._listeners.forEach(function(listener) {
        try { listener.call(this, event); } catch (_) {}
    }, this);
    return true;
};
globalThis.AbortController = function() { this.signal = new globalThis.AbortSignal(); };
globalThis.AbortController.prototype.abort = function(reason) {
    if (this.signal.aborted) return;
    this.signal.aborted = true;
    this.signal.reason = reason;
    this.signal.dispatchEvent({ type: "abort" });
};

(function() {
    var __nuvioTimers = {};
    var __nuvioTimerSeq = 1;
    globalThis.setTimeout = function(handler, timeout) {
        if (typeof handler !== "function") return 0;
        var id = __nuvioTimerSeq++;
        __nuvioTimers[id] = true;
        var extraArgs = Array.prototype.slice.call(arguments, 2);
        __schedule_timeout(function() {
            if (!__nuvioTimers[id]) return;
            delete __nuvioTimers[id];
            try { handler.apply(undefined, extraArgs); }
            catch (e) { if (typeof console !== "undefined" && console.error) console.error("setTimeout callback error:", e); }
        }, Number(timeout) || 0);
        return id;
    };
    globalThis.clearTimeout = function(id) { if (id != null) delete __nuvioTimers[id]; };
    globalThis.setInterval = function() { return 0; };
    globalThis.clearInterval = function(id) { if (id != null) delete __nuvioTimers[id]; };
    globalThis.setImmediate = function(handler) {
        return globalThis.setTimeout.apply(null, [handler, 0].concat(Array.prototype.slice.call(arguments, 1)));
    };
    globalThis.clearImmediate = function(id) { globalThis.clearTimeout(id); };
    if (typeof globalThis.queueMicrotask !== "function") {
        globalThis.queueMicrotask = function(cb) { if (typeof cb === "function") Promise.resolve().then(cb); };
    }
})();

globalThis.URL = function(value, base) {
    var parsed = __parse_url(String(value), base == null ? null : String(base));
    this.href = parsed.href || String(value);
    this.protocol = parsed.protocol || "";
    this.host = parsed.host || "";
    this.hostname = parsed.hostname || "";
    this.port = parsed.port || "";
    this.pathname = parsed.pathname || "";
    this.search = parsed.search || "";
    this.hash = parsed.hash || "";
    this.origin = parsed.origin || "";
    this.searchParams = new globalThis.URLSearchParams(this.search || "");
    Object.defineProperty(this.searchParams, "_url", { value: this, enumerable: false, writable: true, configurable: true });
};
globalThis.URL.prototype.__applySearchParams = function(serialized) {
    var query = serialized.length > 0 ? "?" + serialized : "";
    var base = this.href;
    var hashIndex = base.indexOf("#");
    var hash = hashIndex >= 0 ? base.slice(hashIndex) : "";
    if (hashIndex >= 0) base = base.slice(0, hashIndex);
    var queryIndex = base.indexOf("?");
    if (queryIndex >= 0) base = base.slice(0, queryIndex);
    this.search = query;
    this.href = base + query + hash;
};
globalThis.URL.prototype.toString = function() { return this.href; };

globalThis.URLSearchParams = function(value) {
    this._pairs = [];
    if (value && value._pairs && Array.isArray(value._pairs)) {
        this._pairs = value._pairs.map(function(pair) { return [String(pair[0]), String(pair[1])]; });
        return;
    }
    if (Array.isArray(value)) {
        for (var pairIndex = 0; pairIndex < value.length; pairIndex++) {
            var item = value[pairIndex];
            if (item && item.length >= 2) this._pairs.push([String(item[0]), String(item[1])]);
        }
        return;
    }
    if (value && typeof value === "object") {
        var self = this;
        Object.keys(value).forEach(function(key) { self._pairs.push([String(key), String(value[key])]); });
        return;
    }
    var text = value == null ? "" : String(value);
    if (text.charAt(0) === "?") text = text.slice(1);
    if (text.length > 0) {
        var parts = text.split("&");
        for (var i = 0; i < parts.length; i++) {
            var pair = parts[i].split("=");
            this._pairs.push([decodeURIComponent(pair[0] || ""), decodeURIComponent(pair.slice(1).join("=") || "")]);
        }
    }
};
globalThis.URLSearchParams.prototype.get = function(name) {
    for (var i = 0; i < this._pairs.length; i++) if (this._pairs[i][0] === name) return this._pairs[i][1];
    return null;
};
globalThis.URLSearchParams.prototype.__syncURL = function() {
    if (this._url) this._url.__applySearchParams(this.toString());
};
globalThis.URLSearchParams.prototype.set = function(name, value) {
    var replaced = false;
    for (var i = 0; i < this._pairs.length; i++) {
        if (this._pairs[i][0] === name) {
            this._pairs[i][1] = String(value);
            replaced = true;
            break;
        }
    }
    if (!replaced) this._pairs.push([String(name), String(value)]);
    this.__syncURL();
};
globalThis.URLSearchParams.prototype.append = function(name, value) {
    this._pairs.push([String(name), String(value)]);
    this.__syncURL();
};
globalThis.URLSearchParams.prototype.has = function(name) {
    for (var i = 0; i < this._pairs.length; i++) if (this._pairs[i][0] === name) return true;
    return false;
};
globalThis.URLSearchParams.prototype.delete = function(name) {
    this._pairs = this._pairs.filter(function(pair) { return pair[0] !== name; });
    this.__syncURL();
};
globalThis.URLSearchParams.prototype.getAll = function(name) {
    return this._pairs.filter(function(pair) { return pair[0] === name; }).map(function(pair) { return pair[1]; });
};
globalThis.URLSearchParams.prototype.entries = function() { return this._pairs.slice(); };
globalThis.URLSearchParams.prototype.keys = function() { return this._pairs.map(function(pair) { return pair[0]; }); };
globalThis.URLSearchParams.prototype.values = function() { return this._pairs.map(function(pair) { return pair[1]; }); };
globalThis.URLSearchParams.prototype.forEach = function(callback) {
    for (var i = 0; i < this._pairs.length; i++) callback(this._pairs[i][1], this._pairs[i][0], this);
};
globalThis.URLSearchParams.prototype.sort = function() {
    this._pairs.sort(function(lhs, rhs) { return lhs[0] < rhs[0] ? -1 : (lhs[0] > rhs[0] ? 1 : 0); });
    this.__syncURL();
};
globalThis.URLSearchParams.prototype.toString = function() {
    return this._pairs.map(function(pair) { return encodeURIComponent(pair[0]) + "=" + encodeURIComponent(pair[1]); }).join("&");
};
if (typeof Symbol !== "undefined" && Symbol.iterator) {
    globalThis.URLSearchParams.prototype[Symbol.iterator] = function() { return this.entries()[Symbol.iterator](); };
}

if (typeof TextEncoder === "undefined") {
    globalThis.TextEncoder = function() {};
    TextEncoder.prototype.encode = function(str) {
        var hex = __crypto_utf8_to_hex(String(str == null ? "" : str));
        var bytes = new Uint8Array(hex.length / 2);
        for (var i = 0; i < hex.length; i += 2) bytes[i / 2] = parseInt(hex.substring(i, i + 2), 16);
        return bytes;
    };
}
if (typeof TextDecoder === "undefined") {
    globalThis.TextDecoder = function() {};
    TextDecoder.prototype.decode = function(data) {
        var bytes = data;
        if (data instanceof ArrayBuffer) bytes = new Uint8Array(data);
        else if (data && data.buffer instanceof ArrayBuffer && !(data instanceof Uint8Array)) bytes = new Uint8Array(data.buffer, data.byteOffset || 0, data.byteLength);
        var hex = "";
        for (var i = 0; i < bytes.length; i++) hex += bytes[i].toString(16).padStart(2, "0");
        return __crypto_hex_to_utf8(hex);
    };
}

(function() {
    function bytesToLatin1(bytes) {
        var out = "";
        for (var i = 0; i < bytes.length; i++) out += String.fromCharCode(bytes[i] & 0xff);
        return out;
    }
    function hexToBytes(hex) {
        var bytes = new Uint8Array(hex.length / 2);
        for (var i = 0; i < hex.length; i += 2) bytes[i / 2] = parseInt(hex.substring(i, i + 2), 16);
        return bytes;
    }
    function bytesToHex(bytes) {
        var hex = "";
        for (var i = 0; i < bytes.length; i++) hex += bytes[i].toString(16).padStart(2, "0");
        return hex;
    }
    function latin1ToBytes(value) {
        var bytes = new Uint8Array(value.length);
        for (var i = 0; i < value.length; i++) bytes[i] = value.charCodeAt(i) & 0xff;
        return bytes;
    }
    function makeBuffer(bytes) {
        var buffer = Object.create(BufferShim.prototype);
        buffer._bytes = bytes;
        buffer.length = bytes.length;
        return buffer;
    }
    function BufferShim() {}
    BufferShim.prototype.toString = function(encoding) {
        var enc = String(encoding || "utf8").toLowerCase();
        if (enc === "hex") return bytesToHex(this._bytes);
        if (enc === "base64") return globalThis.btoa(bytesToLatin1(this._bytes));
        if (enc === "latin1" || enc === "binary" || enc === "ascii") return bytesToLatin1(this._bytes);
        return __crypto_hex_to_utf8(bytesToHex(this._bytes));
    };
    BufferShim.from = function(value, encoding) {
        if (value == null) return makeBuffer(new Uint8Array(0));
        if (value instanceof Uint8Array) return makeBuffer(value);
        if (value instanceof ArrayBuffer) return makeBuffer(new Uint8Array(value));
        if (Array.isArray(value)) return makeBuffer(new Uint8Array(value));
        var enc = String(encoding || "utf8").toLowerCase();
        var text = String(value);
        if (enc === "base64") return makeBuffer(latin1ToBytes(globalThis.atob(text)));
        if (enc === "hex") return makeBuffer(hexToBytes(text.length % 2 ? "0" + text : text));
        if (enc === "latin1" || enc === "binary" || enc === "ascii") return makeBuffer(latin1ToBytes(text));
        return makeBuffer(hexToBytes(__crypto_utf8_to_hex(text)));
    };
    BufferShim.byteLength = function(value, encoding) { return BufferShim.from(value, encoding).length; };
    BufferShim.isBuffer = function(value) { return value instanceof BufferShim; };
    BufferShim.concat = function(list) {
        var total = 0, i;
        for (i = 0; i < list.length; i++) total += list[i]._bytes.length;
        var merged = new Uint8Array(total), offset = 0;
        for (i = 0; i < list.length; i++) { merged.set(list[i]._bytes, offset); offset += list[i]._bytes.length; }
        return makeBuffer(merged);
    };
    if (typeof globalThis.Buffer === "undefined") globalThis.Buffer = BufferShim;
})();

if (typeof globalThis.AbortSignal === "function" && typeof globalThis.AbortSignal.timeout !== "function") {
    globalThis.AbortSignal.timeout = function(milliseconds) {
        var controller = new globalThis.AbortController();
        var timeoutMilliseconds = Math.min(Math.max(Number(milliseconds) || 0, 0), 30000);
        controller.signal._eclipseTimeoutMilliseconds = timeoutMilliseconds;
        globalThis.setTimeout(function() { controller.abort("TimeoutError"); }, timeoutMilliseconds);
        return controller.signal;
    };
}
if (typeof globalThis.AbortSignal === "function" && typeof globalThis.AbortSignal.abort !== "function") {
    globalThis.AbortSignal.abort = function(reason) {
        var controller = new globalThis.AbortController();
        controller.abort(reason);
        return controller.signal;
    };
}

if (typeof globalThis.FormData === "undefined") {
    globalThis.FormData = function() { this._entries = []; };
    globalThis.FormData.prototype.append = function(name, value) {
        this._entries.push([String(name), value == null ? "" : String(value)]);
    };
    globalThis.FormData.prototype.set = function(name, value) {
        this.delete(name);
        this.append(name, value);
    };
    globalThis.FormData.prototype.get = function(name) {
        var needle = String(name);
        for (var i = 0; i < this._entries.length; i++) {
            if (this._entries[i][0] === needle) return this._entries[i][1];
        }
        return null;
    };
    globalThis.FormData.prototype.getAll = function(name) {
        var needle = String(name);
        return this._entries.filter(function(pair) { return pair[0] === needle; })
            .map(function(pair) { return pair[1]; });
    };
    globalThis.FormData.prototype.has = function(name) { return this.get(name) !== null; };
    globalThis.FormData.prototype.delete = function(name) {
        var needle = String(name);
        this._entries = this._entries.filter(function(pair) { return pair[0] !== needle; });
    };
    globalThis.FormData.prototype.entries = function() { return this._entries.slice(); };
    globalThis.FormData.prototype.forEach = function(callback) {
        var self = this;
        this._entries.forEach(function(pair) { callback(pair[1], pair[0], self); });
    };
    globalThis.FormData.prototype.__multipartBoundary = function() {
        return "----EclipseNuvioFormBoundary" + String(this._entries.length) + "x7MA4YWxkTrZu0gW";
    };
    globalThis.FormData.prototype.__multipartBody = function(boundary) {
        var body = "";
        this._entries.forEach(function(pair) {
            body += "--" + boundary + "\r\n";
            body += 'Content-Disposition: form-data; name="' + pair[0] + '"\r\n\r\n';
            body += pair[1] + "\r\n";
        });
        return body + "--" + boundary + "--\r\n";
    };
}

var WordArray = {
    init: function(words, sigBytes) {
        this.words = words || [];
        this.sigBytes = sigBytes != undefined ? sigBytes : this.words.length * 4;
    },
    toString: function(encoder) { return (encoder || CryptoJS.enc.Hex).stringify(this); },
    concat: function(wordArray) {
        var thisWords = this.words, thatWords = wordArray.words;
        var thisSigBytes = this.sigBytes, thatSigBytes = wordArray.sigBytes;
        this.clamp();
        for (var i = 0; i < thatSigBytes; i++) {
            var thatByte = (thatWords[i >>> 2] >>> (24 - (i % 4) * 8)) & 0xff;
            thisWords[(thisSigBytes + i) >>> 2] |= thatByte << (24 - ((thisSigBytes + i) % 4) * 8);
        }
        this.sigBytes += thatSigBytes;
        return this;
    },
    clamp: function() {
        var words = this.words, sigBytes = this.sigBytes;
        if (sigBytes % 4) words[sigBytes >>> 2] &= 0xffffffff << (32 - (sigBytes % 4) * 8);
        words.length = Math.ceil(sigBytes / 4);
        return this;
    },
    clone: function() { return __wordArrayCreate(this.words.slice(0), this.sigBytes); }
};
function __wordArrayCreate(words, sigBytes) { var wa = Object.create(WordArray); wa.init(words, sigBytes); return wa; }
function __isWordArray(value) { return value && typeof value === "object" && Array.isArray(value.words) && typeof value.sigBytes === "number"; }
function __copyUint8Array(bytes) { bytes = __toUint8Array(bytes); var copy = new Uint8Array(bytes.length); copy.set(bytes); return copy; }
function __toUint8Array(data) {
    if (!data) return new Uint8Array(0);
    if (data instanceof Uint8Array) return data;
    if (data instanceof ArrayBuffer) return new Uint8Array(data);
    if (typeof ArrayBuffer !== "undefined" && ArrayBuffer.isView && ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset || 0, data.byteLength);
    if (Array.isArray(data)) return new Uint8Array(data);
    if (typeof data.length === "number") return new Uint8Array(Array.prototype.slice.call(data));
    return new Uint8Array(0);
}
function __bytesToArrayBuffer(bytes) { return __copyUint8Array(bytes).buffer; }
function __wordArrayToBytes(wordArray) {
    if (!__isWordArray(wordArray)) return typeof wordArray === "string" ? new TextEncoder().encode(wordArray) : __toUint8Array(wordArray);
    var bytes = new Uint8Array(wordArray.sigBytes);
    for (var i = 0; i < wordArray.sigBytes; i++) bytes[i] = (wordArray.words[i >>> 2] >>> (24 - (i % 4) * 8)) & 0xff;
    return bytes;
}
function __bytesToWordArray(bytes) {
    bytes = __toUint8Array(bytes);
    var words = [];
    for (var i = 0; i < bytes.length; i++) words[i >>> 2] |= (bytes[i] & 0xff) << (24 - (i % 4) * 8);
    return __wordArrayCreate(words, bytes.length);
}
function __normalizeWordArrayInput(value) {
    if (__isWordArray(value)) return __wordArrayToBytes(value);
    if (typeof value === "string") return new TextEncoder().encode(value);
    return __toUint8Array(value);
}
function __bytesToHex(bytes) { bytes = __toUint8Array(bytes); var out = []; for (var i = 0; i < bytes.length; i++) { var hex = bytes[i].toString(16); out.push(hex.length < 2 ? "0" + hex : hex); } return out.join(""); }
function __hexToBytes(hex) {
    hex = String(hex || "").replace(/[^0-9a-fA-F]/g, "");
    if (hex.length % 2) hex = "0" + hex;
    var bytes = new Uint8Array(hex.length / 2);
    for (var i = 0; i < hex.length; i += 2) bytes[i / 2] = parseInt(hex.substr(i, 2), 16) & 0xff;
    return bytes;
}
function __concatBytes() {
    var total = 0, parts = [];
    for (var i = 0; i < arguments.length; i++) { var part = __toUint8Array(arguments[i]); parts.push(part); total += part.length; }
    var out = new Uint8Array(total), offset = 0;
    for (var j = 0; j < parts.length; j++) { out.set(parts[j], offset); offset += parts[j].length; }
    return out;
}
function __normalizeHashName(hash) {
    var name = hash && hash.name ? hash.name : hash;
    name = String(name || "SHA-256").toUpperCase().replace(/[^A-Z0-9]/g, "");
    if (name === "SHA1" || name === "SHA256" || name === "SHA384" || name === "SHA512" || name === "MD5") return name;
    throw new Error("Unsupported hash algorithm: " + name);
}
function __normalizeAlgorithmName(algo) {
    var name = algo && algo.name ? algo.name : algo;
    name = String(name || "").toUpperCase();
    if (name.indexOf("AES-GCM") >= 0) return "AES-GCM";
    if (name.indexOf("AES-CBC") >= 0) return "AES-CBC";
    if (name.indexOf("AES-ECB") >= 0 || name === "ECB") return "AES-ECB";
    if (name.indexOf("PBKDF2") >= 0) return "PBKDF2";
    if (name.indexOf("HMAC") >= 0) return "HMAC";
    return name;
}
function __aesModeName(mode, padding) {
    var normalized = __normalizeAlgorithmName(mode || "AES-CBC");
    if (normalized === "CBC") normalized = "AES-CBC";
    if (normalized === "GCM") normalized = "AES-GCM";
    if (normalized !== "AES-CBC" && normalized !== "AES-GCM" && normalized !== "AES-ECB") throw new Error("Unsupported AES cipher mode: " + normalized);
    if (padding === CryptoJS.pad.NoPadding || padding === "NoPadding") normalized += "-NoPadding";
    return normalized;
}
function __des3ModeName(mode, padding) {
    var m = String((mode && mode.name) || mode || "CBC").toUpperCase();
    if (m.indexOf("CBC") < 0 && m.indexOf("ECB") < 0) throw new Error("Unsupported TripleDES cipher mode: " + m);
    var normalized = m.indexOf("ECB") >= 0 ? "DES3-ECB" : "DES3-CBC";
    if (padding === CryptoJS.pad.NoPadding || padding === "NoPadding") normalized += "-NoPadding";
    return normalized;
}
function __nativeDigestBytes(hash, dataBytes) {
    if (typeof __crypto_digest_hex_raw === "undefined") throw new Error("Native digest bridge is unavailable");
    return __hexToBytes(__crypto_digest_hex_raw(__normalizeHashName(hash), __bytesToHex(dataBytes)));
}
function __nativeHmacBytes(hash, keyBytes, dataBytes) {
    if (typeof __crypto_hmac_hex_raw === "undefined") throw new Error("Native HMAC bridge is unavailable");
    return __hexToBytes(__crypto_hmac_hex_raw(__normalizeHashName(hash), __bytesToHex(keyBytes), __bytesToHex(dataBytes)));
}
function __nativePbkdf2Bytes(passwordBytes, saltBytes, iterations, keySizeBits, hash) {
    if (typeof __crypto_pbkdf2_hex === "undefined") throw new Error("Native PBKDF2 bridge is unavailable");
    return __hexToBytes(__crypto_pbkdf2_hex(__bytesToHex(passwordBytes), __bytesToHex(saltBytes), iterations, keySizeBits, __normalizeHashName(hash)));
}
function __nativeAesBytes(encrypt, mode, keyBytes, ivBytes, dataBytes) {
    var fn = encrypt ? __crypto_aes_encrypt_hex : __crypto_aes_decrypt_hex;
    if (typeof fn === "undefined") throw new Error("Native AES bridge is unavailable");
    return __hexToBytes(fn(mode, __bytesToHex(keyBytes), __bytesToHex(ivBytes), __bytesToHex(dataBytes)));
}
function __nativeDes3Bytes(encrypt, mode, keyBytes, ivBytes, dataBytes) {
    var fn = encrypt ? __crypto_des3_encrypt_hex : __crypto_des3_decrypt_hex;
    if (typeof fn === "undefined") throw new Error("Native TripleDES bridge is unavailable");
    return __hexToBytes(fn(mode, __bytesToHex(keyBytes), __bytesToHex(ivBytes), __bytesToHex(dataBytes)));
}
function __evpKdf(passwordBytes, saltBytes, keySizeBytes, ivSizeBytes) {
    var targetSize = keySizeBytes + ivSizeBytes;
    var derived = new Uint8Array(targetSize);
    var block = new Uint8Array(0), offset = 0;
    while (offset < targetSize) {
        block = __nativeDigestBytes("MD5", __concatBytes(block, passwordBytes, saltBytes || new Uint8Array(0)));
        var take = Math.min(block.length, targetSize - offset);
        derived.set(block.subarray(0, take), offset);
        offset += take;
    }
    return { key: derived.subarray(0, keySizeBytes), iv: derived.subarray(keySizeBytes, keySizeBytes + ivSizeBytes) };
}
function __opensslSaltHeader() { return new Uint8Array([83, 97, 108, 116, 101, 100, 95, 95]); }
function __hasOpenSslSaltHeader(bytes) {
    var header = __opensslSaltHeader();
    if (!bytes || bytes.length < 16) return false;
    for (var i = 0; i < header.length; i++) if (bytes[i] !== header[i]) return false;
    return true;
}
function __makeCipherParams(ciphertext, key, iv, salt, mode) {
    return {
        ciphertext: __bytesToWordArray(ciphertext),
        key: key ? __bytesToWordArray(key) : undefined,
        iv: iv ? __bytesToWordArray(iv) : undefined,
        salt: salt ? __bytesToWordArray(salt) : undefined,
        mode: mode,
        toString: function(formatter) { return (formatter || CryptoJS.format.OpenSSL).stringify(this); }
    };
}
function __makeCipherApi(nativeFn, modeNameFn, keySizeBytes, ivSizeBytes) {
    return {
        encrypt: function(message, key, options) {
            options = options || {};
            var data = __normalizeWordArrayInput(message);
            var kBytes, ivBytes, saltBytes;
            if (typeof key === "string") {
                saltBytes = options.salt ? __wordArrayToBytes(options.salt) : __wordArrayToBytes(CryptoJS.lib.WordArray.random(8));
                var derived = __evpKdf(new TextEncoder().encode(key), saltBytes, keySizeBytes, ivSizeBytes);
                kBytes = derived.key;
                ivBytes = options.iv ? __wordArrayToBytes(options.iv) : derived.iv;
            } else {
                kBytes = __wordArrayToBytes(key);
                ivBytes = options.iv ? __wordArrayToBytes(options.iv) : new Uint8Array(0);
            }
            var mode = modeNameFn(options.mode, options.padding);
            var resBytes = nativeFn(true, mode, kBytes, ivBytes, data);
            return __makeCipherParams(resBytes, kBytes, ivBytes, saltBytes, mode);
        },
        decrypt: function(cipher, key, options) {
            options = options || {};
            var cipherParams = typeof cipher === "string" ? CryptoJS.format.OpenSSL.parse(cipher) : cipher;
            var data = cipherParams.ciphertext ? __wordArrayToBytes(cipherParams.ciphertext) : __toUint8Array(cipherParams);
            var kBytes, ivBytes;
            if (typeof key === "string") {
                var saltBytes = options.salt ? __wordArrayToBytes(options.salt) : (cipherParams.salt ? __wordArrayToBytes(cipherParams.salt) : new Uint8Array(0));
                var derived = __evpKdf(new TextEncoder().encode(key), saltBytes, keySizeBytes, ivSizeBytes);
                kBytes = derived.key;
                ivBytes = options.iv ? __wordArrayToBytes(options.iv) : derived.iv;
            } else {
                kBytes = __wordArrayToBytes(key);
                ivBytes = options.iv ? __wordArrayToBytes(options.iv) : new Uint8Array(0);
            }
            var mode = modeNameFn(options.mode, options.padding);
            return __bytesToWordArray(nativeFn(false, mode, kBytes, ivBytes, data));
        }
    };
}
var CryptoJS = {
    enc: {
        Hex: {
            stringify: function(wordArray) { return __bytesToHex(__wordArrayToBytes(wordArray)); },
            parse: function(hexStr) { return __bytesToWordArray(__hexToBytes(hexStr)); }
        },
        Utf8: {
            stringify: function(wordArray) { return new TextDecoder("utf-8").decode(__wordArrayToBytes(wordArray)); },
            parse: function(utf8Str) { return __bytesToWordArray(new TextEncoder().encode(String(utf8Str))); }
        },
        Latin1: {
            stringify: function(wordArray) { var bytes = __wordArrayToBytes(wordArray); var out = ""; for (var i = 0; i < bytes.length; i++) out += String.fromCharCode(bytes[i]); return out; },
            parse: function(str) { str = String(str || ""); var bytes = new Uint8Array(str.length); for (var i = 0; i < str.length; i++) bytes[i] = str.charCodeAt(i) & 0xff; return __bytesToWordArray(bytes); }
        },
        Base64: {
            stringify: function(wordArray) { var bytes = __wordArrayToBytes(wordArray); var binaryStr = ""; for (var j = 0; j < bytes.length; j++) binaryStr += String.fromCharCode(bytes[j]); return btoa(binaryStr); },
            parse: function(base64Str) { var binaryStr = atob(String(base64Str || "")); var bytes = new Uint8Array(binaryStr.length); for (var i = 0; i < binaryStr.length; i++) bytes[i] = binaryStr.charCodeAt(i) & 0xff; return __bytesToWordArray(bytes); }
        }
    },
    lib: {
        WordArray: {
            create: function(words, sigBytes) {
                if (words == null) return __wordArrayCreate([], sigBytes || 0);
                if (__isWordArray(words)) return words.clone();
                if (typeof words === "string") return CryptoJS.enc.Utf8.parse(words);
                if (words instanceof ArrayBuffer || (typeof ArrayBuffer !== "undefined" && ArrayBuffer.isView && ArrayBuffer.isView(words))) {
                    var bytes = __toUint8Array(words);
                    return __bytesToWordArray(sigBytes != undefined ? bytes.subarray(0, sigBytes) : bytes);
                }
                return __wordArrayCreate(words, sigBytes);
            },
            random: function(nBytes) {
                var bytes = new Uint8Array(nBytes || 0);
                globalThis.crypto.getRandomValues(bytes);
                return __bytesToWordArray(bytes);
            }
        },
        CipherParams: {
            create: function(params) {
                params = params || {};
                params.toString = params.toString || function(formatter) { return (formatter || CryptoJS.format.OpenSSL).stringify(this); };
                return params;
            }
        }
    },
    format: {
        OpenSSL: {
            stringify: function(cipherParams) {
                var cipherBytes = __wordArrayToBytes(cipherParams.ciphertext);
                var out = cipherParams.salt ? __concatBytes(__opensslSaltHeader(), __wordArrayToBytes(cipherParams.salt), cipherBytes) : cipherBytes;
                return CryptoJS.enc.Base64.stringify(__bytesToWordArray(out));
            },
            parse: function(str) {
                var bytes = __wordArrayToBytes(CryptoJS.enc.Base64.parse(str));
                if (__hasOpenSslSaltHeader(bytes)) return CryptoJS.lib.CipherParams.create({ salt: __bytesToWordArray(bytes.subarray(8, 16)), ciphertext: __bytesToWordArray(bytes.subarray(16)) });
                return CryptoJS.lib.CipherParams.create({ ciphertext: __bytesToWordArray(bytes) });
            }
        }
    },
    mode: { CBC: "AES-CBC", GCM: "AES-GCM", ECB: "AES-ECB", CTR: "AES-CTR", CFB: "AES-CFB", OFB: "AES-OFB" },
    pad: { Pkcs7: "Pkcs7", NoPadding: "NoPadding" },
    algo: { MD5: "MD5", SHA1: "SHA1", SHA256: "SHA256", SHA384: "SHA384", SHA512: "SHA512", AES: "AES" },
    MD5: function(m) { return __bytesToWordArray(__nativeDigestBytes("MD5", __normalizeWordArrayInput(m))); },
    SHA1: function(m) { return __bytesToWordArray(__nativeDigestBytes("SHA1", __normalizeWordArrayInput(m))); },
    SHA256: function(m) { return __bytesToWordArray(__nativeDigestBytes("SHA256", __normalizeWordArrayInput(m))); },
    SHA384: function(m) { return __bytesToWordArray(__nativeDigestBytes("SHA384", __normalizeWordArrayInput(m))); },
    SHA512: function(m) { return __bytesToWordArray(__nativeDigestBytes("SHA512", __normalizeWordArrayInput(m))); },
    HmacMD5: function(m, k) { return __bytesToWordArray(__nativeHmacBytes("MD5", __normalizeWordArrayInput(k), __normalizeWordArrayInput(m))); },
    HmacSHA1: function(m, k) { return __bytesToWordArray(__nativeHmacBytes("SHA1", __normalizeWordArrayInput(k), __normalizeWordArrayInput(m))); },
    HmacSHA256: function(m, k) { return __bytesToWordArray(__nativeHmacBytes("SHA256", __normalizeWordArrayInput(k), __normalizeWordArrayInput(m))); },
    HmacSHA384: function(m, k) { return __bytesToWordArray(__nativeHmacBytes("SHA384", __normalizeWordArrayInput(k), __normalizeWordArrayInput(m))); },
    HmacSHA512: function(m, k) { return __bytesToWordArray(__nativeHmacBytes("SHA512", __normalizeWordArrayInput(k), __normalizeWordArrayInput(m))); },
    PBKDF2: function(pass, salt, options) {
        options = options || {};
        var pBytes = __normalizeWordArrayInput(pass);
        var sBytes = __normalizeWordArrayInput(salt);
        var iter = options.iterations || 1000;
        var kSize = options.keySize || 8;
        var algo = options.hasher || "SHA1";
        return __bytesToWordArray(__nativePbkdf2Bytes(pBytes, sBytes, iter, kSize * 32, algo));
    }
};
CryptoJS.AES = __makeCipherApi(__nativeAesBytes, __aesModeName, 32, 16);
CryptoJS.TripleDES = __makeCipherApi(__nativeDes3Bytes, __des3ModeName, 24, 8);
CryptoJS.DES3 = CryptoJS.TripleDES;
globalThis.CryptoJS = CryptoJS;

function __makeCryptoKey(type, algorithm, extractable, usages, rawBytes) {
    return { type: type, extractable: !!extractable, algorithm: algorithm, usages: usages || [], _raw: __copyUint8Array(rawBytes) };
}
function __webCryptoAlgorithm(algo) {
    var name = __normalizeAlgorithmName(algo);
    var out = { name: name };
    if (algo && typeof algo === "object" && algo.length) out.length = algo.length;
    if (algo && typeof algo === "object" && algo.hash) out.hash = { name: __normalizeHashName(algo.hash) };
    return out;
}
globalThis.crypto = {
    subtle: {
        digest: async function(algo, data) { return __bytesToArrayBuffer(__nativeDigestBytes(algo, __toUint8Array(data))); },
        importKey: async function(fmt, data, algo, extractable, usages) {
            fmt = String(fmt || "raw").toLowerCase();
            if (fmt !== "raw") throw new Error("Unsupported key format: " + fmt);
            return __makeCryptoKey("secret", __webCryptoAlgorithm(algo || {}), extractable, usages || [], __toUint8Array(data));
        },
        exportKey: async function(fmt, key) { return __bytesToArrayBuffer(key._raw); },
        deriveBits: async function(params, key, len) {
            if (__normalizeAlgorithmName(params) !== "PBKDF2") throw new Error("Only PBKDF2 deriveBits is supported");
            return __bytesToArrayBuffer(__nativePbkdf2Bytes(__toUint8Array(key._raw), __toUint8Array(params.salt), params.iterations || 1000, len, params.hash || "SHA-256"));
        },
        encrypt: async function(params, key, data) {
            var mode = __normalizeAlgorithmName(params);
            if (mode !== "AES-CBC" && mode !== "AES-GCM") throw new Error("Unsupported encrypt algorithm: " + mode);
            return __bytesToArrayBuffer(__nativeAesBytes(true, mode, __toUint8Array(key._raw), __toUint8Array(params.iv || new Uint8Array(0)), __toUint8Array(data)));
        },
        decrypt: async function(params, key, data) {
            var mode = __normalizeAlgorithmName(params);
            if (mode !== "AES-CBC" && mode !== "AES-GCM") throw new Error("Unsupported decrypt algorithm: " + mode);
            return __bytesToArrayBuffer(__nativeAesBytes(false, mode, __toUint8Array(key._raw), __toUint8Array(params.iv || new Uint8Array(0)), __toUint8Array(data)));
        },
        sign: async function(algo, key, data) {
            if (__normalizeAlgorithmName(algo || key.algorithm) === "HMAC" || (key.algorithm && key.algorithm.name === "HMAC")) {
                var hash = (algo && algo.hash) || (key.algorithm && key.algorithm.hash) || "SHA-256";
                return __bytesToArrayBuffer(__nativeHmacBytes(hash, __toUint8Array(key._raw), __toUint8Array(data)));
            }
            throw new Error("Unsupported sign algorithm");
        },
        verify: async function(algo, key, sig, data) {
            if (__normalizeAlgorithmName(algo || key.algorithm) === "HMAC" || (key.algorithm && key.algorithm.name === "HMAC")) {
                var expected = __nativeHmacBytes((algo && algo.hash) || (key.algorithm && key.algorithm.hash) || "SHA-256", __toUint8Array(key._raw), __toUint8Array(data));
                var actual = __toUint8Array(sig);
                if (expected.length !== actual.length) return false;
                var diff = 0;
                for (var i = 0; i < expected.length; i++) diff |= expected[i] ^ actual[i];
                return diff === 0;
            }
            throw new Error("Unsupported verify algorithm");
        }
    },
    getRandomValues: function(arr) {
        if (!arr) return arr;
        var byteLength = arr.byteLength != undefined ? arr.byteLength : arr.length;
        if (!byteLength) return arr;
        if (typeof __crypto_get_random_values_hex === "undefined") throw new Error("Native random bridge is unavailable");
        if (byteLength > 65536) throw new Error("QuotaExceededError: getRandomValues supports at most 65536 bytes");
        var random = __hexToBytes(__crypto_get_random_values_hex(byteLength));
        if (random.length < byteLength) throw new Error("Native random bridge returned insufficient entropy");
        if (arr.buffer && arr.byteLength != undefined) new Uint8Array(arr.buffer, arr.byteOffset || 0, arr.byteLength).set(random);
        else for (var i = 0; i < arr.length; i++) arr[i] = random[i] || 0;
        return arr;
    },
    randomUUID: function() {
        var b = new Uint8Array(16);
        globalThis.crypto.getRandomValues(b);
        b[6] = (b[6] & 0x0f) | 0x40;
        b[8] = (b[8] & 0x3f) | 0x80;
        var h = __bytesToHex(b);
        return h.substr(0, 8) + "-" + h.substr(8, 4) + "-" + h.substr(12, 4) + "-" + h.substr(16, 4) + "-" + h.substr(20);
    }
};

globalThis.WebAssembly = globalThis.WebAssembly || {
    instantiate: async function() { return { instance: { exports: {} }, module: {} }; }
};

function __cheerioFiltered(list, selector) {
    if (selector === undefined || selector === null) return createCheerioCollection(list);
    var needle = String(selector);
    if (needle === "*") return createCheerioCollection(list);
    return createCheerioCollection(list.filter(function(id) {
        return __cheerio_matches(id, needle);
    }));
}
function createCheerioCollection(ids) {
    ids = ids || [];
    function api(selector) { return api.find(selector); }
    api.length = ids.length;
    api.get = function(index) {
        if (index === undefined) return ids.map(function(id) { return createCheerioCollection([id]); });
        return ids[index] == null ? undefined : createCheerioCollection([ids[index]]);
    };
    api.eq = function(index) { return ids[index] == null ? createCheerioCollection([]) : createCheerioCollection([ids[index]]); };
    api.first = function() { return api.eq(0); };
    api.last = function() { return api.eq(ids.length - 1); };
    api.text = function() { return ids.map(function(id) { return __cheerio_text(id); }).join(""); };
    api.html = function() { return ids.length ? __cheerio_inner_html(ids[0]) : null; };
    api.outerHtml = function() { return ids.length ? __cheerio_html(ids[0]) : null; };
    api.attr = function(name) {
        if (!ids.length) return undefined;
        var value = __cheerio_attr(ids[0], String(name));
        return value == null ? undefined : value;
    };
    api.find = function(selector) {
        var out = [];
        ids.forEach(function(id) { out = out.concat(__cheerio_select(id, String(selector))); });
        return createCheerioCollection(out);
    };
    api.next = function() {
        var out = [];
        ids.forEach(function(id) {
            var next = __cheerio_next(id);
            if (next) out.push(next);
        });
        return createCheerioCollection(out);
    };
    api.prev = function() {
        var out = [];
        ids.forEach(function(id) {
            var previous = __cheerio_prev(id);
            if (previous) out.push(previous);
        });
        return createCheerioCollection(out);
    };
    api.each = function(fn) {
        ids.forEach(function(id, index) { fn.call(createCheerioCollection([id]), index, createCheerioCollection([id])); });
        return api;
    };
    api.map = function(fn) {
        var out = [];
        ids.forEach(function(id, index) {
            var value = fn.call(createCheerioCollection([id]), index, createCheerioCollection([id]));
            if (value !== undefined && value !== null) out.push(value);
        });
        return {
            length: out.length,
            get: function(index) { return typeof index === "number" ? out[index] : out; },
            toArray: function() { return out; }
        };
    };
    api.filter = function(selectorOrCallback) {
        if (typeof selectorOrCallback === "function") {
            var filtered = [];
            ids.forEach(function(id, index) {
                var item = createCheerioCollection([id]);
                if (selectorOrCallback.call(item, index, item)) filtered.push(id);
            });
            return createCheerioCollection(filtered);
        }
        var selector = String(selectorOrCallback);
        return createCheerioCollection(ids.filter(function(id) {
            return __cheerio_matches(id, selector);
        }));
    };
    api.is = function(selector) {
        if (selector == null) return false;
        var needle = String(selector);
        return ids.some(function(id) { return __cheerio_matches(id, needle); });
    };
    api.not = function(selector) {
        var needle = String(selector);
        return createCheerioCollection(ids.filter(function(id) {
            return !__cheerio_matches(id, needle);
        }));
    };
    api.slice = function(start, end) {
        return createCheerioCollection(ids.slice(start, end === undefined ? ids.length : end));
    };
    api.children = function(selector) {
        var out = [];
        ids.forEach(function(id) { out = out.concat(__cheerio_children(id)); });
        return __cheerioFiltered(out, selector);
    };
    api.hasClass = function(name) {
        if (name === undefined || name === null) return false;
        var needle = String(name);
        if (!needle.length) return false;
        return ids.some(function(id) {
            var raw = __cheerio_attr(id, "class");
            if (typeof raw !== "string" || !raw.length) return false;
            var token = "";
            for (var i = 0; i <= raw.length; i++) {
                var code = i < raw.length ? raw.charCodeAt(i) : 32;
                if (code === 32 || code === 9 || code === 10 || code === 13 || code === 12) {
                    if (token === needle) return true;
                    token = "";
                } else {
                    token += raw.charAt(i);
                }
            }
            return false;
        });
    };
    api.nextAll = function(selector) {
        var out = [];
        ids.forEach(function(id) {
            var cursor = __cheerio_next(id);
            while (cursor) { out.push(cursor); cursor = __cheerio_next(cursor); }
        });
        return __cheerioFiltered(out, selector);
    };
    api.prevAll = function(selector) {
        var out = [];
        ids.forEach(function(id) {
            var cursor = __cheerio_prev(id);
            while (cursor) { out.push(cursor); cursor = __cheerio_prev(cursor); }
        });
        return __cheerioFiltered(out, selector);
    };
    api.siblings = function(selector) {
        var out = [];
        ids.forEach(function(id) {
            var backwards = [];
            var cursor = __cheerio_prev(id);
            while (cursor) { backwards.push(cursor); cursor = __cheerio_prev(cursor); }
            backwards.reverse();
            out = out.concat(backwards);
            cursor = __cheerio_next(id);
            while (cursor) { out.push(cursor); cursor = __cheerio_next(cursor); }
        });
        return __cheerioFiltered(out, selector);
    };
    api.parents = function(selector) {
        var out = [];
        ids.forEach(function(id) {
            var cursor = __cheerio_parent(id);
            while (cursor) { out.push(cursor); cursor = __cheerio_parent(cursor); }
        });
        return __cheerioFiltered(out, selector);
    };
    api.closest = function(selector) {
        if (selector === undefined || selector === null) return createCheerioCollection([]);
        var needle = String(selector);
        var out = [];
        ids.forEach(function(id) {
            var cursor = id;
            while (cursor) {
                if (__cheerio_matches(cursor, needle)) { out.push(cursor); return; }
                cursor = __cheerio_parent(cursor);
            }
        });
        return createCheerioCollection(out);
    };
    api.parent = function() {
        var out = [];
        ids.forEach(function(id) {
            var parent = __cheerio_parent(id);
            if (parent) out.push(parent);
        });
        return createCheerioCollection(out);
    };
    api.toArray = function() { return ids.map(function(id) { return createCheerioCollection([id]); }); };
    return api;
}
function cheerioLoad(html) {
    var root = __cheerio_load(String(html || ""));
    function cheerioFn(selector, context) {
        if (selector == null) return createCheerioCollection([root]);
        if (selector && (typeof selector === "object" || typeof selector === "function") && typeof selector.toArray === "function") {
            return selector;
        }
        if (context && (typeof context === "object" || typeof context === "function") && typeof context.find === "function") {
            return context.find(String(selector));
        }
        return createCheerioCollection(__cheerio_select(root, String(selector)));
    }
    cheerioFn.html = function(node) {
        if (node && typeof node === "object" && typeof node.outerHtml === "function") {
            return node.outerHtml();
        }
        return __cheerio_html(root);
    };
    return cheerioFn;
}
var cheerioModule = { load: cheerioLoad };

globalThis.require = function(name) {
    if (name === "cheerio" || name === "cheerio-without-node-native" || name === "react-native-cheerio") return cheerioModule;
    if (name === "crypto-js") return globalThis.CryptoJS;
    throw new Error("Module not available: " + name);
};
