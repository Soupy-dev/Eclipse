using Eclipse.Windows.Models;

namespace Eclipse.Windows.Services;

public sealed partial class EpisodeReminderService
{
    public Task RefreshAsync(CancellationToken token, bool force = true)
    {
        lock (_refreshGate)
        {
            if (_refresh is { IsCompleted: false }) return _refresh.WaitAsync(token);
            _refresh = RefreshCoreAsync(token, force); return _refresh;
        }
    }
    private async Task RefreshCoreAsync(CancellationToken token, bool force)
    {
        using var budget=CancellationTokenSource.CreateLinkedTokenSource(token);budget.CancelAfter(TimeSpan.FromMinutes(2));
        try{await RefreshWorkAsync(budget.Token,force).ConfigureAwait(false);}
        catch(OperationCanceledException)when(!token.IsCancellationRequested)
        {Error="Refresh reached its time budget. Existing alerts are preserved. Refresh again to check remaining shows.";Changed?.Invoke(this,EventArgs.Empty);}
    }
    private async Task RefreshWorkAsync(CancellationToken token,bool force)
    {
        await InitializeAsync().ConfigureAwait(false);
        var sources = _state.Reminders.Select(r => r.Entry.Source).Concat(_state.Subscriptions.Where(s => s.EpisodeNotifications).Select(s => s.Source)).Distinct().ToArray();
        foreach (var source in sources)
        {
            token.ThrowIfCancellationRequested();
            try { var result = await ScheduleService.Shared.LoadAsync(source == "Anime" ? "anime" : "western", WindowDays, token, force).ConfigureAwait(false); await ConsumeAsync(result).ConfigureAwait(false); }
            catch (ProviderException) { Error = "Some calendars could not refresh. Existing confirmed reminders are preserved."; }
        }
        foreach (var snapshot in _state.Subscriptions.Where(s => s.Source == "Anime" || s.FutureSeasonNotifications).OrderBy(s=>s.LastMetadataAttempt).ToArray())
        {
            token.ThrowIfCancellationRequested(); var now = _now();
            if (!force && (snapshot.LastMetadataSuccess is { } success && success > now.AddHours(-6) || snapshot.LastMetadataAttempt is { } attempt && attempt > now.AddSeconds(-60))) continue;
            try
            {
                using var budget = CancellationTokenSource.CreateLinkedTokenSource(token); budget.CancelAfter(TimeSpan.FromSeconds(90));
                var result = await _metadata.LoadAsync(snapshot, budget.Token, force).ConfigureAwait(false);
                await ApplyMetadataAsync(snapshot, result, now).ConfigureAwait(false);
            }
            catch (Exception e) when (e is ProviderException or TmdbException || e is OperationCanceledException && !token.IsCancellationRequested)
            {
                await MutateAsync(s => s with { Subscriptions = s.Subscriptions.Select(n => n.Id == snapshot.Id && n.Revision == snapshot.Revision ? n with { LastMetadataAttempt = now } : n).ToArray() }).ConfigureAwait(false);
                Error = "Some season metadata is unavailable. Existing follows and premiere dates are preserved.";
            }
        }
        await SyncHistoryAsync().ConfigureAwait(false); Changed?.Invoke(this, EventArgs.Empty);
    }
    public async Task ApplyMetadataAsync(NotificationSubscription expected, SeasonSnapshot result, DateTimeOffset checkedAt)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            EnsureReadable(); var old = _state.Subscriptions.FirstOrDefault(s => s.Id == expected.Id && s.Revision == expected.Revision);
            if (old is null) return;
            var known = old.Source == "Anime" ? old.AnimeMediaIds.Concat(old.AnimeSpecialMediaIds).ToArray() : old.KnownWesternSeasonIds.Select(id => "tmdb:" + id).ToArray();
            var newSeasons = result.Seasons.Where(p => !p.Special && p.Upcoming && !known.Contains(old.Source=="Anime"?$"{p.Provider.ToLowerInvariant()}:{p.ProviderId}":p.Id)&&!old.Premieres.Any(previous=>previous.Id==p.Id)).ToArray();
            var premieres = result.Complete ? result.Seasons : old.Premieres.Where(p => !result.Seasons.Any(n => n.Id == p.Id)).Concat(result.Seasons).ToArray();
            var next = old with { AnimeMediaIds = old.AnimeMediaIds.Concat(result.RegularIds.Where(id => !id.StartsWith("tmdb:", StringComparison.Ordinal))).Except(result.SpecialIds.Except(result.RegularIds)).Distinct().Take(256).ToArray(),
                AnimeSpecialMediaIds = old.AnimeSpecialMediaIds.Concat(result.SpecialIds).Except(result.RegularIds).Distinct().Take(256).ToArray(),
                KnownWesternSeasonIds = old.KnownWesternSeasonIds.Concat(result.RegularIds.Where(id => id.StartsWith("tmdb:", StringComparison.Ordinal)).Select(id => int.TryParse(id[5..], out var n) ? n : 0).Where(n => n > 0)).Distinct().Take(256).ToArray(),
                Premieres = premieres.Take(256).ToArray(), HasCompleteBaseline = old.HasCompleteBaseline || result.Complete,
                LastMetadataAttempt = checkedAt, LastMetadataSuccess = result.Complete ? checkedAt : old.LastMetadataSuccess };
            var announcements=new List<NotificationOccurrence>();
            if (old.FutureSeasonNotifications && old.HasCompleteBaseline)
                foreach (var season in newSeasons.Take(32))
                {
                    var id = $"announcement:{old.Id}:{season.Id}"; var tag = ReminderPolicy.Tag(id); var route = ReminderPolicy.RouteToken(_state.OwnerId, id);
                    var entry = new ScheduleEntry(id, old.Source, season.Provider, season.ProviderId, season.Title, checkedAt, 0, season.Season, TmdbId: old.TmdbId);
                    var body = $"{season.Label} has been announced" + (season.Date.Length == 10 ? $" for {season.Date}." : ". The premiere date is not confirmed.");
                    var occurrence = new NotificationOccurrence(id, tag, route, entry, checkedAt, checkedAt, "announcement", body, old.Id,AnnouncementPending:true);
                    announcements.Add(occurrence);
                }
            // Known IDs and announcement intent must advance in the same durable write.
            await CommitAsync(_state with { Subscriptions = _state.Subscriptions.Select(s => s.Id == old.Id ? next : s).ToArray(),Occurrences=_state.Occurrences.Concat(announcements).TakeLast(1000).ToArray() }).ConfigureAwait(false);
            await FlushAnnouncementsAsync().ConfigureAwait(false);
        }
        finally { _gate.Release(); Changed?.Invoke(this, EventArgs.Empty); }
    }
    private async Task FlushAnnouncementsAsync()
    {
        foreach(var occurrence in _state.Occurrences.Where(o=>o.AnnouncementPending&&_state.Subscriptions.Any(s=>s.Id==o.SubscriptionId&&s.FutureSeasonNotifications)).Take(32).ToArray())
        {
            await _platform.ShowAsync(new(occurrence.Tag,occurrence.RouteToken,occurrence.Entry,occurrence.FireDate){Id=occurrence.Id,Kind=occurrence.Kind,Body=occurrence.Body,SubscriptionId=occurrence.SubscriptionId}).ConfigureAwait(false);
            await SaveAsync(_state with{Occurrences=_state.Occurrences.Select(o=>o==occurrence?o with{AnnouncementPending=false}:o).ToArray()}).ConfigureAwait(false);
        }
    }
}
