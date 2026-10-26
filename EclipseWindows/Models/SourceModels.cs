namespace Eclipse.Windows.Models;

public sealed record SourceEpisodeContext
{
    public int LocalSeason {get;init;}
    public int LocalEpisode {get;init;}
    public int? AniListId {get;init;}
    public int? MalId {get;init;}
    public int? KitsuId {get;init;}
    public int? TmdbSeason {get;init;}
    public int? TmdbEpisode {get;init;}
    public int? AbsoluteEpisode {get;init;}
    public int? SeasonEpisodeCount {get;init;}
    public bool IsSpecial {get;init;}
    public bool TitleOnlySearch {get;init;}
    public int? PositiveAniListId=>AniListId is >0?AniListId:null;
    public bool HasAnimeMediaId=>AniListId is not null||KitsuId is not null;
}

public sealed record SourceSearchRequest
{
    public required MediaTitle Title {get;init;}
    public required string MediaTitle {get;init;}
    public string? SeasonTitleOverride {get;init;}
    public string? OriginalTitle {get;init;}
    public string? AnimeSeasonTitle {get;init;}
    public bool IsMovie {get;init;}
    public bool IsAnime {get;init;}
    public int? Year {get;init;}
    public string? OriginalLanguage {get;init;}
    public int? SeasonNumber {get;init;}
    public int? EpisodeNumber {get;init;}
    public string? EpisodeName {get;init;}
    public string? EpisodeOverview {get;init;}
    public int? TmdbSeason {get;init;}
    public int? TmdbEpisode {get;init;}
    public bool SpecialTitleOnlySearch {get;init;}
    public SourceEpisodeContext? Anime {get;init;}
}
