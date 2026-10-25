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
    [JsonIgnore] public string Summary => string.Join(" · ",new[]{Source,DisplayStyle switch{"" or "standard"=>"","continueWatching"=>"Playback",_=>char.ToUpperInvariant(DisplayStyle[0])+DisplayStyle[1..]}}.Where(s=>s.Length>0))+(Availability.Length>0?$"\n{Availability}":"");
    [JsonIgnore] public bool IsAvailable => Source is "TMDB" or "AniList" && SupportedIds.Contains(Id);
    public override string ToString() => Name;
    public static List<HomeCatalog> Defaults()
    {
        (string id, string name, string source, bool enabled, string style)[] rows = [
            ("upNext","Up Next","Local",true,"continueWatching"), ("forYou","Just For You","Local",true,"standard"), ("becauseYouWatched","Because You Watched","Local",true,"standard"),
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
            ("bestAnime","Best Anime","AniList",false,"ranked"),
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
    public string AtmosphereStyle { get; set; } = "multiGradient";
    public string AppearancePalette { get; set; } = "midnightPurple";
    public string[] AppearanceCustomColors { get; set; } = ["#291F33","#422957","#331F29"];
    public double AppearanceBleedStrength { get; set; } = 1;
    public double AppearanceBackgroundIntensity { get; set; } = 1;
    public string AtmosphereSolidColorSource { get; set; } = "dominant";
    public string AtmosphereSolidColor { get; set; } = "#401F73";
    public BrowseFilterPreferences BrowseFilterPreferences { get; set; } = new();
    public string AccentColor { get; set; } = "purple";
    public string ExperimentalMediaDesignPreset { get; set; } = "cinematic";
    public string ExperimentalHomeCardShape { get; set; } = "automatic";
    public double ExperimentalMediaCardScale { get; set; } = 1;
    public double ExperimentalSectionSpacingScale { get; set; } = 1;
    public double ExperimentalCardRadiusScale { get; set; } = 1;
    public double ExperimentalHeroHeightScale { get; set; } = 1;
    public string HeroBannerCatalogId { get; set; } = "trending";
    public string HeroBannerBehavior {get;set;}="carousel";
    public bool HomeAnimatedBackgroundEnabled {get;set;}=true;
    // Apple's key and values; Windows defaults to 30 FPS because 20 reads as stutter on desktop displays.
    public string HomeAnimatedBackgroundFrameRate {get;set;}="fps30";
    public bool LibraryShowBookmarksSection {get;set;}=true;
    public string LibraryCollectionLayout {get;set;}="horizontal";
    public bool RatingsFollowSeasonSelection {get;set;}=true;
    public bool MediaDetailTitleArtworkEnabled { get; set; } = true;
    public bool HorizontalEpisodeList { get; set; } = true;
    public bool ShowUnairedEpisodes { get; set; } = true;
    public bool ImageDataSaverEnabled { get; set; }
    public string[] MediaDetailElementOrder { get; set; } = ["overview","actions","details","cast","ratingNotes","traktComments","episodes","stills","trailers","similarTitles"];
    // Windows hides these supplementary sections until enabled in Appearance (Apple shows all by default).
    public string[] MediaDetailHiddenElements { get; set; } = ["cast","stills","trailers","similarTitles"];
    public string DefaultScheduleMode { get; set; } = "anime";
    public int ScheduleWindowDays { get; set; } = 7;
    public bool ShowLocalScheduleTime { get; set; } = true;
    [JsonExtensionData] public Dictionary<string, JsonElement>? AdditionalSettings { get; set; }
    public void Normalize()
    {
        if(LibraryCollectionLayout is not ("horizontal" or "vertical"))LibraryCollectionLayout="horizontal";
        if(HeroBannerBehavior is not ("static" or "carousel"))HeroBannerBehavior="carousel";
        HomeAnimatedBackgroundFrameRate=HomeAnimatedBackgroundFrameRate switch{"fps15"=>"fps20","fps20" or "fps30" or "fps60" or "fps120"=>HomeAnimatedBackgroundFrameRate,_=>"fps30"};
        AdditionalSettings?.Remove("appearance");
        if(AtmosphereStyle is not ("gradient" or "multiGradient" or "aurora" or "ember" or "solid"))AtmosphereStyle="multiGradient";
        if(!AtmospherePalette.Ids.Contains(AppearancePalette))AppearancePalette="midnightPurple";
        var customColors=new[]{"#291F33","#422957","#331F29"};
        AppearanceCustomColors=Enumerable.Range(0,3).Select(i=>AppearanceCustomColors?.ElementAtOrDefault(i) is {} color&&IsHexColor(color)?color:customColors[i]).ToArray();
        AppearanceBleedStrength=Math.Clamp(double.IsFinite(AppearanceBleedStrength)?AppearanceBleedStrength:1,0,1.2);
        AppearanceBackgroundIntensity=Math.Clamp(double.IsFinite(AppearanceBackgroundIntensity)?AppearanceBackgroundIntensity:1,.6,1.3);
        if(AtmosphereSolidColorSource is not ("dominant" or "custom"))AtmosphereSolidColorSource="dominant";
        if(!IsHexColor(AtmosphereSolidColor))AtmosphereSolidColor="#401F73";
        BrowseFilterPreferences??=new();
        if(!BrowseOptions.MediaTypes.Contains(BrowseFilterPreferences.MediaTypeRawValue))BrowseFilterPreferences.MediaTypeRawValue="Movies";
        BrowseFilterPreferences.ConfigurationsByMediaType=BrowseOptions.MediaTypes.ToDictionary(type=>type,type=>BrowseOptions.Sanitized(BrowseFilterPreferences.ConfigurationsByMediaType?.GetValueOrDefault(type),type));
        if(!IsHexColor(AccentColor)&&!AtmospherePalette.Accents.Any(p=>p.Id==AccentColor))AccentColor="purple";
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
    public static bool IsHexColor(string? value)=>value is {Length:7}&&value[0]=='#'&&value.Skip(1).All(Uri.IsHexDigit);
}
