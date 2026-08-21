//
//  Module.swift
//  Kanzen
//
//  Created by Dawud Osman on 13/05/2025.
//
import Foundation
struct ModuleData: Codable, Equatable
{

    let sourceName: String
    let author: Author
    let iconURL: String
    let version: String
    let language: String
    let scriptURL: String
    let novel: Bool?

    enum CodingKeys: String, CodingKey {
        case sourceName, author, version, language, novel

        case iconURL
        case scriptURL

        case iconUrl
        case scriptUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceName = try container.decode(String.self, forKey: .sourceName)
        author = try container.decode(Author.self, forKey: .author)
        version = try container.decode(String.self, forKey: .version)
        language = try container.decode(String.self, forKey: .language)
        novel = try container.decodeIfPresent(Bool.self, forKey: .novel)

        if let val = try container.decodeIfPresent(String.self, forKey: .iconURL) {
            iconURL = val
        } else {
            iconURL = try container.decode(String.self, forKey: .iconUrl)
        }

        if let val = try container.decodeIfPresent(String.self, forKey: .scriptURL) {
            scriptURL = val
        } else {
            scriptURL = try container.decode(String.self, forKey: .scriptUrl)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceName, forKey: .sourceName)
        try container.encode(author, forKey: .author)
        try container.encode(version, forKey: .version)
        try container.encode(language, forKey: .language)
        try container.encodeIfPresent(novel, forKey: .novel)
        try container.encode(iconURL, forKey: .iconURL)
        try container.encode(scriptURL, forKey: .scriptURL)
    }

    struct Author: Codable, Equatable
    {
        let name: String
        let iconURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case iconURL
            case icon
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)

            if let val = try container.decodeIfPresent(String.self, forKey: .iconURL) {
                iconURL = val
            } else {
                iconURL = (try? container.decode(String.self, forKey: .icon)) ?? ""
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(iconURL, forKey: .iconURL)
        }
    }
}
struct ModuleDataContainer: Codable, Identifiable,Hashable
{
    let id: UUID
    let moduleData: ModuleData
    let localPath: String
    let moduleurl: String
    var isActive: Bool
    init(id:UUID = UUID(), moduleData: ModuleData, localPath: String, moduleurl: String, isActive: Bool = false) {
        self.id = id
        self.moduleData = moduleData
        self.localPath = localPath
        self.moduleurl = moduleurl
        self.isActive = isActive
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    static func == (lhs: ModuleDataContainer, rhs: ModuleDataContainer) -> Bool {
        return lhs.id == rhs.id
    }
}
