using System.Text.RegularExpressions;
using Eclipse.Windows.Models;

namespace Eclipse.Windows.Services;

public sealed partial class SourceSearchContext(SourceSearchRequest request)
{
    [GeneratedRegex(@"(?i)season\s+\d+")] private static partial Regex SeasonWords();
    public SourceSearchRequest Request {get;}=request;
    public bool IsMovie=>Request.IsMovie;
    public bool AnimeContext=>Request.IsAnime||Request.AnimeSeasonTitle is not null;
    public bool HasEpisode=>Request.SeasonNumber is not null&&Request.EpisodeNumber is not null;
    public string EffectiveTitle=>Request.SeasonTitleOverride??Request.MediaTitle;
    public SourceEpisodeContext? PlaybackContext=>Request.Anime;
    public bool HasAnimeLookupContext=>AnimeContext||PlaybackContext?.HasAnimeMediaId==true;
    public string? StrippedAnimeFallbackTitle
    {
        get
        {
            if(!AnimeContext)return null;
            var stripped=SeasonWords().Replace(EffectiveTitle,"").Trim();
            return stripped.Length>0&&!stripped.Equals(EffectiveTitle,StringComparison.OrdinalIgnoreCase)?stripped:null;
        }
    }
    public string? NormalizedAnimeSequelTitle
    {
        get
        {
            if(!AnimeContext||Request.SeasonNumber is not {} season||season<=1)return null;
            var trimmed=EffectiveTitle.Trim();var suffix=season.ToString();
            if(!trimmed.EndsWith(suffix))return null;
            var attached=trimmed[..^suffix.Length];
            return attached.Length>0&&char.IsLetter(attached[^1])?$"{attached.Trim()} Season {season}":null;
        }
    }
    public string? FallbackAnimeSearchQuery=>StrippedAnimeFallbackTitle is not {} stripped?null:!HasEpisode||Request.SpecialTitleOnlySearch?stripped:AnimeContext?$"{stripped} E{Request.EpisodeNumber}":$"{stripped} S{Request.SeasonNumber}E{Request.EpisodeNumber}";
    public string? NormalizedAnimeSequelSearchQuery=>NormalizedAnimeSequelTitle is not {} sequel?null:HasEpisode&&!Request.SpecialTitleOnlySearch?$"{sequel} E{Request.EpisodeNumber}":sequel;
    public string DisplayTitle=>!HasEpisode?EffectiveTitle:Request.SpecialTitleOnlySearch?EffectiveTitle:AnimeContext?$"{EffectiveTitle} E{Request.EpisodeNumber}":$"{EffectiveTitle} S{Request.SeasonNumber}E{Request.EpisodeNumber}";
    public string EpisodeSeasonInfo=>!HasEpisode?"":Request.SpecialTitleOnlySearch?"Special":AnimeContext?$"E{Request.EpisodeNumber}":$"S{Request.SeasonNumber}E{Request.EpisodeNumber}";
    public string MediaTypeText=>IsMovie?"Movie":"TV Show";
    public bool ShouldSearchStremio=>IsMovie||PlaybackContext is not {IsSpecial:true} c||c.PositiveAniListId is not null||c.KitsuId is not null||c.TmdbSeason is not null&&c.TmdbEpisode is not null;
    public int? StreamSeason=>PlaybackContext is {IsSpecial:true} c?c.TmdbSeason:Request.SpecialTitleOnlySearch?null:PlaybackContext?.TmdbSeason??Request.TmdbSeason??Request.SeasonNumber;
    public int? StreamEpisode=>PlaybackContext is {IsSpecial:true} c?c.TmdbEpisode:Request.SpecialTitleOnlySearch?null:PlaybackContext?.TmdbEpisode??Request.TmdbEpisode??Request.EpisodeNumber;
    public string SheetTitleBase=>TitleText.StripEpisodeSuffix(DisplayTitle).Trim();
    public ResultRanking Ranking=>new()
    {
        EffectiveTitle=EffectiveTitle,MediaTitle=Request.MediaTitle,DisplayTitle=DisplayTitle,OriginalTitle=Request.OriginalTitle,AnimeSeasonTitle=Request.AnimeSeasonTitle,
        NormalizedAnimeSequelTitle=NormalizedAnimeSequelTitle,StrippedAnimeFallbackTitle=StrippedAnimeFallbackTitle,IsAnime=Request.IsAnime,
        SelectedEpisode=HasEpisode?(Request.SeasonNumber!.Value,Request.EpisodeNumber!.Value):null,MinimumSimilarity=ServicesPreferenceStore.Shared.Value.MinimumSimilarity,Algorithm=ServicesPreferenceStore.Shared.Value.SimilarityAlgorithm
    };
    public IReadOnlyList<string> RankingCandidates
    {
        get
        {
            string?[] values=[SheetTitleBase,EffectiveTitle,Request.MediaTitle,NormalizedAnimeSequelTitle,StrippedAnimeFallbackTitle,AnimeContext?null:Request.OriginalTitle];
            var seen=new HashSet<string>();return values.Select(v=>v?.Trim()).Where(v=>v is {Length:>0}&&seen.Add(TitleText.Normalized(v))).Select(v=>v!).ToArray();
        }
    }
    public IReadOnlyList<string> CatalogTitleCandidates
    {
        get
        {
            var candidates=new List<string>();
            if(HasAnimeLookupContext&&Request.OriginalTitle?.Trim() is {Length:>0} original)candidates.Add(original);
            candidates.AddRange(RankingCandidates);candidates.Add(DisplayTitle);
            if(FallbackAnimeSearchQuery is {} fallback)candidates.Add(fallback);
            if(Request.EpisodeName is {Length:>0} name)candidates.Add($"{SheetTitleBase} {name}");
            var seen=new HashSet<string>();return candidates.Select(c=>c.Trim()).Where(c=>c.Length>0&&seen.Add(TitleText.Normalized(c))).ToArray();
        }
    }
}
