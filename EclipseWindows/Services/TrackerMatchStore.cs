using Eclipse.Windows.Models;
namespace Eclipse.Windows.Services;

public sealed class TrackerMatchStore
{
    public static TrackerMatchStore Shared { get; } = new();
    private readonly LocalJsonFile<Dictionary<string, string>> _file = new("tracker-library-matches.json", 1024 * 1024);
    private static string Key(TrackerSession s, TrackerEntry e) => $"{s.Service}:{s.UserId}:{e.Title.MediaType}:{e.RemoteId}";
    public string? Get(TrackerSession s, TrackerEntry e) => _file.Value.GetValueOrDefault(Key(s, e));
    public void Set(TrackerSession s, TrackerEntry e, string? target) { TrackerAccounts.Shared.AssertCurrent(s); if (target is not null && (!MediaTitle.TryParseId(target, out var type, out _) || type != e.Title.MediaType)) throw new IOException("Choose a TMDB title of the same media kind."); var copy = _file.Copy(); if (target is null) copy.Remove(Key(s, e)); else copy[Key(s, e)] = target; if (copy.Count > 10000) throw new IOException("Match override limit reached."); _file.Save(copy); }
    public async Task<MediaTitle> ResolveAsync(TrackerSession s, TrackerEntry e, CancellationToken ct)
    {
        TrackerAccounts.Shared.AssertCurrent(s); var target = Get(s, e); var title = target is not null ? await TmdbService.Shared.DetailsAsync(target, ct) : await AnimeMetadataService.Shared.DetailsAsync(e.Title.Id, ct, knownMalId: e.Title.MalId); TrackerAccounts.Shared.AssertCurrent(s); return title;
    }
}
