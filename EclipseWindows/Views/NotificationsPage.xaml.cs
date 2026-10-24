using Eclipse.Windows.Models;
using Eclipse.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Navigation;

namespace Eclipse.Windows.Views;

public sealed class NotificationRow
{
    public required string Title { get; init; }
    public required string Detail { get; init; }
    public string PrimaryLabel { get; init; } = "";
    public required string SecondaryLabel { get; init; }
    public required object Item { get; init; }
    public bool HasPrimary => PrimaryLabel.Length > 0;
    public string PrimaryName => $"{PrimaryLabel} {Title}";
    public string SecondaryName => $"{SecondaryLabel} {Title}";
}

public sealed partial class NotificationsPage : Page
{
    private readonly CancellationTokenSource _lifetime = new();
    private bool _setting, _busy;
    private int _historyLimit = 40;
    private string _section = "";
    private string? _serviceError;
    public event EventHandler<ScheduleEntry>? HistoryRequested;
    public NotificationsPage()
    {
        InitializeComponent();
        SettingsUI.Fit(Scroll, Form);
        Loaded += async (_, _) => { EpisodeReminderService.Shared.Changed += Changed; Render(); await RunAsync(() => EpisodeReminderService.Shared.SyncHistoryAsync()); };
        Unloaded += (_, _) => { EpisodeReminderService.Shared.Changed -= Changed; _lifetime.Cancel(); Busy.IsIndeterminate = RowsBusy.IsIndeterminate = false; };
    }
    protected override void OnNavigatedTo(NavigationEventArgs args)
    {
        base.OnNavigatedTo(args);
        _section = args.Parameter as string ?? "";
        var title = _section switch { "center" => "Notification Center", "following" => "Following", "episodes" => "Individual episodes", _ => "" };
        if (title.Length == 0) { _section = ""; return; }
        Scroll.Visibility = Visibility.Collapsed; Rows.Visibility = Visibility.Visible;
        RowsHeader.Trail = $"Settings|Notifications|{title}";
        RowsDescription.Text = _section switch
        {
            "center" => "Alerts observed in Windows Notification Center or opened from a notification. Recorded time is when Eclipse observed the alert.",
            "following" => "Each followed title can alert for upcoming episodes, future seasons, or both. Turning both options off removes the title from Following.",
            _ => "These are one-off episode choices. Automatic reminders from followed shows are managed separately under Following."
        };
    }
    private InfoBar CurrentNotice => _section.Length == 0 ? Notice : RowsNotice;
    private ProgressBar CurrentBusy => _section.Length == 0 ? Busy : RowsBusy;
    private void Changed(object? sender, EventArgs args) => DispatcherQueue.TryEnqueue(() => { if (IsLoaded) Render(); });
    private void Render()
    {
        _setting = true; var s = EpisodeReminderService.Shared.State;
        EpisodeLead.SelectedItem = EpisodeLead.Items.OfType<ComboBoxItem>().First(i => (string)i.Tag == s.LocalNotificationEpisodeLeadTime.ToString());
        SeasonLead.SelectedItem = SeasonLead.Items.OfType<ComboBoxItem>().First(i => (string)i.Tag == s.LocalNotificationSeasonLeadTime.ToString());
        Specials.IsOn = s.LocalNotificationIncludeAnimeSpecials; _setting = false;
        Pending.Text = $"{EpisodeReminderService.Shared.ScheduledCount} scheduled alerts · Up to 48 upcoming alerts are kept in Windows.";
        CenterSummary.Text = Count(s.History.Count, "No recent alerts", "recent alert", "recent alerts");
        FollowingSummary.Text = Count(s.Subscriptions.Count, "No shows", "show", "shows");
        EpisodesSummary.Text = Count(s.Reminders.Count, "No reminders", "reminder", "reminders");
        if (EpisodeReminderService.Shared.Error is { } error) { CurrentNotice.Message = error; CurrentNotice.IsOpen = true; }
        else if (CurrentNotice.Message == _serviceError) CurrentNotice.IsOpen = false;
        _serviceError = EpisodeReminderService.Shared.Error;
        if (_section.Length > 0) RenderRows();
    }
    private static string Count(int count, string empty, string singular, string plural) => count == 0 ? empty : $"{count} {(count == 1 ? singular : plural)}";
    private void RenderRows()
    {
        var state = EpisodeReminderService.Shared.State;
        var rows = (_section switch
        {
            "following" => state.Subscriptions.Select(item => new NotificationRow
            {
                Title = item.Title, PrimaryLabel = "Options", SecondaryLabel = "Remove", Item = item,
                Detail = string.Join(" · ", new[] { item.EpisodeNotifications ? "Upcoming episodes" : "", item.FutureSeasonNotifications ? "Future seasons" : "", item.MutedEpisodes.Count > 0 ? $"{item.MutedEpisodes.Count} muted episode keys" : "" }.Where(s => s.Length > 0))
            }),
            "episodes" => state.Reminders.OrderBy(r => r.Entry.AiringAt).Select(item => new NotificationRow
            {
                Title = item.Entry.Title, SecondaryLabel = "Remove", Item = item,
                Detail = $"{item.Entry.EpisodeLabel} · {(item.Entry.KnownTime ? item.Entry.AiringAt.ToLocalTime().ToString("g") : "Time withdrawn — waiting for an update")}"
            }),
            _ => state.History.Take(_historyLimit).Select(item => new NotificationRow
            {
                Title = item.Entry.Title, PrimaryLabel = "Open", SecondaryLabel = "Delete", Item = item,
                Detail = $"{item.Body}\nRecorded {item.RecordedAt.ToLocalTime():g}" + (item.WasOpened ? " · Opened" : "")
            })
        }).ToArray();
        var scroll = FindScroll(Rows); var offset = scroll?.VerticalOffset ?? 0;
        Rows.ItemsSource = rows;
        if (scroll is not null && offset > 0) DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => scroll.ChangeView(null, offset, null, true));
        RowsEmpty.Text = _section switch { "following" => "Follow shows from Notifications on their Details page.", "episodes" => "Use an episode's bell in Schedule to add an individual reminder.", _ => "No notifications recorded yet." };
        RowsEmpty.Visibility = rows.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        More.Visibility = _section == "center" && state.History.Count > _historyLimit ? Visibility.Visible : Visibility.Collapsed;
        ClearHistory.Visibility = _section == "center" && state.History.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }
    private async Task RunAsync(Func<Task> action)
    {
        if (_busy) return; _busy = true; SetBusy(true); CurrentNotice.IsOpen = false; CurrentBusy.Visibility = Visibility.Visible; CurrentBusy.IsIndeterminate = true;
        try { await action(); Access.Text = await EpisodeReminderService.Shared.AvailabilityAsync() ?? "Windows notifications are enabled for Eclipse."; }
        catch (OperationCanceledException) { }
        catch (Exception e) when (e is IOException or InvalidOperationException or ProviderException or TmdbException or System.Runtime.InteropServices.COMException)
        { if (IsLoaded) { CurrentNotice.Message = e.Message; CurrentNotice.IsOpen = true; } }
        finally { _busy = false; if (IsLoaded) { SetBusy(false); CurrentBusy.IsIndeterminate = false; CurrentBusy.Visibility = Visibility.Collapsed; Render(); } }
    }
    private void SetBusy(bool busy) { foreach (var control in new Control[] { Refresh, EpisodeLead, SeasonLead, Specials, CenterLink, FollowingLink, EpisodesLink, ClearSelections, ClearHistory, More, Rows }) control.IsEnabled = !busy; }
    private void Manage_Click(object sender, RoutedEventArgs args) { if (sender is Button { Tag: string section }) Frame.Navigate(typeof(NotificationsPage), section, new SuppressNavigationTransitionInfo()); }
    private async void RowPrimary_Click(object sender, RoutedEventArgs args)
    {
        if (sender is not FrameworkElement { DataContext: NotificationRow row }) return;
        if (row.Item is NotificationSubscription item) await RunAsync(async () => { if (await NotificationOptions.ShowAsync(XamlRoot, item)) await EpisodeReminderService.Shared.RefreshAsync(_lifetime.Token); });
        else if (row.Item is NotificationHistoryEntry entry)
        {
            await RunAsync(() => EpisodeReminderService.Shared.SyncHistoryAsync("eclipse-reminder=" + entry.RouteToken));
            if (IsLoaded) HistoryRequested?.Invoke(this, entry.Kind == "batch" ? entry.Entry with { Episode = 0, Id = "batch:" + entry.Entry.Id } : entry.Entry);
        }
    }
    private async void RowSecondary_Click(object sender, RoutedEventArgs args)
    {
        if (sender is not FrameworkElement { DataContext: NotificationRow row }) return;
        switch (row.Item)
        {
            case NotificationSubscription item: await RunAsync(() => EpisodeReminderService.Shared.RemoveFollowAsync(item.Id)); break;
            case EpisodeReminder item: await RunAsync(() => EpisodeReminderService.Shared.RemoveAsync(item.Id)); break;
            case NotificationHistoryEntry item: await RunAsync(() => EpisodeReminderService.Shared.DeleteHistoryAsync(item.Id)); break;
        }
    }
    private async void Timing_Changed(object sender, SelectionChangedEventArgs args)
    {
        if (_setting || !IsLoaded) return;
        if (((ComboBox)sender).SelectedItem is ComboBoxItem { Tag: string value }) await RunAsync(() => ReferenceEquals(sender,EpisodeLead) ? EpisodeReminderService.Shared.SetLeadAsync(int.Parse(value)) : EpisodeReminderService.Shared.SetSeasonLeadAsync(int.Parse(value)));
    }
    private async void Specials_Toggled(object sender, RoutedEventArgs args) { if (!_setting && IsLoaded) await RunAsync(() => EpisodeReminderService.Shared.SetSpecialsAsync(Specials.IsOn)); }
    private async void Refresh_Click(object sender, RoutedEventArgs args) => await RunAsync(() => EpisodeReminderService.Shared.RefreshAsync(_lifetime.Token));
    private async void SystemSettings_Click(object sender, RoutedEventArgs args) => await global::Windows.System.Launcher.LaunchUriAsync(new Uri("ms-settings:notifications"));
    private void More_Click(object sender, RoutedEventArgs args) { _historyLimit += 40; RenderRows(); }
    private void Page_SizeChanged(object sender, SizeChangedEventArgs args)
    { var padding = Rows.Padding; Rows.Padding = new Thickness(padding.Left, padding.Top, Math.Max(36, args.NewSize.Width - padding.Left - 1000), padding.Bottom); }
    private async Task<bool> ConfirmAsync(string title) => await new EclipseDialog { XamlRoot = XamlRoot, Title = title, PrimaryButtonText = "Remove", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close }.ShowAsync() == ContentDialogResult.Primary;
    private async void ClearSelections_Click(object sender, RoutedEventArgs args) { if (!_busy&&await ConfirmAsync(EpisodeReminderService.Shared.ReadError is null?"Remove all follows and individual reminders?":"Reset unreadable notifications? The original file will be preserved.")) await RunAsync(() => EpisodeReminderService.Shared.ClearSelectionsAsync()); }
    private async void ClearHistory_Click(object sender, RoutedEventArgs args) { if (!_busy&&await ConfirmAsync("Clear notification history?")) await RunAsync(() => EpisodeReminderService.Shared.ClearHistoryAsync()); }
    private static ScrollViewer? FindScroll(DependencyObject root)
    { for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) { var child = VisualTreeHelper.GetChild(root, i); if (child is ScrollViewer scroll) return scroll; if (FindScroll(child) is { } found) return found; } return null; }
}
