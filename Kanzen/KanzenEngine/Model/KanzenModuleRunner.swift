//
//  KanzenModuleRunner.swift
//  Kanzen
//
//  Created by Dawud Osman on 12/05/2025.
//

import Foundation
import JavaScriptCore

class KanzenModuleRunner
{
    private var jsContext: JSContext?
    private var lastJSException: String?
    
    func extractImages(params:Any, completion: @escaping (JSValue?,Error?) -> Void)
    {
        Logger.shared.log("ModuleRunner.extractImages: called with params type=\(type(of: params))", type: "Debug")
        guard let context = jsContext else {
            Logger.shared.log("ModuleRunner.extractImages: jsContext is nil", type: "Error")
            completion(nil, NSError(domain: "JSContext", code: 1, userInfo: [NSLocalizedDescriptionKey: "JS function not found"]))
            return
        
        }
        guard let chaptersFunc = context.objectForKeyedSubscript("extractImages") else {
            completion(nil, NSError(domain: "JSContext", code: 1, userInfo: [NSLocalizedDescriptionKey: "JS function not found"]))
            return
        }
        guard let promise = chaptersFunc.call(withArguments: [params]) else {
            completion(nil, NSError(domain: "JSContext", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to call JS async function"]))
            return
        }
        // Prepare resolve and reject blocks
        let resolveBlock: @convention(block) (JSValue) -> Void = { result in

            completion(result, nil)
        }
        let rejectBlock: @convention(block) (JSValue) -> Void = { error in

            let err = NSError(domain: "JSContext", code: 3, userInfo: [NSLocalizedDescriptionKey: error.toString() ?? "-"])
            completion(nil, err)
        }
        let resolveCallback = JSValue(object: resolveBlock, in: context)
        let rejectCallback = JSValue(object: rejectBlock, in: context)

        // Attach callbacks to the Promise
        promise.invokeMethod("then", withArguments: [resolveCallback as Any])
        promise.invokeMethod("catch", withArguments: [rejectCallback as Any])
    }
    
    func extractChapters(params:Any, completion: @escaping (JSValue?,Error?) -> Void)
    {
        Logger.shared.log("ModuleRunner.extractChapters: called with params type=\(type(of: params)), value=\(params)", type: "Debug")
        guard let context = jsContext else {
            Logger.shared.log("ModuleRunner.extractChapters: jsContext is nil", type: "Error")
            completion(nil, NSError(domain: "JSContext", code: 1, userInfo: [NSLocalizedDescriptionKey: "JS function not found"]))
            return
        
        }
        guard let chaptersFunc = context.objectForKeyedSubscript("extractChapters") else {
            Logger.shared.log("ModuleRunner.extractChapters: extractChapters function not found in JS", type: "Error")
            completion(nil, NSError(domain: "JSContext", code: 1, userInfo: [NSLocalizedDescriptionKey: "JS function not found"]))
            return
        }
        Logger.shared.log("ModuleRunner.extractChapters: calling JS extractChapters...", type: "Debug")
        let callResult = chaptersFunc.call(withArguments: [params])
        Logger.shared.log("ModuleRunner.extractChapters: call returned isUndefined=\(callResult?.isUndefined ?? true), isNull=\(callResult?.isNull ?? true), isObject=\(callResult?.isObject ?? false), isArray=\(callResult?.isArray ?? false)", type: "Debug")
        if let exception = context.exception {
            Logger.shared.log("ModuleRunner.extractChapters: JS exception after call: \(exception)", type: "Error")
        }
        guard let promise = callResult else {
            Logger.shared.log("ModuleRunner.extractChapters: call result is nil", type: "Error")
            completion(nil, NSError(domain: "JSContext", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to call JS async function"]))
            return
        }
        // Check if it's a Promise (has .then)
        let isPromise = promise.hasProperty("then")
        Logger.shared.log("ModuleRunner.extractChapters: isPromise=\(isPromise)", type: "Debug")
        if !isPromise {
            // Synchronous result - return directly
            Logger.shared.log("ModuleRunner.extractChapters: sync result, returning directly", type: "Debug")
            completion(promise, nil)
            return
        }
        // Prepare resolve and reject blocks
        let resolveBlock: @convention(block) (JSValue) -> Void = { result in
            Logger.shared.log("ModuleRunner.extractChapters: Promise resolved, isArray=\(result.isArray), isObject=\(result.isObject), isString=\(result.isString), isUndefined=\(result.isUndefined)", type: "Debug")
            if let str = result.toString() {
                let preview = str.prefix(200)
                Logger.shared.log("ModuleRunner.extractChapters: resolved toString preview: \(preview)", type: "Debug")
            }
            completion(result, nil)
        }
        let rejectBlock: @convention(block) (JSValue) -> Void = { error in
            Logger.shared.log("ModuleRunner.extractChapters: Promise rejected: \(error.toString() ?? "unknown")", type: "Error")
            let err = NSError(domain: "JSContext", code: 3, userInfo: [NSLocalizedDescriptionKey: error.toString() ?? "-"])
            completion(nil, err)
        }
        let resolveCallback = JSValue(object: resolveBlock, in: context)
        let rejectCallback = JSValue(object: rejectBlock, in: context)

        // Attach callbacks to the Promise
        promise.invokeMethod("then", withArguments: [resolveCallback as Any])
        promise.invokeMethod("catch", withArguments: [rejectCallback as Any])
    }

    func extractDetails(params:Any, completion: @escaping (JSValue?,Error?) -> Void)
    {

        guard let context = jsContext else {
            completion(nil, NSError(domain: "JSContext", code: 1, userInfo: [NSLocalizedDescriptionKey: "JS function not found"]))
            return
        }
        
        guard let contentDataFunc = context.objectForKeyedSubscript("extractDetails") else {
            completion(nil, NSError(domain: "JSContext", code: 1, userInfo: [NSLocalizedDescriptionKey: "JS function not found"]))
            return
        }
        guard let promise = contentDataFunc.call(withArguments: [params]) else {
            completion(nil, NSError(domain: "JSContext", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to call JS async function"]))
            return
        }
        // Prepare resolve and reject blocks
        let resolveBlock: @convention(block) (JSValue) -> Void = { result in

            completion(result, nil)
        }
        let rejectBlock: @convention(block) (JSValue) -> Void = { error in

            let err = NSError(domain: "JSContext", code: 3, userInfo: [NSLocalizedDescriptionKey: error.toString() ?? "-"])
            completion(nil, err)
        }
        let resolveCallback = JSValue(object: resolveBlock, in: context)
        let rejectCallback = JSValue(object: rejectBlock, in: context)

        // Attach callbacks to the Promise
        promise.invokeMethod("then", withArguments: [resolveCallback as Any])
        promise.invokeMethod("catch", withArguments: [rejectCallback as Any])
    }
    
    func searchResults(input:String, page:Int = 0,completion: @escaping(JSValue?,Error?) -> Void)
    {
        Logger.shared.log("ModuleRunner.searchResults: input='\(input)', page=\(page)", type: "Debug")
        guard let context = jsContext else {
            Logger.shared.log("ModuleRunner.searchResults: jsContext is nil", type: "Error")
            completion(nil, NSError(domain: "JSContext", code: 1, userInfo: [NSLocalizedDescriptionKey: "JS function not found"]))
            return
        }
     

        guard let searchFunc = context.objectForKeyedSubscript("searchResults") else {
            Logger.shared.log("ModuleRunner.searchResults: searchResults function not found in JS", type: "Error")
            completion(nil, NSError(domain: "JSContext", code: 1, userInfo: [NSLocalizedDescriptionKey: "JS function not found"]))
            return
        }

        Logger.shared.log("ModuleRunner.searchResults: calling JS searchResults...", type: "Debug")
        guard let promise = searchFunc.call(withArguments: [input,page]) else {
            Logger.shared.log("ModuleRunner.searchResults: call returned nil", type: "Error")
            completion(nil, NSError(domain: "JSContext", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to call JS async function"]))
            return
        }
        if let exception = context.exception {
            Logger.shared.log("ModuleRunner.searchResults: JS exception after call: \(exception)", type: "Error")
        }
        Logger.shared.log("ModuleRunner.searchResults: call returned isUndefined=\(promise.isUndefined), isNull=\(promise.isNull), hasProperty('then')=\(promise.hasProperty("then"))", type: "Debug")
        
        // Prepare resolve and reject blocks
        let resolveBlock: @convention(block) (JSValue) -> Void = { result in
            Logger.shared.log("ModuleRunner.searchResults: Promise resolved, isArray=\(result.isArray), isObject=\(result.isObject), isString=\(result.isString), isUndefined=\(result.isUndefined)", type: "Debug")
            if let str = result.toString() {
                let preview = str.prefix(300)
                Logger.shared.log("ModuleRunner.searchResults: resolved preview: \(preview)", type: "Debug")
            }
            completion(result, nil)
        }
        let rejectBlock: @convention(block) (JSValue) -> Void = { error in
            Logger.shared.log("ModuleRunner.searchResults: Promise rejected: \(error.toString() ?? "unknown")", type: "Error")
            let err = NSError(domain: "JSContext", code: 3, userInfo: [NSLocalizedDescriptionKey: error.toString() ?? "-"])
            completion(nil, err)
        }
        let resolveCallback = JSValue(object: resolveBlock, in: context)
        let rejectCallback = JSValue(object: rejectBlock, in: context)

        // Attach callbacks to the Promise
        promise.invokeMethod("then", withArguments: [resolveCallback as Any])
        promise.invokeMethod("catch", withArguments: [rejectCallback as Any])
    }
    
    func extractText(params:Any, completion: @escaping (JSValue?,Error?) -> Void)
    {
        Logger.shared.log("ModuleRunner.extractText: called with params type=\(type(of: params)), value=\(params)", type: "Debug")
        guard let context = jsContext else {
            Logger.shared.log("ModuleRunner.extractText: jsContext is nil", type: "Error")
            completion(nil, NSError(domain: "JSContext", code: 1, userInfo: [NSLocalizedDescriptionKey: "JS function not found"]))
            return
        }
        guard let textFunc = context.objectForKeyedSubscript("extractText") else {
            Logger.shared.log("ModuleRunner.extractText: extractText function not found in JS", type: "Error")
            completion(nil, NSError(domain: "JSContext", code: 1, userInfo: [NSLocalizedDescriptionKey: "JS function not found"]))
            return
        }
        Logger.shared.log("ModuleRunner.extractText: calling JS extractText...", type: "Debug")
        let callResult = textFunc.call(withArguments: [params])
        if let exception = context.exception {
            Logger.shared.log("ModuleRunner.extractText: JS exception after call: \(exception)", type: "Error")
        }
        Logger.shared.log("ModuleRunner.extractText: call returned isUndefined=\(callResult?.isUndefined ?? true), isNull=\(callResult?.isNull ?? true), hasProperty('then')=\(callResult?.hasProperty("then") ?? false)", type: "Debug")
        guard let promise = callResult else {
            Logger.shared.log("ModuleRunner.extractText: call result is nil", type: "Error")
            completion(nil, NSError(domain: "JSContext", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to call JS async function"]))
            return
        }
        // Check if it's a Promise
        let isPromise = promise.hasProperty("then")
        if !isPromise {
            Logger.shared.log("ModuleRunner.extractText: sync result, returning directly", type: "Debug")
            completion(promise, nil)
            return
        }
        let resolveBlock: @convention(block) (JSValue) -> Void = { result in
            Logger.shared.log("ModuleRunner.extractText: Promise resolved, isString=\(result.isString), isUndefined=\(result.isUndefined)", type: "Debug")
            completion(result, nil)
        }
        let rejectBlock: @convention(block) (JSValue) -> Void = { error in
            Logger.shared.log("ModuleRunner.extractText: Promise rejected: \(error.toString() ?? "unknown")", type: "Error")
            let err = NSError(domain: "JSContext", code: 3, userInfo: [NSLocalizedDescriptionKey: error.toString() ?? "-"])
            completion(nil, err)
        }
        let resolveCallback = JSValue(object: resolveBlock, in: context)
        let rejectCallback = JSValue(object: rejectBlock, in: context)
        promise.invokeMethod("then", withArguments: [resolveCallback as Any])
        promise.invokeMethod("catch", withArguments: [rejectCallback as Any])
    }
    
    func setUpEnvironMent(isNovel: Bool = false)
    {
        Logger.shared.log("ModuleRunner.setUpEnvironMent: isNovel=\(isNovel)", type: "Debug")
        jsContext = JSContext()
        jsContext?.exceptionHandler = { context, exception in
            let errorMsg = exception?.toString() ?? "unknown error"
            let line = exception?.objectForKeyedSubscript("line")?.toInt32() ?? -1
            let column = exception?.objectForKeyedSubscript("column")?.toInt32() ?? -1
            let stack = exception?.objectForKeyedSubscript("stack")?.toString() ?? "no stack"
            print("JS Error: \(errorMsg)")
            Logger.shared.log("JS Error: \(errorMsg) at line \(line) col \(column)", type: "Error")
            Logger.shared.log("JS Stack: \(stack)", type: "Error")
            self.lastJSException = "JS Error: \(errorMsg)"
        }
        if isNovel {
            Logger.shared.log("ModuleRunner: Using NOVEL JS environment (Sora-compatible fetch)", type: "Debug")
            jsContext?.setUpNovelJSEnvironment()
        } else {
            Logger.shared.log("ModuleRunner: Using MANGA JS environment (response-object fetch)", type: "Debug")
            jsContext?.setUpJSEnvirontment()
        }
    }
    
    func loadScript(_ script: String, isNovel: Bool = false) throws
    {
        Logger.shared.log("ModuleRunner.loadScript: isNovel=\(isNovel), scriptLength=\(script.count)", type: "Debug")
            lastJSException = nil
            setUpEnvironMent(isNovel: isNovel)
            jsContext?.evaluateScript(script)

        if let exception = self.lastJSException {
            Logger.shared.log("ModuleRunner.loadScript: exception during eval: \(exception)", type: "Error")
        }
        
        // Log what JS functions are available after loading
        let funcs = ["searchResults", "extractChapters", "extractText", "extractImages", "extractDetails"]
        for f in funcs {
            let exists = jsContext?.objectForKeyedSubscript(f)?.isUndefined == false
            Logger.shared.log("ModuleRunner.loadScript: JS function '\(f)' exists=\(exists)", type: "Debug")
        }
        
        // Also log if fetch/fetchv2 are available
        let fetchExists = jsContext?.objectForKeyedSubscript("fetch")?.isUndefined == false
        let fetchv2Exists = jsContext?.objectForKeyedSubscript("fetchv2")?.isUndefined == false
        Logger.shared.log("ModuleRunner.loadScript: fetch=\(fetchExists), fetchv2=\(fetchv2Exists)", type: "Debug")
        
        if let exception = self.lastJSException
        {
            
            let errorMessage = exception
            throw ScriptExecutionError.scriptLoadError(errorMessage)
        }
    }
}
