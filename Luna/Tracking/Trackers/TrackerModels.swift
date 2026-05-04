//
//  TrackerModels.swift
//  Luna
//
//  Created by Soupy-dev
//

import Foundation

enum TrackerService: String, Codable, CaseIterable {
    case anilist
    case myAnimeList
    case trakt

    var displayName: String {
        switch self {
        case .anilist:
            return "AniList"
        case .myAnimeList:
            return "MyAnimeList"
        case .trakt:
            return "Trakt"
        }
    }

    var baseURL: String {
        switch self {
        case .anilist:
            return "https://anilist.co"
        case .myAnimeList:
            return "https://myanimelist.net"
        case .trakt:
            return "https://trakt.tv"
        }
    }

    var logoURL: URL? {
        switch self {
        case .anilist:
            return URL(string: "https://anilist.co/img/icons/android-chrome-512x512.png")
        case .myAnimeList:
            return URL(string: "https://cdn.myanimelist.net/images/favicon.ico")
        case .trakt:
            return URL(string: "https://walter.trakt.tv/hotlink-ok/public/apple-touch-icon.png")
        }
    }
}

struct TrackerAccount: Codable {
    let service: TrackerService
    let username: String
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    let userId: String
    var isConnected: Bool = true

    mutating func updateTokens(access: String, refresh: String?, expiresAt: Date?) {
        self.accessToken = access
        self.refreshToken = refresh
        self.expiresAt = expiresAt
    }
}

struct TrackerState: Codable {
    var accounts: [TrackerAccount] = []
    var syncEnabled: Bool = true
    var autoSyncRatings: Bool = false
    var lastSyncDate: Date?

    enum CodingKeys: String, CodingKey {
        case accounts
        case syncEnabled
        case autoSyncRatings
        case lastSyncDate
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try container.decodeIfPresent([TrackerAccount].self, forKey: .accounts) ?? []
        syncEnabled = try container.decodeIfPresent(Bool.self, forKey: .syncEnabled) ?? true
        autoSyncRatings = try container.decodeIfPresent(Bool.self, forKey: .autoSyncRatings) ?? false
        lastSyncDate = try container.decodeIfPresent(Date.self, forKey: .lastSyncDate)
    }

    mutating func addOrUpdateAccount(_ account: TrackerAccount) {
        if let index = accounts.firstIndex(where: { $0.service == account.service }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
    }

    func getAccount(for service: TrackerService) -> TrackerAccount? {
        accounts.first { $0.service == service && $0.isConnected }
    }

    mutating func disconnectAccount(for service: TrackerService) {
        if let index = accounts.firstIndex(where: { $0.service == service }) {
            accounts[index].isConnected = false
        }
    }
}

// AniList Models
struct AniListAuthResponse: Codable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }
}

struct AniListUser: Codable {
    let id: Int
    let name: String
}

struct AniListMediaListEntry: Codable {
    let id: Int
    let mediaId: Int
    let status: String  // CURRENT, PLANNING, COMPLETED, DROPPED, PAUSED, REPEATING
    let progress: Int
    let progressVolumes: Int?
    let score: Int?
    let startedAt: AniListDate?
    let completedAt: AniListDate?

    enum CodingKeys: String, CodingKey {
        case id, status, progress, score
        case mediaId = "mediaId"
        case progressVolumes = "progressVolumes"
        case startedAt, completedAt
    }
}

struct AniListDate: Codable {
    let year: Int?
    let month: Int?
    let day: Int?
}

struct AniListMediaEntry: Codable {
    let id: Int
    let title: AniListTitle
    let episodes: Int?
    let status: String?
    let seasonYear: Int?
    let season: String?
    let format: String?
    let coverImage: AniListCoverImage?
    let nextAiringEpisode: AniListAiringSchedule?
    let relations: AniListRelations?
    let type: String?

    struct AniListTitle: Codable {
        let romaji: String?
        let english: String?
        let native: String?
    }
}

struct AniListCoverImage: Codable {
    let large: String?
    let medium: String?
}

struct AniListRelations: Codable {
    let edges: [AniListRelationEdge]
}

struct AniListRelationEdge: Codable {
    let relationType: String
    let node: AniListRelatedAnime
}

struct AniListRelatedAnime: Codable {
    let id: Int
    let title: AniListTitle
    
    struct AniListTitle: Codable {
        let romaji: String?
        let english: String?
        let native: String?
    }
}

struct AniListAiringSchedule: Codable {
    let episode: Int
    let airingAt: Int
}

// MyAnimeList Models
struct MALAuthResponse: Codable {
    let accessToken: String
    let tokenType: String?
    let expiresIn: Int?
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}

struct MALUser: Codable {
    let id: Int
    let name: String
}

// Trakt Models
struct TraktAuthResponse: Codable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}

struct TraktUser: Codable {
    let username: String
    let ids: TraktIds
}

struct TraktIds: Codable {
    let trakt: Int?
    let slug: String
    let imdb: String?
    let tmdb: Int?
}

enum TrackerSyncToolAction: String, CaseIterable, Identifiable {
    case fillEclipseFromAniList
    case fillEclipseFromMAL
    case pushEclipseToAniList
    case pushEclipseToMAL
    case portAniListToMAL
    case portMALToAniList

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fillEclipseFromAniList:
            return "Fill Eclipse From AniList"
        case .fillEclipseFromMAL:
            return "Fill Eclipse From MAL"
        case .pushEclipseToAniList:
            return "Push Eclipse To AniList"
        case .pushEclipseToMAL:
            return "Push Eclipse To MAL"
        case .portAniListToMAL:
            return "Port AniList To MAL"
        case .portMALToAniList:
            return "Port MAL To AniList"
        }
    }

    var subtitle: String {
        switch self {
        case .fillEclipseFromAniList:
            return "Add missing shows and advance local watched progress."
        case .fillEclipseFromMAL:
            return "Use MAL list progress to fill local Eclipse progress."
        case .pushEclipseToAniList:
            return "Send completed local episodes and chapters to AniList."
        case .pushEclipseToMAL:
            return "Send completed local episodes and chapters to MAL."
        case .portAniListToMAL:
            return "Copy AniList watch/read progress into MAL after preview."
        case .portMALToAniList:
            return "Copy MAL watch/read progress into AniList after preview."
        }
    }

    var isProviderPort: Bool {
        switch self {
        case .portAniListToMAL, .portMALToAniList:
            return true
        default:
            return false
        }
    }
}

struct TrackerSyncPreview: Identifiable {
    let id = UUID()
    let action: TrackerSyncToolAction
    var itemsToAdd: Int
    var itemsToAdvance: Int
    var skipped: Int
    var unmapped: Int
    var estimatedAPICalls: Int
    var notes: [String]
    var conflicts: [String] = []

    var requiresConfirmation: Bool {
        action.isProviderPort || itemsToAdd > 0 || itemsToAdvance > 0
    }
}
