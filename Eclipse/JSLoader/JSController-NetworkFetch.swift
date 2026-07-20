import Combine
import Foundation
import JavaScriptCore

#if !os(tvOS)
import WebKit
#if os(iOS)
import UIKit
#endif

/// A viewport that contradicts the declared User-Agent (e.g. a fixed 1920x1080 desktop
/// canvas under a mobile UA) is an internal-consistency tell bot detection checks for.
/// Keep the two in the same class so they always agree.
private func serviceWebViewViewportBounds(forUserAgent userAgent: String) -> CGRect {
    let lowerUA = userAgent.lowercased()
    let isMobile = lowerUA.contains("mobile") || lowerUA.contains("iphone") || lowerUA.contains("android")
    #if os(iOS)
    if isMobile {
        return UIScreen.main.bounds
    }
    #endif
    return isMobile
        ? CGRect(x: 0, y: 0, width: 414, height: 896)
        : CGRect(x: 0, y: 0, width: 1920, height: 1080)
}

private enum ServiceWebViewCookieLoader {
    static func load(_ request: URLRequest, in webView: WKWebView, for url: URL) {
        if let host = url.host,
           let userAgent = CloudflareBypassManager.shared.bypassUserAgent(for: host) {
            // This overrides whatever UA setupWebView() picked (and sized the frame for), so
            // the frame has to be re-paired here too or we reintroduce the exact
            // viewport/UA mismatch this pairing exists to avoid.
            webView.customUserAgent = userAgent
            webView.frame = serviceWebViewViewportBounds(forUserAgent: userAgent)
        }

        #if os(tvOS)
        webView.load(request)
        #else
        guard let cookieHeader = request.value(forHTTPHeaderField: "Cookie"),
              let host = url.host,
              !cookieHeader.isEmpty else {
            webView.load(request)
            return
        }

        let cookies = cookies(from: cookieHeader, host: host)
        guard !cookies.isEmpty else {
            webView.load(request)
            return
        }

        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        Task { @MainActor in
            for cookie in cookies {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    cookieStore.setCookie(cookie) {
                        continuation.resume()
                    }
                }
            }
            webView.load(request)
        }
        #endif
    }

    #if !os(tvOS)
    private static func cookies(from header: String, host: String) -> [HTTPCookie] {
        header.split(separator: ";").compactMap { part in
            let pieces = part.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard pieces.count == 2, !pieces[0].isEmpty else { return nil }
            return HTTPCookie(properties: [
                .name: pieces[0],
                .value: pieces[1],
                .domain: host,
                .path: "/",
                .secure: "TRUE"
            ])
        }
    }
    #endif
}
#endif

struct NetworkFetchOptions {
    let timeoutSeconds: Int
    let headers: [String: String]
    let cutoff: String?
    let returnHTML: Bool
    let returnCookies: Bool
    let clickSelectors: [String]
    let waitForSelectors: [String]
    let maxWaitTime: Int
    let htmlContent: String?
    
    init(
        timeoutSeconds: Int = 10,
        headers: [String: String] = [:],
        cutoff: String? = nil,
        returnHTML: Bool = false,
        returnCookies: Bool = true,
        clickSelectors: [String] = [],
        waitForSelectors: [String] = [],
        maxWaitTime: Int = 5,
        htmlContent: String? = nil
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.headers = headers
        self.cutoff = cutoff
        self.returnHTML = returnHTML
        self.returnCookies = returnCookies
        self.clickSelectors = clickSelectors
        self.waitForSelectors = waitForSelectors
        self.maxWaitTime = maxWaitTime
        self.htmlContent = htmlContent
    }
}

extension JSContext {
    func setupNetworkFetch(sandbox: ServiceSandboxState) {
        let networkFetchNativeFunction: @convention(block) (String, JSValue?, JSValue, JSValue) -> Void = { urlString, optionsValue, resolve, reject in
            guard let operation = sandbox.allowServiceNetworkRequest(api: "networkFetch", urlString: urlString) else {
                reject.call(withArguments: ["Service network request blocked by sandbox"])
                return
            }

            DispatchQueue.main.async {
                var options = NetworkFetchOptions()

                if let optionsDict = optionsValue?.toDictionary() {
                    let timeoutSeconds = optionsDict["timeoutSeconds"] as? Int ?? 10
                    let headers = optionsDict["headers"] as? [String: String] ?? [:]
                    let cutoff = optionsDict["cutoff"] as? String
                    let returnHTML = optionsDict["returnHTML"] as? Bool ?? false
                    let returnCookies = optionsDict["returnCookies"] as? Bool ?? true
                    let clickSelectors = optionsDict["clickSelectors"] as? [String] ?? []
                    let waitForSelectors = optionsDict["waitForSelectors"] as? [String] ?? []
                    let maxWaitTime = optionsDict["maxWaitTime"] as? Int ?? 5
                    let htmlContent = optionsDict["htmlContent"] as? String

                    options = NetworkFetchOptions(
                        timeoutSeconds: timeoutSeconds,
                        headers: headers,
                        cutoff: cutoff,
                        returnHTML: returnHTML,
                        returnCookies: returnCookies,
                        clickSelectors: clickSelectors,
                        waitForSelectors: waitForSelectors,
                        maxWaitTime: maxWaitTime,
                        htmlContent: htmlContent
                    )
                }

                NetworkFetchManager.shared.performNetworkFetch(
                    urlString: urlString,
                    options: options,
                    operation: operation,
                    resolve: resolve,
                    reject: reject
                )
            }
        }

        self.setObject(networkFetchNativeFunction, forKeyedSubscript: "networkFetchNative" as NSString)

        let networkFetchDefinition = """
            function networkFetch(url, options = {}) {
                if (typeof options === 'number') {
                    const timeoutSeconds = options;
                    const headers = arguments[2] || {};
                    const cutoff = arguments[3] || null;
                    options = { timeoutSeconds, headers, cutoff };
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
                            cutoffTriggered: result.cutoffTriggered || false,
                            cutoffUrl: result.cutoffUrl || null,
                            htmlCaptured: result.htmlCaptured || false,
                            cookiesCaptured: result.cookiesCaptured || false,
                            elementsClicked: result.elementsClicked || [],
                            waitResults: result.waitResults || {}
                        });
                    }, reject);
                });
            }

            function networkFetchWithHTML(url, timeoutSeconds = 10) {
                return networkFetch(url, {
                    timeoutSeconds: timeoutSeconds,
                    returnHTML: true,
                    returnCookies: true
                });
            }

            function networkFetchWithCutoff(url, cutoff, timeoutSeconds = 10) {
                return networkFetch(url, {
                    timeoutSeconds: timeoutSeconds,
                    cutoff: cutoff,
                    returnCookies: true
                });
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
            """

        self.evaluateScript(networkFetchDefinition)
    }

    func setupNetworkFetchSimple(sandbox: ServiceSandboxState) {
        let networkFetchSimpleNativeFunction: @convention(block) (String, JSValue?, JSValue, JSValue) -> Void = { urlString, optionsValue, resolve, reject in
            guard let operation = sandbox.allowServiceNetworkRequest(api: "networkFetchSimple", urlString: urlString) else {
                reject.call(withArguments: ["Service network request blocked by sandbox"])
                return
            }

            DispatchQueue.main.async {
                var timeoutSeconds = 5
                var htmlContent: String? = nil
                var headers: [String: String] = [:]
                if let optionsDict = optionsValue?.toDictionary() {
                    timeoutSeconds = optionsDict["timeoutSeconds"] as? Int ?? 5
                    htmlContent = optionsDict["htmlContent"] as? String
                    headers = optionsDict["headers"] as? [String: String] ?? [:]
                }
                NetworkFetchSimpleManager.shared.performNetworkFetch(
                    urlString: urlString,
                    timeoutSeconds: timeoutSeconds,
                    htmlContent: htmlContent,
                    headers: headers,
                    operation: operation,
                    resolve: resolve,
                    reject: reject
                )
            }
        }
        self.setObject(networkFetchSimpleNativeFunction, forKeyedSubscript: "networkFetchSimpleNative" as NSString)
        let networkFetchSimpleDefinition = """
            function networkFetchSimple(url, options = {}) {
                if (typeof options === 'number') {
                    const timeoutSeconds = options;
                    options = { timeoutSeconds };
                }
                const finalOptions = {
                    timeoutSeconds: options.timeoutSeconds || 5,
                    htmlContent: options.htmlContent || null,
                    headers: options.headers || {}
                };
                return new Promise(function(resolve, reject) {
                    networkFetchSimpleNative(url || '', finalOptions, function(result) {
                        const requests = result.requests || [];
                        resolve({
                            url: result.originalUrl,
                            requests: requests,
                            success: result.success,
                            error: result.error || null,
                            totalRequests: requests.length
                        });
                    }, reject);
                });
            }

            function networkFetchSimpleFromHTML(htmlContent, options = {}) {
                return networkFetchSimple('', {
                    timeoutSeconds: options.timeoutSeconds || 5,
                    htmlContent: htmlContent,
                    headers: options.headers || {}
                });
            }
            """
        self.evaluateScript(networkFetchSimpleDefinition)
    }
}

#if !os(tvOS)
class NetworkFetchSimpleManager: NSObject, ObservableObject {
    static let shared = NetworkFetchSimpleManager()

    private var activeMonitors: [String: NetworkFetchSimpleMonitor] = [:]

    private override init() {
        super.init()
    }

    func performNetworkFetch(urlString: String, timeoutSeconds: Int, htmlContent: String? = nil, headers: [String: String] = [:], operation: ServiceSandboxOperation, resolve: JSValue, reject: JSValue) {
        let monitorId = UUID().uuidString
        let monitor = NetworkFetchSimpleMonitor()
        activeMonitors[monitorId] = monitor
        monitor.startMonitoring(
            urlString: urlString,
            timeoutSeconds: timeoutSeconds,
            htmlContent: htmlContent,
            headers: headers,
            operation: operation
        ) { [weak self] result in
            self?.activeMonitors.removeValue(forKey: monitorId)
            DispatchQueue.main.async {
                if !resolve.isUndefined {
                    resolve.call(withArguments: [result])
                }
            }
        }
    }
}

class NetworkFetchSimpleMonitor: NSObject, ObservableObject {
    private var webView: WKWebView?
    private var completionHandler: (([String: Any]) -> Void)?
    private var timer: Timer?
    private var operation: ServiceSandboxOperation?

    @Published private(set) var networkRequests: [String] = []

    private var originalUrlString: String = ""

    func startMonitoring(urlString: String, timeoutSeconds: Int, htmlContent: String? = nil, headers: [String: String] = [:], operation: ServiceSandboxOperation, completion: @escaping ([String: Any]) -> Void) {
        originalUrlString = urlString
        self.operation = operation
        completionHandler = completion
        networkRequests.removeAll()
        if let htmlContent = htmlContent, !htmlContent.isEmpty {
            setupWebView()
            loadHTMLContent(htmlContent)
        } else {
            guard let url = URL(string: urlString) else {
                completion([
                    "originalUrl": urlString,
                    "requests": [],
                    "success": false,
                    "error": "Invalid URL format"
                ])
                return
            }
            setupWebView()
            loadURL(url: url, headers: headers)
        }
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(timeoutSeconds), repeats: false) { [weak self] _ in
            self?.stopMonitoring()
        }
    }

    private func loadHTMLContent(_ htmlContent: String) {
        guard let webView = webView else { return }

        addRequest("data:text/html;charset=utf-8,<html_content>")

        webView.loadHTMLString(htmlContent, baseURL: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.simulateUserInteraction()
        }
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
#if os(iOS)
        config.allowsInlineMediaPlayback = true
#endif
        config.mediaTypesRequiringUserActionForPlayback = []

        let jsCode = """
        """

        let userScript = WKUserScript(source: jsCode, injectionTime: WKUserScriptInjectionTime.atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(userScript)
        config.userContentController.add(self, name: "networkLogger")

        // Desktop-only pool paired with the fixed desktop frame below: existing service
        // scrapers' clickSelectors/waitForSelectors were built and tested against a guaranteed
        // desktop-shaped DOM, so this deliberately doesn't vary the viewport by UA pick — only
        // the cached-bypass-session path (ServiceWebViewCookieLoader.load) resizes the frame,
        // for the specific hosts where the resulting UA is a real, non-desktop device profile.
        let userAgent = URLSession.randomDesktopUserAgent
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), configuration: config)
        webView?.navigationDelegate = self

        webView?.customUserAgent = userAgent
    }

    private func loadURL(url: URL, headers: [String: String] = [:]) {
        guard let webView = webView else { return }
        addRequest(url.absoluteString)
        var request = URLRequest(url: url)
        request.setValue(webView.customUserAgent ?? URLSession.randomUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.5", forHTTPHeaderField: "Accept-Language")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("upgrade-insecure-requests", forHTTPHeaderField: "Upgrade-Insecure-Requests")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        CloudflareBypassManager.shared.applyCachedBypass(to: &request, for: url)
        let randomReferers = [
            "https://www.google.com/",
            "https://www.youtube.com/",
            "https://twitter.com/",
            "https://www.reddit.com/",
            "https://www.facebook.com/"
        ]
        let randomReferer = randomReferers.randomElement() ?? "https://www.google.com/"
        if request.value(forHTTPHeaderField: "Referer") == nil {
            request.setValue(randomReferer, forHTTPHeaderField: "Referer")
        }
        ServiceWebViewCookieLoader.load(request, in: webView, for: url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.simulateUserInteraction()
        }
    }

    private func simulateUserInteraction() {
        guard let webView = webView else { return }

        let jsInteraction = """
        """
        webView.evaluateJavaScript(jsInteraction, completionHandler: nil)
    }

    private func stopMonitoring() {
        timer?.invalidate()
        timer = nil

        if let webView {
            Task { @MainActor in
                CloudflareBypassManager.shared.captureSolvedCookies(from: webView, for: webView.url)
            }
        }
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "networkLogger")

        let originalUrl = networkRequests.first == "data:text/html;charset=utf-8,<html_content>" ?
            "data:text/html;charset=utf-8,<html_content>" :
            (webView?.url?.absoluteString ?? originalUrlString)

        let result: [String: Any] = [
            "originalUrl": originalUrl,
            "requests": networkRequests,
            "success": true
        ]

        if let operation {
            Logger.shared.log("Service networkFetchSimple completed service=\(operation.serviceName) operation=\(operation.operation) requestCount=\(networkRequests.count) original=\(ServiceSandboxState.redactedURL(originalUrl))", type: "Service")
        }

        webView = nil
        operation = nil

        completionHandler?(result)
        completionHandler = nil
    }

    private func addRequest(_ urlString: String) {
        DispatchQueue.main.async {
            if !self.networkRequests.contains(urlString) {
                self.networkRequests.append(urlString)
            }
        }
    }
}

extension NetworkFetchSimpleMonitor: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation) {}

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation) {
        Task { @MainActor in
            CloudflareBypassManager.shared.captureSolvedCookies(from: webView, for: webView.url)
        }
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation, withError error: Error) {}
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url {
            if ServiceSandboxState.isBlockedTrackingURL(url.absoluteString) {
                if let operation {
                    Logger.shared.log("Service sandbox blocked tracking navigation service=\(operation.serviceName) operation=\(operation.operation) target=\(ServiceSandboxState.redactedURL(url.absoluteString))", type: "ServiceSandbox")
                }
                decisionHandler(.cancel)
                return
            }
            addRequest(url.absoluteString)
        }
        decisionHandler(.allow)
    }
}

extension NetworkFetchSimpleMonitor: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "networkLogger" {
            if let messageBody = message.body as? [String: Any],
               let url = messageBody["url"] as? String {
                addRequest(url)
            }
        }
    }
}

class NetworkFetchManager: NSObject, ObservableObject {
    static let shared = NetworkFetchManager()
    
    private var activeMonitors: [String: NetworkFetchMonitor] = [:]
    
    private override init() {
        super.init()
    }
    
    func performNetworkFetch(urlString: String, options: NetworkFetchOptions, operation: ServiceSandboxOperation, resolve: JSValue, reject: JSValue) {
        let monitorId = UUID().uuidString
        let monitor = NetworkFetchMonitor()
        activeMonitors[monitorId] = monitor
        
        monitor.startMonitoring(
            urlString: urlString,
            options: options,
            operation: operation
        ) { [weak self] result in
            self?.activeMonitors.removeValue(forKey: monitorId)
            
            DispatchQueue.main.async {
                if !resolve.isUndefined {
                    resolve.call(withArguments: [result])
                }
            }
        }
    }
}

class NetworkFetchMonitor: NSObject, ObservableObject {
    private var webView: WKWebView?
    private var completionHandler: (([String: Any]) -> Void)?
    private var timer: Timer?
    private var options: NetworkFetchOptions?
    private var operation: ServiceSandboxOperation?
    private var elementsClicked: [String] = []
    private var waitResults: [String: Bool] = [:]
    private var cookies: [String: String] = [:]
    
    @Published private(set) var networkRequests: [String] = []
    @Published private(set) var cutoffTriggered = false
    @Published private(set) var cutoffUrl: String? = nil
    @Published private(set) var htmlContent: String? = nil
    @Published private(set) var htmlCaptured = false
    @Published private(set) var cookiesCaptured = false
    
    func startMonitoring(urlString: String, options: NetworkFetchOptions, operation: ServiceSandboxOperation, completion: @escaping ([String: Any]) -> Void) {
        self.options = options
        self.operation = operation
        completionHandler = completion
        networkRequests.removeAll()
        cutoffTriggered = false
        cutoffUrl = nil
        htmlContent = nil
        htmlCaptured = false
        cookiesCaptured = false
        elementsClicked.removeAll()
        waitResults.removeAll()
        cookies.removeAll()


        if let htmlContent = options.htmlContent, !htmlContent.isEmpty {
            setupWebView()
            loadHTMLContent(htmlContent)
        } else {
            guard let url = URL(string: urlString) else {
                completion([
                    "originalUrl": urlString,
                    "requests": [],
                    "html": NSNull(),
                    "cookies": NSNull(),
                    "success": false,
                    "error": "Invalid URL format",
                    "htmlCaptured": false,
                    "cookiesCaptured": false,
                    "elementsClicked": [],
                    "waitResults": [:]
                ])
                return
            }
            
            setupWebView()
            loadURL(url: url, headers: options.headers)
        }
        
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(options.timeoutSeconds), repeats: false) { [weak self] _ in
            if options.returnHTML || options.returnCookies {
                self?.captureDataThenComplete()
            } else {
                self?.stopMonitoring(reason: "timeout")
            }
        }
    }
    
    private func captureDataThenComplete() {
        guard let webView = webView, let options = options else {
            stopMonitoring(reason: "timeout")
            return
        }
        
        let shouldCaptureHTML = options.returnHTML
        let shouldCaptureCookies = options.returnCookies
        
        var completedTasks = 0
        let totalTasks = (shouldCaptureHTML ? 1 : 0) + (shouldCaptureCookies ? 1 : 0)
        
        if totalTasks == 0 {
            stopMonitoring(reason: "timeout")
            return
        }
        
        let checkCompletion = {
            completedTasks += 1
            if completedTasks >= totalTasks {
                self.stopMonitoring(reason: "timeout_with_data")
            }
        }
        
        
        if shouldCaptureHTML {
            webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, error in
                DispatchQueue.main.async {
                    if let html = result as? String, error == nil {
                        self?.htmlContent = html
                        self?.htmlCaptured = true
                    }
                    checkCompletion()
                }
            }
        }
        
        if shouldCaptureCookies {
            captureCookies {
                DispatchQueue.main.async {
                    checkCompletion()
                }
            }
        }
    }
    
    private func captureCookies(completion: @escaping () -> Void) {
        guard let webView = webView else {
            completion()
            return
        }
        
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore

        cookieStore.getAllCookies { [weak self] cookies in
            DispatchQueue.main.async {
                var cookieDict: [String: String] = [:]
                for cookie in cookies {
                    cookieDict[cookie.name] = cookie.value
                }
                
                self?.cookies = cookieDict
                self?.cookiesCaptured = !cookieDict.isEmpty
                
                completion()
            }
        }
    }
    
    private func setupWebView() {
        let config = WKWebViewConfiguration()
#if os(iOS)
        config.allowsInlineMediaPlayback = true
#endif
        config.mediaTypesRequiringUserActionForPlayback = []

        let jsCode = """
        (function() {
            const eclipseBlockedHostSuffixes = [
                "google-analytics.com",
                "googletagmanager.com",
                "doubleclick.net",
                "googlesyndication.com",
                "facebook.net",
                "facebook.com",
                "mixpanel.com",
                "segment.io",
                "segment.com",
                "amplitude.com",
                "appsflyer.com",
                "branch.io",
                "hotjar.com",
                "clarity.ms",
                "scorecardresearch.com",
                "quantserve.com",
                "newrelic.com",
                "sentry.io",
                "datadoghq-browser-agent.com"
            ];
            const eclipseBlockedHostTokens = ["analytics", "telemetry", "metrics", "tracking", "tracker", "beacon"];
            function eclipseIsBlockedTrackingUrl(value) {
                try {
                    const parsed = new URL(value, window.location.href);
                    const host = parsed.hostname.toLowerCase();
                    if (eclipseBlockedHostSuffixes.some(suffix => host === suffix || host.endsWith("." + suffix))) {
                        return true;
                    }
                    return eclipseBlockedHostTokens.some(token => host.includes(token));
                } catch(e) {
                    return false;
                }
            }
            function eclipseReportBlockedTracking(type, value) {
                try {
                    const fullUrl = new URL(value, window.location.href).href;
                    window.webkit.messageHandlers.networkLogger.postMessage({
                        type: "blocked-tracking-" + type,
                        url: fullUrl
                    });
                } catch(e) {
                    window.webkit.messageHandlers.networkLogger.postMessage({
                        type: "blocked-tracking-" + type,
                        url: value ? value.toString() : ""
                    });
                }
            }
            Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
            Object.defineProperty(navigator, 'plugins', { get: () => [1, 2, 3, 4, 5] });
            Object.defineProperty(navigator, 'languages', { get: () => ['en-US', 'en'] });
            delete window.navigator.__proto__.webdriver;
            
            window.chrome = { runtime: {} };
            Object.defineProperty(navigator, 'permissions', { get: () => undefined });
            
            const originalFetch = window.fetch;
            const originalXHROpen = XMLHttpRequest.prototype.open;
            const originalXHRSend = XMLHttpRequest.prototype.send;
            
            window.fetch = function() {
                const url = arguments[0];
                const options = arguments[1] || {};
                if (eclipseIsBlockedTrackingUrl(url)) {
                    eclipseReportBlockedTracking("fetch", url);
                    return Promise.reject(new Error("Tracking request blocked by Eclipse sandbox"));
                }
                
                try {
                    const fullUrl = new URL(url, window.location.href).href;
                    window.webkit.messageHandlers.networkLogger.postMessage({
                        type: 'fetch',
                        url: fullUrl
                    });
                } catch(e) {
                    window.webkit.messageHandlers.networkLogger.postMessage({
                        type: 'fetch',
                        url: url.toString()
                    });
                }
                return originalFetch.apply(this, arguments);
            };
            
            XMLHttpRequest.prototype.open = function() {
                const method = arguments[0];
                const url = arguments[1];
                
                try {
                    this._url = new URL(url, window.location.href).href;
                } catch(e) {
                    this._url = url;
                }

                this._eclipseBlockedTracking = eclipseIsBlockedTrackingUrl(this._url);
                
                window.webkit.messageHandlers.networkLogger.postMessage({
                    type: this._eclipseBlockedTracking ? 'blocked-tracking-xhr-open' : 'xhr-open',
                    url: this._url
                });

                if (this._eclipseBlockedTracking) {
                    return;
                }
                
                const self = this;
                const originalOnReadyStateChange = this.onreadystatechange;
                
                this.onreadystatechange = function() {
                    if (this.readyState === 4) {
                        if (this.responseURL) {
                            window.webkit.messageHandlers.networkLogger.postMessage({
                                type: 'xhr-response',
                                url: this.responseURL
                            });
                        }
                        
                        try {
                            const responseText = this.responseText;
                            if (responseText) {
                                const urlRegex = /(https?:\\/\\/[^\\s"'<>]+\\.(m3u8|ts|mp4|webm|mkv))/gi;
                                const matches = responseText.match(urlRegex);
                                if (matches) {
                                    matches.forEach(function(match) {
                                        window.webkit.messageHandlers.networkLogger.postMessage({
                                            type: 'response-content',
                                            url: match
                                        });
                                    });
                                }
                            }
                        } catch(e) {
                        }
                    }
                    
                    if (originalOnReadyStateChange) {
                        originalOnReadyStateChange.apply(this, arguments);
                    }
                };
                
                return originalXHROpen.apply(this, arguments);
            };
            
            XMLHttpRequest.prototype.send = function() {
                if (this._eclipseBlockedTracking) {
                    return;
                }
                if (this._url) {
                    window.webkit.messageHandlers.networkLogger.postMessage({
                        type: 'xhr-send',
                        url: this._url
                    });
                }
                return originalXHRSend.apply(this, arguments);
            };
            
            const originalWebSocket = window.WebSocket;
            window.WebSocket = function(url, protocols) {
                if (eclipseIsBlockedTrackingUrl(url)) {
                    eclipseReportBlockedTracking("websocket", url);
                    throw new Error("Tracking request blocked by Eclipse sandbox");
                }
                window.webkit.messageHandlers.networkLogger.postMessage({
                    type: 'websocket',
                    url: url
                });
                return new originalWebSocket(url, protocols);
            };
            
            const hookUrlProperties = function(obj, properties) {
                properties.forEach(function(prop) {
                    if (obj && obj.prototype) {
                        const descriptor = Object.getOwnPropertyDescriptor(obj.prototype, prop) || {};
                        const originalSetter = descriptor.set;
                        
                        if (originalSetter) {
                            Object.defineProperty(obj.prototype, prop, {
                                set: function(value) {
                                    if (typeof value === 'string' && (value.includes('http') || value.includes('.m3u8') || value.includes('.ts'))) {
                                        if (eclipseIsBlockedTrackingUrl(value)) {
                                            eclipseReportBlockedTracking("property-set", value);
                                            return;
                                        }
                                        window.webkit.messageHandlers.networkLogger.postMessage({
                                            type: 'property-set',
                                            url: value
                                        });
                                    }
                                    return originalSetter.call(this, value);
                                },
                                get: descriptor.get,
                                configurable: true
                            });
                        }
                    }
                });
            };
            
            hookUrlProperties(HTMLVideoElement, ['src']);
            hookUrlProperties(HTMLSourceElement, ['src']);
            hookUrlProperties(HTMLScriptElement, ['src']);
            hookUrlProperties(HTMLImageElement, ['src']);
            
            let jwHookAttempts = 0;
            const aggressiveJWHook = function() {
                jwHookAttempts++;
                
                if (window.jwplayer) {
                    const originalJWPlayer = window.jwplayer;
                    window.jwplayer = function(id) {
                        const player = originalJWPlayer.apply(this, arguments);
                        
                        if (player && player.setup) {
                            const originalSetup = player.setup;
                            player.setup = function(config) {
                                const extractUrls = function(obj, path = '') {
                                    if (!obj) return;
                                    
                                    if (typeof obj === 'string' && (obj.includes('http') || obj.includes('.m3u8') || obj.includes('.ts'))) {
                                        window.webkit.messageHandlers.networkLogger.postMessage({
                                            type: 'jwplayer-config',
                                            url: obj
                                        });
                                    } else if (typeof obj === 'object' && obj !== null) {
                                        Object.keys(obj).forEach(function(key) {
                                            extractUrls(obj[key], path + '.' + key);
                                        });
                                    }
                                };
                                
                                extractUrls(config);
                                return originalSetup.call(this, config);
                            };
                        }
                        
                        return player;
                    };
                    
                    Object.keys(originalJWPlayer).forEach(function(key) {
                        window.jwplayer[key] = originalJWPlayer[key];
                    });
                }
                
                if (jwHookAttempts < 20) {
                    setTimeout(aggressiveJWHook, 200);
                }
            };
            
            aggressiveJWHook();
            
            window.waitForElementAndClick = function(waitSelectors, clickSelectors, maxWaitTime) {
                return new Promise(function(resolve) {
                    const results = {
                        waitResults: {},
                        clickResults: []
                    };
                    
                    waitSelectors.forEach(function(selector) {
                        results.waitResults[selector] = false;
                    });
                    
                    const startTime = Date.now();
                    const checkInterval = 100; 
                    
                    const checkAndClick = function() {
                        const elapsed = (Date.now() - startTime) / 1000;
                        
                        let allFound = waitSelectors.length === 0; 
                        
                        waitSelectors.forEach(function(selector) {
                            const element = document.querySelector(selector);
                            if (element && element.offsetParent !== null) { 
                                results.waitResults[selector] = true;
                            }
                        });
                        
                        allFound = waitSelectors.every(function(selector) {
                            return results.waitResults[selector];
                        });
                        
                        if (allFound || elapsed >= maxWaitTime) {
                            clickSelectors.forEach(function(selector) {
                                try {
                                    const elements = document.querySelectorAll(selector);
                                    let clicked = false;
                                    
                                    elements.forEach(function(element) {
                                        if (element && element.offsetParent !== null) {
                                            try {
                                                element.click();
                                                clicked = true;
                                            } catch(e1) {
                                                try {
                                                    const event = new MouseEvent('click', {
                                                        view: window,
                                                        bubbles: true,
                                                        cancelable: true
                                                    });
                                                    element.dispatchEvent(event);
                                                    clicked = true;
                                                } catch(e2) {
                                                }
                                            }
                                        }
                                    });
                                    
                                    results.clickResults.push({
                                        selector: selector,
                                        success: clicked,
                                        elementsFound: elements.length
                                    });
                                } catch(e) {
                                    results.clickResults.push({
                                        selector: selector,
                                        success: false,
                                        error: e.message
                                    });
                                }
                            });
                            
                            window.webkit.messageHandlers.networkLogger.postMessage({
                                type: 'click-results',
                                results: results
                            });
                            
                            resolve(results);
                        } else if (elapsed < maxWaitTime) {
                            setTimeout(checkAndClick, checkInterval);
                        }
                    };
                    
                    checkAndClick();
                });
            };
            
            const nuclearScan = function() {
                Object.keys(window).forEach(function(key) {
                    try {
                        const value = window[key];
                        if (typeof value === 'string' && (value.includes('.m3u8') || value.includes('.ts') || (value.includes('http') && value.includes('.')))) {
                            window.webkit.messageHandlers.networkLogger.postMessage({
                                type: 'global-variable',
                                url: value
                            });
                        }
                    } catch(e) {
                    }
                });
                
                document.querySelectorAll('script').forEach(function(script) {
                    if (script.textContent) {
                        const urlRegex = /(https?:\\/\\/[^\\s"'<>]+\\.(m3u8|ts|mp4))/gi;
                        const matches = script.textContent.match(urlRegex);
                        if (matches) {
                            matches.forEach(function(match) {
                                window.webkit.messageHandlers.networkLogger.postMessage({
                                    type: 'script-content',
                                    url: match
                                });
                            });
                        }
                    }
                });
            };
            
            setTimeout(nuclearScan, 500);
            setTimeout(nuclearScan, 1500);
            setTimeout(nuclearScan, 3000);
            
            window.captureCookies = function() {
                const cookies = {};
                document.cookie.split(';').forEach(function(cookie) {
                    const parts = cookie.trim().split('=');
                    if (parts.length === 2) {
                        cookies[parts[0]] = decodeURIComponent(parts[1]);
                    }
                });
                
                if (Object.keys(cookies).length > 0) {
                    window.webkit.messageHandlers.networkLogger.postMessage({
                        type: 'cookies',
                        cookies: cookies
                    });
                }
                
                return cookies;
            };
            
            setTimeout(window.captureCookies, 1000);
            setTimeout(window.captureCookies, 3000);
            setTimeout(window.captureCookies, 5000);
        })();
        """
        
        let userScript = WKUserScript(source: jsCode, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(userScript)
        config.userContentController.add(self, name: "networkLogger")
        
        // Desktop-only pool paired with the fixed desktop frame below: existing service
        // scrapers' clickSelectors/waitForSelectors were built and tested against a guaranteed
        // desktop-shaped DOM, so this deliberately doesn't vary the viewport by UA pick — only
        // the cached-bypass-session path (ServiceWebViewCookieLoader.load) resizes the frame,
        // for the specific hosts where the resulting UA is a real, non-desktop device profile.
        let userAgent = URLSession.randomDesktopUserAgent
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), configuration: config)
        webView?.navigationDelegate = self

        webView?.customUserAgent = userAgent
    }

    private func loadHTMLContent(_ htmlContent: String) {
        guard let webView = webView else { return }
        
        addRequest("data:text/html;charset=utf-8,<html_content>")
        
        webView.loadHTMLString(htmlContent, baseURL: nil)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.performCustomInteractions()
            
            if self.options?.returnCookies == true {
                self.captureCookies {
                }
            }
        }
    }
    
    private func loadURL(url: URL, headers: [String: String]) {
        guard let webView = webView else { return }
        
        addRequest(url.absoluteString)
        
        var request = URLRequest(url: url)

        request.setValue(webView.customUserAgent ?? URLSession.randomUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.5", forHTTPHeaderField: "Accept-Language")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("upgrade-insecure-requests", forHTTPHeaderField: "Upgrade-Insecure-Requests")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
        
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        CloudflareBypassManager.shared.applyCachedBypass(to: &request, for: url)
        
        if request.value(forHTTPHeaderField: "Referer") == nil {
            let randomReferers = [
                "https://www.google.com/",
                "https://www.youtube.com/",
                "https://twitter.com/",
                "https://www.reddit.com/",
                "https://www.facebook.com/"
            ]
            let defaultReferer = randomReferers.randomElement() ?? "https://www.google.com/"
            request.setValue(defaultReferer, forHTTPHeaderField: "Referer")
        }
        
        ServiceWebViewCookieLoader.load(request, in: webView, for: url)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.performCustomInteractions()
            
            if self.options?.returnCookies == true {
                self.captureCookies {
                }
            }
        }
    }
    
    private func performCustomInteractions() {
        guard let webView = webView, let options = options else { return }
        
        if !options.waitForSelectors.isEmpty || !options.clickSelectors.isEmpty {
            let waitSelectorsJS = options.waitForSelectors.map { "'\($0)'" }.joined(separator: ", ")
            let clickSelectorsJS = options.clickSelectors.map { "'\($0)'" }.joined(separator: ", ")
            
            let customInteractionJS = """
            window.waitForElementAndClick(
                [\(waitSelectorsJS)],
                [\(clickSelectorsJS)],
                \(options.maxWaitTime)
            );
            """
            webView.evaluateJavaScript(customInteractionJS, completionHandler: nil)
        } else {
            simulateUserInteraction()
        }
    }
    
    private func simulateUserInteraction() {
        guard let webView = webView else { return }
        
        let jsInteraction = """
        setTimeout(function() {
            const playButtons = document.querySelectorAll('button, div, span, a');
            const filteredButtons = Array.from(playButtons).filter(function(el) {
                const text = el.textContent || el.innerText || '';
                const classes = el.className || '';
                const id = el.id || '';
                return text.toLowerCase().includes('play') || 
                       classes.toLowerCase().includes('play') ||
                       id.toLowerCase().includes('play') ||
                       el.getAttribute('aria-label')?.toLowerCase().includes('play');
            });
            filteredButtons.forEach(function(btn, index) {
                setTimeout(function() {
                    try {
                        btn.click();
                    } catch(e) {}
                }, index * 200);
            });
            window.scrollTo(0, document.body.scrollHeight / 2);
            setTimeout(function() {
                window.scrollTo(0, 0);
            }, 500);
            document.querySelectorAll('video').forEach(function(video) {
                if (video.play && typeof video.play === 'function') {
                    video.play().catch(function(e) {
                    });
                }
            });
            if (window.jwplayer) {
                try {
                    const players = window.jwplayer().getInstances?.() || [];
                    players.forEach(function(player) {
                        if (player.play) {
                            player.play();
                        }
                    });
                } catch(e) {}
            }
            if (window.videojs) {
                try {
                    window.videojs.getAllPlayers?.().forEach(function(player) {
                        if (player.play) {
                            player.play();
                        }
                    });
                } catch(e) {}
            }
        }, 1000);
        """
        webView.evaluateJavaScript(jsInteraction, completionHandler: nil)
    }
    
    private func stopMonitoring(reason: String = "completed") {
        timer?.invalidate()
        timer = nil
        
        if let webView {
            Task { @MainActor in
                CloudflareBypassManager.shared.captureSolvedCookies(from: webView, for: webView.url)
            }
        }
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "networkLogger")
        
        let originalUrl = options?.htmlContent != nil ? "data:text/html;charset=utf-8,<html_content>" : (webView?.url?.absoluteString ?? "")
        
        let result: [String: Any] = [
            "originalUrl": originalUrl,
            "requests": networkRequests,
            "html": htmlContent as Any,
            "cookies": cookies.isEmpty ? NSNull() : cookies,
            "success": true,
            "cutoffTriggered": cutoffTriggered,
            "cutoffUrl": cutoffUrl as Any,
            "htmlCaptured": htmlCaptured,
            "cookiesCaptured": cookiesCaptured,
            "elementsClicked": elementsClicked,
            "waitResults": waitResults
        ]

        if let operation {
            Logger.shared.log("Service networkFetch completed service=\(operation.serviceName) operation=\(operation.operation) reason=\(reason) requestCount=\(networkRequests.count) original=\(ServiceSandboxState.redactedURL(originalUrl)) cutoff=\(cutoffTriggered)", type: "Service")
        }
        
        webView = nil
        operation = nil
        
        
        completionHandler?(result)
        completionHandler = nil
    }
    
    private func addRequest(_ urlString: String) {
        DispatchQueue.main.async {
            if !self.networkRequests.contains(urlString) {
                self.networkRequests.append(urlString)
                
                if let cutoff = self.options?.cutoff, !cutoff.isEmpty {
                    if urlString.lowercased().contains(cutoff.lowercased()) {
                        self.cutoffTriggered = true
                        self.cutoffUrl = urlString
                        self.stopMonitoring(reason: "cutoff")
                        return
                    }
                }
            }
        }
    }
}

extension NetworkFetchMonitor: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation) {}

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation) {
        Task { @MainActor in
            CloudflareBypassManager.shared.captureSolvedCookies(from: webView, for: webView.url)
        }
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation, withError error: Error) {}
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url {
            if ServiceSandboxState.isBlockedTrackingURL(url.absoluteString) {
                if let operation {
                    Logger.shared.log("Service sandbox blocked tracking navigation service=\(operation.serviceName) operation=\(operation.operation) target=\(ServiceSandboxState.redactedURL(url.absoluteString))", type: "ServiceSandbox")
                }
                decisionHandler(.cancel)
                return
            }
            addRequest(url.absoluteString)
        }
        decisionHandler(.allow)
    }
}

extension NetworkFetchMonitor: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "networkLogger" {
            if let messageBody = message.body as? [String: Any] {
                if let url = messageBody["url"] as? String {
                    if let type = messageBody["type"] as? String,
                       type.hasPrefix("blocked-tracking"),
                       let operation {
                        Logger.shared.log("Service sandbox blocked tracking request service=\(operation.serviceName) operation=\(operation.operation) api=\(type) target=\(ServiceSandboxState.redactedURL(url))", type: "ServiceSandbox")
                        return
                    }
                    addRequest(url)
                } else if let type = messageBody["type"] as? String {
                    if type == "click-results" {
                        if let results = messageBody["results"] as? [String: Any] {
                            if let clickResults = results["clickResults"] as? [[String: Any]] {
                                DispatchQueue.main.async {
                                    for clickResult in clickResults {
                                        if let selector = clickResult["selector"] as? String,
                                           let success = clickResult["success"] as? Bool, success {
                                            self.elementsClicked.append(selector)
                                        }
                                    }
                                }
                            }
                            
                            if let waitResults = results["waitResults"] as? [String: Bool] {
                                DispatchQueue.main.async {
                                    self.waitResults = waitResults
                                }
                            }
                        }
                    } else if type == "cookies" {
                        if let cookiesData = messageBody["cookies"] as? [String: String] {
                            DispatchQueue.main.async {
                                for (key, value) in cookiesData {
                                    self.cookies[key] = value
                                }
                                self.cookiesCaptured = !self.cookies.isEmpty
                            }
                        }
                    }
                }
            }
        }
    }
}
#else
private enum TVNetworkFetchExecutor {
    private static let maximumResponseBytes = 10_000_000
    private static let blockedRequestHeaders: Set<String> = [
        "connection", "content-length", "host", "proxy-authenticate",
        "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade"
    ]

    static func execute(
        urlString: String,
        options: NetworkFetchOptions,
        operation: ServiceSandboxOperation
    ) async -> [String: Any] {
        if options.htmlContent?.isEmpty == false
            || !options.clickSelectors.isEmpty
            || !options.waitForSelectors.isEmpty {
            return failure(
                originalURL: urlString,
                error: ServiceCompatibilityError.browserAutomationRequired.localizedDescription
            )
        }

        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return failure(
                originalURL: urlString,
                error: ServiceCompatibilityError.unsupportedTransport.localizedDescription
            )
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = TimeInterval(min(max(options.timeoutSeconds, 1), 60))
        request.setValue(URLSession.randomUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/json,text/plain;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        for (key, value) in sanitizedHeaders(options.headers) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = request.timeoutInterval
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        let session = URLSession(
            configuration: configuration,
            delegate: FetchDelegate(allowRedirects: true),
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.boundedData(
                for: request,
                maximumResponseBytes: maximumResponseBytes
            )

            let httpResponse = response as? HTTPURLResponse
            let body = decodedText(from: data, response: httpResponse)
            let responseHeaders = CloudflareBypassManager.headersDictionary(from: httpResponse)
            if CloudflareBypassManager.isChallengeResponse(
                status: httpResponse?.statusCode ?? 0,
                body: body,
                headers: responseHeaders
            ) {
                Logger.shared.log(
                    "Service networkFetch hit Cloudflare challenge service=\(operation.serviceName) operation=\(operation.operation) target=\(ServiceSandboxState.redactedURL(url.absoluteString)) \(CloudflareBypassManager.challengeDebugSummary(status: httpResponse?.statusCode ?? 0, body: body, headers: responseHeaders))",
                    type: "Service"
                )
                await CloudflareBypassManager.shared.flagPendingVerification(for: url)
                return failure(
                    originalURL: url.absoluteString,
                    error: ServiceCompatibilityError.interactiveChallengeRequired.localizedDescription
                )
            }

            let finalURL = httpResponse?.url?.absoluteString ?? url.absoluteString
            let cutoffMatched = options.cutoff.map {
                !$0.isEmpty && finalURL.localizedCaseInsensitiveContains($0)
            } ?? false
            let cookieValues = options.returnCookies
                ? responseCookies(from: httpResponse, for: httpResponse?.url ?? url)
                : [:]
            let htmlValue: Any = options.returnHTML ? body : NSNull()
            let cookieValue: Any = cookieValues.isEmpty ? NSNull() : cookieValues

            Logger.shared.log(
                "Service networkFetch completed service=\(operation.serviceName) operation=\(operation.operation) requestCount=1 original=\(ServiceSandboxState.redactedURL(finalURL)) cutoff=\(cutoffMatched)",
                type: "Service"
            )

            return [
                "originalUrl": finalURL,
                "requests": [finalURL],
                "html": htmlValue,
                "cookies": cookieValue,
                "success": true,
                "cutoffTriggered": cutoffMatched,
                "cutoffUrl": cutoffMatched ? finalURL : NSNull(),
                "htmlCaptured": options.returnHTML,
                "cookiesCaptured": !cookieValues.isEmpty,
                "elementsClicked": [],
                "waitResults": [:]
            ]
        } catch is BoundedURLSessionError {
            Logger.shared.log(
                "Service networkFetch rejected oversized response service=\(operation.serviceName) operation=\(operation.operation) target=\(ServiceSandboxState.redactedURL(urlString)) limitBytes=\(maximumResponseBytes)",
                type: "Error"
            )
            return failure(
                originalURL: urlString,
                error: ServiceCompatibilityError.responseTooLarge.localizedDescription
            )
        } catch {
            let safeError: String
            if let urlError = error as? URLError {
                safeError = "Network request failed (\(urlError.code.rawValue))."
            } else {
                safeError = "Network request failed."
            }
            Logger.shared.log(
                "Service networkFetch failed service=\(operation.serviceName) operation=\(operation.operation) target=\(ServiceSandboxState.redactedURL(urlString))",
                type: "Error"
            )
            return failure(originalURL: urlString, error: safeError)
        }
    }

    private static func failure(originalURL: String, error: String) -> [String: Any] {
        [
            "originalUrl": ServiceSandboxState.redactedURL(originalURL),
            "requests": [],
            "html": NSNull(),
            "cookies": NSNull(),
            "success": false,
            "error": error,
            "cutoffTriggered": false,
            "cutoffUrl": NSNull(),
            "htmlCaptured": false,
            "cookiesCaptured": false,
            "elementsClicked": [],
            "waitResults": [:]
        ]
    }

    private static func sanitizedHeaders(_ headers: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in headers.prefix(64) {
            let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKey.isEmpty,
                  !trimmedValue.isEmpty,
                  trimmedKey.count <= 128,
                  trimmedValue.utf8.count <= 8_192,
                  !blockedRequestHeaders.contains(trimmedKey.lowercased()),
                  !trimmedKey.contains("\r"),
                  !trimmedKey.contains("\n"),
                  !trimmedValue.contains("\r"),
                  !trimmedValue.contains("\n") else { continue }
            result[trimmedKey] = trimmedValue
        }
        return result
    }

    private static func decodedText(from data: Data, response: HTTPURLResponse?) -> String {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let encodingName = response?.textEncodingName {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)
            guard cfEncoding != kCFStringEncodingInvalidId else {
                return String(decoding: data, as: UTF8.self)
            }
            let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            if let decoded = String(data: data, encoding: String.Encoding(rawValue: nsEncoding)) {
                return decoded
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func responseCookies(from response: HTTPURLResponse?, for url: URL) -> [String: String] {
        guard let response else { return [:] }
        let headerFields = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            result[String(describing: pair.key)] = String(describing: pair.value)
        }
        return HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
            .reduce(into: [String: String]()) { result, cookie in
                result[cookie.name] = cookie.value
            }
    }
}

final class NetworkFetchSimpleManager: NSObject, ObservableObject {
    static let shared = NetworkFetchSimpleManager()

    private override init() {
        super.init()
    }

    func performNetworkFetch(
        urlString: String,
        timeoutSeconds: Int,
        htmlContent: String? = nil,
        headers: [String: String] = [:],
        operation: ServiceSandboxOperation,
        resolve: JSValue,
        reject: JSValue
    ) {
        let options = NetworkFetchOptions(
            timeoutSeconds: timeoutSeconds,
            headers: headers,
            returnHTML: false,
            returnCookies: false,
            htmlContent: htmlContent
        )
        Task {
            let result = await TVNetworkFetchExecutor.execute(
                urlString: urlString,
                options: options,
                operation: operation
            )
            await MainActor.run {
                if !resolve.isUndefined {
                    resolve.call(withArguments: [[
                        "originalUrl": result["originalUrl"] ?? ServiceSandboxState.redactedURL(urlString),
                        "requests": result["requests"] ?? [],
                        "success": result["success"] ?? false,
                        "error": result["error"] ?? NSNull()
                    ]])
                }
            }
        }
    }
}

final class NetworkFetchManager: NSObject, ObservableObject {
    static let shared = NetworkFetchManager()

    private override init() {
        super.init()
    }

    func performNetworkFetch(
        urlString: String,
        options: NetworkFetchOptions,
        operation: ServiceSandboxOperation,
        resolve: JSValue,
        reject: JSValue
    ) {
        Task {
            let result = await TVNetworkFetchExecutor.execute(
                urlString: urlString,
                options: options,
                operation: operation
            )
            await MainActor.run {
                if !resolve.isUndefined {
                    resolve.call(withArguments: [result])
                }
            }
        }
    }
}
#endif
