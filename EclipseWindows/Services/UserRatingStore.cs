using System.Text.RegularExpressions;
using Eclipse.Windows.Models;
namespace Eclipse.Windows.Services;

public sealed class UserRatingStore
{
    public static UserRatingStore Shared { get; } = new();
    private readonly LocalJsonFile<RatingDocument> _file = new($"ratings-{LocalProfile.Id}.json", validate: d => d.Ratings is not null && d.Notes is not null && d.LegacyAttachments is not null && d.Ratings.Count <= 20000 && d.Notes.Count <= 20000 && d.Ratings.All(p => (Valid(p.Key) || int.TryParse(p.Key, out var id) && id is > 0 and <= 1000000000) && double.IsFinite(p.Value) && p.Value is >= .5 and <= 10) && d.Notes.All(p => p.Value is not null && p.Value.Length <= 65536 && (Valid(p.Key) || int.TryParse(p.Key, out var id) && id is > 0 and <= 1000000000)));
    public event EventHandler? Changed;
    public string? Error => _file.Error;
    public RatingDocument Snapshot => _file.Copy();
    public static string? TitleKey(MediaTitle title) => title.TmdbId > 0 ? $"{title.MediaType}:{title.TmdbId}" : null;
    public static string? ScopeKey(MediaTitle title, MediaSeason? season, bool whole)
    {
        if (title.TmdbId <= 0) return null; if (whole || title.MediaType == "movie") return TitleKey(title);
        if (season?.Cour is { } cour) { if (cour.HasIdentityConflict) return null; if (cour.Node.AniListId is > 0) return $"tv:{title.TmdbId}:anilist:{cour.Node.AniListId}"; if (cour.Node.MalId is > 0) return $"tv:{title.TmdbId}:mal:{cour.Node.MalId}"; return null; }
        return title.TmdbId > 0 && season is not null ? $"tv:{title.TmdbId}:season:{season.Number}" : null;
    }
    public double? Rating(string? key) => key is not null && _file.Value.Ratings.TryGetValue(key, out var value) ? value : null;
    public string Note(string? key) => key is not null ? _file.Value.Notes.GetValueOrDefault(key, "") : "";
    private static bool Valid(string key) => Regex.IsMatch(key, @"^(movie:[1-9]\d{0,9}|tv:[1-9]\d{0,9}(:season:\d{1,4}|:(anilist|mal):[1-9]\d{0,9})?)$") && key.Split(':').Where((_, i) => i % 2 == 1).All(s => int.TryParse(s, out var n) && n <= 1000000000);
    public void Save(string key, double? rating, string note)
    {
        if (!Valid(key)) throw new IOException("Rating identity is unresolved."); if (note.Length > 65536) throw new IOException("Notes are limited to 64 KiB.");
        var copy = _file.Copy(); if (rating is { } value) copy.Ratings[key] = Math.Clamp(Math.Round((double.IsFinite(value) ? value : .5) * 2, MidpointRounding.AwayFromZero) / 2, .5, 10); else copy.Ratings.Remove(key);
        if (string.IsNullOrWhiteSpace(note)) copy.Notes.Remove(key); else copy.Notes[key] = note;
        if (copy.Ratings.Count > 20000 || copy.Notes.Count > 20000) throw new IOException("Local rating limit reached."); _file.Save(copy); Changed?.Invoke(this, EventArgs.Empty);
    }
    public (double? Score, bool Average) HeroRating(MediaTitle title)
    {
        if (Rating(TitleKey(title)) is { } direct) return (direct, false); if (title.TmdbId <= 0 || title.MediaType != "tv") return (null, false);
        var prefix = $"tv:{title.TmdbId}:"; var values = _file.Value.Ratings.Where(p => p.Key.StartsWith(prefix, StringComparison.Ordinal) && Valid(p.Key)).Select(p => p.Value).ToArray(); return values.Length > 0 ? (values.Average(), true) : (null, false);
    }
    public void ReconcileMal(MediaTitle title, AnimeCour cour)
    {
        if (cour.HasIdentityConflict || cour.Node.AniListId is not > 0 || cour.Node.MalId is not > 0) return;
        var canonical = $"tv:{title.TmdbId}:anilist:{cour.Node.AniListId}"; var alias = $"tv:{title.TmdbId}:mal:{cour.Node.MalId}"; var copy = _file.Copy();
        if (!copy.Ratings.ContainsKey(alias) && !copy.Notes.ContainsKey(alias)) return;
        if (copy.Ratings.TryGetValue(alias, out var score)) copy.Ratings.TryAdd(canonical, score);
        if (copy.Notes.TryGetValue(alias, out var note)) copy.Notes.TryAdd(canonical, note);
        if (copy.Ratings.GetValueOrDefault(alias) == copy.Ratings.GetValueOrDefault(canonical) && copy.Notes.GetValueOrDefault(alias) == copy.Notes.GetValueOrDefault(canonical)) { copy.Ratings.Remove(alias); copy.Notes.Remove(alias); }
        _file.Save(copy); Changed?.Invoke(this, EventArgs.Empty);
    }
}
