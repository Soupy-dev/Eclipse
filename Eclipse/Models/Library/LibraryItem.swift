//
//  LibraryItem.swift
//  Sora
//
//  Created by Francesco on 08/09/25.
//

import Foundation

struct LibraryItem: Codable, Identifiable {

    var id: String { searchResult.stableIdentity }
    let searchResult: TMDBSearchResult
    var dateAdded: Date = Date()
}
