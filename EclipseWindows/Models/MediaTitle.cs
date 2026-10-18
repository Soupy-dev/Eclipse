using Microsoft.UI.Xaml.Media.Imaging;

namespace Eclipse.Windows.Models;

public sealed record MediaTitle
{
    public required int TmdbId { get; init; }
    public required string MediaType { get; init; }
    public required string Title { get; init; }
    public string Provider { get; init; } = "TMDB";
    public int ProviderId { get; init; }
    public int? AniListId { get; init; }
    public int? MalId { get; init; }
    public int? MappedSeason { get; init; }
    public string Format { get; init; } = "";
    public string OriginalTitle { get; init; } = "";
    public string OriginalLanguage { get; init; } = "";
    public int[] GenreIds { get; init; } = [];
    public string Status { get; init; } = "";
    public string? LogoPath { get; init; }
    public string IdentityNotice { get; init; } = "";
    public IReadOnlyList<AnimeMapping> AnimeMappings { get; init; } = [];
    public AnimeStructure? AnimeStructure { get; init; }
    public IReadOnlyDictionary<int,int> TmdbSeasonCounts { get; init; } = new Dictionary<int,int>();
    public IReadOnlyList<MediaSeason> TmdbSeasons { get; init; } = [];
    public int? RuntimeMinutes { get; init; }
    public string ScoreProvider { get; init; } = "TMDB";
    public string Id => Provider is "AniList" or "MAL" or "TVMaze" ? $"{Provider.ToLowerInvariant()}:{ProviderId}" : $"{MediaType}:{TmdbId}";
    public string Kind => MediaType == "movie" ? "Movie" : "Series";
    public string Synopsis { get; init; } = "";
    public string Tagline { get; init; } = "";
    public string ReleaseDate { get; init; } = "";
    public string Genre { get; init; } = "";
    public string Duration { get; init; } = "";
    public double Score { get; init; }
    public string? PosterPath { get; init; }
    public string? BackdropPath { get; init; }
    public IReadOnlyList<MediaSeason> Seasons { get; init; } = [];
    public IReadOnlyList<CastMember> Cast { get; init; } = [];
    public string Year => ReleaseDate.Length>=4 && int.TryParse(ReleaseDate[..4],out var year) && year is >=1900 and <2200 ? year.ToString() : "Date not announced";
    public string Rating => Score > 0 ? $"{Score:0.0} / 10" : "Not yet rated";
    public string Subtitle => $"{Year} · {Kind}";
    public string Metadata => string.Join("   ·   ", new[] { Year, Kind, Genre, Duration }.Where(value => !string.IsNullOrWhiteSpace(value)));
    public string AccessibleName => $"{Title}, {Subtitle}. Open details.";
    public static bool DataSaver { get; set; }
    public Uri? ArtworkUri => ImageUri(BackdropPath, DataSaver ? "w780" : "w1280");
    public Uri? PosterUri => ImageUri(PosterPath, "w342");
    private BitmapImage? _poster;
    private BitmapImage? _landscape;
    public BitmapImage? Landscape => ImageUri(BackdropPath, "w300") is { } uri ? _landscape ??= new BitmapImage
    { DecodePixelType = DecodePixelType.Logical, DecodePixelWidth = 320, UriSource = uri } : Poster;
    public BitmapImage? Poster => PosterUri is { } uri ? _poster ??= new BitmapImage
    { DecodePixelType = DecodePixelType.Logical, DecodePixelHeight = DataSaver ? 180 : 300, UriSource = uri } : null;
    public void ReleaseArtwork()
    {
        if(_poster is not null) _poster.UriSource=null;
        if(_landscape is not null) _landscape.UriSource=null;
        _poster=_landscape=null;
    }
    public static Uri? ImageUri(string? path, string size) =>
        !string.IsNullOrWhiteSpace(path) && path.StartsWith('/') && !path.Contains("..") && !path.Contains('?')
            ? new Uri($"https://image.tmdb.org/t/p/{size}{path}") : SafeImage(path);
    private static Uri? SafeImage(string? value) => Uri.TryCreate(value,UriKind.Absolute,out var uri) && uri.Scheme=="https" && uri.UserInfo.Length==0 &&
        new[] {"s4.anilist.co","s3.anilist.co","cdn.myanimelist.net","static.tvmaze.com","image.tmdb.org"}.Contains(uri.Host) ? uri : null;
    public static bool TryParseId(string? id, out string type, out int number)
    {
        var parts = id?.Split(':');
        type = parts?.FirstOrDefault() ?? "";
        number = 0;
        return parts is { Length: 2 } && type is "movie" or "tv" && int.TryParse(parts[1], out number) && number > 0;
    }
    public override string ToString() => AccessibleName;
}

public sealed record MediaGenre(int Id, string Name) { public override string ToString() => Name; }
public sealed record BrowseOrder(string Id, string Name) { public override string ToString() => Name; }
public sealed record MediaSeason(int Number, string Name, int EpisodeCount)
{
    public AnimeCour? Cour { get; init; }
    public override string ToString() => Name;
}
public sealed record MediaEpisode(int Number, string Title, string Duration, string Synopsis, string AirDate, string? StillPath=null)
{
    public int? SourceEpisodeId { get; init; }
    public int? TmdbSeasonNumber { get; init; }
    public int? TmdbEpisodeNumber { get; init; }
    public int? RuntimeMinutes { get; init; }
    public string? AnimeId { get; init; }
    public AnimeEpisodeUnit? Unit { get; init; }
    public string CoordinateLabel => Unit is {} unit?$"{unit.Edition} · AniList {unit.AniList} · MAL {unit.Mal}":TmdbSeasonNumber is {} s&&TmdbEpisodeNumber is {} e?$"TMDB S{s:00} E{e:00}":AnimeId is not null?"Provider episode · TMDB unresolved":"";
    private BitmapImage? _still;
    public string NumberLabel => Number.ToString("00");
    public string AccessibleName => $"Episode {Number}, {Title}, {Duration}";
    public override string ToString() => AccessibleName;
    public BitmapImage? Still => MediaTitle.ImageUri(StillPath,"w300") is { } uri ? _still ??= new BitmapImage { DecodePixelWidth=300,UriSource=uri } : null;
    public void ReleaseArtwork() { if(_still is not null)_still.UriSource=null;_still=null; }
    public string AirLabel => DateOnly.TryParse(AirDate,out var date) ? date.ToString("MMM d, yyyy") : "Date TBA";
    public bool HasAired => DateOnly.TryParse(AirDate,out var date) && date<=DateOnly.FromDateTime(DateTime.Now);
}
public sealed record CastMember(string Name, string Character, string? ProfilePath=null)
{
    private BitmapImage? _portrait;
    public BitmapImage? Portrait=>MediaTitle.ImageUri(ProfilePath,"w185") is {} uri?_portrait??=new BitmapImage{DecodePixelHeight=180,UriSource=uri}:null;
    public void ReleaseArtwork(){if(_portrait is not null)_portrait.UriSource=null;_portrait=null;}
    public string Description => string.IsNullOrWhiteSpace(Character) ? Name : $"{Name} as {Character}";
}
public sealed record CatalogPage(IReadOnlyList<MediaTitle> Titles, int Page, int TotalPages);
