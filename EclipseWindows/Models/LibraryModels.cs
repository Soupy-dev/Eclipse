using System.Text.Json.Serialization;
namespace Eclipse.Windows.Models;

// The Apple backup shape is an array of collections containing TMDBSearchResult snapshots.
public sealed record LibraryCollection
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public string Name { get; init; } = "";
    public string? Description { get; init; }
    public List<LibraryItem> Items { get; init; } = [];
    [JsonIgnore] public string Summary => $"{Items.Count} titles" + (string.IsNullOrWhiteSpace(Description) ? "" : $" · {Description}");
}
public sealed record LibraryItem
{
    public required LibraryMedia SearchResult { get; init; }
    public double DateAdded { get; init; }
    [JsonIgnore] public string Id => SearchResult.Identity;
}
public sealed record LibraryMedia
{
    public int Id { get; init; }
    [JsonPropertyName("media_type")] public string MediaType { get; init; } = "tv";
    public string? Title { get; init; }
    public string? Name { get; init; }
    public string? Overview { get; init; }
    [JsonPropertyName("poster_path")] public string? PosterPath { get; init; }
    [JsonPropertyName("backdrop_path")] public string? BackdropPath { get; init; }
    [JsonPropertyName("release_date")] public string? ReleaseDate { get; init; }
    [JsonPropertyName("first_air_date")] public string? FirstAirDate { get; init; }
    [JsonPropertyName("vote_average")] public double? VoteAverage { get; init; }
    public double Popularity { get; init; }
    [JsonPropertyName("genre_ids")] public int[] GenreIds { get; init; } = [];
    [JsonPropertyName("original_language")] public string? OriginalLanguage { get; init; }
    [JsonPropertyName("anime_identity_seed")] public AnimeIdentitySeed? AnimeIdentitySeed { get; init; }
    // Windows retains an unresolved provider route without claiming a TMDB match.
    public string? Provider { get; init; }
    public int? ProviderId { get; init; }
    [JsonIgnore] public string Identity => Provider is "AniList" or "MAL" ? $"{Provider.ToLowerInvariant()}:{ProviderId}" : $"{MediaType}:{Id}";
    public MediaTitle ToTitle() => new() { TmdbId = Provider is "AniList" or "MAL" ? 0 : Id, MediaType = MediaType, Title = Title ?? Name ?? "Untitled", Synopsis = Overview ?? "", PosterPath = PosterPath, BackdropPath = BackdropPath, ReleaseDate = ReleaseDate ?? FirstAirDate ?? "", Score = VoteAverage ?? 0, GenreIds = GenreIds, OriginalLanguage = OriginalLanguage ?? "", Provider = Provider ?? "TMDB", ProviderId = ProviderId ?? Id, AniListId = AnimeIdentitySeed?.AnilistId is > 0 ? AnimeIdentitySeed.AnilistId : null, MalId = AnimeIdentitySeed?.MalId };
    public static LibraryMedia From(MediaTitle t) => new() { Id = t.TmdbId > 0 ? t.TmdbId : t.ProviderId, MediaType = t.MediaType, Title = t.MediaType == "movie" ? t.Title : null, Name = t.MediaType == "tv" ? t.Title : null, Overview = t.Synopsis, PosterPath = t.PosterPath, BackdropPath = t.BackdropPath, ReleaseDate = t.MediaType == "movie" ? t.ReleaseDate : null, FirstAirDate = t.MediaType == "tv" ? t.ReleaseDate : null, VoteAverage = t.Score, GenreIds = t.GenreIds, OriginalLanguage = t.OriginalLanguage, Provider = t.TmdbId <= 0 && t.Provider is "AniList" or "MAL" ? t.Provider : null, ProviderId = t.TmdbId <= 0 && t.Provider is "AniList" or "MAL" ? t.ProviderId : null, AnimeIdentitySeed = t.AniListId is > 0 || t.MalId is > 0 ? new(t.AniListId ?? -(t.MalId ?? 0), t.MalId, null, t.Format) : null };
}
public sealed record AnimeIdentitySeed(int AnilistId, int? MalId, int? KitsuId, string? Format);
public sealed record RatingDocument
{
    public Dictionary<string, double> Ratings { get; init; } = [];
    public Dictionary<string, string> Notes { get; init; } = [];
    public Dictionary<string, System.Text.Json.JsonElement> LegacyAttachments { get; init; } = [];
}
