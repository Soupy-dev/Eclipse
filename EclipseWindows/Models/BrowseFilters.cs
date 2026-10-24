namespace Eclipse.Windows.Models;

public sealed class BrowseFilterConfiguration
{
    public List<string> SelectedGenreKeys { get; set; } = [];
    public List<string> ExcludedGenreKeys { get; set; } = [];
    public List<int> SelectedYears { get; set; } = [];
    public List<int> ExcludedYears { get; set; } = [];
    public List<string> SelectedCountryCodes { get; set; } = [];
    public string SortRawValue { get; set; } = "popularity.desc";
    public double MinimumRating { get; set; }
    public string AgeRatingRawValue { get; set; } = "all";
    public bool HasActiveFilters => SelectedGenreKeys.Count > 0 || ExcludedGenreKeys.Count > 0 || SelectedYears.Count > 0 || ExcludedYears.Count > 0 || SelectedCountryCodes.Count > 0 || SortRawValue != "popularity.desc" || MinimumRating > 0 || AgeRatingRawValue != "all";
}

public sealed class BrowseFilterPreferences
{
    public string MediaTypeRawValue { get; set; } = "Movies";
    public Dictionary<string, BrowseFilterConfiguration> ConfigurationsByMediaType { get; set; } = [];
}

public sealed record BrowseGenre(string Key, string Name, int? GenreId = null, string? Keyword = null)
{
    public static BrowseGenre Tmdb(int id, string name) => new($"tmdb-{id}", name, id);
    public static BrowseGenre Tag(string keyword, string name) => new($"keyword-{keyword}", name, null, keyword);
}

public static class BrowseOptions
{
    public static readonly string[] MediaTypes = ["Movies", "TV Shows", "Anime"];
    public static readonly (string Raw, string Title)[] Sorts = [("popularity.desc", "Most Popular"), ("newest", "Newest"), ("oldest", "Oldest"), ("vote_average.desc", "Rank"), ("title.asc", "Title A-Z")];
    public static readonly (string Raw, string Title)[] AgeRatings = [("all", "Any Age Rating"), ("general", "All Ages"), ("teen", "Up to 14+"), ("mature", "Up to 17+"), ("adult", "18+ Only")];
    private static readonly BrowseGenre[] MovieGenres = [Tmdb(28, "Action"), Tmdb(12, "Adventure"), Tmdb(16, "Animation"), Tmdb(35, "Comedy"), Tmdb(80, "Crime"), Tmdb(99, "Documentary"), Tmdb(18, "Drama"), Tmdb(10751, "Family"), Tmdb(14, "Fantasy"), Tmdb(36, "History"), Tmdb(27, "Horror"), Tmdb(10402, "Music"), Tmdb(9648, "Mystery"), Tmdb(10749, "Romance"), Tmdb(878, "Sci-Fi"), Tmdb(10770, "TV Movie"), Tmdb(53, "Thriller"), Tmdb(10752, "War"), Tmdb(37, "Western")];
    private static readonly BrowseGenre[] TvGenres = [Tmdb(10759, "Action & Adventure"), Tmdb(16, "Animation"), Tmdb(35, "Comedy"), Tmdb(80, "Crime"), Tmdb(99, "Documentary"), Tmdb(18, "Drama"), Tmdb(10751, "Family"), Tmdb(10762, "Kids"), Tmdb(9648, "Mystery"), Tmdb(10763, "News"), Tmdb(10764, "Reality"), Tmdb(10765, "Sci-Fi & Fantasy"), Tmdb(10766, "Soap"), Tmdb(10767, "Talk"), Tmdb(10768, "War & Politics"), Tmdb(37, "Western")];
    private static readonly BrowseGenre[] AnimeGenres = [Tmdb(10759, "Action & Adventure"), Tmdb(35, "Comedy"), Tmdb(18, "Drama"), Tmdb(10751, "Family"), Tmdb(10762, "Kids"), Tmdb(9648, "Mystery"), Tmdb(10765, "Sci-Fi & Fantasy"),
        Tag("isekai", "Isekai"), Tag("reincarnation", "Reincarnation"), Tag("slice of life", "Slice of Life"), Tag("romance", "Romance"), Tag("fantasy", "Fantasy"), Tag("supernatural", "Supernatural"), Tag("psychological", "Psychological"), Tag("mecha", "Mecha"), Tag("sports", "Sports"), Tag("school", "School"), Tag("historical", "Historical"), Tag("harem", "Harem"), Tag("magical girl", "Magical Girl"), Tag("music", "Music"), Tag("horror", "Horror"), Tag("samurai", "Samurai"), Tag("super power", "Super Power"), Tag("time travel", "Time Travel"), Tag("video game", "Video Game")];
    private static readonly (string Code, string Name)[] AllCountries = [("US", "United States"), ("JP", "Japan"), ("KR", "South Korea"), ("GB", "United Kingdom"), ("CA", "Canada"), ("FR", "France"), ("DE", "Germany"), ("CN", "China"), ("IN", "India"), ("ES", "Spain"), ("MX", "Mexico"), ("BR", "Brazil"), ("AU", "Australia"), ("TH", "Thailand")];
    private static readonly (string Code, string Name)[] AnimeCountries = [("JP", "Japan"), ("CN", "China"), ("KR", "South Korea"), ("TW", "Taiwan")];
    private static BrowseGenre Tmdb(int id, string name) => BrowseGenre.Tmdb(id, name);
    private static BrowseGenre Tag(string keyword, string name) => BrowseGenre.Tag(keyword, name);

    public static IReadOnlyList<BrowseGenre> Genres(string type) => type == "Movies" ? MovieGenres : type == "Anime" ? AnimeGenres : TvGenres;
    public static IReadOnlyList<(string Code, string Name)> Countries(string type) => type == "Anime" ? AnimeCountries : AllCountries;
    public static IReadOnlyList<int> Years => Enumerable.Range(1950, Math.Max(1, DateTime.Now.Year - 1949)).Reverse().ToArray();
    public static string TmdbType(string type) => type == "Movies" ? "movie" : "tv";
    public static BrowseFilterConfiguration Default(string type) => new() { SelectedCountryCodes = type == "Anime" ? ["JP"] : [] };

    public static BrowseFilterConfiguration Sanitized(BrowseFilterConfiguration? value, string type)
    {
        value ??= Default(type);
        var genres = Genres(type).Select(g => g.Key).ToHashSet(); var countries = Countries(type).Select(c => c.Code).ToHashSet(); var years = Years.ToHashSet();
        var selectedGenres = value.SelectedGenreKeys.Where(genres.Contains).Distinct().Order().ToList();
        var selectedYears = value.SelectedYears.Where(years.Contains).Distinct().Order().ToList();
        return new()
        {
            SelectedGenreKeys = selectedGenres,
            ExcludedGenreKeys = value.ExcludedGenreKeys.Where(g => genres.Contains(g) && !selectedGenres.Contains(g)).Distinct().Order().ToList(),
            SelectedYears = selectedYears,
            ExcludedYears = value.ExcludedYears.Where(y => years.Contains(y) && !selectedYears.Contains(y)).Distinct().Order().ToList(),
            SelectedCountryCodes = value.SelectedCountryCodes.Select(c => c.ToUpperInvariant()).Where(countries.Contains).Distinct().Order().ToList(),
            SortRawValue = Sorts.Any(s => s.Raw == value.SortRawValue) ? value.SortRawValue : "popularity.desc",
            MinimumRating = double.IsFinite(value.MinimumRating) ? Math.Clamp(value.MinimumRating, 0, 10) : 0,
            AgeRatingRawValue = AgeRatings.Any(a => a.Raw == value.AgeRatingRawValue) ? value.AgeRatingRawValue : "all"
        };
    }

    public static string TmdbSort(string sort, string type)
    {
        var tv = TmdbType(type) == "tv";
        return sort switch { "newest" => tv ? "first_air_date.desc" : "primary_release_date.desc", "oldest" => tv ? "first_air_date.asc" : "primary_release_date.asc", "vote_average.desc" => "vote_average.desc", "title.asc" => tv ? "name.asc" : "original_title.asc", _ => "popularity.desc" };
    }

    public static string Summary(IEnumerable<string> values, string empty)
    {
        var list = values.ToArray();
        return list.Length switch { 0 => empty, 1 => list[0], 2 => $"{list[0]}, {list[1]}", _ => $"{list[0]} +{list.Length - 1}" };
    }
}
