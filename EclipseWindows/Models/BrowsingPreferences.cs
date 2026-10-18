using System.Text.Json;
using System.Text.Json.Serialization;

namespace Eclipse.Windows.Models;

// Preserve Apple catalog identifiers and applicable appearance keys; Windows-only options remain local.
public sealed class HomeCatalog
{
    public static IReadOnlySet<string> SupportedIds {get;}=Defaults().Where(c=>c.Source is "TMDB" or "AniList").Select(c=>c.Id).ToHashSet();
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Source { get; set; } = "TMDB";
    public bool IsEnabled { get; set; }
    public int Order { get; set; }
    public string DisplayStyle { get; set; } = "standard";
    [JsonIgnore] public double HorizontalOffset { get; set; }
    [JsonIgnore] public int FacetId { get; set; }
    [JsonIgnore] public string? FocusTitleId { get; set; }
    [JsonIgnore] public bool RestoreKeyboardFocus { get; set; }
    [JsonExtensionData] public Dictionary<string, JsonElement>? ProviderConfiguration { get; set; }
    [JsonIgnore] public string Availability => Source switch
    {
        "Local" => "Requires local viewing history or library data",
        "Stremio" => "Requires a configured Stremio addon",
        "Trakt" => "Requires a connected Trakt account",
        _ => SupportedIds.Contains(Id) ? "" : "This catalog needs a provider integration that is not available on Windows yet"
    };
    [JsonIgnore] public bool IsAvailable => Source is "TMDB" or "AniList" && SupportedIds.Contains(Id);
    public override string ToString() => Name;
    public static List<HomeCatalog> Defaults()
    {
        (string id, string name, string source, bool enabled, string style)[] rows = [
            ("forYou","Just For You","Local",true,"standard"), ("becauseYouWatched","Because You Watched","Local",true,"standard"),
            ("trending","Trending This Week","TMDB",true,"standard"), ("popularMovies","Popular Movies","TMDB",true,"standard"),
            ("networks","Network","TMDB",true,"network"), ("nowPlayingMovies","Now Playing Movies","TMDB",false,"standard"),
            ("upcomingMovies","Upcoming Movies","TMDB",false,"standard"), ("upcomingTV","Upcoming TV Shows","TMDB",false,"standard"),
            ("popularTVShows","Popular TV Shows","TMDB",true,"standard"), ("genres","Category","TMDB",true,"genre"),
            ("onTheAirTV","On The Air TV Shows","TMDB",false,"standard"), ("airingTodayTV","Airing Today TV Shows","TMDB",false,"standard"),
            ("topRatedTVShows","Top Rated TV Shows","TMDB",true,"standard"), ("topRatedMovies","Top Rated Movies","TMDB",true,"standard"),
            ("companies","Company","TMDB",true,"company"), ("trendingAnime","Trending Anime","AniList",true,"standard"),
            ("popularAnime","Popular Anime","AniList",true,"standard"), ("featured","Featured","TMDB",true,"featured"),
            ("topRatedAnime","Top Rated Anime","AniList",true,"standard"), ("airingAnime","Currently Airing Anime","AniList",false,"standard"),
            ("bestTVShows","Best TV Shows","TMDB",false,"ranked"), ("bestMovies","Best Movies","TMDB",false,"ranked"),
            ("bestAnime","Best Anime","AniList",false,"ranked"), ("upNext","Up Next","Local",false,"continueWatching"),
            ("traktContinueWatching","Trakt Continue Watching","Trakt",false,"continueWatching")
        ];
        return rows.Select((r,i) => new HomeCatalog { Id=r.id, Name=r.name, Source=r.source, IsEnabled=r.enabled, Order=i, DisplayStyle=r.style }).ToList();
    }
}
public sealed class CatalogLayout
{
    public string Orientation { get; set; } = "global";
    public double? SizeScale { get; set; }
}
public sealed class BrowsingPreferences
{
    public List<HomeCatalog> EnabledCatalogs { get; set; } = HomeCatalog.Defaults();
    public Dictionary<string, CatalogLayout> HomeCatalogLayoutOverrides { get; set; } = [];
    public string Appearance { get; set; } = "dark";
    public string AtmosphereStyle { get; set; } = "gradient";
    public string AppearancePalette { get; set; } = "midnightPurple";
    public string AccentColor { get; set; } = "purple";
    public string ExperimentalMediaDesignPreset { get; set; } = "cinematic";
    public string ExperimentalHomeCardShape { get; set; } = "automatic";
    public double ExperimentalMediaCardScale { get; set; } = 1;
    public double ExperimentalSectionSpacingScale { get; set; } = 1;
    public double ExperimentalCardRadiusScale { get; set; } = 1;
    public double ExperimentalHeroHeightScale { get; set; } = 1;
    public string HeroBannerCatalogId { get; set; } = "trending";
    public bool MediaDetailTitleArtworkEnabled { get; set; } = true;
    public bool HorizontalEpisodeList { get; set; } = true;
    public bool ShowUnairedEpisodes { get; set; } = true;
    public bool ImageDataSaverEnabled { get; set; }
    public string[] MediaDetailElementOrder { get; set; } = ["overview","actions","details","cast","ratingNotes","traktComments","episodes","stills","trailers","similarTitles"];
    public string[] MediaDetailHiddenElements { get; set; } = [];
    public string DefaultScheduleMode { get; set; } = "anime";
    public int ScheduleWindowDays { get; set; } = 7;
    public bool ShowLocalScheduleTime { get; set; } = true;
    [JsonExtensionData] public Dictionary<string, JsonElement>? AdditionalSettings { get; set; }
    public void Normalize()
    {
        EnabledCatalogs = (EnabledCatalogs ?? []).Where(c => c is not null && c.Id is {Length: >0 and <=200} && c.Id != "upcomingAnime")
            .DistinctBy(c => c.Id).OrderBy(c=>c.Order).Take(80).ToList();
        foreach(var c in EnabledCatalogs) {c.Name=string.IsNullOrWhiteSpace(c.Name) ? c.Id : c.Name[..Math.Min(c.Name.Length,200)];c.Source??="TMDB";c.DisplayStyle??="standard";}
        HomeCatalogLayoutOverrides ??= [];
        HomeCatalogLayoutOverrides=HomeCatalogLayoutOverrides.Where(p=>p.Key.Length<=200 && p.Value is not null).Take(80).ToDictionary(p=>p.Key,p=>p.Value);
        foreach(var layout in HomeCatalogLayoutOverrides.Values)
        {if(layout.Orientation is not ("global" or "automatic" or "poster" or "landscape"))layout.Orientation="global";if(layout.SizeScale is { } scale)layout.SizeScale=double.IsFinite(scale)?Math.Clamp(scale,.75,1.35):null;}
        ExperimentalMediaCardScale = Math.Clamp(double.IsFinite(ExperimentalMediaCardScale) ? ExperimentalMediaCardScale : 1, .75, 1.35);
        ExperimentalSectionSpacingScale = Math.Clamp(double.IsFinite(ExperimentalSectionSpacingScale)?ExperimentalSectionSpacingScale:1, .75, 1.35);
        ExperimentalCardRadiusScale = Math.Clamp(double.IsFinite(ExperimentalCardRadiusScale)?ExperimentalCardRadiusScale:1, .5, 1.5);
        ExperimentalHeroHeightScale = Math.Clamp(double.IsFinite(ExperimentalHeroHeightScale)?ExperimentalHeroHeightScale:1, .75, 1.35);
        ScheduleWindowDays = new[] {7,14,21,30}.Contains(ScheduleWindowDays) ? ScheduleWindowDays : 7;
        DefaultScheduleMode = new[] {"anime","western","combined"}.Contains(DefaultScheduleMode) ? DefaultScheduleMode : "anime";
        MediaDetailElementOrder = (MediaDetailElementOrder??[]).Where(s=>s is {Length:>0 and <80}).Distinct().Take(30).ToArray();
        MediaDetailHiddenElements = (MediaDetailHiddenElements??[]).Where(s=>s is {Length:>0 and <80}).Distinct().Take(30).ToArray();
    }
}
