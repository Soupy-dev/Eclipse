using System.Text;
using System.Text.Json;
using Eclipse.Windows.Models;

namespace Eclipse.Windows.Services;

public interface IReminderStore
{
    ReminderState Read();
    void Write(ReminderState state);
    void Reset(ReminderState state)=>Write(state);
}

public sealed class LocalReminderStore(string path) : IReminderStore
{
    private const int Limit = 8 * 1024 * 1024;
    public ReminderState Read()
    {
        if (!File.Exists(path)) return new();
        if (new FileInfo(path).Length > Limit) throw new IOException("The notification file exceeds its size limit.");
        var state = JsonSerializer.Deserialize<ReminderState>(File.ReadAllText(path), PreferenceStore.JsonOptions) ?? throw new JsonException();
        Validate(state);
        return state;
    }
    internal static bool ValidToken(string? token) => token?.Length == 32 && Guid.TryParseExact(token, "N", out _);
    private static bool Text(string? value, int limit = 500) => value is not null && value.Length <= limit;
    private static bool Key(string? value) => value is { Length: > 0 and <= 300 } && value.All(c => char.IsAsciiLetterOrDigit(c) || c is ':' or '-' or '_');
    private static bool RouteEntry(ScheduleEntry? e) => e is not null && Text(e.Title) && e.Title.Length > 0 &&
        (ReminderPolicy.ValidEntry(e) || e.Episode == 0 && ReminderPolicy.ValidEntry(e with { Episode = 1 }));
    private static bool ProviderId(string value) => value is not null && value.Split(':') is [var provider, var raw] &&
        provider is "anilist" or "mal" && int.TryParse(raw, out var id) && id is > 0 and <= 1_000_000_000;
    private static void Validate(ReminderState s)
    {
        if (s.Version != 1 || !ValidToken(s.OwnerId) || !ReminderPolicy.ValidLead(s.LocalNotificationEpisodeLeadTime) || !ReminderPolicy.ValidSeasonLead(s.LocalNotificationSeasonLeadTime) ||
            s.Reminders is null || s.Reminders.Count > 200 || s.RecentRoutes is null || s.RecentRoutes.Count > 200 ||
            s.Subscriptions is null || s.Subscriptions.Count > 100 || s.AutoEpisodes is null || s.AutoEpisodes.Count > 2000 ||
            s.Occurrences is null || s.Occurrences.Count > 1000 || s.History is null || s.History.Count > 1000 ||
            s.DeletedHistoryIds is null || s.DeletedHistoryIds.Count > 2000 || s.DeletedHistoryIds.Any(id => !Text(id, 400)) ||
            s.Reminders.Any(r => r is null || !Key(r.Id) || !ValidToken(r.RouteToken) || !ReminderPolicy.ValidEntry(r.Entry)) ||
            s.Reminders.DistinctBy(r => r.Id).Count() != s.Reminders.Count || s.Reminders.DistinctBy(r => r.RouteToken).Count() != s.Reminders.Count ||
            s.RecentRoutes.Any(r => r is null || !ValidToken(r.RouteToken) || !RouteEntry(r.Entry)) ||
            s.AutoEpisodes.Any(e => !ReminderPolicy.ValidEntry(e)) ||
            s.Occurrences.Any(o => o is null || !Key(o.Id) || !ValidToken(o.RouteToken) || !RouteEntry(o.Entry) || !Text(o.Body, 2000) || !Text(o.Kind, 30) || o.EpisodeNumbers?.Count > 2000) ||
            s.History.Any(h => h is null || !Text(h.Id, 400) || !ValidToken(h.RouteToken) || !RouteEntry(h.Entry) || !Text(h.Body, 2000) || !Text(h.Kind, 30)) ||
            s.Subscriptions.Any(n => n is null || !Key(n.Id) || !ValidToken(n.Revision) || n.Source is not ("Anime" or "Western") || n.TmdbId < 0 || n.TmdbId > 1_000_000_000 || !Text(n.Title) || n.Title.Length == 0 ||
                n.Source == "Western" && n.TmdbId == 0 || n.TitleAliases is null || n.TitleAliases.Count > 64 || n.TitleAliases.Any(a => !Text(a)) ||
                n.AnimeMediaIds is null || n.AnimeSpecialMediaIds is null || n.AnimeMediaIds.Count > 256 || n.AnimeSpecialMediaIds.Count > 256 ||
                n.AnimeMediaIds.Concat(n.AnimeSpecialMediaIds).Any(id => !ProviderId(id)) ||
                n.KnownWesternSeasonIds is null || n.KnownWesternSeasonIds.Count > 256 || n.KnownWesternSeasonIds.Any(id => id <= 0) ||
                n.MutedEpisodes is null || n.MutedEpisodes.Count > 2000 || n.MutedEpisodes.Keys.Any(k => !Key(k)) ||
                n.Premieres is null || n.Premieres.Count > 256 || n.Premieres.Any(p => p is null || !Key(p.Id) || !Text(p.Title) || !Text(p.Label) || !Text(p.Date, 10) || p.ProviderId <= 0 || p.ProviderId > 1_000_000_000 || p.Provider is not ("AniList" or "MAL" or "Trakt") || p.Season is < 0 or > 10000)) ||
            s.Subscriptions.DistinctBy(n => n.Id).Count() != s.Subscriptions.Count) throw new JsonException("Invalid notification state.");
    }
    public void Write(ReminderState state)
    {
        Validate(state);
        var json = JsonSerializer.Serialize(state, PreferenceStore.JsonOptions);
        if (Encoding.UTF8.GetByteCount(json) > Limit) throw new IOException("The notification file exceeds its size limit.");
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, json);
        File.Move(temporary, path, true);
    }
    public void Reset(ReminderState state)
    {
        var backup=path+".unreadable-"+Guid.NewGuid().ToString("N");
        if(!File.Exists(path)){Write(state);return;}
        File.Move(path,backup);
        try{Write(state);}catch{if(!File.Exists(path))File.Move(backup,path);throw;}
    }
}
