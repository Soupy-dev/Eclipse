using System.Text.Json;
using Eclipse.Windows.Models;
using static Eclipse.Windows.Services.JsonValue;

namespace Eclipse.Windows.Services;

public interface INotificationMetadata
{
    Task<SeasonSnapshot> LoadAsync(NotificationSubscription follow, CancellationToken token, bool refresh);
}

// Apple's notification graph is deliberately smaller than Details' episode reconciliation graph.
// At most 32 ordinary nodes, batches of 12, and no episode inventory or artwork hydration.
public sealed class NotificationMetadataService : INotificationMetadata
{
    public async Task<SeasonSnapshot> LoadAsync(NotificationSubscription follow, CancellationToken token, bool refresh)
    {
        if (follow.Source == "Western") return await TmdbService.Shared.NotificationSeasonsAsync(follow.TmdbId, token, refresh);
        var seeds = follow.AnimeMediaIds.Where(id => id.StartsWith("anilist:", StringComparison.Ordinal)).Select(id => int.TryParse(id[8..], out var n) ? n : 0).Where(n => n > 0).Distinct().Take(32).ToArray();
        if (seeds.Length == 0) throw new ProviderException("Future anime metadata requires AniList.");
        IReadOnlyList<AnimeMapping> mappings = [];
        var complete = follow.AnimeMediaIds.Count(id=>id.StartsWith("anilist:",StringComparison.Ordinal))<=32;
        if (follow.TmdbId > 0)
            try { mappings = await AnimeMetadataService.Shared.MappingsAsync("tmdb_show", follow.TmdbId, token, refresh); }
            catch (ProviderException) { complete = false; }
        var pending = new Queue<int>(seeds); var queued = seeds.ToHashSet(); var visited = new HashSet<int>();
        var result = new Dictionary<int, SeasonPremiere>(); var malIds = new Dictionary<int, int>();var hydrated=new HashSet<int>();
        bool? Role(JsonElement node, string relation = "")
        {
            if (Bool(node, "isAdult") || Text(node, "type") != "ANIME") return null;
            var title = Name(node).ToLowerInvariant();
            if (new[] { "recap", "summary", "music", "trailer", " pv", " cm" }.Any(title.Contains)) return null;
            var rows = mappings.Where(m => m.AniListId == Int(node, "id")).ToArray();
            var format = Text(node, "format");
            bool Regular(AnimeMapping m)
            {var type=m.Format.Length>0?m.Format:format;return type is "TV" or "TV_SHORT"||type=="ONA"&&(m.TmdbSeason is >0||m.TvdbSeason is >0)||type is "SPECIAL" or "OVA" or "OAD" or "MOVIE"&&m.TmdbSeason is >0;}
            if (rows.Any(Regular)) return false;
            if (rows.Any(m=>!Regular(m)&&(m.Format.Length>0?m.Format:format) is "SPECIAL" or "OVA" or "OAD" or "ONA" or "MOVIE" or "MUSIC")) return true;
            bool? special = format is "TV" or "TV_SHORT" or "ONA" ? false : format is "SPECIAL" or "OVA" or "OAD" or "MOVIE" ? true : null;
            if (rows.Length == 0 && relation is "SIDE_STORY" or "SPIN_OFF" or "OTHER" or "SUMMARY" or "ALTERNATIVE_VERSION") special = true;
            return special;
        }
        void Observe(JsonElement node, bool special,bool full=false)
        {
            var id = Int(node, "id"); if (id <= 0 || result.Count >= 256 && !result.ContainsKey(id)) { complete = false; return; }
            if(!full&&hydrated.Contains(id))return;if(full)hydrated.Add(id);
            var date = Child(node, "startDate"); var y = Int(date, "year"); var m = Int(date, "month"); var d = Int(date, "day");
            var raw = $"{y:D4}-{m:D2}-{d:D2}"; var validDate = AnimeReconciliation.Day(raw) is not null ? raw : "";
            var title = Name(node); if (title.Length == 0) { complete = false; return; }
            result[id] = new($"anilist:{id}", title, title, "AniList", id, null, validDate, Text(node, "status") == "NOT_YET_RELEASED", special);
            if (Positive(node, "idMal") is { } mal) malIds[id] = mal;
        }
        while (pending.Count > 0 && visited.Count < 32)
        {
            token.ThrowIfCancellationRequested(); var batch = new List<int>();
            while (pending.Count > 0 && batch.Count < 12 && visited.Count < 32) { var id = pending.Dequeue(); if (visited.Add(id)) batch.Add(id); }
            const string fields = "id idMal type isAdult format status title{english romaji} startDate{year month day}";
            var query = "query($ids:[Int]){Page(perPage:12){media(id_in:$ids,type:ANIME){" + fields + " relations{edges{relationType node{" + fields + "}}}}}}";
            JsonElement data;
            try { data = await AnimeMetadataService.Shared.GraphAsync(query, new { ids = batch }, token, refresh); }
            catch (ProviderException) { complete = false; continue; }
            var nodes = Array(Child(data, "Page"), "media").ToArray();
            if (nodes.Length != batch.Count || !nodes.Select(n=>Int(n,"id")).ToHashSet().SetEquals(batch)) complete = false;
            foreach (var node in nodes.Where(n => batch.Contains(Int(n, "id"))))
            {
                if (Role(node) is { } role) Observe(node, role,true);
                var edges = Child(Child(node, "relations"), "edges");
                if (edges.ValueKind != JsonValueKind.Array) { complete = false; continue; }
                foreach (var edge in Items(edges))
                {
                    var child = Child(edge, "node"); var relation = Text(edge, "relationType");
                    if (Role(child, relation) is not { } special) continue;
                    var ordinary = relation is "SEQUEL" or "PREQUEL" or "SEASON" && !special;
                    if (!ordinary && !special) continue;
                    Observe(child, special); var id = Int(child, "id");
                    if (ordinary && id > 0 && !queued.Contains(id)) { if (queued.Count < 32) { pending.Enqueue(id); queued.Add(id); } else complete = false; }
                }
            }
        }
        complete &= pending.Count == 0;
        string[] Ids(bool special) => result.Where(p => p.Value.Special == special).SelectMany(p => malIds.TryGetValue(p.Key, out var mal) ? new[] { p.Value.Id, $"mal:{mal}" } : new[] { p.Value.Id }).ToArray();
        return new(result.Values.ToArray(), complete, Ids(false), Ids(true));
    }
    private static string Name(JsonElement node) { var title = Child(node, "title"); var english = Text(title, "english"); return english.Length > 0 ? english : Text(title, "romaji"); }
}
