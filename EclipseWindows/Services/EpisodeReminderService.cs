using System.Text.Json;
using Eclipse.Windows.Models;
using Windows.Storage;

namespace Eclipse.Windows.Services;

public interface IReminderPlatform
{
    Task<string?> AvailabilityAsync();
    Task<IReadOnlyList<PendingReminder>> PendingAsync();
    Task ScheduleAsync(ReminderPlan plan);
    Task RemoveAsync(string tag);
    Task<IReadOnlyList<DeliveredReminder>> DeliveredAsync() => Task.FromResult<IReadOnlyList<DeliveredReminder>>([]);
    Task RemoveDeliveredAsync(string tag) => Task.CompletedTask;
    Task ShowAsync(ReminderPlan plan) => Task.CompletedTask;
}

// Serialized device-local selections and OS reconciliation. Discovery checks follow revisions.
public sealed partial class EpisodeReminderService
{
    public static EpisodeReminderService Shared { get; } = new(new WindowsReminderPlatform(),
        new LocalReminderStore(Path.Combine(ApplicationData.Current.LocalFolder.Path, "episode-reminders.json")));
    private readonly IReminderPlatform _platform;
    private readonly IReminderStore _store;
    private readonly INotificationMetadata _metadata;
    private readonly Func<DateTimeOffset> _now;
    private readonly SemaphoreSlim _gate = new(1);
    private readonly object _refreshGate = new();
    private Task? _refresh;
    private ReminderState _state = new();
    public ReminderState State => _state;
    public string? Error { get; private set; }
    public string? ReadError { get; private set; }
    public int ScheduledCount { get; private set; }
    public event EventHandler? Changed;
    private static int WindowDays => PreferenceStore.Shared.Value.ScheduleWindowDays;
    public EpisodeReminderService(IReminderPlatform platform, IReminderStore store, Func<DateTimeOffset>? now = null, INotificationMetadata? metadata = null)
    {
        _platform = platform; _store = store; _now = now ?? (() => DateTimeOffset.UtcNow); _metadata = metadata ?? new NotificationMetadataService();
        try { _state = store.Read(); }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        { ReadError = Error = "Saved notifications could not be read. The original file is preserved."; }
    }
    public Task<string?> AvailabilityAsync() => _platform.AvailabilityAsync();
    public bool IsSaved(ScheduleEntry entry) => _state.Reminders.Any(r => ReminderPolicy.SameEpisode(r.Entry, entry));
    public EpisodeNotificationState Status(ScheduleEntry entry) => ReminderPolicy.EpisodeState(_state, entry, _now(), WindowDays);
    public ScheduleEntry? ResolveArgument(string? argument)
    {
        if(!ReminderPolicy.ReadArgument(argument,out var token,out var occurrence))return null;
        if(occurrence.Length>0){var matched=_state.Occurrences.LastOrDefault(o=>o.RouteToken==token&&ReminderPolicy.OccurrenceKey(o.Id,o.FireDate)==occurrence);return matched?.Kind=="batch"?matched.Entry with{Episode=0,Id=matched.Id}:matched?.Entry;}
        if(_state.Occurrences.LastOrDefault(o=>o.RouteToken==token) is{Kind:"batch"}batch)return batch.Entry with{Episode=0,Id=batch.Id};
        return _state.Reminders.FirstOrDefault(r => r.RouteToken == token)?.Entry ?? _state.Occurrences.LastOrDefault(o => o.RouteToken == token)?.Entry ??
            _state.History.FirstOrDefault(h => h.RouteToken == token)?.Entry ?? _state.RecentRoutes.FirstOrDefault(r => r.RouteToken == token && r.ExpiresAt > _now())?.Entry;
    }
    public async Task InitializeAsync()
    {
        if(_state.Reminders.Count==0&&_state.Subscriptions.Count==0&&!_state.PendingPlatformUpdate)return;
        await _gate.WaitAsync().ConfigureAwait(false);
        try{EnsureReadable();await CommitAsync(_state).ConfigureAwait(false);await FlushAnnouncementsAsync().ConfigureAwait(false);}
        finally{_gate.Release();Changed?.Invoke(this,EventArgs.Empty);}
    }
    public Task ConsumeAsync(IReadOnlyList<ScheduleEntry> entries) => ConsumeAsync(new ScheduleResult(entries, ""));
    public Task ConsumeAsync(ScheduleResult result) => _state.Reminders.Count == 0 && _state.Subscriptions.Count == 0 ? Task.CompletedTask : MutateAsync(s =>
    {
        var now = _now(); var entries = result.Entries.Where(ReminderPolicy.ValidEntry).ToArray();
        var old = s.AutoEpisodes.Where(e => e.AiringAt > now && ReminderPolicy.WithinWindow(e, now, WindowDays) && (!result.AuthoritativeSources.Contains(e.Source)||entries.Any(n=>ReminderPolicy.SameEpisode(e,n))))
            .Select(e=>ReminderPolicy.Merge([new(ReminderPolicy.StableId(e),"",e)],entries,now)[0].Entry).ToArray();
        var incoming=entries.Where(e=>!e.Estimated&&(e.KnownTime||e.AiringTimeWithdrawn)).GroupBy(ReminderPolicy.StableId)
            .Where(g=>g.Select(e=>(e.AiringAt,e.KnownTime,e.AiringTimeWithdrawn)).Distinct().Count()==1).Select(g=>g.First())
            .Where(e=>!old.Any(previous=>ReminderPolicy.SameEpisode(previous,e)));
        var subs = s.Subscriptions.Select(sub =>
        {
            var mutes = sub.MutedEpisodes.Where(m => m.Value > now).ToDictionary();
            foreach (var e in entries.Where(e => ReminderPolicy.Matches(sub, e))) foreach (var key in ReminderPolicy.EpisodeKeys(e)) if (mutes.ContainsKey(key)) mutes[key] = e.AiringAt.AddDays(1);
            return sub with { MutedEpisodes = mutes };
        }).ToArray();
        return s with { Reminders = ReminderPolicy.Merge(s.Reminders, entries, now), Subscriptions = subs,
            AutoEpisodes = old.Concat(incoming).Where(e => subs.Any(sub => sub.EpisodeNotifications && ReminderPolicy.Matches(sub, e))).DistinctBy(ReminderPolicy.StableId).OrderBy(e => e.AiringAt).Take(2000).Select(e => e with { Cover = null }).ToArray() };
    });
    public Task SetLeadAsync(int lead) => MutateAsync(s => ReminderPolicy.ValidLead(lead) ? s with { LocalNotificationEpisodeLeadTime = lead } : throw new ArgumentException("Invalid episode timing."));
    public Task SetSeasonLeadAsync(int lead) => MutateAsync(s => ReminderPolicy.ValidSeasonLead(lead) ? s with { LocalNotificationSeasonLeadTime = lead } : throw new ArgumentException("Invalid season timing."));
    public Task SetSpecialsAsync(bool include) => MutateAsync(s => s with { LocalNotificationIncludeAnimeSpecials = include });
    public async Task ToggleAsync(ScheduleEntry entry)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            EnsureReadable(); var existing = _state.Reminders.FirstOrDefault(r => ReminderPolicy.SameEpisode(r.Entry, entry)); var status = Status(entry);
            if (existing is not null || status is EpisodeNotificationState.Followed or EpisodeNotificationState.Muted)
            {
                if(status==EpisodeNotificationState.Muted)await EnsureAvailableAsync().ConfigureAwait(false);
                var mute = status != EpisodeNotificationState.Muted;
                var subs = _state.Subscriptions.Select(s =>
                {
                    if (!s.EpisodeNotifications || !ReminderPolicy.Matches(s, entry)) return s;
                    var values = s.MutedEpisodes.ToDictionary();
                    foreach (var key in ReminderPolicy.EpisodeKeys(entry)) { if (mute) values[key] = entry.AiringAt.AddDays(1); else values.Remove(key); }
                    return s with { MutedEpisodes = values };
                }).ToArray();
                await CommitAsync(_state with { Subscriptions = subs, Reminders = _state.Reminders.Where(r => r.Id != existing?.Id).ToArray(), Occurrences = _state.Occurrences.Where(o => !ReminderPolicy.SameEpisode(o.Entry, entry) || o.FireDate <= _now()).ToArray() }).ConfigureAwait(false); return;
            }
            if (!ReminderPolicy.CanEnable(entry, _now())) throw new InvalidOperationException("This episode does not have a confirmed future airtime.");
            if (_state.Reminders.Count >= ReminderPolicy.MaximumSaved) throw new InvalidOperationException("Remove an individual reminder before adding another.");
            await EnsureAvailableAsync().ConfigureAwait(false);
            var reminder = new EpisodeReminder(ReminderPolicy.StableId(entry), Guid.NewGuid().ToString("N"), entry with { Cover = null });
            await CommitAsync(_state with { Reminders = _state.Reminders.Append(reminder).ToArray() }).ConfigureAwait(false);
        }
        finally { _gate.Release(); Changed?.Invoke(this, EventArgs.Empty); }
    }
    public Task RemoveAsync(string id) => MutateAsync(s => s with { Reminders = s.Reminders.Where(r => r.Id != id).ToArray(), Occurrences = s.Occurrences.Where(o => o.Id != id || o.FireDate <= _now()).ToArray() });
    public async Task FollowAsync(NotificationSubscription selection)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            EnsureReadable(); var old = _state.Subscriptions.FirstOrDefault(s => s.Id == selection.Id);
            if (!selection.EpisodeNotifications && !selection.FutureSeasonNotifications) { await CommitAsync(_state with { Subscriptions = _state.Subscriptions.Where(s => s.Id != selection.Id).ToArray() }).ConfigureAwait(false); return; }
            if (old is null && _state.Subscriptions.Count >= 100) throw new InvalidOperationException("The following limit has been reached.");
            if (selection.Source == "Anime" && selection.FutureSeasonNotifications && !selection.AnimeMediaIds.Any(id => id.StartsWith("anilist:", StringComparison.Ordinal))) throw new InvalidOperationException("Future anime seasons require a verified AniList identity.");
            if (selection.EpisodeNotifications && old?.EpisodeNotifications != true || selection.FutureSeasonNotifications && old?.FutureSeasonNotifications != true) await EnsureAvailableAsync().ConfigureAwait(false);
            var baseline = selection.FutureSeasonNotifications && old?.FutureSeasonNotifications != true;
            var next = (old ?? selection) with { Revision = Guid.NewGuid().ToString("N"), EpisodeNotifications = selection.EpisodeNotifications, FutureSeasonNotifications = selection.FutureSeasonNotifications,
                Title=selection.Title,TitleAliases=(old?.TitleAliases??[]).Concat(selection.TitleAliases).Distinct().Take(64).ToArray(),
                AnimeMediaIds=(old?.AnimeMediaIds??[]).Concat(selection.AnimeMediaIds).Except(selection.AnimeSpecialMediaIds.Except(selection.AnimeMediaIds)).Distinct().Take(256).ToArray(),
                AnimeSpecialMediaIds=(old?.AnimeSpecialMediaIds??[]).Concat(selection.AnimeSpecialMediaIds).Except(selection.AnimeMediaIds).Distinct().Take(256).ToArray(),
                HasCompleteBaseline = !baseline && (old?.HasCompleteBaseline ?? false), LastMetadataAttempt = baseline ? null : old?.LastMetadataAttempt, LastMetadataSuccess = baseline ? null : old?.LastMetadataSuccess };
            await CommitAsync(_state with { Subscriptions = _state.Subscriptions.Where(s => s.Id != next.Id).Append(next).ToArray() }).ConfigureAwait(false);
        }
        finally { _gate.Release(); Changed?.Invoke(this, EventArgs.Empty); }
    }
    public Task RemoveFollowAsync(string id) => MutateAsync(s => s with { Subscriptions = s.Subscriptions.Where(n => n.Id != id).ToArray() });
    public async Task ClearSelectionsAsync()
    {
        if(ReadError is not null)
        {
            await _gate.WaitAsync().ConfigureAwait(false);
            try{var reset=new ReminderState();await Task.Run(()=>_store.Reset(reset)).ConfigureAwait(false);_state=reset;ReadError=null;Error=null;}
            finally{_gate.Release();}
        }
        await SyncHistoryAsync().ConfigureAwait(false);
        await MutateAsync(s => s with { Reminders = [], Subscriptions = [], AutoEpisodes = [], Occurrences = s.Occurrences.Where(o => o.FireDate <= _now()).Select(o=>o with{AnnouncementPending=false}).ToArray() }).ConfigureAwait(false);
        foreach(var item in await _platform.DeliveredAsync().ConfigureAwait(false))await _platform.RemoveDeliveredAsync(item.Tag).ConfigureAwait(false);
    }
    private async Task EnsureAvailableAsync() { if (await _platform.AvailabilityAsync().ConfigureAwait(false) is { } unavailable) throw new InvalidOperationException(unavailable); }
    private void EnsureReadable() { if (ReadError is not null) throw new IOException(ReadError); }
    private async Task MutateAsync(Func<ReminderState, ReminderState> change)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try { EnsureReadable(); await CommitAsync(change(_state)).ConfigureAwait(false); }
        finally { _gate.Release(); Changed?.Invoke(this, EventArgs.Empty); }
    }
    private async Task SaveAsync(ReminderState next) { await Task.Run(() => _store.Write(next)).ConfigureAwait(false); _state = next; }
    private async Task CommitAsync(ReminderState next)
    {
        var now = _now(); var active = next.Reminders.Where(r => r.Entry.AiringAt > now || r.Entry.Source == "Anime" && !r.Entry.KnownTime).ToArray();
        var expired = next.Reminders.Except(active).Where(r => r.ScheduledFireDate is not null).Select(r => new ReminderRoute(r.RouteToken, r.Entry, r.Entry.AiringAt.AddDays(7)));
        next = next with { Reminders = active, PendingPlatformUpdate = true, RecentRoutes = next.RecentRoutes.Concat(expired).Where(r => r.ExpiresAt > now).DistinctBy(r => r.RouteToken).OrderByDescending(r => r.ExpiresAt).Take(200).ToArray(), Occurrences = next.Occurrences.Where(o => o.FireDate > now.AddDays(-30)).TakeLast(1000).ToArray() };
        await SaveAsync(next).ConfigureAwait(false); Error = null;
        try
        {
            var plans = ReminderPolicy.BuildPlans(next, now, WindowDays).ToDictionary(p => p.Tag);
            var pending = await _platform.PendingAsync().ConfigureAwait(false); var byTag = pending.ToDictionary(p => p.Tag);
            foreach (var old in pending)
            {
                if (plans.TryGetValue(old.Tag, out var wanted) && Math.Abs((old.FireDate - wanted.FireDate).TotalSeconds) < 1 && (old.ContentKey.Length == 0 || old.ContentKey == ReminderPolicy.ContentKey(wanted))) continue;
                var due = next.Occurrences.LastOrDefault(o => o.Tag == old.Tag && o.FireDate == old.FireDate);
                var retained = due is not null && due.Entry.KnownTime && !due.Entry.AiringTimeWithdrawn && (due.Kind == "explicit" ? active.Any(r => r.Id == due.Id && r.Entry.AiringAt == due.EventDate && r.Entry.KnownTime) : next.Subscriptions.Any(s => s.Id == due.SubscriptionId && (due.Kind == "season" ? s.FutureSeasonNotifications : s.EpisodeNotifications && !ReminderPolicy.EpisodeKeys(due.Entry).Any(k => s.MutedEpisodes.ContainsKey(k)))));
                if(retained&&due is{Kind:"followed" or "batch"})retained=(due.EpisodeNumbers??new[]{due.Entry.Episode}).All(number=>next.AutoEpisodes.Any(e=>ReminderPolicy.SameEpisode(due.Entry with{Episode=number},e)&&e.KnownTime&&!e.AiringTimeWithdrawn&&!e.Estimated&&
                    (due.Kind=="batch"?e.AiringAt.ToUnixTimeSeconds()/300==due.EventDate.ToUnixTimeSeconds()/300:e.AiringAt==due.EventDate)&&!next.Subscriptions.Any(s=>s.Id==due.SubscriptionId&&ReminderPolicy.EpisodeKeys(e).Any(k=>s.MutedEpisodes.TryGetValue(k,out var until)&&until>now))));
                if (!plans.ContainsKey(old.Tag) && retained && old.FireDate <= now && old.FireDate > now.AddMinutes(-5)) continue;
                await _platform.RemoveAsync(old.Tag).ConfigureAwait(false); byTag.Remove(old.Tag);
            }
            foreach (var plan in plans.Values)
            {
                if (!byTag.ContainsKey(plan.Tag)) await _platform.ScheduleAsync(plan).ConfigureAwait(false);
                var occurrence = new NotificationOccurrence(plan.Id, plan.Tag, plan.RouteToken, plan.Entry with { Cover = null }, plan.FireDate, plan.Entry.AiringAt, plan.Kind, plan.Body, plan.SubscriptionId, plan.EpisodeNumbers);
                next = next with { Occurrences = next.Occurrences.Where(o => o.Id != plan.Id || o.EventDate != plan.Entry.AiringAt).Append(occurrence).TakeLast(1000).ToArray(), Reminders = next.Reminders.Select(r => ReminderPolicy.Tag(r.Id) == plan.Tag ? r with { ScheduledFireDate = plan.FireDate, ScheduledAiringAt = plan.Entry.AiringAt } : r).ToArray() };
            }
            await SaveAsync(next with { PendingPlatformUpdate = false }).ConfigureAwait(false); ScheduledCount = (await _platform.PendingAsync().ConfigureAwait(false)).Count;
        }
        catch (Exception e) when (e is not OutOfMemoryException) { Error = "Selections are saved, but Windows could not finish updating alerts. Refresh reminders to retry."; throw new InvalidOperationException(Error, e); }
    }
}
