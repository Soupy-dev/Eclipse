using System.Collections.ObjectModel;
using Eclipse.Windows.Models;
using Eclipse.Windows.Navigation;
using Eclipse.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using Windows.UI.ViewManagement;

namespace Eclipse.Windows.Views;

public sealed partial class BrowseView : UserControl
{
    private readonly ObservableCollection<MediaTitle> _results = [];
    private readonly UISettings _uiSettings = new();
    private CancellationTokenSource? _loadCts, _randomCts;
    private int _generation, _page, _totalPages;
    private string _category = "All", _query = "";
    private bool _active, _restoreFocus, _busy, _retryAppend, _restorePending, _released;
    private bool? _compact;
    private double _gridOffset;
    private string? _returnTitleId;
    private FocusState _returnFocusState = FocusState.Programmatic;
    private string MediaType => _category == "Movie" ? "movie" : _category == "Series" ? "tv" : "multi";
    public event EventHandler<TitleRequestedEventArgs>? TitleRequested;
    public event EventHandler? BrowseRequested;

    public BrowseView()
    {
        InitializeComponent();
        ResultsGrid.ItemsSource = _results;
        SearchTypePicker.SelectedIndex = 0;
        Loaded += (_, _) => { _uiSettings.TextScaleFactorChanged += TextScaleFactor_Changed; UpdateGridLayout(); if (_restorePending) DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, RestorePosition); };
        Unloaded += (_, _) => _uiSettings.TextScaleFactorChanged -= TextScaleFactor_Changed;
    }

    public void Enter(NavigationMode mode)
    {
        _active = true;
        if (_released) { _released = false; ResultsGrid.ItemsSource = _results; }
        _restorePending = _results.Count > 0;
        _restoreFocus = mode == NavigationMode.Back;
        if (_query.Length == 0) ShowLanding();
        else if (_page == 0 && !_busy && !LoadError.IsOpen) _ = LoadAsync(false);
    }

    private void ShowLanding()
    {
        _loadCts?.Cancel();
        ++_generation;
        PosterImages.Clear(ResultsGrid);
        _results.Clear();
        _page = _totalPages = 0;
        SetBusy(false);
        LoadError.IsOpen = false;
        BrowsePanel.Visibility = Visibility.Collapsed;
        SearchTypePicker.Visibility = Visibility.Collapsed;
        EmptyText.Visibility = Visibility.Collapsed;
        ResultCount.Text = "";
    }

    private async Task LoadAsync(bool append, bool refresh = false)
    {
        if (_query.Length == 0) { ShowLanding(); return; }
        _loadCts?.Cancel();
        _loadCts?.Dispose();
        _loadCts = new CancellationTokenSource();
        var token = _loadCts.Token;
        var generation = ++_generation;
        var nextPage = append ? _page + 1 : 1;
        _retryAppend = append;
        _restorePending = false;
        SetBusy(true);
        LoadError.IsOpen = false;
        EmptyText.Visibility = Visibility.Collapsed;
        SearchTypePicker.Visibility = BrowsePanel.Visibility = Visibility.Visible;
        if (!append)
        {
            ResultCount.Text = "";
            PosterImages.Clear(ResultsGrid);
            _results.Clear();
            _page = _totalPages = 0;
            FindScrollViewer(ResultsGrid)?.ChangeView(null, 0, null, true);
        }
        try
        {
            var catalog = await TmdbService.Shared.SearchAsync(MediaType, _query, nextPage, token, refresh);
            if (generation != _generation || token.IsCancellationRequested) return;
            foreach (var title in catalog.Titles)
                if (_results.Count < 100 && !_results.Any(value => value.Id == title.Id)) _results.Add(title);
            _page = catalog.Page;
            _totalPages = Math.Min(catalog.TotalPages, 5);
            ResultCount.Text = _results.Count == 0 ? "" : $"{_results.Count} titles" + (_page >= 5 && catalog.TotalPages > 5 ? " · Refine your search or filters to explore more" : "");
            EmptyText.Visibility = _results.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            DispatcherQueue.TryEnqueue(UpdateGridLayout);
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
        LoadMoreButton.Visibility = !busy && _page > 0 && _page < _totalPages && _results.Count < 100 ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void Random_Click(object sender, RoutedEventArgs args)
    {
        if (_randomCts is not null) return;
        _randomCts = new CancellationTokenSource();
        RandomButton.IsEnabled = false; RandomIcon.Visibility = Visibility.Collapsed; RandomBusy.Visibility = Visibility.Visible; RandomBusy.IsActive = true;
        string? failure = null;
        try
        {
            var trending = await TmdbService.Shared.BrowseAsync("all", "trending", 0, 1, _randomCts.Token);
            if (trending.Titles.Count == 0) failure = "No eligible movies or TV shows were available.";
            else if (_active) RequestTitle(trending.Titles[System.Random.Shared.Next(trending.Titles.Count)]);
        }
        catch (OperationCanceledException) { }
        catch (TmdbException error) { failure = error.Message; }
        finally
        {
            _randomCts.Dispose(); _randomCts = null;
            RandomButton.IsEnabled = true; RandomBusy.IsActive = false; RandomBusy.Visibility = Visibility.Collapsed; RandomIcon.Visibility = Visibility.Visible;
        }
        if (failure is not null && _active && XamlRoot is not null)
            await new EclipseDialog { XamlRoot = XamlRoot, Title = "Couldn't Find a Random Title", Content = failure, CloseButtonText = "OK" }.ShowAsync();
    }

    private void Browse_Click(object sender, RoutedEventArgs args) => BrowseRequested?.Invoke(this, EventArgs.Empty);
    private void Search_QuerySubmitted(AutoSuggestBox sender, AutoSuggestBoxQuerySubmittedEventArgs args)
    {
        _query = args.QueryText.Trim();
        if (_query.Length > 200) _query = _query[..200];
        _ = LoadAsync(false);
    }
    private void SearchType_Changed(object sender, SelectionChangedEventArgs args)
    {
        if (_active && SearchTypePicker.SelectedItem is ComboBoxItem { Tag: string category } && category != _category)
        { _category = category; _ = LoadAsync(false); }
    }
    private void Search_TextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (args.Reason == AutoSuggestionBoxTextChangeReason.UserInput && sender.Text.Length == 0 && _query.Length > 0)
        { _query = ""; ShowLanding(); }
    }
    private void Retry_Click(object sender, RoutedEventArgs args) => _ = LoadAsync(_retryAppend, true);
    private void LoadMore_Click(object sender, RoutedEventArgs args) { if (!_busy && _page < _totalPages) _ = LoadAsync(true); }
    private void Title_ItemClick(object sender, ItemClickEventArgs args) { if (args.ClickedItem is MediaTitle title) RequestTitle(title); }
    private void RequestTitle(MediaTitle title)
    {
        _returnTitleId = title.Id;
        _returnFocusState = (FocusManager.GetFocusedElement(XamlRoot) as Control)?.FocusState ?? FocusState.Programmatic;
        TitleRequested?.Invoke(this, new TitleRequestedEventArgs(title.Id));
    }

    public void CapturePosition() => _gridOffset = FindScrollViewer(ResultsGrid)?.VerticalOffset ?? 0;
    public void Leave()
    { _active = false; _loadCts?.Cancel(); _randomCts?.Cancel(); SetBusy(false); }
    public void ReleaseArtwork()
    {
        if (_released) return;
        _released = true; PosterImages.Clear(ResultsGrid); ResultsGrid.ItemsSource = null;
    }

    public void FocusSearch() => DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
    {
        if (_active) SearchBox.Focus(FocusState.Keyboard);
    });

    private void SearchShortcut_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    { SearchBox.Focus(FocusState.Keyboard); args.Handled = true; }
    private void RestorePosition()
    {
        if (!_restorePending || !_active) return;
        _restorePending = false;
        Root.UpdateLayout();
        FindScrollViewer(ResultsGrid)?.ChangeView(null, _gridOffset, null, true);
        if (!_restoreFocus) return;
        if (_results.FirstOrDefault(title => title.Id == _returnTitleId) is { } title)
        { ResultsGrid.ScrollIntoView(title); ResultsGrid.UpdateLayout(); if (ResultsGrid.ContainerFromItem(title) is Control card) card.Focus(_returnFocusState); }
        else SearchBox.Focus(_returnFocusState);
    }
    private void Results_ContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (!args.InRecycleQueue && args.Item is MediaTitle title) AutomationProperties.SetName(args.ItemContainer, title.AccessibleName);
        PosterImages.Update(args, (args.Item as MediaTitle)?.PosterUri, ResultsGrid.ItemsPanelRoot is ItemsWrapGrid panel ? (panel.ItemWidth - 16) * 1.5 : 246);
    }
    private void TextScaleFactor_Changed(UISettings sender, object args) => DispatcherQueue.TryEnqueue(UpdateGridLayout);
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

    private void Root_SizeChanged(object sender, SizeChangedEventArgs args)
    {
        if (args.NewSize.Width <= 0) return;
        var compact = args.NewSize.Width < 720;
        if (_compact == compact) return;
        _compact = compact;
        HeaderLayout.Margin = compact ? new Thickness(16, 20, 16, 12) : new Thickness(32, 24, 32, 12);
        BrowsePanel.Margin = compact ? new Thickness(8, 0, 8, 16) : new Thickness(24, 0, 24, 20);
    }
}
