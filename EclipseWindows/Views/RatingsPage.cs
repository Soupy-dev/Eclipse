using System.Collections.ObjectModel;
using System.ComponentModel;
using Eclipse.Windows.Models;
using Eclipse.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
namespace Eclipse.Windows.Views;

public sealed partial class RatingsPage : Page
{
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.Single, IsItemClickEnabled = true };
    private readonly Button _back = new() { Content = "Back" };
    private readonly ObservableCollection<Entry> _rows = [];
    private readonly SemaphoreSlim _slots = new(2, 2);
    private readonly Dictionary<string, CancellationTokenSource> _pending = [];
    private CancellationTokenSource _lifetime = new();
    public sealed class Entry(string key, double? rating) : INotifyPropertyChanged
    {
        public string Key { get; } = key;
        public double? Rating { get; private set; } = rating;
        public string? Name { get; private set; }
        public event PropertyChangedEventHandler? PropertyChanged;
        public string Scope => Key.Split(':') is [_, _, "season", var season] ? $"Season {season}" : Key.Split(':').Length == 4 ? "Anime cour" : "Whole title";
        public string Label => $"{Name ?? (Key.Contains(':') ? "Loading title…" : "Unassigned legacy rating")} · {Scope} · {(Rating is {} score ? $"{score:0.0}/10" : "Notes only")}";
        public void SetName(string name) { if (Name == name) return; Name = name; PropertyChanged?.Invoke(this, new(nameof(Label))); }
        public void SetRating(double? value) { if (Rating == value) return; Rating = value; PropertyChanged?.Invoke(this, new(nameof(Label))); }
    }
    public RatingsPage()
    {
        InitializeComponent();
        var grid = new Grid { Padding = new(24), RowSpacing = 16, Background = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["EclipsePageBrush"] };
        grid.RowDefinitions.Add(new() { Height = GridLength.Auto }); grid.RowDefinitions.Add(new() { Height = GridLength.Auto }); grid.RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) });
        _back.Click += (_, _) => { if (Frame.CanGoBack) Frame.GoBack(); }; grid.Children.Add(_back);
        var toggle = new ToggleSwitch { Header = "Ratings follow selected season or anime cour", IsOn = PreferenceStore.Shared.Value.RatingsFollowSeasonSelection };
        toggle.Toggled += async (_, _) => { try { var p = PreferenceStore.Shared.Copy(); p.RatingsFollowSeasonSelection = toggle.IsOn; PreferenceStore.Shared.Save(p); } catch (IOException e) { await ErrorAsync(e.Message); } };
        Grid.SetRow(toggle, 1); grid.Children.Add(toggle); Grid.SetRow(_list, 2); grid.Children.Add(_list); Content = grid; _list.ItemTemplate = (DataTemplate)Resources["RatingEntryTemplate"]; _list.ItemsSource = _rows;
        _list.ItemClick += Edit_Click; _list.ContainerContentChanging += Entry_Changing;
    }
    protected override void OnNavigatedTo(NavigationEventArgs args) { base.OnNavigatedTo(args); Render(); }
    protected override void OnNavigatedFrom(NavigationEventArgs args)
    {
        _lifetime.Cancel(); foreach (var request in _pending.Values) { request.Cancel(); request.Dispose(); } _pending.Clear(); base.OnNavigatedFrom(args);
    }
    private void Render()
    {
        _lifetime.Cancel(); _lifetime.Dispose(); _lifetime = new();
        foreach (var request in _pending.Values) request.Dispose(); _pending.Clear(); _rows.Clear();
        var data = UserRatingStore.Shared.Snapshot;
        foreach (var key in data.Ratings.Keys.Concat(data.Notes.Keys).Distinct().Order(StringComparer.Ordinal)) _rows.Add(new(key, data.Ratings.TryGetValue(key, out var score) ? score : null));
        _list.Header = new TextBlock { Text = UserRatingStore.Shared.Error ?? (_rows.Count == 0 ? "Your ratings and private notes will appear here." : "Your ratings & notes"), TextWrapping = TextWrapping.Wrap, Margin = new(0, 0, 0, 16) };
    }
    private void RefreshSavedEntries()
    {
        if (_lifetime.IsCancellationRequested) return;
        var data = UserRatingStore.Shared.Snapshot;
        var keys = data.Ratings.Keys.Concat(data.Notes.Keys).Distinct().Order(StringComparer.Ordinal).ToArray();
        // Preserve the dialog's focus target and its container while updating a saved score.
        foreach (var row in _rows.ToArray())
        {
            if (Array.BinarySearch(keys, row.Key, StringComparer.Ordinal) >= 0) row.SetRating(data.Ratings.TryGetValue(row.Key, out var score) ? score : null);
            else { _back.Focus(FocusState.Programmatic); _rows.Remove(row); }
        }
        var existing = _rows.Select(row => row.Key).ToHashSet(StringComparer.Ordinal);
        foreach (var key in keys)
        {
            if (!existing.Add(key)) continue;
            var index = 0; while (index < _rows.Count && StringComparer.Ordinal.Compare(_rows[index].Key, key) < 0) index++;
            _rows.Insert(index, new(key, data.Ratings.TryGetValue(key, out var score) ? score : null));
        }
        if (_list.Header is TextBlock header) header.Text = UserRatingStore.Shared.Error ?? (_rows.Count == 0 ? "Your ratings and private notes will appear here." : "Your ratings & notes");
    }
    private void Entry_Changing(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.Item is not Entry entry) return;
        if (args.InRecycleQueue) { if (_pending.Remove(entry.Key, out var old)) { old.Cancel(); old.Dispose(); } return; }
        if (entry.Name is not null || !entry.Key.Contains(':') || _pending.ContainsKey(entry.Key)) return;
        var request = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token); _pending[entry.Key] = request; _ = LoadNameAsync(entry, request.Token);
    }
    private async Task LoadNameAsync(Entry entry, CancellationToken ct)
    {
        var entered = false; string? name = null;
        try
        {
            await _slots.WaitAsync(ct); entered = true; var parts = entry.Key.Split(':');
            var title = parts is [_, _, "anilist", var ani] ? await AnimeMetadataService.Shared.AniListAsync(int.Parse(ani), ct) :
                parts is [_, _, "mal", var mal] ? await AnimeMetadataService.Shared.MalAsync(int.Parse(mal), ct) : await TmdbService.Shared.DetailsAsync($"{parts[0]}:{parts[1]}", ct);
            name = title.Title;
        }
        catch (OperationCanceledException) { } catch (Exception e) when (e is TmdbException or ProviderException) { name = "Title unavailable"; }
        finally { if (entered) _slots.Release(); }
        if (ct.IsCancellationRequested || name is null) return;
        if (_rows.Contains(entry)) entry.SetName(name);
    }
    private async void Edit_Click(object sender, ItemClickEventArgs args)
    {
        if (args.ClickedItem is not Entry entry) return;
        if (!entry.Key.Contains(':')) { await ErrorAsync("This legacy rating has no movie/show identity. It is preserved and will not be attached automatically."); return; }
        var parts = entry.Key.Split(':'); if (!int.TryParse(parts[1], out var id)) return;
        var title = new MediaTitle { TmdbId = id, MediaType = parts[0], Title = entry.Name ?? "Your rating" };
        MediaSeason? season = parts is [_, _, "season", var number] ? new(int.Parse(number), $"Season {number}", 0) : null;
        if (parts is [_, _, "anilist" or "mal", var providerId])
        {
            var node = new AnimeNode("", parts[2] == "anilist" ? int.Parse(providerId) : null, parts[2] == "mal" ? int.Parse(providerId) : null, entry.Name ?? "Anime cour", "", "", null, "", "", []);
            season = new(0, node.Title, 0) { Cour = new(node, null, 0, null, false, null, "") };
        }
        try
        {
            if (await LibraryDialogs.RatingAsync(XamlRoot, title, season, wholeOverride: parts.Length == 2))
                DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, RefreshSavedEntries);
        }
        catch (IOException e) { await ErrorAsync(e.Message); }
    }
    private async Task ErrorAsync(string message) => await new ContentDialog { XamlRoot = XamlRoot, Title = "Ratings & notes", Content = message, CloseButtonText = "Close" }.ShowAsync();
}

