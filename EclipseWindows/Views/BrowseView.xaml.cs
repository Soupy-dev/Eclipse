using System.Collections.ObjectModel;
using System.Runtime.InteropServices;
using Eclipse.Windows.Models;
using Eclipse.Windows.Navigation;
using Eclipse.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Navigation;
using Windows.System;
using Windows.UI.ViewManagement;

namespace Eclipse.Windows.Views;

public sealed partial class BrowseView : UserControl
{
    private readonly ObservableCollection<MediaTitle> _results = [];
    private IReadOnlyList<MediaTitle> _homeTitles = [], _heroes = [];
    private readonly BitmapImage _heroImage = new() { DecodePixelType = DecodePixelType.Logical, DecodePixelWidth = 1280 };
    private readonly UISettings _uiSettings = new();
    private CancellationTokenSource? _loadCts;
    private int _generation, _page, _totalPages, _heroIndex;
    private string _category = "All", _query = "";
    private bool _searchOnly, _initialized, _active, _restoreFocus;
    private bool _loaded, _busy, _updatingControls, _retryAppend, _restorePending;
    private bool? _compact;
    private double _pageOffset, _spotlightOffset, _sceneryOffset, _gridOffset;
    private ListViewBase? _returnShelf;
    private string? _returnTitleId;
    private FocusState _returnFocusState = FocusState.Programmatic;
    private ScrollViewer? _spotlightScroll, _sceneryScroll;
    private bool IsHome => !_searchOnly && _category == "All" && _query.Length == 0;
    private string MediaType => _category == "Movie" ? "movie" : _category == "Series" ? "tv" : "multi";
    public event EventHandler<TitleRequestedEventArgs>? TitleRequested;
    public event EventHandler? SearchRequested;

    public BrowseView()
    {
        InitializeComponent();
        ResultsGrid.ItemsSource = _results;
        HeroArtwork.ImageSource = _heroImage;
        Loaded += Page_Loaded;
        Unloaded += Page_Unloaded;
        Spotlight.AddHandler(PointerWheelChangedEvent, new PointerEventHandler(Shelf_PointerWheelChanged), true);
        Scenery.AddHandler(PointerWheelChangedEvent, new PointerEventHandler(Shelf_PointerWheelChanged), true);
    }

    public void Enter(bool searchOnly, NavigationMode mode)
    {
        _active = true;
        _searchOnly = searchOnly;
        HeaderLayout.Visibility = searchOnly ? Visibility.Visible : Visibility.Collapsed;
        AutomationProperties.SetName(this, searchOnly ? "Search" : "Home");
        SearchTypePicker.Visibility = searchOnly ? Visibility.Visible : Visibility.Collapsed;
        if (!_initialized)
        {
            _initialized = true;
            _updatingControls = true;
            SearchTypePicker.SelectedIndex = 0;
            _updatingControls = false;
            if (searchOnly) ShowSearchLanding();
            else _ = LoadAsync(false);
        }
        else if (_loaded)
        {
            SetBusy(false);
            if (IsHome) ShowHero();
            _restorePending = true;
            _restoreFocus = mode == NavigationMode.Back;
        }
        else _ = LoadAsync(false);
    }

    private void ShowSearchLanding()
    {
        _loadCts?.Cancel();
        ++_generation;
        _results.Clear();
        _page = _totalPages = 0;
        _loaded = true;
        SetBusy(false);
        LoadError.IsOpen = false;
        HomeScroll.Visibility = Visibility.Collapsed;
        BrowsePanel.Visibility = Filters.Visibility = Visibility.Visible;
        EmptyText.Text = "Search movies and TV shows by title.";
        EmptyText.Visibility = Visibility.Visible;
        ResultCount.Text = "";
    }

    private async Task LoadAsync(bool append, bool refresh = false)
    {
        if (_searchOnly && _query.Length == 0) { ShowSearchLanding(); return; }
        _loadCts?.Cancel();
        _loadCts?.Dispose();
        _loadCts = new CancellationTokenSource();
        var token = _loadCts.Token;
        var generation = ++_generation;
        var type = MediaType;
        var query = _query;
        var nextPage = append ? _page + 1 : 1;
        _retryAppend = append;
        _restorePending = false;
        SetBusy(true);
        LoadError.IsOpen = false;
        EmptyText.Visibility = Visibility.Collapsed;
        if (!append)
        {
            _loaded = false;
            _heroImage.UriSource = null;
            _heroes = _homeTitles = [];
            Hero.Visibility = Visibility.Collapsed;
            _results.Clear();
            Spotlight.ItemsSource = Scenery.ItemsSource = null;
            _page = _totalPages = _heroIndex = 0;
            HomeScroll.ChangeView(null, 0, null, true);
            FindScrollViewer(ResultsGrid)?.ChangeView(null, 0, null, true);
        }
        HomeScroll.Visibility = IsHome ? Visibility.Visible : Visibility.Collapsed;
        BrowsePanel.Visibility = IsHome ? Visibility.Collapsed : Visibility.Visible;
        Filters.Visibility = !IsHome ? Visibility.Visible : Visibility.Collapsed;
        EmptyText.Text = "No titles found. Try another search or filter.";
        try
        {
            if (IsHome)
            {
                var trendingTask = TmdbService.Shared.BrowseAsync("all", "trending", 0, 1, token, refresh);
                var popularTask = TmdbService.Shared.BrowseAsync("movie", "popular", 0, 1, token, refresh);
                await Task.WhenAll(trendingTask, popularTask);
                if (generation != _generation || token.IsCancellationRequested) return;
                var trending = trendingTask.Result.Titles;
                var popular = popularTask.Result.Titles;
                _homeTitles = trending.Concat(popular).DistinctBy(title => title.Id).ToArray();
                _heroes = trending.Where(title => title.ArtworkUri is not null).Take(10).ToArray();
                SpotlightHeading.Text = "Trending this week";
                SpotlightCaption.Text = "Movies and series people are discovering.";
                Spotlight.ItemsSource = trending;
                Scenery.ItemsSource = popular;
                ShowHero();
                EmptyText.Visibility = _homeTitles.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            }
            else
            {
                var catalog = await TmdbService.Shared.SearchAsync(type, query, nextPage, token, refresh);
                if (generation != _generation || token.IsCancellationRequested) return;
                foreach (var title in catalog.Titles)
                    if (_results.Count < 100 && !_results.Any(value => value.Id == title.Id)) _results.Add(title);
                _page = catalog.Page;
                _totalPages = Math.Min(catalog.TotalPages, 5);
                ResultCount.Text = _results.Count == 0 ? "" : $"{_results.Count} titles" + (_page >= 5 && catalog.TotalPages > 5 ? " · Refine your search or filters to explore more" : "");
                EmptyText.Visibility = _results.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
                DispatcherQueue.TryEnqueue(UpdateGridLayout);
            }
            _loaded = true;
            DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, UpdateShelfButtons);
        }
        catch (OperationCanceledException) { }
        catch (TmdbException error) when (generation == _generation && !token.IsCancellationRequested)
        { LoadError.Message = error.Message; LoadError.IsOpen = true; }
        finally { if (generation == _generation && !token.IsCancellationRequested) SetBusy(false); }
    }

    private void SetBusy(bool busy)
    {
        _busy = busy;
        LoadingBar.IsIndeterminate = busy;
        LoadingBar.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        LoadMoreButton.IsEnabled = !busy;
        LoadMoreButton.Visibility = !IsHome && _loaded && _page < _totalPages && _results.Count < 100 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ShowHero()
    {
        Hero.Visibility = _heroes.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (_heroes.Count == 0) return;
        var title = _heroes[_heroIndex];
        HeroTitle.Text = title.Title;
        HeroMetadata.Text = $"{title.Subtitle}   ·   {title.Rating}";
        HeroSynopsis.Text = title.Synopsis;
        HeroPosition.Text = $"{_heroIndex + 1} / {_heroes.Count}";
        AutomationProperties.SetName(ExploreButton, $"View details for {title.Title}");
        _heroImage.UriSource = title.ArtworkUri;
    }

    private void Search_QuerySubmitted(AutoSuggestBox sender, AutoSuggestBoxQuerySubmittedEventArgs args)
    {
        _query = args.QueryText.Trim();
        if (_query.Length > 200) _query = _query[..200];
        _ = LoadAsync(false);
    }
    private void SearchType_Changed(object sender, SelectionChangedEventArgs args)
    {
        if (!_updatingControls && _active && SearchTypePicker.SelectedItem is ComboBoxItem { Tag: string category })
        { _category = category; _ = LoadAsync(false); }
    }
    private void Search_TextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (!_updatingControls && args.Reason == AutoSuggestionBoxTextChangeReason.UserInput && sender.Text.Length == 0 && _query.Length > 0)
        { _query = ""; _ = LoadAsync(false); }
    }
    private void Retry_Click(object sender, RoutedEventArgs args) => _ = LoadAsync(_retryAppend, true);
    private void LoadMore_Click(object sender, RoutedEventArgs args) { if (!_busy && _page < _totalPages) _ = LoadAsync(true); }
    private void PreviousHero_Click(object sender, RoutedEventArgs args) { if (_heroes.Count > 0) { _heroIndex = (_heroIndex - 1 + _heroes.Count) % _heroes.Count; ShowHero(); } }
    private void NextHero_Click(object sender, RoutedEventArgs args) { if (_heroes.Count > 0) { _heroIndex = (_heroIndex + 1) % _heroes.Count; ShowHero(); } }
    private void HeroInformation_Click(object sender, RoutedEventArgs args) { if (_heroes.Count > 0) RequestTitle(_heroes[_heroIndex], null); }
    private void Title_ItemClick(object sender, ItemClickEventArgs args) { if (args.ClickedItem is MediaTitle title) RequestTitle(title, sender as ListViewBase); }
    private void RequestTitle(MediaTitle title, ListViewBase? shelf)
    {
        _returnShelf = shelf;
        _returnTitleId = title.Id;
        _returnFocusState = (FocusManager.GetFocusedElement(XamlRoot) as Control)?.FocusState ?? FocusState.Programmatic;
        TitleRequested?.Invoke(this, new TitleRequestedEventArgs(title.Id));
    }

    public void CapturePosition()
    {
        _pageOffset = HomeScroll.VerticalOffset;
        _spotlightOffset = _spotlightScroll?.HorizontalOffset ?? 0;
        _sceneryOffset = _sceneryScroll?.HorizontalOffset ?? 0;
        _gridOffset = FindScrollViewer(ResultsGrid)?.VerticalOffset ?? 0;
    }
    public void Leave()
    { _active = false; _loadCts?.Cancel(); SetBusy(false); _heroImage.UriSource = null; }

    public void FocusSearch() => DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
    {
        if (_active && _searchOnly) SearchBox.Focus(FocusState.Keyboard);
    });

    private void SearchShortcut_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    { if (_searchOnly) SearchBox.Focus(FocusState.Keyboard); else SearchRequested?.Invoke(this, EventArgs.Empty); args.Handled = true; }
    private void Page_Loaded(object sender, RoutedEventArgs args)
    {
        _uiSettings.TextScaleFactorChanged += TextScaleFactor_Changed;
        UpdateShelfHeights();
        _spotlightScroll = FindScrollViewer(Spotlight);
        _sceneryScroll = FindScrollViewer(Scenery);
        if (_spotlightScroll is not null) _spotlightScroll.ViewChanged += Shelf_ViewChanged;
        if (_sceneryScroll is not null) _sceneryScroll.ViewChanged += Shelf_ViewChanged;
        UpdateShelfButtons();
        if (_restorePending) DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, RestoreHomePosition);
    }
    private void Page_Unloaded(object sender, RoutedEventArgs args)
    {
        _uiSettings.TextScaleFactorChanged -= TextScaleFactor_Changed;
        if (_spotlightScroll is not null) _spotlightScroll.ViewChanged -= Shelf_ViewChanged;
        if (_sceneryScroll is not null) _sceneryScroll.ViewChanged -= Shelf_ViewChanged;
    }
    private void RestoreHomePosition()
    {
        if (!_restorePending || !_active) return;
        _restorePending = false;
        Root.UpdateLayout();
        HomeScroll.ChangeView(null, _pageOffset, null, true);
        _spotlightScroll?.ChangeView(_spotlightOffset, null, null, true);
        _sceneryScroll?.ChangeView(_sceneryOffset, null, null, true);
        FindScrollViewer(ResultsGrid)?.ChangeView(null, _gridOffset, null, true);
        if (!_restoreFocus) { UpdateShelfButtons(); return; }
        var titles = IsHome ? _homeTitles : _results;
        if (_returnShelf is { } shelf && titles.FirstOrDefault(title => title.Id == _returnTitleId) is { } title)
        { shelf.ScrollIntoView(title); shelf.UpdateLayout(); if (shelf.ContainerFromItem(title) is Control card) card.Focus(_returnFocusState); }
        else if (IsHome && _heroes.Count > 0) ExploreButton.Focus(_returnFocusState);
        else SearchBox.Focus(_returnFocusState);
        UpdateShelfButtons();
    }
    private void Shelf_ContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    { if (!args.InRecycleQueue && args.Item is MediaTitle title) AutomationProperties.SetName(args.ItemContainer, title.AccessibleName); }
    private void Shelf_ViewChanged(object? sender, ScrollViewerViewChangedEventArgs args) => UpdateShelfButtons();
    private void UpdateShelfButtons()
    {
        SpotlightBack.IsEnabled = _spotlightScroll is { HorizontalOffset: > 0.5 };
        SpotlightForward.IsEnabled = _spotlightScroll is { } first && first.HorizontalOffset < first.ScrollableWidth - 0.5;
        SceneryBack.IsEnabled = _sceneryScroll is { HorizontalOffset: > 0.5 };
        SceneryForward.IsEnabled = _sceneryScroll is { } second && second.HorizontalOffset < second.ScrollableWidth - 0.5;
    }
    private void TextScaleFactor_Changed(UISettings sender, object args) => DispatcherQueue.TryEnqueue(UpdateShelfHeights);
    private void UpdateShelfHeights()
    {
        var extra = 80 * Math.Max(0, _uiSettings.TextScaleFactor - 1);
        Spotlight.Height = 310 + extra;
        Scenery.Height = 234 + extra;
        UpdateGridLayout();
    }
    private void ResultsGrid_SizeChanged(object sender, SizeChangedEventArgs args) => UpdateGridLayout();
    private void UpdateGridLayout()
    {
        if (ResultsGrid.ItemsPanelRoot is not ItemsWrapGrid panel || ResultsGrid.ActualWidth <= 0) return;
        var available = Math.Max(160, ResultsGrid.ActualWidth - 16);
        var columns = Math.Max(1, Math.Floor(available / 180));
        var width = available / columns;
        var height = (width - 16) * 1.5 + 84 + 80 * Math.Max(0, _uiSettings.TextScaleFactor - 1);
        if (Math.Abs(panel.ItemWidth - width) > 0.5) panel.ItemWidth = width;
        if (Math.Abs(panel.ItemHeight - height) > 0.5) panel.ItemHeight = height;
    }
    private void ShelfBack_Click(object sender, RoutedEventArgs args) => ScrollShelf(sender, -1);
    private void ShelfForward_Click(object sender, RoutedEventArgs args) => ScrollShelf(sender, 1);

    private void ScrollShelf(object sender, int direction)
    {
        var shelf = (sender as Button)?.Tag as string == "Scenery" ? Scenery : Spotlight;
        if (FindScrollViewer(shelf) is { } scroll)
            scroll.ChangeView(Math.Clamp(scroll.HorizontalOffset + direction * scroll.ViewportWidth * 0.8, 0, scroll.ScrollableWidth), null, null, true);
    }

    private void Shelf_PointerWheelChanged(object sender, PointerRoutedEventArgs args)
    {
        var pointer = args.GetCurrentPoint(this).Properties;
        if (pointer.IsHorizontalMouseWheel || pointer.MouseWheelDelta == 0 ||
            (args.KeyModifiers & VirtualKeyModifiers.Control) != 0) return;

        var scroll = (args.KeyModifiers & VirtualKeyModifiers.Shift) != 0
            ? (ReferenceEquals(sender, Spotlight) ? _spotlightScroll : _sceneryScroll)
            : HomeScroll;
        if (scroll is null) return;

        // Respect Windows' wheel preference, including zero lines and one page per notch.
        if (!SystemParametersInfo(0x0068, 0, out var lines, 0)) lines = 3;
        var horizontal = !ReferenceEquals(scroll, HomeScroll);
        var distance = pointer.MouseWheelDelta / 120.0 *
            (lines == uint.MaxValue ? (horizontal ? scroll.ViewportWidth : scroll.ViewportHeight) : lines * 16.0);
        if (horizontal)
            scroll.ChangeView(Math.Clamp(scroll.HorizontalOffset - distance, 0, scroll.ScrollableWidth), null, null, true);
        else
            scroll.ChangeView(null, Math.Clamp(scroll.VerticalOffset - distance, 0, scroll.ScrollableHeight), null, true);
        args.Handled = true;
    }

    [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SystemParametersInfo(uint action, uint parameter, out uint value, uint flags);

    private static ScrollViewer? FindScrollViewer(DependencyObject parent)
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
        {
            var child = VisualTreeHelper.GetChild(parent, i);
            if (child is ScrollViewer scroll) return scroll;
            if (FindScrollViewer(child) is { } descendant) return descendant;
        }
        return null;
    }

    private void PageLayout_SizeChanged(object sender, SizeChangedEventArgs args)
    {
        // A finite horizontal viewport preserves the ListView's ItemsStackPanel virtualization
        // even though the page itself scrolls vertically.
        if (args.NewSize.Width <= 0) return;
        if (Math.Abs(Spotlight.Width - args.NewSize.Width) > 0.5 || double.IsNaN(Spotlight.Width)) Spotlight.Width = args.NewSize.Width;
        if (Math.Abs(Scenery.Width - args.NewSize.Width) > 0.5 || double.IsNaN(Scenery.Width)) Scenery.Width = args.NewSize.Width;
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, UpdateShelfButtons);
    }

    private void Root_SizeChanged(object sender, SizeChangedEventArgs args)
    {
        if (args.NewSize.Width <= 0) return;
        var compact = args.NewSize.Width < 720;
        if (_compact == compact) return;
        _compact = compact;
        VisualStateManager.GoToState(this, compact ? "Compact" : "Wide", false);
    }
}



