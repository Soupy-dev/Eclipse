using System.Globalization;
using System.Text.RegularExpressions;
using Eclipse.Windows.Models;

namespace Eclipse.Windows.Services;

public enum MaturityRating { General, Teen, Mature, Adult, Unknown }

public static partial class MaturityRatings
{
    private const int BatchSize = 6, CacheLimit = 4000;
    private static readonly Dictionary<string, MaturityRating> Cache = [];
    private static readonly Dictionary<string, Task<MaturityRating?>> Pending = [];
    private static readonly Dictionary<string, MaturityRating> Exact = new()
    {
        ["G"] = MaturityRating.General, ["TVY"] = MaturityRating.General, ["TVY7"] = MaturityRating.General, ["TVY7FV"] = MaturityRating.General, ["TVG"] = MaturityRating.General, ["PG"] = MaturityRating.General, ["TVPG"] = MaturityRating.General,
        ["PG13"] = MaturityRating.Teen, ["TV14"] = MaturityRating.Teen, ["R"] = MaturityRating.Mature, ["TVMA"] = MaturityRating.Mature,
        ["NC17"] = MaturityRating.Adult, ["X"] = MaturityRating.Adult, ["XXX"] = MaturityRating.Adult, ["AO"] = MaturityRating.Adult, ["ADULT"] = MaturityRating.Adult, ["ADULTONLY"] = MaturityRating.Adult, ["UNRATED"] = MaturityRating.Unknown, ["NR"] = MaturityRating.Unknown,
        ["U"] = MaturityRating.General, ["UC"] = MaturityRating.General, ["12"] = MaturityRating.Teen, ["12A"] = MaturityRating.Teen, ["15"] = MaturityRating.Mature, ["18"] = MaturityRating.Adult, ["R18"] = MaturityRating.Adult,
        ["E"] = MaturityRating.General, ["M"] = MaturityRating.Mature, ["MA15"] = MaturityRating.Mature, ["MA15PLUS"] = MaturityRating.Mature, ["R13"] = MaturityRating.Teen, ["R15"] = MaturityRating.Mature, ["R16"] = MaturityRating.Mature,
        ["R18PLUS"] = MaturityRating.Adult, ["X18PLUS"] = MaturityRating.Adult, ["RC"] = MaturityRating.Adult, ["PG12"] = MaturityRating.Teen, ["R15PLUS"] = MaturityRating.Mature, ["T"] = MaturityRating.Teen, ["TPLUS"] = MaturityRating.Mature, ["A"] = MaturityRating.General,
        ["R17"] = MaturityRating.Mature, ["RPLUS"] = MaturityRating.Mature, ["RX"] = MaturityRating.Adult, ["ALL"] = MaturityRating.General, ["19"] = MaturityRating.Adult, ["L"] = MaturityRating.General, ["10"] = MaturityRating.General, ["14"] = MaturityRating.Teen, ["16"] = MaturityRating.Mature,
        ["PG13SG"] = MaturityRating.Teen, ["NC16"] = MaturityRating.Mature, ["M18"] = MaturityRating.Adult, ["R21"] = MaturityRating.Adult, ["0"] = MaturityRating.General, ["6"] = MaturityRating.General, ["7"] = MaturityRating.General, ["9"] = MaturityRating.General, ["AL"] = MaturityRating.General, ["TP"] = MaturityRating.General
    };
    private static readonly Dictionary<string, Dictionary<string, MaturityRating>> Regional = new()
    {
        ["IN"] = new() { ["A"] = MaturityRating.Adult, ["S"] = MaturityRating.Adult, ["UA"] = MaturityRating.Teen },
        ["CA"] = new() { ["A"] = MaturityRating.Adult, ["R"] = MaturityRating.Adult }
    };
    private static readonly string[] ExplicitAnimeTerms = ["adult animation", "adult anime", "adult cartoon", "adult film", "adult video", "ecchi", "ero anime", "eroge", "erotica", "erotic", "erotic animation", "erotic anime", "explicit sex", "explicit sexual", "female nudity", "hentai", "mature anime", "mild nudity", "nudity", "ova hentai", "pornographic", "pornography", "r 18", "r18", "sex comedy", "sexual content", "sexually explicit", "softcore", "uncensored"];

    private static string Key(MediaTitle title) => $"{title.MediaType}:{title.TmdbId}";
    public static MaturityRating? Cached(MediaTitle title) => Cache.TryGetValue(Key(title), out var rating) ? rating : null;

    public static async Task ResolveAsync(IEnumerable<MediaTitle> titles, CancellationToken token)
    {
        var missing = titles.Where(t => t.TmdbId > 0).DistinctBy(Key).Where(t => !Cache.ContainsKey(Key(t))).ToArray();
        if (Cache.Count + missing.Length > CacheLimit) Cache.Clear();
        foreach (var chunk in missing.Chunk(BatchSize))
        {
            token.ThrowIfCancellationRequested();
            await Task.WhenAll(chunk.Select(Lookup)).WaitAsync(token);
        }
    }

    private static Task<MaturityRating?> Lookup(MediaTitle title)
    {
        var key = Key(title);
        if (!Pending.TryGetValue(key, out var task)) { task = FetchAsync(key, title); if (!task.IsCompleted) Pending[key] = task; }
        return task;
    }

    private static async Task<MaturityRating?> FetchAsync(string key, MediaTitle title)
    {
        try
        {
            var certifications = await TmdbService.Shared.CertificationsAsync(title, CancellationToken.None);
            var rating = Preferred(certifications);
            Cache[key] = rating;
            return rating;
        }
        catch (TmdbException) { return null; }
        finally { Pending.Remove(key); }
    }

    public static bool Includes(string ageRating, MaturityRating? rating, bool explicitContent)
    {
        if (ageRating == "all") return true;
        if (explicitContent) return rating is null or MaturityRating.Unknown or MaturityRating.Adult && ageRating == "adult";
        if (rating is null or MaturityRating.Unknown) return false;
        return ageRating switch { "general" => rating == MaturityRating.General, "teen" => rating <= MaturityRating.Teen, "mature" => rating <= MaturityRating.Mature, "adult" => rating == MaturityRating.Adult, _ => true };
    }

    public static bool HasExplicitAnimeMetadata(MediaTitle title)
    {
        var text = $" {Normalized(title.Title + " " + title.Synopsis)} ";
        return ExplicitAnimeTerms.Any(term => text.Contains($" {term} ", StringComparison.Ordinal));
    }

    private static string Normalized(string text) => string.Join(' ', NonAlphanumeric().Split(text.ToLowerInvariant()).Where(part => part.Length > 0));

    private static MaturityRating Preferred(IReadOnlyDictionary<string, List<string>> byRegion)
    {
        var candidates = byRegion.SelectMany(pair => pair.Value.Select(v => v.Trim()).Where(v => v.Length > 0).Select(value => (Value: value, Region: pair.Key, Rating: Classify(value, pair.Key))))
            .OrderBy(c => c.Rating == MaturityRating.Unknown ? 1 : 0).ThenByDescending(c => c.Rating == MaturityRating.Unknown ? 0 : (int)c.Rating).ThenBy(c => c.Region, StringComparer.Ordinal).ThenBy(c => c.Value, StringComparer.Ordinal).ToArray();
        var regions = new List<string>();
        try { regions.Add(RegionInfo.CurrentRegion.TwoLetterISORegionName.ToUpperInvariant()); } catch (ArgumentException) { }
        foreach (var fallback in new[] { "US", "GB" }) if (!regions.Contains(fallback)) regions.Add(fallback);
        foreach (var region in regions) foreach (var candidate in candidates) if (candidate.Region == region && candidate.Rating != MaturityRating.Unknown) return candidate.Rating;
        foreach (var candidate in candidates) if (candidate.Rating != MaturityRating.Unknown) return candidate.Rating;
        return MaturityRating.Unknown;
    }

    public static MaturityRating Classify(string certification, string? region = null)
    {
        var normalized = certification.Trim().ToUpperInvariant();
        if (normalized.Length == 0) return MaturityRating.Unknown;
        var compact = string.Concat(normalized.Replace("+", "PLUS").Where(char.IsLetterOrDigit));
        if (compact.Length == 0) return MaturityRating.Unknown;
        if (region is not null && Regional.TryGetValue(region.ToUpperInvariant(), out var regional) && regional.TryGetValue(compact, out var local)) return local;
        if (Exact.TryGetValue(compact, out var exact)) return exact;
        if (new[] { "18禁", "限制級", "成人", "청소년관람불가" }.Any(normalized.Contains)) return MaturityRating.Adult;
        if (new[] { "輔導級", "보호자" }.Any(normalized.Contains)) return MaturityRating.Mature;
        if (new[] { "普遍級", "전체관람가" }.Any(normalized.Contains)) return MaturityRating.General;
        if (new[] { "R18", "R21", "NC17", "X18", "AO", "RX" }.Any(p => compact.StartsWith(p, StringComparison.Ordinal))) return MaturityRating.Adult;
        if (new[] { "MA", "R15", "R16", "R17", "TVMA" }.Any(p => compact.StartsWith(p, StringComparison.Ordinal))) return MaturityRating.Mature;
        if (new[] { "TV14", "PG13", "R13" }.Any(p => compact.StartsWith(p, StringComparison.Ordinal))) return MaturityRating.Teen;
        if (new[] { "TVY", "TVG" }.Any(p => compact.StartsWith(p, StringComparison.Ordinal))) return MaturityRating.General;
        if (compact.StartsWith("PG", StringComparison.Ordinal)) return LeadingAge(compact[2..]) is { } pgAge ? Tier(pgAge) : MaturityRating.General;
        return LeadingAge(compact) is { } age ? Tier(age) : MaturityRating.Unknown;
    }

    private static int? LeadingAge(string compact)
    {
        var digits = new string(compact.TakeWhile(char.IsDigit).ToArray());
        return digits.Length is > 0 and <= 2 ? int.Parse(digits, CultureInfo.InvariantCulture) : null;
    }

    private static MaturityRating Tier(int age) => age switch { < 12 => MaturityRating.General, < 15 => MaturityRating.Teen, < 18 => MaturityRating.Mature, _ => MaturityRating.Adult };

    [GeneratedRegex("[^\\p{L}\\p{N}]+")]
    private static partial Regex NonAlphanumeric();
}
