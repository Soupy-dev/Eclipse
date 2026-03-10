//
//  KanzenRunnerController.swift
//  Kanzen
//
//  Created by Dawud Osman on 12/05/2025.
//
import Foundation
import JavaScriptCore

class KanzenRunnerController {
    private let moduleRunner: KanzenModuleRunner
    init(moduleRunner: KanzenModuleRunner) {
        self.moduleRunner = moduleRunner
    }
    
    func loadScript(_script: String) throws
    {
        try moduleRunner.loadScript(_script)
    }
    
    func extractImages(params:Any,completion: @escaping ([String]?) -> Void)
    {
        moduleRunner.extractImages(params: params)
        {
            jsResult, error in
            guard let result = jsResult?.toArray() as? [String] else {
                completion(nil)
                return
            }
            completion(result)
        }
    }
    
    func extractChapters(params:Any, completion: @escaping (Any?) -> Void )
    {
        moduleRunner.extractChapters(params: params){
            jsResult, error in
            // Try dictionary first (Kanzen format: {language: [[name, [data...]]]})
            if let result = jsResult?.toDictionary() as? [String:Any] {
                completion(result)
                return
            }
            // Try array (Sora format: [{number, title, href}, ...])
            if let result = jsResult?.toArray() as? [[String:Any]] {
                completion(result)
                return
            }
            // Try JSON string fallback
            if let jsonString = jsResult?.toString(), let data = jsonString.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) {
                completion(parsed)
                return
            }
            completion(nil)
        }
    }
    
    func extractDetails(params:Any, completion: @escaping ([String:Any]?)-> Void)
    {
       
        moduleRunner.extractDetails(params: params)
        {
            jsResult, error in
            guard let result = jsResult?.toDictionary() as? [String:Any] else
            {
                completion(nil)
                return
            }
            completion(result)
        }
    }
    
    func extractText(params:Any, completion: @escaping (String?) -> Void)
    {
        moduleRunner.extractText(params: params)
        {
            jsResult, error in
            guard let result = jsResult?.toString() else {
                completion(nil)
                return
            }
            completion(result)
        }
    }
    
    func searchInput(_input: String,page:Int = 0, completion: @escaping ([[String:Any]]?) -> Void)
    {
        moduleRunner.searchResults(input: _input,page: page)
        {
            jsResult,error in
            guard let result = jsResult?.toArray() as? [[String:Any]] else {
                completion(nil)
                return
            }
            completion(result)
            
        }
    }
}
