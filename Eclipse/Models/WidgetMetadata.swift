import Foundation

struct WidgetNetwork: Identifiable {
    let id: Int
    let name: String
    let logoName: String

    static let curated: [WidgetNetwork] = [
        WidgetNetwork(id: 213,  name: "Netflix",      logoName: "play.rectangle.fill"),
        WidgetNetwork(id: 2739, name: "Disney+",      logoName: "sparkles.tv.fill"),
        WidgetNetwork(id: 49,   name: "HBO",           logoName: "tv.fill"),
        WidgetNetwork(id: 1024, name: "Amazon",        logoName: "shippingbox.fill"),
        WidgetNetwork(id: 2552, name: "Apple TV+",     logoName: "apple.logo"),
        WidgetNetwork(id: 453,  name: "Hulu",          logoName: "play.tv.fill"),
        WidgetNetwork(id: 4330, name: "Paramount+",    logoName: "mountain.2.fill"),
        WidgetNetwork(id: 1112, name: "Crunchyroll",   logoName: "play.circle.fill")
    ]

    static let kidsCurated: [WidgetNetwork] = [
        WidgetNetwork(id: 2739, name: "Disney+",         logoName: "sparkles.tv.fill"),
        WidgetNetwork(id: 54,   name: "Disney Channel",  logoName: "wand.and.stars"),
        WidgetNetwork(id: 13,   name: "Nickelodeon",     logoName: "star.circle.fill"),
        WidgetNetwork(id: 56,   name: "Cartoon Network", logoName: "paintpalette.fill"),
        WidgetNetwork(id: 4689, name: "PBS Kids",        logoName: "book.fill"),
        WidgetNetwork(id: 2076, name: "Boomerang",       logoName: "arrow.uturn.left.circle.fill"),
        WidgetNetwork(id: 213,  name: "Netflix",         logoName: "play.rectangle.fill"),
        WidgetNetwork(id: 2552, name: "Apple TV+",       logoName: "apple.logo")
    ]

    static var active: [WidgetNetwork] {
        ProfileManager.shared.isKidsModeActive ? kidsCurated : curated
    }
}

struct WidgetCompany: Identifiable {
    let id: Int
    let name: String

    static let curated: [WidgetCompany] = [
        WidgetCompany(id: 33,    name: "Universal"),
        WidgetCompany(id: 4,     name: "Paramount"),
        WidgetCompany(id: 174,   name: "Warner Bros."),
        WidgetCompany(id: 25,    name: "20th Century"),
        WidgetCompany(id: 2,     name: "Walt Disney"),
        WidgetCompany(id: 41077, name: "A24"),
        WidgetCompany(id: 1632,  name: "Lionsgate"),
        WidgetCompany(id: 5,     name: "Columbia")
    ]

    static let kidsCurated: [WidgetCompany] = [
        WidgetCompany(id: 3,     name: "Pixar"),
        WidgetCompany(id: 2,     name: "Walt Disney"),
        WidgetCompany(id: 6704,  name: "Illumination"),
        WidgetCompany(id: 521,   name: "DreamWorks"),
        WidgetCompany(id: 10342, name: "Studio Ghibli"),
        WidgetCompany(id: 9383,  name: "Blue Sky"),
        WidgetCompany(id: 6363,  name: "Warner Animation"),
        WidgetCompany(id: 4,     name: "Paramount")
    ]

    static var active: [WidgetCompany] {
        ProfileManager.shared.isKidsModeActive ? kidsCurated : curated
    }
}

struct WidgetGenre: Identifiable {
    let id: Int
    let name: String

    static let curated: [WidgetGenre] = [
        WidgetGenre(id: 28,    name: "Action"),
        WidgetGenre(id: 35,    name: "Comedy"),
        WidgetGenre(id: 18,    name: "Drama"),
        WidgetGenre(id: 878,   name: "Sci-Fi"),
        WidgetGenre(id: 10749, name: "Romance"),
        WidgetGenre(id: 16,    name: "Animation"),
        WidgetGenre(id: 10751, name: "Family"),
        WidgetGenre(id: 53,    name: "Thriller"),
        WidgetGenre(id: 27,    name: "Horror"),
        WidgetGenre(id: 99,    name: "Documentary")
    ]

    static let kidsCurated: [WidgetGenre] = [
        WidgetGenre(id: 10751, name: "Family"),
        WidgetGenre(id: 16,    name: "Animation"),
        WidgetGenre(id: 12,    name: "Adventure"),
        WidgetGenre(id: 35,    name: "Comedy"),
        WidgetGenre(id: 14,    name: "Fantasy"),
        WidgetGenre(id: 878,   name: "Sci-Fi"),
        WidgetGenre(id: 10402, name: "Music"),
        WidgetGenre(id: 36,    name: "History")
    ]

    static var active: [WidgetGenre] {
        ProfileManager.shared.isKidsModeActive ? kidsCurated : curated
    }
}
