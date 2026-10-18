using Eclipse.Windows.Models;

namespace Eclipse.Windows.Services;

public sealed partial class EpisodeReminderService
{
    public async Task SyncHistoryAsync(string? openedArgument = null)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            EnsureReadable(); var delivered = await _platform.DeliveredAsync().ConfigureAwait(false); var history = _state.History.ToList();
            ReminderPolicy.ReadArgument(openedArgument,out var opened,out var openedOccurrence);
            NotificationOccurrence? Find(string tag,string token,string key)=>_state.Occurrences.LastOrDefault(o=>o.RouteToken==token&&(tag.Length==0||o.Tag==tag)&&
                (key.Length>0?ReminderPolicy.OccurrenceKey(o.Id,o.FireDate)==key:o.FireDate<=_now()));
            var observed = delivered.Select(d => Find(d.Tag,d.RouteToken,d.OccurrenceKey)).OfType<NotificationOccurrence>()
                .Concat(new[]{Find("",opened,openedOccurrence)}.OfType<NotificationOccurrence>());
            foreach (var o in observed)
            {
                var id = o.Tag + ":" + o.FireDate.ToUnixTimeMilliseconds();
                if (_state.DeletedHistoryIds.Contains(id) || _state.HistoryClearedAt is { } cutoff && o.FireDate <= cutoff) continue;
                var index = history.FindIndex(h => h.Id == id);
                var wasOpened=o.RouteToken==opened&&(openedOccurrence.Length==0||ReminderPolicy.OccurrenceKey(o.Id,o.FireDate)==openedOccurrence);
                if (index >= 0) { if (wasOpened) history[index] = history[index] with { WasOpened = true }; }
                else history.Add(new(id, o.RouteToken, o.Entry, o.Kind, o.Body, _now(), wasOpened));
            }
            var next = history.OrderByDescending(h => h.RecordedAt).Take(1000).ToArray();
            if (!_state.History.SequenceEqual(next)) await SaveAsync(_state with { History = next }).ConfigureAwait(false);
        }
        finally { _gate.Release(); Changed?.Invoke(this, EventArgs.Empty); }
    }
    public async Task DeleteHistoryAsync(string id)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            EnsureReadable(); if (!_state.History.Any(h => h.Id == id)) return;
            await SaveAsync(_state with { History = _state.History.Where(h => h.Id != id).ToArray(), DeletedHistoryIds = _state.DeletedHistoryIds.Append(id).Distinct().TakeLast(2000).ToArray() }).ConfigureAwait(false);
            await _platform.RemoveDeliveredAsync(id.Split(':')[0]).ConfigureAwait(false);
        }
        finally { _gate.Release(); Changed?.Invoke(this, EventArgs.Empty); }
    }
    public async Task ClearHistoryAsync()
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            EnsureReadable(); var delivered = await _platform.DeliveredAsync().ConfigureAwait(false);
            await SaveAsync(_state with { History = [], HistoryClearedAt = _now() }).ConfigureAwait(false);
            foreach (var item in delivered) await _platform.RemoveDeliveredAsync(item.Tag).ConfigureAwait(false);
        }
        finally { _gate.Release(); Changed?.Invoke(this, EventArgs.Empty); }
    }
}
