import Foundation

enum MaturityRating: Int, Comparable, Codable, Sendable {

    case general = 0

    case teen = 1

    case mature = 2

    case adult = 3

    case unknown = 4

    static func < (lhs: MaturityRating, rhs: MaturityRating) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var isBlockedForKids: Bool {
        self == .mature || self == .adult || self == .unknown
    }

    static func strictest(_ lhs: MaturityRating, _ rhs: MaturityRating) -> MaturityRating {
        if lhs == .unknown { return rhs }
        if rhs == .unknown { return lhs }
        return lhs > rhs ? lhs : rhs
    }

    static func classify(certification: String, region: String? = nil) -> MaturityRating {
        let normalized = certification.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return .unknown }

        let compact = normalized
            .replacingOccurrences(of: "+", with: "PLUS")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        guard !compact.isEmpty else { return .unknown }

        if let region, let regional = regionalRatings[region.uppercased()]?[compact] {
            return regional
        }

        if let exact = exactRatings[compact] {
            return exact
        }

        if normalized.contains("18禁") || normalized.contains("限制級")
            || normalized.contains("成人") || normalized.contains("청소년관람불가") {
            return .adult
        }
        if normalized.contains("輔導級") || normalized.contains("보호자") {
            return .mature
        }
        if normalized.contains("普遍級") || normalized.contains("전체관람가") {
            return .general
        }

        if compact.hasPrefix("R18") || compact.hasPrefix("R21") || compact.hasPrefix("NC17")
            || compact.hasPrefix("X18") || compact.hasPrefix("AO") || compact.hasPrefix("RX") {
            return .adult
        }
        if compact.hasPrefix("MA") || compact.hasPrefix("R15") || compact.hasPrefix("R16")
            || compact.hasPrefix("R17") || compact.hasPrefix("TVMA") {
            return .mature
        }
        if compact.hasPrefix("TV14") || compact.hasPrefix("PG13") || compact.hasPrefix("R13") {
            return .teen
        }
        if compact.hasPrefix("TVY") || compact.hasPrefix("TVG") {
            return .general
        }

        if compact.hasPrefix("PG") {
            if let age = leadingAge(in: String(compact.dropFirst(2))) {
                return tier(forMinimumAge: age)
            }
            return .general
        }

        if let age = leadingAge(in: compact) {
            return tier(forMinimumAge: age)
        }

        return .unknown
    }

    private static func tier(forMinimumAge age: Int) -> MaturityRating {
        switch age {
        case ..<12: return .general
        case 12..<15: return .teen
        case 15..<18: return .mature
        default: return .adult
        }
    }

    static func classify(certifications: [String], region: String? = nil) -> MaturityRating {
        certifications.reduce(MaturityRating.unknown) { result, value in
            strictest(result, classify(certification: value, region: region))
        }
    }

    static var preferredRegions: [String] {
        var regions: [String] = []
        if #available(iOS 16.0, tvOS 16.0, macOS 13.0, *) {
            if let region = Locale.current.region?.identifier { regions.append(region) }
        } else if let region = Locale.current.regionCode {
            regions.append(region)
        }
        for fallback in ["US", "GB"] where !regions.contains(fallback) {
            regions.append(fallback)
        }
        return regions
    }

    static func classify(certificationsByRegion: [String: [String]]) -> MaturityRating {
        for region in preferredRegions {
            guard let certifications = certificationsByRegion[region] else { continue }
            let rating = classify(certifications: certifications, region: region)
            if rating != .unknown { return rating }
        }

        return certificationsByRegion.reduce(MaturityRating.unknown) { result, entry in
            strictest(result, classify(certifications: entry.value, region: entry.key))
        }
    }

    private static func leadingAge(in compact: String) -> Int? {
        let digits = compact.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 2, let value = Int(digits) else { return nil }
        return value
    }

    private static let regionalRatings: [String: [String: MaturityRating]] = [

        "IN": ["A": .adult, "S": .adult, "UA": .teen],

        "CA": ["A": .adult, "R": .adult]
    ]

    private static let exactRatings: [String: MaturityRating] = [

        "G": .general, "TVY": .general, "TVY7": .general, "TVY7FV": .general,
        "TVG": .general, "PG": .general, "TVPG": .general,
        "PG13": .teen, "TV14": .teen,
        "R": .mature, "TVMA": .mature,
        "NC17": .adult, "X": .adult, "XXX": .adult, "AO": .adult,
        "ADULT": .adult, "ADULTONLY": .adult, "UNRATED": .unknown, "NR": .unknown,

        "U": .general, "UC": .general,
        "12": .teen, "12A": .teen,
        "15": .mature,
        "18": .adult, "R18": .adult,

        "E": .general, "M": .mature, "MA15": .mature, "MA15PLUS": .mature,
        "R13": .teen, "R15": .mature, "R16": .mature,
        "R18PLUS": .adult, "X18PLUS": .adult, "RC": .adult,

        "PG12": .teen, "R15PLUS": .mature,
        "T": .teen, "TPLUS": .mature, "A": .general,
        "R17": .mature, "RPLUS": .mature, "RX": .adult,

        "ALL": .general, "19": .adult,

        "L": .general, "10": .general, "14": .teen, "16": .mature,

        "PG13SG": .teen, "NC16": .mature, "M18": .adult, "R21": .adult,

        "0": .general, "6": .general, "7": .general, "9": .general,
        "AL": .general, "TP": .general
    ]

    static let matureTextMarkers: Set<String> = [
        "adult", "adults only", "aged up", "boys love", "doujinshi", "ecchi",
        "erotic", "erotica", "explicit", "gore", "hentai", "incest",
        "josei", "lolicon", "mature", "nsfw", "nudity", "pornographic",
        "pornography", "prostitution", "r 18", "r18", "rape", "seinen",
        "sexual content", "sexually explicit", "shotacon", "smut",
        "softcore", "yaoi", "yuri", "18 plus"
    ]

    static func containsMatureText(_ text: String) -> Bool {
        let normalized = " " + text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ") + " "
        return matureTextMarkers.contains { normalized.contains(" \($0) ") }
    }
}
