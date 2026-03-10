//
//  JavaScriptCore.swift
//  Kanzen
//
//  Created by Dawud Osman on 13/05/2025.
//

import JavaScriptCore
import Foundation

extension JSContext
{
    func setupTimeOut()
    {
        // Define `setTimeout` in Swift
        let setTimeout: @convention(block) (JSValue, Double) -> Void = { callback, delay in
            let delayTime = DispatchTime.now() + delay / 1000.0  // Convert ms to seconds
            DispatchQueue.main.asyncAfter(deadline: delayTime) {
                callback.call(withArguments: [])
            }
        }
        // Inject `setTimeout` into JSContext
        self.setObject(setTimeout, forKeyedSubscript: "setTimeout" as (NSCopying & NSObjectProtocol))
    }
    
    func setupBundle()
    {
        guard let jsPath = Bundle.main.path(forResource: "bundle", ofType: "js")
        else{
            Logger.shared.log("bundle not found",type: "Error")
            return
        }
        do {
            let jsCode = try String(contentsOfFile: jsPath, encoding: .utf8)
            self.evaluateScript(jsCode)
            Logger.shared.log("bundle loaded successfully")
        } catch {
            Logger.shared.log("Error loading bundle.js: \(error)")
        }
        
    }
    
    // MARK: - Console (manga)
    
    func setUpConsole()
    {
        let consoleObject = JSValue(newObjectIn: self)
        let consoleLogFunction: @convention(block) (String) -> Void = {
            message in
            Logger.shared.log(message,type: "Debug")
        }
        let consolePrintFunction: @convention(block) (JSValue) -> Void = {
            message in
            print(message)
        }
        
        consoleObject?.setObject(consoleLogFunction, forKeyedSubscript: "log" as NSString)
        consoleObject?.setObject(consolePrintFunction, forKeyedSubscript: "print" as NSString)
        self.setObject(consoleObject, forKeyedSubscript: "console" as NSString)
    }
    
    // MARK: - Fetch (manga: resolves with response object)
    
    func setUpFetch()
    {
        let fetch: @convention(block) (JSValue,JSValue) -> JSValue = {
            jsUrl, jsOptions in
            guard let urlStr = jsUrl.toString(), let url = URL(string: urlStr) else
            {
                return JSValue(newErrorFromMessage: "Invalid URL", in: self)
            }
            
            guard let _ = self.objectForKeyedSubscript("Promise") else
            {
                fatalError("Promise constructor not found in JSContext")
            }
            
            let executor: @convention(block) (@escaping (JSValue) -> Void, @escaping (JSValue) -> Void) -> Void = { resolve, reject in
                var request  = URLRequest(url: url)
                request.httpMethod = "GET"
                if let options = jsOptions.toDictionary() as? [String: Any]
                {
                    if let method = options["method"] as? String
                    {
                        request.httpMethod = method.uppercased()
                    }
                    if let headers = options["headers"] as? [String: String]
                    {
                        for (key,value) in headers
                        {
                            request.addValue(value, forHTTPHeaderField: key)
                        }
                    }
                    if let body = options["body"] as? String
                    {
                        let bodyData = body.data(using: .utf8)
                        request.httpBody = bodyData
                    }
                }
                
                let task = URLSession.shared.dataTask(with: request) { data, response, error in
                    
                    if let error = error
                    {
                        return reject(JSValue(newErrorFromMessage: error.localizedDescription, in: self))
                    }
                    guard let  httpResponse = response as? HTTPURLResponse
                    else
                    {
                        reject(JSValue(newErrorFromMessage: "No Response", in: self ))
                        return
                    }
                    let textFunc: @convention(block) () -> String = {
                        if let data = data
                        {
                            return String(data: data, encoding: .utf8) ?? ""
                        }
                        return ""
                    }
                    let jsonFunc: @convention(block) () -> JSValue = {
                        if let data = data {
                            do{
                                let json = try JSONSerialization.jsonObject(with: data, options: [])
                                return JSValue(object: json, in: self)
                            }
                            catch
                            {
                                Logger.shared.log("JSON serialization failed",type:"Error")
                            }
                        }
                        return JSValue(newErrorFromMessage: "No Data", in: self)
                        
                    }
                    guard let textJs = JSValue(object: textFunc, in: self),
                          let jsonJs = JSValue(object: jsonFunc, in: self)
                    else
                    {
                        return reject(JSValue(newErrorFromMessage: "Failed to create JSValue", in: self))
                    }
                    let responseObject: [String: Any] = [
                        "status": httpResponse.statusCode,
                        "headers": httpResponse.allHeaderFields,
                        "text": textJs,
                        "json": jsonJs,
                        "data": data?.base64EncodedString() ?? ""
                    ]
                    
                    resolve(JSValue(object: responseObject, in: self))
                    
                }
                task.resume()
                
            }
            
            let promise = JSValue(newPromiseIn: self, fromExecutor: { resolve, reject in
                executor(
                    { value in resolve?.call(withArguments: [value]) },
                    { error in reject?.call(withArguments: [error]) }
                )
            })
            
            return promise ?? JSValue(newErrorFromMessage: "Promise not supported", in: self)
            
        }
        
        self.setObject(fetch, forKeyedSubscript: "fetch" as NSString)
    }
    
    // MARK: - Manga JS Environment (original)
    
    func setUpJSEnvirontment()
    {
        setUpFetch()
        setUpConsole()
        setupBundle()
        setupTimeOut()
    }
    
    // MARK: - Novel/Sora-compatible Console
    
    func setUpNovelConsole()
    {
        let consoleObject = JSValue(newObjectIn: self)
        
        let consoleLogFunction: @convention(block) (String) -> Void = { message in
            Logger.shared.log(message, type: "Debug")
        }
        consoleObject?.setObject(consoleLogFunction, forKeyedSubscript: "log" as NSString)
        
        let consoleErrorFunction: @convention(block) (String) -> Void = { message in
            Logger.shared.log(message, type: "Error")
        }
        consoleObject?.setObject(consoleErrorFunction, forKeyedSubscript: "error" as NSString)
        
        self.setObject(consoleObject, forKeyedSubscript: "console" as NSString)
        
        let logFunction: @convention(block) (String) -> Void = { message in
            Logger.shared.log("JavaScript log: \(message)", type: "Debug")
        }
        self.setObject(logFunction, forKeyedSubscript: "log" as NSString)
    }
    
    // MARK: - Novel/Sora-compatible Fetch (resolves with text string)
    
    func setUpNovelFetch()
    {
        let fetchNativeFunction: @convention(block) (String, [String: String]?, JSValue, JSValue) -> Void = { urlString, headers, resolve, reject in
            guard let url = URL(string: urlString) else {
                Logger.shared.log("Invalid URL: \(urlString)", type: "Error")
                reject.call(withArguments: ["Invalid URL"])
                return
            }
            var request = URLRequest(url: url)
            if let headers = headers {
                for (key, value) in headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }
            let task = URLSession.shared.dataTask(with: request) { data, _, error in
                if let error = error {
                    Logger.shared.log("Network error in fetch: \(error.localizedDescription)", type: "Error")
                    reject.call(withArguments: [error.localizedDescription])
                    return
                }
                guard let data = data else {
                    Logger.shared.log("No data in fetch response", type: "Error")
                    reject.call(withArguments: ["No data"])
                    return
                }
                if let text = String(data: data, encoding: .utf8) {
                    resolve.call(withArguments: [text])
                } else {
                    Logger.shared.log("Unable to decode fetch data to text", type: "Error")
                    reject.call(withArguments: ["Unable to decode data"])
                }
            }
            task.resume()
        }
        self.setObject(fetchNativeFunction, forKeyedSubscript: "fetchNative" as NSString)
        
        let fetchDefinition = """
            function fetch(url, headers) {
                return new Promise(function(resolve, reject) {
                    fetchNative(url, headers, resolve, reject);
                });
            }
            """
        self.evaluateScript(fetchDefinition)
    }
    
    // MARK: - Novel/Sora-compatible FetchV2
    
    func setUpNovelFetchV2()
    {
        let fetchV2NativeFunction: @convention(block) (String, Any?, String?, String?, ObjCBool, String?, JSValue, JSValue) -> Void = { urlString, headersAny, method, body, redirect, encoding, resolve, reject in
            guard let url = URL(string: urlString) else {
                Logger.shared.log("Invalid URL in fetchv2: \(urlString)", type: "Error")
                DispatchQueue.main.async {
                    resolve.call(withArguments: [["error": "Invalid URL"]])
                }
                return
            }
            
            var headers: [String: String]? = nil
            if let headersAny = headersAny {
                if headersAny is NSNull {
                    headers = nil
                } else if let headersDict = headersAny as? [String: Any] {
                    var safeHeaders: [String: String] = [:]
                    for (key, value) in headersDict {
                        if let str = value as? String {
                            safeHeaders[key] = str
                        } else if let num = value as? NSNumber {
                            safeHeaders[key] = num.stringValue
                        } else if value is NSNull {
                            continue
                        } else {
                            safeHeaders[key] = String(describing: value)
                        }
                    }
                    headers = safeHeaders.isEmpty ? nil : safeHeaders
                }
            }
            
            let httpMethod = method ?? "GET"
            var request = URLRequest(url: url)
            request.httpMethod = httpMethod
            
            func getEncoding(from encodingString: String?) -> String.Encoding {
                guard let enc = encodingString?.lowercased() else { return .utf8 }
                switch enc {
                case "utf-8", "utf8": return .utf8
                case "windows-1251", "cp1251": return .windowsCP1251
                case "windows-1252", "cp1252": return .windowsCP1252
                case "iso-8859-1", "latin1": return .isoLatin1
                case "ascii": return .ascii
                case "utf-16", "utf16": return .utf16
                default: return .utf8
                }
            }
            let textEncoding = getEncoding(from: encoding)
            
            let bodyIsEmpty = body == nil || body?.isEmpty == true || body == "null" || body == "undefined"
            if httpMethod != "GET" && !bodyIsEmpty {
                request.httpBody = body?.data(using: .utf8)
            }
            
            if let headers = headers {
                for (key, value) in headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }
            
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                let callResolve: ([String: Any]) -> Void = { dict in
                    DispatchQueue.main.async {
                        if !resolve.isUndefined {
                            resolve.call(withArguments: [dict])
                        }
                    }
                }
                
                if let error = error {
                    Logger.shared.log("Network error in fetchv2: \(error.localizedDescription)", type: "Error")
                    callResolve(["error": error.localizedDescription])
                    return
                }
                
                var safeHeaders: [String: String] = [:]
                if let httpResponse = response as? HTTPURLResponse {
                    for (key, value) in httpResponse.allHeaderFields {
                        if let keyString = key as? String {
                            safeHeaders[keyString] = value is String ? (value as! String) : String(describing: value)
                        }
                    }
                }
                
                var responseDict: [String: Any] = [
                    "status": (response as? HTTPURLResponse)?.statusCode ?? 0,
                    "headers": safeHeaders,
                    "body": ""
                ]
                
                if let data = data {
                    if let text = String(data: data, encoding: textEncoding) {
                        responseDict["body"] = text
                    } else if let text = String(data: data, encoding: .utf8) {
                        responseDict["body"] = text
                    }
                }
                
                callResolve(responseDict)
            }
            task.resume()
        }
        
        self.setObject(fetchV2NativeFunction, forKeyedSubscript: "fetchV2Native" as NSString)
        
        let fetchv2Definition = """
            function fetchv2(url, headers, method, body, redirect, encoding) {
                if (headers === undefined || headers === null) headers = {};
                if (method === undefined || method === null) method = "GET";
                if (body === undefined) body = null;
                if (redirect === undefined || redirect === null) redirect = true;

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
                        var responseObj = {
                            headers: rawText.headers,
                            status: rawText.status,
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
            """
        self.evaluateScript(fetchv2Definition)
    }
    
    // MARK: - Novel Base64 Functions
    
    func setupNovelBase64Functions()
    {
        let btoaFunction: @convention(block) (String) -> String? = { data in
            guard let data = data.data(using: .utf8) else { return nil }
            return data.base64EncodedString()
        }
        let atobFunction: @convention(block) (String) -> String? = { base64String in
            guard let data = Data(base64Encoded: base64String) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        self.setObject(btoaFunction, forKeyedSubscript: "btoa" as NSString)
        self.setObject(atobFunction, forKeyedSubscript: "atob" as NSString)
    }
    
    // MARK: - Novel Scraping Utilities
    
    func setupNovelScrapingUtilities()
    {
        let scrapingUtils = """
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
            const regex = new RegExp(`<${tag}[^>]*${attr}=[\"']?([^\"' >]+)[\"']?[^>]*>`, 'i');
            const match = regex.exec(html);
            return match ? match[1] : null;
        }
        function getInnerText(html) {
            return html.replace(/<[^>]+>/g, '').replace(/\\s+/g, ' ').trim();
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
            return str.replace(/\\s+/g, ' ').trim();
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
        """
        self.evaluateScript(scrapingUtils)
    }
    
    // MARK: - Novel JS Environment (Sora-compatible)
    
    func setUpNovelJSEnvironment()
    {
        setUpNovelConsole()
        setUpNovelFetch()
        setUpNovelFetchV2()
        setupNovelBase64Functions()
        setupNovelScrapingUtilities()
        setupBundle()
        setupTimeOut()
    }
}
