using System.Text.Json;
using Eclipse.Windows.Models;
using static Eclipse.Windows.Services.JsonValue;
namespace Eclipse.Windows.Services;

public sealed class TrackerLibraryService
{
    public static TrackerLibraryService Shared { get; } = new();
    private readonly SemaphoreSlim _write = new(1, 1);
    private readonly Dictionary<string, (TrackerLibraryResult Result, DateTimeOffset Time)> _cache = [];
    private readonly object _cacheLock = new(); private readonly Dictionary<string, long> _revisions = [];
    private static string Authority(TrackerSession s) => $"{s.Service}:{s.UserId}:{s.Generation}:";
    private long Revision(TrackerSession s) { lock (_cacheLock) return _revisions.GetValueOrDefault(Authority(s)); }
    private void Invalidate(TrackerSession s) { lock (_cacheLock) { var prefix = Authority(s); _revisions[prefix] = _revisions.GetValueOrDefault(prefix) + 1; foreach (var key in _cache.Keys.Where(k => k.StartsWith(prefix, StringComparison.Ordinal)).ToArray()) _cache.Remove(key); } }
    private static long Bytes(TrackerLibraryResult r) => r.Entries.Sum(Size);
    private static long Size(TrackerEntry e) => 512L + 2L * (e.Title.Title.Length + (e.Title.PosterPath?.Length ?? 0) + e.Genres.Sum(s => s.Length) + e.CustomLists.Sum(s => s.Length));
    private static void CheckSize(List<TrackerEntry> rows) { if (rows.Sum(Size) > 16 * 1024 * 1024) throw new TrackerException("This library exceeds the supported metadata memory limit. Use the tracker's website to narrow it."); }
    private static TrackerLibraryResult Copy(TrackerLibraryResult value) => value with { Entries = value.Entries.Select(e => e with { Title = e.Title with { } }).ToArray() };
    private const string AnimeFields = "id idMal type title { english romaji } coverImage { large } format genres episodes mediaListEntry { id mediaId status progress score(format: POINT_100) customLists }";
    private static MediaTitle AniTitle(JsonElement media) => new() { TmdbId = 0, MediaType = Text(media, "format") == "MOVIE" ? "movie" : "tv", Title = Text(Child(media, "title"), "english") is { Length: > 0 } en ? en : Text(Child(media, "title"), "romaji"), Provider = "AniList", ProviderId = Int(media, "id"), AniListId = Positive(media, "id"), MalId = Positive(media, "idMal"), Format = Text(media, "format"), PosterPath = Text(Child(media, "coverImage"), "large") };
    private static TrackerEntry AniEntry(JsonElement entry)
    {
        var media = Child(entry, "media"); var custom = Child(entry, "customLists");
        if (Positive(media, "id") is null || Text(media, "type") is { Length: > 0 } type && type != "ANIME" || Positive(entry, "mediaId") is { } mediaId && mediaId != Int(media, "id") || Text(entry, "status") is not ("CURRENT" or "PLANNING" or "COMPLETED" or "DROPPED" or "PAUSED" or "REPEATING") || Child(entry, "progress").ValueKind != JsonValueKind.Number || Int(entry, "progress") < 0 || Child(entry, "score").ValueKind != JsonValueKind.Number || Double(entry, "score") is < 0 or > 100) throw new TrackerException("AniList returned an invalid library entry. Refresh before editing it.");
        return new(TrackerKind.AniList, Int(media, "id"), Int(entry, "id"), AniTitle(media), Text(entry, "status"), Int(entry, "progress"), Double(entry, "score") / 10, Array(media, "genres").Select(x => x.GetString() ?? "").ToArray(), custom.ValueKind == JsonValueKind.Object ? custom.EnumerateObject().Where(p => p.Value.ValueKind == JsonValueKind.True).Select(p => p.Name).ToArray() : []) { EpisodeCount = Positive(media, "episodes"), CustomListsKnown = custom.ValueKind == JsonValueKind.Object };
    }
    private static TrackerEntry MalEntry(JsonElement wrapper)
    {
        var node = Child(wrapper, "node"); var status = Child(wrapper, "list_status"); if (Positive(node, "id") is null || Text(node, "title").Length == 0 || Text(status, "status") is not ("watching" or "completed" or "on_hold" or "dropped" or "plan_to_watch") || Child(status, "num_episodes_watched").ValueKind != JsonValueKind.Number || Int(status, "num_episodes_watched") < 0 || Child(status, "score").ValueKind != JsonValueKind.Number || Double(status, "score") is < 0 or > 10) throw new TrackerException("MAL returned an invalid library entry. Refresh before editing it."); return new(TrackerKind.MAL, Int(node, "id"), 0, new() { TmdbId = 0, MediaType = Text(node, "media_type") == "movie" ? "movie" : "tv", Title = Text(node, "title"), Provider = "MAL", ProviderId = Int(node, "id"), MalId = Positive(node, "id"), PosterPath = Text(Child(node, "main_picture"), "medium") }, Bool(status, "is_rewatching") ? "rewatching" : Text(status, "status"), Int(status, "num_episodes_watched"), Double(status, "score"), Array(node, "genres").Select(g => Text(g, "name")).ToArray(), []) { EpisodeCount = Positive(node, "num_episodes") };
    }
    private static TrackerEntry TraktEntry(JsonElement wrapper, string kind, string status)
    {
        var node = Child(wrapper, kind); var ids = Child(node, "ids"); var type = kind == "movie" ? "movie" : "tv"; if (Positive(ids, "trakt") is null || Text(node, "title").Length == 0) throw new TrackerException("Trakt returned an invalid title identity."); return new(TrackerKind.Trakt, Int(ids, "trakt"), 0, new() { TmdbId = Int(ids, "tmdb"), MediaType = type, Title = Text(node, "title"), ReleaseDate = Int(node, "year").ToString() }, status, 0, Double(wrapper, "rating"), Array(node, "genres").Where(g => g.ValueKind == JsonValueKind.String).Select(g => g.GetString()!).ToArray(), []);
    }
    public async Task<TrackerLibraryResult> LoadAsync(TrackerSession session, string source, string kind, CancellationToken ct, bool refresh = false)
    {
        var accounts = TrackerAccounts.Shared; accounts.AssertCurrent(session); var cacheKey = $"{session.Service}:{session.UserId}:{session.Generation}:{source}:{kind}";
        var revision = Revision(session); lock (_cacheLock) if (!refresh && _cache.TryGetValue(cacheKey, out var cached) && DateTimeOffset.UtcNow - cached.Time < TimeSpan.FromSeconds(120)) return Copy(cached.Result);
        var rows = new List<TrackerEntry>(); var lists = new List<TrackerList>(); bool complete = true;
        if (session.Service == TrackerKind.AniList)
        {
            for (var chunk = 1; chunk <= 100; chunk++)
            {
                var response = (await accounts.RequestAsync(session, "", HttpMethod.Post, ct, new { query = $"query($user:Int!,$chunk:Int!) {{ MediaListCollection(userId:$user,type:ANIME,chunk:$chunk,perChunk:100,forceSingleCompletedList:true) {{ hasNextChunk lists {{ name isCustomList entries {{ id mediaId status progress score(format:POINT_100) customLists media {{ {AnimeFields} }} }} }} }} User(id:$user) {{ mediaListOptions {{ animeList {{ customLists }} }} }} }}", variables = new { user = int.Parse(session.UserId), chunk } })).Data;
                if (Child(response, "errors").ValueKind == JsonValueKind.Array) throw new TrackerException("AniList could not load this library."); var data = Child(response, "data");
                lists = Array(Child(Child(Child(data, "User"), "mediaListOptions"), "animeList"), "customLists").Select(n => new TrackerList(n.GetString() ?? "", n.GetString() ?? "")).ToList();
                var collection = Child(data, "MediaListCollection"); if (collection.ValueKind != JsonValueKind.Object || Child(collection, "hasNextChunk").ValueKind is not (JsonValueKind.True or JsonValueKind.False)) throw new TrackerException("AniList did not return a complete library response.");
                rows.AddRange(Array(collection, "lists").SelectMany(l => Array(l, "entries")).Select(AniEntry));
                CheckSize(rows);
                if (!Bool(collection, "hasNextChunk")) break; if (chunk == 100 || rows.Count >= 10000) { complete = false; break; }
            }
        }
        else if (session.Service == TrackerKind.MAL)
        {
            var path = "v2/users/@me/animelist?limit=100&sort=list_updated_at&nsfw=true&fields=list_status,media_type,genres,num_episodes"; var seen = new HashSet<string>();
            for (var page = 0; page < 100; page++)
            {
                if (!seen.Add(path)) throw new TrackerException("MAL returned a repeated library page."); var data = (await accounts.RequestAsync(session, path, HttpMethod.Get, ct)).Data;
                if (Child(data, "data").ValueKind != JsonValueKind.Array || Child(data, "data").GetArrayLength() > 100) throw new TrackerException("MAL did not return a valid bounded library page."); rows.AddRange(Array(data, "data").Select(MalEntry));
                CheckSize(rows);
                var next = Text(Child(data, "paging"), "next"); if (next.Length == 0) break;
                if (!Uri.TryCreate(next, UriKind.Absolute, out var uri) || uri.Scheme != "https" || uri.Host != "api.myanimelist.net" || uri.AbsolutePath != "/v2/users/@me/animelist" || uri.UserInfo.Length > 0 || !uri.IsDefaultPort) throw new TrackerException("MAL returned an invalid next page."); path = uri.PathAndQuery.TrimStart('/'); if (page == 99) { complete = false; break; }
            }
        }
        else
        {
            for (var listPage = 1; listPage <= 10; listPage++) { var listResponse = await accounts.RequestAsync(session, $"users/me/lists?page={listPage}&limit=100", HttpMethod.Get, ct); if (listResponse.Data.ValueKind != JsonValueKind.Array) throw new TrackerException("Trakt did not return valid custom lists."); lists.AddRange(Items(listResponse.Data).Select(l => new TrackerList(Int(Child(l, "ids"), "trakt").ToString(), Text(l, "name"))).Where(l => l.Id != "0")); if (lists.Count > 200) throw new TrackerException("This account exceeds the supported custom-list limit (200)."); if (listResponse.Pages is not { } lp || listPage >= lp) break; if (listPage == 10) throw new TrackerException("Trakt custom-list pagination exceeds the limit."); }
            var media = kind == "movie" ? "movies" : "shows"; var singular = kind == "movie" ? "movie" : "show";
            var basePath = source.StartsWith("list:") ? $"users/me/lists/{Uri.EscapeDataString(source[5..])}/items/{singular}" : source switch { "history" => $"sync/watched/{media}", "collection" => $"sync/collection/{media}", "ratings" => $"sync/ratings/{media}", _ => $"sync/watchlist/{media}/added/desc" };
            for (var page = 1; page <= 100; page++)
            {
                var response = await accounts.RequestAsync(session, $"{basePath}?page={page}&limit=100&extended=full", HttpMethod.Get, ct); if (response.Data.ValueKind != JsonValueKind.Array) throw new TrackerException("Trakt did not return a valid library page.");
                var entries = Items(response.Data).ToArray(); rows.AddRange(entries.Select(e => TraktEntry(e, singular, source)));
                CheckSize(rows);
                if (rows.Count > 10000) { rows = rows.Take(10000).ToList(); complete = false; break; }
                if (response.Pages is { } pages) { if (page >= pages) break; }
                else { if (entries.Length >= 100 && source != "collection") complete = false; break; }
                if (page == 100) complete = false;
            }
        }
        if (rows.Count > 10000) complete = false;
        foreach (var versions in rows.GroupBy(r => (r.RemoteId, r.Title.MediaType))) if (versions.Select(v => (v.Status, v.Progress, v.Score, v.ListEntryId, string.Join('|', v.CustomLists.Order()))).Distinct().Count() > 1) throw new TrackerException("The tracker returned conflicting versions of a title. Refresh the library.");
        accounts.AssertCurrent(session); var result = new TrackerLibraryResult(rows.Where(r => r.RemoteId > 0).DistinctBy(r => (r.RemoteId, r.Title.MediaType)).Take(10000).ToArray(), lists, complete, complete ? "" : "This library is partial. Refresh before making membership changes.");
        lock (_cacheLock) { if (Revision(session) != revision) throw new TrackerException("The library changed while loading. Refresh to show its current state."); while (_cache.Count >= 4 || _cache.Values.Sum(v => v.Result.Entries.Count) + result.Entries.Count > 20000 || _cache.Values.Sum(v => Bytes(v.Result)) + Bytes(result) > 16 * 1024 * 1024) { if (_cache.Count == 0) break; _cache.Remove(_cache.MinBy(p => p.Value.Time).Key); } _cache[cacheKey] = (Copy(result), DateTimeOffset.UtcNow); }
        return result;
    }
    private async Task<TrackerEntry?> ReadAnimeAsync(TrackerSession session, int id, CancellationToken ct)
    {
        if (session.Service == TrackerKind.AniList)
        {
            var data = (await TrackerAccounts.Shared.RequestAsync(session, "", HttpMethod.Post, ct, new { query = $"query($id:Int!) {{ Media(id:$id,type:ANIME) {{ {AnimeFields} }} }}", variables = new { id } })).Data;
            var media = Child(Child(data, "data"), "Media"); if (Int(media, "id") != id) throw new TrackerException("AniList returned a different title."); var entry = Child(media, "mediaListEntry"); if (entry.ValueKind == JsonValueKind.Null) return null; if (entry.ValueKind != JsonValueKind.Object || Positive(entry, "id") is null) throw new TrackerException("AniList did not confirm library membership. No change was sent.");
            // Reuse the exact parser with the media attached.
            var map = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(entry.GetRawText()) ?? []; map["media"] = media; return AniEntry(JsonSerializer.SerializeToElement(map));
        }
        var result = (await TrackerAccounts.Shared.RequestAsync(session, $"v2/anime/{id}?fields=my_list_status,genres,media_type,num_episodes", HttpMethod.Get, ct)).Data; if (Int(result, "id") != id || Text(result, "media_type") is not ("tv" or "movie" or "ova" or "ona" or "special" or "music" or "tv_special")) throw new TrackerException("MAL returned an invalid title identity or media kind."); var status = Child(result, "my_list_status"); if (status.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null) return null; if (status.ValueKind != JsonValueKind.Object) throw new TrackerException("MAL returned invalid library membership.");
        return MalEntry(JsonSerializer.SerializeToElement(new { node = result, list_status = status }));
    }
    public Task<TrackerEntry?> EntryAsync(TrackerSession session, int id, CancellationToken ct) => ReadAnimeAsync(session, id, ct);
    public async Task SetAniListListsAsync(TrackerSession session, TrackerEntry original, IReadOnlySet<string> lists, CancellationToken ct)
    {
        if (session.Service != TrackerKind.AniList || original.Service != session.Service) throw new TrackerException("This is not an AniList entry."); await _write.WaitAsync(ct); try { Invalidate(session); var current = await ReadAnimeAsync(session, original.RemoteId, ct); if (current is null || !current.CustomListsKnown || !original.CustomListsKnown || !current.CustomLists.Order().SequenceEqual(original.CustomLists.Order())) throw new TrackerException("Custom-list membership is incomplete or changed remotely. Refresh before editing."); var result = (await TrackerAccounts.Shared.RequestAsync(session, "", HttpMethod.Post, ct, new { query = "mutation($id:Int!,$lists:[String]) { SaveMediaListEntry(id:$id,customLists:$lists) { mediaId } }", variables = new { id = current.ListEntryId, lists = lists.ToArray() } })).Data; if (Int(Child(Child(result, "data"), "SaveMediaListEntry"), "mediaId") != original.RemoteId) throw new TrackerException("AniList did not confirm list membership. Refresh before retrying."); } finally { Invalidate(session); _write.Release(); }
    }
    public async Task AddAnimeAsync(TrackerSession session, int id, CancellationToken ct)
    {
        await _write.WaitAsync(ct); try
        {
            Invalidate(session);
            var existing = await ReadAnimeAsync(session, id, ct); if (existing is not null) return;
            if (session.Service == TrackerKind.AniList) { var data = (await TrackerAccounts.Shared.RequestAsync(session, "", HttpMethod.Post, ct, new { query = "mutation($id:Int!) { SaveMediaListEntry(mediaId:$id,status:PLANNING) { mediaId } }", variables = new { id } })).Data; if (Int(Child(Child(data, "data"), "SaveMediaListEntry"), "mediaId") != id) throw new TrackerException("AniList did not confirm the addition. Refresh to check its state."); }
            else { var saved = (await TrackerAccounts.Shared.RequestAsync(session, $"v2/anime/{id}/my_list_status", HttpMethod.Patch, ct, form: new Dictionary<string, string> { { "status", "plan_to_watch" } })).Data; if (Text(saved, "status") != "plan_to_watch" || await ReadAnimeAsync(session, id, ct) is null) throw new TrackerException("MAL did not confirm the addition. Refresh to check the entry before retrying."); }
        }
        finally { Invalidate(session); _write.Release(); }
    }
    public async Task SetAniListMembershipAsync(TrackerSession session, TrackerEntry original, string list, bool member, CancellationToken ct)
    {
        if (session.Service != TrackerKind.AniList || original.Service != TrackerKind.AniList) throw new TrackerException("This is not an AniList entry."); await _write.WaitAsync(ct); try
        {
            Invalidate(session);
            var current = await ReadAnimeAsync(session, original.RemoteId, ct); if (current is null || !current.CustomListsKnown || !original.CustomListsKnown || !current.CustomLists.Order().SequenceEqual(original.CustomLists.Order())) throw new TrackerException("The list memberships are incomplete or changed remotely. Refresh before editing.");
            var memberships = current.CustomLists.ToHashSet(); if (member) memberships.Add(list); else memberships.Remove(list);
            var result = (await TrackerAccounts.Shared.RequestAsync(session, "", HttpMethod.Post, ct, new { query = "mutation($id:Int!,$lists:[String]) { SaveMediaListEntry(id:$id,customLists:$lists) { mediaId } }", variables = new { id = current.ListEntryId, lists = memberships.ToArray() } })).Data; if (Int(Child(Child(result, "data"), "SaveMediaListEntry"), "mediaId") != original.RemoteId) throw new TrackerException("AniList did not confirm the memberships. Refresh to check them.");
        }
        finally { Invalidate(session); _write.Release(); }
    }
    public async Task EditAnimeAsync(TrackerSession session, TrackerEntry original, TrackerEdit edit, CancellationToken ct)
    {
        if (session.Service == TrackerKind.Trakt || original.Service != session.Service) throw new TrackerException("The tracker entry belongs to a different service."); await _write.WaitAsync(ct);
        try
        {
            Invalidate(session);
            var current = await ReadAnimeAsync(session, original.RemoteId, ct); TrackerAccounts.Shared.AssertCurrent(session);
            if (current is null || edit.Status is not null && current.Status != original.Status || edit.Progress is not null && current.Progress != original.Progress || edit.Score is not null && current.Score != original.Score) throw new TrackerException("This entry changed on the tracker. Refresh before editing it.");
            if (edit.Progress is < 0 or > 100000 || edit.Score is < 0 or > 10) throw new TrackerException("Progress or score is outside the allowed range.");
            if (edit.Progress is { } progress && current.EpisodeCount is { } count && progress > count) throw new TrackerException("Progress exceeds the known episode count.");
            if (edit.Score is { } score && !double.IsFinite(score)) throw new TrackerException("Enter a finite score.");
            if (edit.Status is { } status && (session.Service == TrackerKind.AniList ? status is not ("CURRENT" or "PLANNING" or "COMPLETED" or "DROPPED" or "PAUSED" or "REPEATING") : status is not ("watching" or "plan_to_watch" or "completed" or "dropped" or "on_hold" or "rewatching"))) throw new TrackerException("Choose a valid tracker status.");
            if (session.Service == TrackerKind.MAL && edit.Score is { } malScore && malScore != Math.Truncate(malScore)) throw new TrackerException("MAL uses whole-number scores.");
            if (session.Service == TrackerKind.AniList)
            {
                var variables = new Dictionary<string, object> { { "id", current.ListEntryId } }; var declarations = "$id:Int!"; var args = "id:$id";
                if (edit.Status is not null) { variables["status"] = edit.Status; declarations += ",$status:MediaListStatus"; args += ",status:$status"; }
                if (edit.Progress is not null) { variables["progress"] = edit.Progress; declarations += ",$progress:Int"; args += ",progress:$progress"; }
                if (edit.Score is not null) { variables["score"] = Math.Round(edit.Score.Value * 10); declarations += ",$score:Int"; args += ",scoreRaw:$score"; }
                var data = (await TrackerAccounts.Shared.RequestAsync(session, "", HttpMethod.Post, ct, new { query = $"mutation({declarations}) {{ SaveMediaListEntry({args}) {{ id mediaId }} }}", variables })).Data; var saved = Child(Child(data, "data"), "SaveMediaListEntry"); if (Int(saved, "mediaId") != original.RemoteId) throw new TrackerException("AniList did not confirm the update. Refresh to check its current state.");
            }
            else
            {
                var form = new Dictionary<string, string>(); if (edit.Status is not null) { form["status"] = edit.Status == "rewatching" ? "watching" : edit.Status; form["is_rewatching"] = (edit.Status == "rewatching").ToString().ToLowerInvariant(); }
                if (edit.Progress is not null) form["num_watched_episodes"] = edit.Progress.ToString()!; if (edit.Score is not null) form["score"] = Math.Round(edit.Score.Value).ToString();
                var saved = (await TrackerAccounts.Shared.RequestAsync(session, $"v2/anime/{original.RemoteId}/my_list_status", HttpMethod.Patch, ct, form: form)).Data;
                if (form.Any(p => p.Key switch { "num_watched_episodes" => Child(saved, "num_episodes_watched").ValueKind != JsonValueKind.Number || Int(saved, "num_episodes_watched").ToString() != p.Value, "score" => Child(saved, "score").ValueKind != JsonValueKind.Number || Int(saved, "score").ToString() != p.Value, "status" => Text(saved, "status") != p.Value, "is_rewatching" => Child(saved, "is_rewatching").ValueKind is not (JsonValueKind.True or JsonValueKind.False) || Bool(saved, "is_rewatching").ToString().ToLowerInvariant() != p.Value, _ => true })) throw new TrackerException("MAL did not confirm the requested fields. Refresh to check the current entry.");
            }
        }
        finally { Invalidate(session); _write.Release(); }
    }
    public async Task RemoveAnimeAsync(TrackerSession session, TrackerEntry original, CancellationToken ct)
    {
        if (session.Service != original.Service || session.Service == TrackerKind.Trakt) throw new TrackerException("The tracker entry belongs to a different service."); await _write.WaitAsync(ct); try
        {
            Invalidate(session);
            var current = await ReadAnimeAsync(session, original.RemoteId, ct); if (current is null) return; if (current.Status != original.Status || current.Progress != original.Progress || current.Score != original.Score) throw new TrackerException("This entry changed remotely. Refresh before removing it.");
            if (session.Service == TrackerKind.AniList) { var data = (await TrackerAccounts.Shared.RequestAsync(session, "", HttpMethod.Post, ct, new { query = "mutation($id:Int!) { DeleteMediaListEntry(id:$id) { deleted } }", variables = new { id = current.ListEntryId } })).Data; if (!Bool(Child(Child(data, "data"), "DeleteMediaListEntry"), "deleted")) throw new TrackerException("AniList did not confirm removal. Refresh to check the entry."); }
            else await TrackerAccounts.Shared.RequestAsync(session, $"v2/anime/{original.RemoteId}/my_list_status", HttpMethod.Delete, ct);
        }
        finally { Invalidate(session); _write.Release(); }
    }
    public async Task SetTraktAsync(TrackerSession session, TrackerEntry entry, string action, bool add, double? score, CancellationToken ct, bool? expectedMember = null, double? expectedScore = null)
    {
        if (session.Service != TrackerKind.Trakt || entry.Service != TrackerKind.Trakt || entry.RemoteId <= 0) throw new TrackerException("This is not a verified Trakt title.");
        if (score is { } rating && (!double.IsFinite(rating) || rating is < 1 or > 10)) throw new TrackerException("Trakt ratings must be between 1 and 10.");
        var allowed = action is "watchlist" or "collection" or "history" or "ratings" || action.StartsWith("list:"); if (!allowed) throw new TrackerException("Unknown Trakt action.");
        await _write.WaitAsync(ct); try
        {
            Invalidate(session);
            if (expectedMember is not null || expectedScore is not null) { var snapshot = await LoadAsync(session, action, entry.Title.MediaType, ct, true); if (!snapshot.Complete) throw new TrackerException("Trakt returned a partial list. The change was not sent."); var remote = snapshot.Entries.FirstOrDefault(e => e.RemoteId == entry.RemoteId); if (expectedMember is { } membership && (remote is not null) != membership || expectedScore is { } prior && (remote?.Score ?? 0) != prior) throw new TrackerException("This entry changed remotely. Refresh before editing it."); }
            var item = new Dictionary<string, object> { { "ids", new { trakt = entry.RemoteId } } }; if (score is not null) item["rating"] = Math.Clamp((int)Math.Round(score.Value), 1, 10);
            var body = new Dictionary<string, object> { { entry.Title.MediaType == "movie" ? "movies" : "shows", new[] { item } } };
            var path = action.StartsWith("list:") ? $"users/me/lists/{Uri.EscapeDataString(action[5..])}/items" : $"sync/{action}"; if (!add) path += "/remove";
            var result = (await TrackerAccounts.Shared.RequestAsync(session, path, HttpMethod.Post, ct, body, retryUnauthorized: action != "history")).Data;
            var missing = Child(result, "not_found"); if (missing.ValueKind == JsonValueKind.Object && missing.EnumerateObject().Any(p => p.Value.ValueKind == JsonValueKind.Array && p.Value.GetArrayLength() > 0)) throw new TrackerException("Trakt could not find the requested title. Refresh before trying again.");
            var confirmations = new[] { "added", "deleted", "updated", "existing" }.Select(name => Child(result, name)).Where(e => e.ValueKind == JsonValueKind.Object).ToArray();
            if (!confirmations.Any(e => e.EnumerateObject().Any()) || confirmations.Any(e => e.EnumerateObject().Any(p => p.Name is not ("movies" or "shows" or "seasons" or "episodes" or "people") || p.Value.ValueKind != JsonValueKind.Number || !p.Value.TryGetInt32(out var count) || count is < 0 or > 1000000))) throw new TrackerException("Trakt did not confirm the change. Refresh to check the current entry before retrying.");
        }
        finally { Invalidate(session); _write.Release(); }
    }
}
