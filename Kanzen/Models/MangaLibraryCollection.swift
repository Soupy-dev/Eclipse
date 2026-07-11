import Foundation
import Combine

final class MangaLibraryCollection: ObservableObject, Codable, Identifiable, Equatable {
    @Published var items: [MangaLibraryItem] = []
    var id: UUID
    @Published var name: String
    var description: String?

    init(id: UUID = UUID(), name: String, items: [MangaLibraryItem] = [], description: String? = nil) {
        self.id = id
        self.name = name
        self.items = items
        self.description = description
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id, name, items, description
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(items, forKey: .items)
        try container.encode(description, forKey: .description)
    }

    required convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let name = try container.decode(String.self, forKey: .name)
        let items = try container.decodeIfPresent([MangaLibraryItem].self, forKey: .items) ?? []
        let description = try container.decodeIfPresent(String.self, forKey: .description)
        self.init(id: id, name: name, items: items, description: description)
    }

    // MARK: - Equatable

    static func == (lhs: MangaLibraryCollection, rhs: MangaLibraryCollection) -> Bool {
        lhs.id == rhs.id
    }
}
