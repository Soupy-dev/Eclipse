using Eclipse.Windows.Models;
using Eclipse.Windows.Navigation;
using Eclipse.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Navigation;
namespace Eclipse.Windows.Views;

public sealed partial class LibraryPage : Page
{
    public event EventHandler<TitleRequestedEventArgs>? TitleRequested;
    private Guid? _collection;
    private IReadOnlyList<MediaTitle> _localTitles = [];
    private TrackerLibraryResult? _remote;
    private TrackerSession? _session;
    private CancellationTokenSource? _load;
    private int _generation;
    private bool _updating;
    private LibraryNavigationState _state = new();
    private readonly MouseShelfDrag _drag, _collectionDrag;
    private readonly SemaphoreSlim _metadataSlots = new(2, 2);
    private readonly Dictionary<object, CancellationTokenSource> _artLoads = new(ReferenceEqualityComparer.Instance);
    private sealed record SourceItem(string Name, TrackerKind? Kind = null) { public override string ToString() => Name; }
    public LibraryPage() { InitializeComponent(); _drag = new(Bookmarks, () => FindScroll(Bookmarks)); _collectionDrag = new(CollectionShelf, () => FindScroll(CollectionShelf)); foreach (var list in new ListViewBase[] { Bookmarks, Titles, RemoteTitles }) list.ContainerContentChanging += Recycling; foreach (var list in new ListViewBase[] { Bookmarks, CollectionShelf, Collections, Titles, RemoteTitles }) list.ContextRequested += Row_ContextRequested; Bookmarks.AddHandler(PointerWheelChangedEvent, new PointerEventHandler(Bookmarks_Wheel), true); CollectionShelf.AddHandler(PointerWheelChangedEvent,new PointerEventHandler(Bookmarks_Wheel),true); Loaded += (_, _) => Restore(); }
    private void Bookmarks_Wheel(object sender, PointerRoutedEventArgs args)
    { var point = args.GetCurrentPoint((UIElement)sender).Properties; if (point.IsHorizontalMouseWheel || (args.KeyModifiers & (global::Windows.System.VirtualKeyModifiers.Control | global::Windows.System.VirtualKeyModifiers.Shift)) != 0) return; var scroll = FindScroll(Collections); if (scroll is not null) { scroll.ChangeView(null, Math.Clamp(scroll.VerticalOffset - point.MouseWheelDelta / 120d * 48, 0, scroll.ScrollableHeight), null, true); args.Handled = true; } }
    private void Row_ContextRequested(UIElement sender, ContextRequestedEventArgs args)
    {
        var focused = FocusManager.GetFocusedElement(XamlRoot) ?? sender; MenuFlyout? menu = null; UIElement anchor = focused as UIElement ?? sender;
        if (ItemAt<LibraryCollection>(focused) is { } collection) menu = CollectionMenu(collection);
        else if (ItemAt<MediaTitle>(focused) is { } title) menu = TitleMenu(title, _collection ?? LocalProfile.BookmarksId);
        else if (ItemAt<TrackerEntry>(focused) is { } entry && _session is { } session) menu = RemoteMenu(session, entry);
        if (menu is not null) { menu.ShowAt(anchor as FrameworkElement ?? (FrameworkElement)sender); args.Handled = true; }
    }
    protected override void OnNavigatedTo(NavigationEventArgs args) { base.OnNavigatedTo(args); _state = args.Parameter as LibraryNavigationState ?? new(); _collection = _state.Collection; LibraryStore.Shared.Changed += Store_Changed; TrackerAccounts.Shared.Changed += Accounts_Changed; UpdateSources(); }
    protected override void OnNavigatedFrom(NavigationEventArgs args) { SaveState(); LibraryStore.Shared.Changed -= Store_Changed; TrackerAccounts.Shared.Changed -= Accounts_Changed; _load?.Cancel(); ++_generation; _drag.Reset(); _collectionDrag.Reset(); ReleaseArt(); base.OnNavigatedFrom(args); }
    private static ScrollViewer? FindScroll(DependencyObject root) { for (var i = 0; i < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(root); i++) { var child = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(root, i); if (child is ScrollViewer s) return s; if (FindScroll(child) is { } nested) return nested; } return null; }
    private void Recycling(ListViewBase sender, ContainerContentChangingEventArgs args)
    { if (args.InRecycleQueue) { if (args.Item is not null && _artLoads.Remove(args.Item, out var load)) { load.Cancel(); load.Dispose(); } if (args.Item is MediaTitle title) title.ReleaseArtwork(); if (args.Item is TrackerEntry entry) entry.Title.ReleaseArtwork(); } else if (args.Item is TrackerEntry { Service: TrackerKind.Trakt, Title.TmdbId: > 0, Title.PosterPath: null } row && !_artLoads.ContainsKey(row) && _load is not null) { var cancellation = CancellationTokenSource.CreateLinkedTokenSource(_load.Token); _artLoads[row] = cancellation; _ = HydrateAsync(row, cancellation.Token); } }
    private async Task HydrateAsync(TrackerEntry entry, CancellationToken token)
    {
        var entered = false; try { await _metadataSlots.WaitAsync(token); entered = true; var title = await TmdbService.Shared.DetailsAsync(entry.Title.Id, token); if (!token.IsCancellationRequested && _session is { } s && TrackerAccounts.Shared.IsCurrent(s)) entry.Title = title; } catch (OperationCanceledException) { } catch (TmdbException) { } finally { if (entered) _metadataSlots.Release(); }
    }
    private void SaveState() { _state.Collection = _collection; _state.Service = _session?.Service; _state.List = (RemoteList.SelectedItem as TrackerList)?.Id ?? "all"; _state.Kind = Kind.SelectedIndex; _state.Filter = Filter.Text; _state.Status = StatusFilter.SelectedItem as string; _state.Genre = GenreFilter.SelectedItem as string; _state.Offset = FindScroll(_session is not null ? RemoteTitles : _collection is not null ? Titles : Collections)?.VerticalOffset ?? 0; }
    private void Restore() { DispatcherQueue.TryEnqueue(() => { if (!IsLoaded) return; ListViewBase list = _session is not null ? RemoteTitles : _collection is not null ? Titles : Collections; FindScroll(list)?.ChangeView(null, _state.Offset, null, true); if (_state.FocusId is { } id) { if (_session is null && _collection is null && Bookmarks.Items.Cast<MediaTitle>().Any(t => t.Id == id)) list = Bookmarks; else if(_session is null&&_collection is null&&CollectionShelf.Items.Cast<LibraryCollection>().Any(c=>c.Id.ToString()==id))list=CollectionShelf; var item = list.Items.Cast<object>().FirstOrDefault(o => o is MediaTitle t ? t.Id == id : o is TrackerEntry e ? $"{e.Service}:{e.RemoteId}" == id : o is LibraryCollection c ? c.Id.ToString() == id : false); if (item is not null) { list.ScrollIntoView(item); list.UpdateLayout(); if (list.ContainerFromItem(item) is Control control) control.Focus(FocusState.Keyboard); } } }); }
    private void ReleaseArt() { foreach (var load in _artLoads.Values) { load.Cancel(); load.Dispose(); } _artLoads.Clear(); CollectionShelf.ItemsSource = Bookmarks.ItemsSource = Titles.ItemsSource = RemoteTitles.ItemsSource = null; foreach (var t in _localTitles) t.ReleaseArtwork(); foreach (var row in _remote?.Entries ?? []) row.Title.ReleaseArtwork(); _localTitles = []; _remote = null; }
    private void Store_Changed(object? sender, EventArgs args) { if (Source.SelectedItem is SourceItem { Kind: null }) ShowLocal(); }
    private void Accounts_Changed(object? sender, EventArgs args) => DispatcherQueue.TryEnqueue(() => { if (_session is { } current && TrackerAccounts.Shared.IsCurrent(current)) return; SaveState(); _state.List = "all"; _state.Filter = ""; _state.Status = _state.Genre = _state.FocusId = null; _state.Offset = 0; UpdateSources(); });
    private void UpdateSources()
    {
        var selected = (Source.SelectedItem as SourceItem)?.Kind ?? _state.Service; _updating = true; Source.ItemsSource = new[] { new SourceItem("Local Library") }.Concat(Enum.GetValues<TrackerKind>().Where(k => TrackerAccounts.Shared.Session(k) is not null).Select(k => new SourceItem(k.ToString(), k))).ToArray(); Source.SelectedIndex = 0;
        if (selected is { } kind) Source.SelectedItem = ((IEnumerable<SourceItem>)Source.ItemsSource).FirstOrDefault(s => s.Kind == kind) ?? ((IEnumerable<SourceItem>)Source.ItemsSource).First(); _updating = false; SetSource(true);
    }
    private void Source_Changed(object sender, SelectionChangedEventArgs args) { if (!_updating) SetSource(); }
    private void SetSource(bool restore = false)
    {
        _load?.Cancel(); ++_generation; ReleaseArt(); if (!restore) { _collection = null; _state.Offset = 0; _state.FocusId = null; _state.List = "all"; _state.Filter = ""; }
        Notice.IsOpen = false;
        if (Source.SelectedItem is SourceItem { Kind: { } kind })
        {
            _session = TrackerAccounts.Shared.Session(kind); RemoteFilters.Visibility = Visibility.Visible; Collections.Visibility = Titles.Visibility = Visibility.Collapsed; RemoteTitles.Visibility = Visibility.Visible; BackButton.Visibility = Visibility.Collapsed; Heading.Text = $"{kind} · {_session?.Name}"; Heading.Visibility = Visibility.Visible;
            _updating = true; var sources = kind == TrackerKind.Trakt ? new[] { new TrackerList("watchlist", "Watchlist"), new("history", "Watched history"), new("collection", "Collection") } : new[] { new TrackerList("all", "All anime") }; if (restore && _state.List.StartsWith("list:") && !sources.Any(s => s.Id == _state.List)) sources = [.. sources, new(_state.List, _state.List)]; RemoteList.ItemsSource = sources; RemoteList.DisplayMemberPath = "Name"; RemoteList.SelectedItem = sources.FirstOrDefault(s => s.Id == _state.List) ?? (restore && _state.List.StartsWith("list:") ? new TrackerList(_state.List, _state.List) : sources[0]); Kind.SelectedIndex = _state.Kind; Filter.Text = _state.Filter; Kind.Visibility = kind == TrackerKind.Trakt ? Visibility.Visible : Visibility.Collapsed; _updating = false; _ = LoadRemoteAsync();
        }
        else { _session = null; RemoteFilters.Visibility = RemoteTitles.Visibility = Visibility.Collapsed; ShowLocal(); }
    }
    private void ShowLocal()
    {
        ReleaseArt(); Notice.IsOpen = false; var store = LibraryStore.Shared; if (store.Error is { } error) ShowError(error);
        var horizontal = PreferenceStore.Shared.Value.LibraryCollectionLayout == "horizontal";
        Collections.ItemsPanel = (ItemsPanelTemplate)Microsoft.UI.Xaml.Markup.XamlReader.Load("<ItemsPanelTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'>" + "<ItemsWrapGrid Orientation='Horizontal' ItemWidth='200' ItemHeight='272'/>" + "</ItemsPanelTemplate>");
        var collection = store.Collections.FirstOrDefault(c => c.Id == _collection); Heading.Text = collection?.Name ?? ""; Heading.Visibility = collection is null ? Visibility.Collapsed : Visibility.Visible; BackButton.Visibility = collection is null ? Visibility.Collapsed : Visibility.Visible; Collections.Visibility = collection is null ? Visibility.Visible : Visibility.Collapsed; Titles.Visibility = collection is null ? Visibility.Collapsed : Visibility.Visible;
        if (collection is not null) { _localTitles = collection.Items.Select(i => i.SearchResult.ToTitle()).ToArray(); Titles.ItemsSource = _localTitles; }
        else { var bookmarks = store.Collections.First(); _localTitles = bookmarks.Items.Select(i => i.SearchResult.ToTitle()).ToArray(); Bookmarks.ItemsSource = _localTitles; Bookmarks.Visibility = _localTitles.Count == 0 ? Visibility.Collapsed : Visibility.Visible; var groups=store.Collections.Skip(1).ToArray(); Collections.ItemsSource=horizontal?Array.Empty<LibraryCollection>():groups; CollectionShelf.ItemsSource=horizontal?groups:Array.Empty<LibraryCollection>(); CollectionShelf.Visibility=horizontal&&groups.Length>0?Visibility.Visible:Visibility.Collapsed; NoCollections.Visibility=groups.Length==0?Visibility.Visible:Visibility.Collapsed; BookmarksSection.Visibility = PreferenceStore.Shared.Value.LibraryShowBookmarksSection ? Visibility.Visible : Visibility.Collapsed; }
        Empty.Text = collection is not null && _localTitles.Count == 0 ? "This collection is empty. Add titles from their details page." : collection is null && store.Collections.Count == 1 && _localTitles.Count == 0 ? "Your library starts here. Bookmark a title or create a collection." : ""; Empty.Visibility = Empty.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        Restore();
    }
    private void Collection_Click(object sender, ItemClickEventArgs args) { if (ReferenceEquals(sender,CollectionShelf)&&_collectionDrag.SuppressClick) return; if (args.ClickedItem is LibraryCollection c) { _collection = c.Id; ShowLocal(); } }
    private void Bookmarks_Click(object sender, RoutedEventArgs args) { _collection = LocalProfile.BookmarksId; ShowLocal(); }
    private void Back_Click(object sender, RoutedEventArgs args) { _state.FocusId=_collection?.ToString(); _collection = null; ShowLocal(); }
    private void Title_Click(object sender, ItemClickEventArgs args) { if (ReferenceEquals(sender,Bookmarks)&&_drag.SuppressClick) return; if (args.ClickedItem is MediaTitle t) { _state.FocusId = t.Id; TitleRequested?.Invoke(this, new(t.Id)); } }
    private async void Remote_Click(object sender, ItemClickEventArgs args) { if (args.ClickedItem is TrackerEntry e && _session is { } s) try { if (e.Service == TrackerKind.Trakt && e.Title.TmdbId <= 0 && TrackerMatchStore.Shared.Get(s, e) is null) { await ChooseMatchAsync(s, e); if (TrackerMatchStore.Shared.Get(s, e) is null) return; } _state.FocusId = $"{e.Service}:{e.RemoteId}"; TitleRequested?.Invoke(this, new(e.Title.Id, manualTmdbMatch: TrackerMatchStore.Shared.Get(s, e))); } catch (IOException ex) { ShowError(ex.Message); } }
    private async void Create_Click(object sender, RoutedEventArgs args)
    {
        var name = new TextBox { Header = "Name", MaxLength = 200 }; var description = new TextBox { Header = "Description (optional)", MaxLength = 2000, AcceptsReturn = true }; var panel = new StackPanel { Spacing = 12 }; panel.Children.Add(name); panel.Children.Add(description);
        if (await new ContentDialog { XamlRoot = XamlRoot, Title = "New collection", Content = panel, PrimaryButtonText = "Create", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary }.ShowAsync() == ContentDialogResult.Primary) try { _collection = LibraryStore.Shared.Create(name.Text, description.Text); Source.SelectedIndex = 0; ShowLocal(); } catch (IOException e) { ShowError(e.Message); }
    }
    private static T? ItemAt<T>(object original) where T : class { var element = original as DependencyObject; while (element is not null) { if (element is FrameworkElement { DataContext: T item }) return item; element = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(element); } return null; }
    private void Collection_RightTapped(object sender, RightTappedRoutedEventArgs args)
    {
        if (ItemAt<LibraryCollection>(args.OriginalSource) is not { } collection) return; CollectionMenu(collection).ShowAt((FrameworkElement)sender, args.GetPosition((UIElement)sender)); args.Handled = true;
    }
    private MenuFlyout CollectionMenu(LibraryCollection collection) { var menu = new MenuFlyout(); Add(menu, "Rename", async () => await RenameAsync(collection)); Add(menu, "Move earlier", () => { LibraryStore.Shared.Move(collection.Id, null, -1); return Task.CompletedTask; }); Add(menu, "Move later", () => { LibraryStore.Shared.Move(collection.Id, null, 1); return Task.CompletedTask; }); Add(menu, "Delete", async () => { if (await ConfirmAsync($"Delete {collection.Name}?", "Titles remain in other collections.")) LibraryStore.Shared.Delete(collection.Id); }); return menu; }
    private async Task RenameAsync(LibraryCollection c)
    {
        var name = new TextBox { Header = "Name", Text = c.Name, MaxLength = 200 }; var description = new TextBox { Header = "Description", Text = c.Description ?? "", MaxLength = 2000 }; var panel = new StackPanel { Spacing = 12 }; panel.Children.Add(name); panel.Children.Add(description);
        if (await new ContentDialog { XamlRoot = XamlRoot, Title = "Edit collection", Content = panel, PrimaryButtonText = "Save", CloseButtonText = "Cancel" }.ShowAsync() == ContentDialogResult.Primary) LibraryStore.Shared.Rename(c.Id, name.Text, description.Text);
    }
    private void Title_RightTapped(object sender, RightTappedRoutedEventArgs args)
    {
        if (ItemAt<MediaTitle>(args.OriginalSource) is not { } t) return; TitleMenu(t, _collection ?? LocalProfile.BookmarksId).ShowAt((FrameworkElement)sender, args.GetPosition((UIElement)sender)); args.Handled = true;
    }
    private MenuFlyout TitleMenu(MediaTitle t, Guid id) { var menu = new MenuFlyout(); Add(menu, "Move earlier", () => { LibraryStore.Shared.Move(id, t.Id, -1); return Task.CompletedTask; }); Add(menu, "Move later", () => { LibraryStore.Shared.Move(id, t.Id, 1); return Task.CompletedTask; }); Add(menu, "Remove from collection", async () => { if (await ConfirmAsync("Remove this title?", "It remains in any other collections.")) LibraryStore.Shared.SetMembership(t, LibraryStore.Shared.Collections.Where(c => c.Id != id && c.Items.Any(i => i.Id == t.Id)).Select(c => c.Id).ToHashSet()); }); return menu; }
    private void Add(MenuFlyout menu, string label, Func<Task> action) { var item = new MenuFlyoutItem { Text = label }; item.Click += async (_, _) => { try { await action(); } catch (Exception e) when (e is IOException or TrackerException or OperationCanceledException) { ShowError(e is OperationCanceledException ? "Operation cancelled." : e.Message); } }; menu.Items.Add(item); }
    private async Task<bool> ConfirmAsync(string title, string body) => await new ContentDialog { XamlRoot = XamlRoot, Title = title, Content = body, PrimaryButtonText = "Confirm", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close }.ShowAsync() == ContentDialogResult.Primary;
    private void ShowError(string message) { Notice.Message = message; Notice.IsOpen = true; }
    private async void Options_Click(object sender, RoutedEventArgs args)
    {
        var show = new ToggleSwitch { Header = "Show Bookmarks section", IsOn = PreferenceStore.Shared.Value.LibraryShowBookmarksSection }; var layout = new ComboBox { Header = "Collections layout", ItemsSource = new[] { "horizontal", "vertical" }, SelectedItem = PreferenceStore.Shared.Value.LibraryCollectionLayout }; var panel = new StackPanel { Spacing = 16 }; panel.Children.Add(show); panel.Children.Add(layout); var accounts = new Button { Content = "Connected accounts" }; panel.Children.Add(accounts); ContentDialog? dialog = null; accounts.Click += (_, _) => { dialog?.Hide(); Frame.Navigate(typeof(AccountsPage)); }; dialog = new() { XamlRoot = XamlRoot, Title = "Library options", Content = panel, PrimaryButtonText = "Save", CloseButtonText = "Cancel" }; if (await dialog.ShowAsync() == ContentDialogResult.Primary) try { var p = PreferenceStore.Shared.Copy(); p.LibraryShowBookmarksSection = show.IsOn; p.LibraryCollectionLayout = layout.SelectedItem as string ?? "horizontal"; PreferenceStore.Shared.Save(p); if (_session is null) ShowLocal(); } catch (IOException e) { ShowError(e.Message); }
    }
    private void RemoteList_Changed(object sender, SelectionChangedEventArgs args) { if (!_updating && _session is not null) { _state.Offset = 0; _state.FocusId = null; _ = LoadRemoteAsync(); } }
    private void Refresh_Click(object sender, RoutedEventArgs args) => _ = LoadRemoteAsync(true);
    private async Task LoadRemoteAsync(bool refresh = false)
    {
        if (_session is not { } session) return; _load?.Cancel(); _load?.Dispose(); _load = new(); var token = _load.Token; var gen = ++_generation; var source = (RemoteList.SelectedItem as TrackerList)?.Id ?? "all"; Busy.Visibility = Visibility.Visible; Busy.IsIndeterminate = true; Notice.IsOpen = false;
        try
        {
            var result = await TrackerLibraryService.Shared.LoadAsync(session, source, Kind.SelectedIndex == 0 ? "movie" : "tv", token, refresh); if (token.IsCancellationRequested || gen != _generation) return; foreach (var row in _remote?.Entries ?? []) row.Title.ReleaseArtwork(); _remote = result;
            _updating = true; var choices = (session.Service == TrackerKind.Trakt ? new[] { new TrackerList("watchlist", "Watchlist"), new("history", "Watched history"), new("collection", "Collection") } : new[] { new TrackerList("all", "All anime") }).Concat(result.Lists.Select(l => new TrackerList("list:" + l.Id, l.Name))).ToArray(); RemoteList.ItemsSource = choices; RemoteList.SelectedItem = choices.FirstOrDefault(l => l.Id == source) ?? choices[0]; StatusFilter.ItemsSource = new[] { "All statuses" }.Concat(result.Entries.Select(e => e.Status).Distinct().Order()); StatusFilter.SelectedItem = ((IEnumerable<string>)StatusFilter.ItemsSource).FirstOrDefault(s => s == _state.Status) ?? "All statuses"; GenreFilter.ItemsSource = new[] { "All genres" }.Concat(result.Entries.SelectMany(e => e.Genres).Distinct().Order()); GenreFilter.SelectedItem = ((IEnumerable<string>)GenreFilter.ItemsSource).FirstOrDefault(s => s == _state.Genre) ?? "All genres"; _updating = false; ApplyFilter(); Restore(); if (result.Notice.Length > 0) ShowError(result.Notice);
        }
        catch (OperationCanceledException) { }
        catch (Exception e) when (e is TrackerException or TrackerUnauthorizedException) { if (gen == _generation) ShowError(e is TrackerUnauthorizedException ? "Reconnect this tracker to continue." : e.Message); }
        finally { if (gen == _generation) { Busy.IsIndeterminate = false; Busy.Visibility = Visibility.Collapsed; } }
    }
    private void Filter_Changed(object sender, RoutedEventArgs args) { if (!_updating) ApplyFilter(); }
    private void Filter_Changed(object sender, SelectionChangedEventArgs args) { if (!_updating) ApplyFilter(); }
    private void ApplyFilter()
    {
        if (_remote is null) return; var source = (RemoteList.SelectedItem as TrackerList)?.Id; var rows = _remote.Entries.Where(e => (string.IsNullOrWhiteSpace(Filter.Text) || e.Title.Title.Contains(Filter.Text, StringComparison.CurrentCultureIgnoreCase)) && (StatusFilter.SelectedIndex <= 0 || e.Status == StatusFilter.SelectedItem as string) && (GenreFilter.SelectedIndex <= 0 || e.Genres.Contains(GenreFilter.SelectedItem as string ?? "")) && (_session?.Service != TrackerKind.AniList || source is null || !source.StartsWith("list:") || e.CustomLists.Contains(source[5..]))).ToArray(); RemoteTitles.ItemsSource = rows; Empty.Text = rows.Length == 0 ? "No titles match this library view." : ""; Empty.Visibility = rows.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
    }
    private void Remote_RightTapped(object sender, RightTappedRoutedEventArgs args)
    {
        if (_session is not { } session || ItemAt<TrackerEntry>(args.OriginalSource) is not { } entry) return; RemoteMenu(session, entry).ShowAt(RemoteTitles, args.GetPosition(RemoteTitles)); args.Handled = true;
    }
    private MenuFlyout RemoteMenu(TrackerSession session, TrackerEntry entry)
    {
        var menu = new MenuFlyout(); if (session.Service != TrackerKind.Trakt) Add(menu, "Edit status, progress and score", () => EditAnimeAsync(session, entry)); else foreach (var action in new[] { "watchlist", "collection", "history", "ratings" }) { var captured = action; Add(menu, "Update " + action, () => EditTraktAsync(session, entry, captured)); }
        foreach (var list in _remote?.Lists ?? []) if (session.Service == TrackerKind.Trakt) { var captured = list; Add(menu, "Update " + list.Name, () => EditTraktAsync(session, entry, "list:" + captured.Id)); } else if (session.Service == TrackerKind.AniList) { var captured = list; Add(menu, "Update " + list.Name, () => EditAniListMembershipAsync(session, entry, captured)); }
        if (session.Service != TrackerKind.Trakt) Add(menu, "Remove from " + session.Service, async () => { if (await ConfirmAsync("Remove this tracker entry?", "Its remote status, progress and rating will be removed.")) { await TrackerLibraryService.Shared.RemoveAnimeAsync(session, entry, _load?.Token ?? default); await LoadRemoteAsync(true); } });
        Add(menu, "Choose different TMDB match", () => ChooseMatchAsync(session, entry)); Add(menu, "Add to local collection", async () => { var title = await TrackerMatchStore.Shared.ResolveAsync(session, entry, _load?.Token ?? default); await LibraryDialogs.MembershipAsync(XamlRoot, title, ct: _load?.Token ?? default); }); return menu;
    }
    private async Task ChooseMatchAsync(TrackerSession session, TrackerEntry entry)
    {
        using var cancellation = new CancellationTokenSource(); var search = new TextBox { Header = "TMDB title", Text = entry.Title.Title }; var button = new Button { Content = "Search" }; var results = new ListView { MaxHeight = 300, SelectionMode = ListViewSelectionMode.Single, DisplayMemberPath = "Title" }; var message = new TextBlock { TextWrapping = TextWrapping.Wrap }; var panel = new StackPanel { Spacing = 10 }; panel.Children.Add(search); panel.Children.Add(button); panel.Children.Add(message); panel.Children.Add(results);
        button.Click += async (_, _) => { button.IsEnabled = false; try { var page = await TmdbService.Shared.SearchAsync(entry.Title.MediaType, search.Text.Trim(), 1, cancellation.Token); results.ItemsSource = page.Titles; message.Text = page.Titles.Count == 0 ? "No matching titles." : "Select the correct title. This does not assert episode or season equivalence."; } catch (OperationCanceledException) { } catch (TmdbException e) { message.Text = e.Message; } finally { button.IsEnabled = true; } };
        var choice = await new ContentDialog { XamlRoot = XamlRoot, Title = "Choose TMDB match", Content = panel, PrimaryButtonText = "Use selected match", SecondaryButtonText = "Use automatic matching", CloseButtonText = "Cancel" }.ShowAsync(); cancellation.Cancel(); if (choice == ContentDialogResult.Primary && results.SelectedItem is MediaTitle selected) TrackerMatchStore.Shared.Set(session, entry, selected.Id); else if (choice == ContentDialogResult.Secondary) TrackerMatchStore.Shared.Set(session, entry, null);
    }
    private async Task EditAniListMembershipAsync(TrackerSession session, TrackerEntry entry, TrackerList list)
    {
        var member = entry.CustomLists.Contains(list.Name); if (await ConfirmAsync($"{(member ? "Remove from" : "Add to")} {list.Name}?", entry.Title.Title)) await TrackerLibraryService.Shared.SetAniListMembershipAsync(session, entry, list.Name, !member, _load?.Token ?? default); await LoadRemoteAsync(true);
    }
    private async Task EditAnimeAsync(TrackerSession session, TrackerEntry entry)
    {
        var statuses = session.Service == TrackerKind.AniList ? new[] { "CURRENT", "PLANNING", "COMPLETED", "DROPPED", "PAUSED", "REPEATING" } : new[] { "watching", "plan_to_watch", "completed", "dropped", "on_hold", "rewatching" }; var status = new ComboBox { Header = "Status", ItemsSource = statuses, SelectedItem = entry.Status }; var progress = new NumberBox { Header = "Episodes watched", Minimum = 0, Maximum = 100000, Value = entry.Progress, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact }; var score = new NumberBox { Header = "Tracker score (0 clears)", Minimum = 0, Maximum = 10, SmallChange = session.Service == TrackerKind.MAL ? 1 : .1, Value = entry.Score }; var panel = new StackPanel { Spacing = 12 }; panel.Children.Add(status); panel.Children.Add(progress); panel.Children.Add(score);
        if (await new ContentDialog { XamlRoot = XamlRoot, Title = entry.Title.Title, Content = panel, PrimaryButtonText = "Save to " + session.Service, CloseButtonText = "Cancel" }.ShowAsync() != ContentDialogResult.Primary) return;
        if (!double.IsFinite(progress.Value) || !double.IsFinite(score.Value)) throw new TrackerException("Enter valid progress and score values."); await TrackerLibraryService.Shared.EditAnimeAsync(session, entry, new((status.SelectedItem as string) == entry.Status ? null : status.SelectedItem as string, (int)progress.Value == entry.Progress ? null : (int)progress.Value, score.Value == entry.Score ? null : score.Value), _load?.Token ?? default); await LoadRemoteAsync(true);
    }
    private async Task EditTraktAsync(TrackerSession session, TrackerEntry entry, string action)
    {
        var current = await TrackerLibraryService.Shared.LoadAsync(session, action, entry.Title.MediaType, _load?.Token ?? default, true); if (!current.Complete) throw new TrackerException("This list is partial. Refresh before changing membership."); var existing = current.Entries.FirstOrDefault(e => e.RemoteId == entry.RemoteId); var add = new ComboBox { Header = "Action", ItemsSource = new[] { "Add / update", "Remove" }, SelectedIndex = existing is null ? 0 : 1 }; var score = new NumberBox { Header = "Trakt rating", Minimum = 1, Maximum = 10, Value = existing?.Score is > 0 ? existing.Score : 7 }; var panel = new StackPanel { Spacing = 12 }; panel.Children.Add(new TextBlock { Text = existing is null ? "Currently absent from this list." : action == "ratings" ? $"Your current Trakt rating: {existing.Score:0.#}" : "Currently in this list." }); panel.Children.Add(add); if (action == "ratings") panel.Children.Add(score); panel.Children.Add(new TextBlock { Text = action == "history" ? "This changes watched history on Trakt. A show action can affect all its episodes." : "This updates your connected Trakt account.", TextWrapping = TextWrapping.Wrap }); if (await new ContentDialog { XamlRoot = XamlRoot, Title = "Update " + action, Content = panel, PrimaryButtonText = "Confirm", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close }.ShowAsync() != ContentDialogResult.Primary) return; await TrackerLibraryService.Shared.SetTraktAsync(session, entry, action, add.SelectedIndex == 0, action == "ratings" ? score.Value : null, _load?.Token ?? default, expectedMember: existing is not null, expectedScore: action == "ratings" ? existing?.Score ?? 0 : null); await LoadRemoteAsync(true);
    }
}
