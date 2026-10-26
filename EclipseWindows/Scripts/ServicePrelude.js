function fetchv2(url, headers = {}, method = "GET", body = null, redirect = true, encoding) {
    var processedBody = null;
    if (method != "GET") {
        processedBody = (body && (typeof body === 'object')) ? JSON.stringify(body) : (body || null);
    }
    var finalEncoding = encoding || "utf-8";
    var processedHeaders = {};
    if (headers && typeof headers === 'object' && !Array.isArray(headers)) {
        processedHeaders = headers;
    }
    return new Promise(function(resolve, reject) {
        fetchV2Native(url, processedHeaders, method, processedBody, redirect, finalEncoding, function(rawText) {
            const responseObj = {
                headers: rawText.headers,
                status: rawText.status,
                ok: rawText.ok || (rawText.status >= 200 && rawText.status < 300),
                url: rawText.url || url,
                error: rawText.error || null,
                _data: rawText.body,
                text: function() {
                    return Promise.resolve(this._data);
                },
                json: function() {
                    try {
                        return Promise.resolve(JSON.parse(this._data));
                    } catch (e) {
                        return Promise.reject("JSON parse error: " + e.message);
                    }
                }
            };
            resolve(responseObj);
        }, reject);
    });
}
function soraFetch(url, options) {
    var headers = {};
    var method = "GET";
    var body = null;
    var redirect = true;
    var encoding = undefined;
    if (options) {
        if (options.headers !== undefined || options.method !== undefined || options.body !== undefined || options.redirect !== undefined || options.encoding !== undefined) {
            headers = options.headers || {};
            method = options.method || "GET";
            body = options.body || null;
            redirect = options.redirect !== undefined ? options.redirect : true;
            encoding = options.encoding;
        } else if (typeof options === "object" && !Array.isArray(options)) {
            headers = options;
        }
    }
    return fetchv2(url, headers, method, body, redirect, encoding);
}
function fetch(url, options) {
    return soraFetch(url, options);
}
if (typeof sendLog === "undefined") {
    function sendLog(message) {
        if (typeof console !== "undefined" && console.log) {
            console.log("[Module] " + message);
        }
    }
}
function networkFetch(url, options = {}) {
    if (typeof options === 'number') {
        options = { timeoutSeconds: options, headers: arguments[2] || {}, cutoff: arguments[3] || null };
    }
    const finalOptions = {
        timeoutSeconds: options.timeoutSeconds || 10,
        headers: options.headers || {},
        cutoff: options.cutoff || null,
        returnHTML: options.returnHTML || false,
        returnCookies: options.returnCookies !== undefined ? options.returnCookies : true,
        clickSelectors: options.clickSelectors || [],
        waitForSelectors: options.waitForSelectors || [],
        maxWaitTime: options.maxWaitTime || 5,
        htmlContent: options.htmlContent || null
    };
    return new Promise(function(resolve, reject) {
        networkFetchNative(url || '', finalOptions, function(result) {
            const requests = result.requests || [];
            resolve({
                url: result.originalUrl,
                requests: requests,
                html: result.html || null,
                cookies: result.cookies || null,
                success: result.success,
                error: result.error || null,
                totalRequests: requests.length,
                requestsTruncated: result.requestsTruncated || false,
                cutoffTriggered: result.cutoffTriggered || false,
                cutoffUrl: result.cutoffUrl || null,
                htmlCaptured: result.htmlCaptured || false,
                htmlTruncated: result.htmlTruncated || false,
                cookiesCaptured: result.cookiesCaptured || false,
                elementsClicked: result.elementsClicked || [],
                waitResults: result.waitResults || {}
            });
        }, reject);
    });
}
function networkFetchWithHTML(url, timeoutSeconds = 10) {
    return networkFetch(url, { timeoutSeconds: timeoutSeconds, returnHTML: true, returnCookies: true });
}
function networkFetchWithCutoff(url, cutoff, timeoutSeconds = 10) {
    return networkFetch(url, { timeoutSeconds: timeoutSeconds, cutoff: cutoff, returnCookies: true });
}
function networkFetchWithClicks(url, clickSelectors, options = {}) {
    return networkFetch(url, {
        timeoutSeconds: options.timeoutSeconds || 10,
        headers: options.headers || {},
        cutoff: options.cutoff || null,
        returnHTML: options.returnHTML || false,
        returnCookies: options.returnCookies !== undefined ? options.returnCookies : true,
        clickSelectors: Array.isArray(clickSelectors) ? clickSelectors : [clickSelectors],
        waitForSelectors: options.waitForSelectors || [],
        maxWaitTime: options.maxWaitTime || 5
    });
}
function networkFetchWithWaitAndClick(url, waitForSelectors, clickSelectors, options = {}) {
    return networkFetch(url, {
        timeoutSeconds: options.timeoutSeconds || 10,
        headers: options.headers || {},
        cutoff: options.cutoff || null,
        returnHTML: options.returnHTML || false,
        returnCookies: options.returnCookies !== undefined ? options.returnCookies : true,
        clickSelectors: Array.isArray(clickSelectors) ? clickSelectors : [clickSelectors],
        waitForSelectors: Array.isArray(waitForSelectors) ? waitForSelectors : [waitForSelectors],
        maxWaitTime: options.maxWaitTime || 5
    });
}
function networkFetchFromHTML(htmlContent, options = {}) {
    return networkFetch('', {
        timeoutSeconds: options.timeoutSeconds || 10,
        headers: options.headers || {},
        cutoff: options.cutoff || null,
        returnHTML: options.returnHTML || false,
        returnCookies: options.returnCookies !== undefined ? options.returnCookies : true,
        clickSelectors: options.clickSelectors || [],
        waitForSelectors: options.waitForSelectors || [],
        maxWaitTime: options.maxWaitTime || 5,
        htmlContent: htmlContent
    });
}
function getElementsByTag(html, tag) {
    const regex = new RegExp(`<${tag}[^>]*>([\\s\\S]*?)<\\/${tag}>`, 'gi');
    let result = [];
    let match;
    while ((match = regex.exec(html)) !== null) {
        result.push(match[1]);
    }
    return result;
}
function getAttribute(html, tag, attr) {
    const regex = new RegExp(`<${tag}[^>]*${attr}=["']?([^"' >]+)["']?[^>]*>`, 'i');
    const match = regex.exec(html);
    return match ? match[1] : null;
}
function getInnerText(html) {
    return html.replace(/<[^>]+>/g, '').replace(/\s+/g, ' ').trim();
}
function extractBetween(str, start, end) {
    const s = str.indexOf(start);
    if (s === -1) return '';
    const e = str.indexOf(end, s + start.length);
    if (e === -1) return '';
    return str.substring(s + start.length, e);
}
function stripHtml(html) {
    return html.replace(/<[^>]+>/g, '');
}
function normalizeWhitespace(str) {
    return str.replace(/\s+/g, ' ').trim();
}
function urlEncode(str) {
    return encodeURIComponent(str);
}
function urlDecode(str) {
    try { return decodeURIComponent(str); } catch (e) { return str; }
}
function htmlEntityDecode(str) {
    return str.replace(/&([a-zA-Z]+);/g, function(_, entity) {
        const entities = { quot: '"', apos: "'", amp: '&', lt: '<', gt: '>' };
        return entities[entity] || _;
    });
}
function transformResponse(response, fn) {
    try { return fn(response); } catch (e) { return response; }
}
