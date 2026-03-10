//
//  KanzenEngine.swift
//  Kanzen
//
//  Created by Dawud Osman on 12/05/2025.
//

import SwiftUI

class KanzenEngine: ObservableObject
{
    private let controller: KanzenRunnerController
    init() {
        let moduleRunner = KanzenModuleRunner()
        self.controller = KanzenRunnerController(moduleRunner: moduleRunner)
    }
    
    func loadScript(_ script: String) throws {
        try self.controller.loadScript(_script: script)
    }
    
    func extractDetails(params:Any, completion: @escaping ([String:Any]?) -> Void)
    {
        controller.extractDetails(params: params)
        {
            result in
            completion(result)
        }
    }
    
    func extractImages(params:Any, completion: @escaping ([String]?)-> Void)
    {
        controller.extractImages(params: params){
            result in
            completion(result)
        }
    }
    
    func extractChapters(params: Any, completion: @escaping (Any?)-> Void)
    {
        controller.extractChapters(params: params){
            result in
            completion(result)
        }
    }
    
    func extractText(params: Any, completion: @escaping (String?) -> Void)
    {
        controller.extractText(params: params){
            result in
            completion(result)
        }
    }
    
    func searchInput(_ input: String,page: Int = 0, completion: @escaping ([[String:Any]]?) -> Void) -> Void {
        controller.searchInput(_input: input,page: page)
        {
            result in
            
            completion(result)
            
        }
    }
}
