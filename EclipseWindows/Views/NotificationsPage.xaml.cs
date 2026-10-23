using Eclipse.Windows.Models;
using Eclipse.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Eclipse.Windows.Views;

public sealed partial class NotificationsPage : Page
{
    private readonly CancellationTokenSource _lifetime = new();
    private bool _setting, _busy;
    private int _historyLimit = 40;
    private string? _serviceError;
    public event EventHandler<ScheduleEntry>? HistoryRequested;
    public NotificationsPage()
    {
        InitializeComponent();
        SettingsUI.Fit(Scroll, Form);
        Loaded += async (_, _) => { EpisodeReminderService.Shared.Changed += Changed; Render(); await RunAsync(() => EpisodeReminderService.Shared.SyncHistoryAsync()); };
        Unloaded += (_, _) => { EpisodeReminderService.Shared.Changed -= Changed; _lifetime.Cancel(); Busy.IsIndeterminate = false; };
    }
    private void Changed(object? sender, EventArgs args) => DispatcherQueue.TryEnqueue(() => { if (IsLoaded) Render(); });
    private void Render()
    {
        _setting = true; var s = EpisodeReminderService.Shared.State;
        EpisodeLead.SelectedItem = EpisodeLead.Items.OfType<ComboBoxItem>().First(i => (string)i.Tag == s.LocalNotificationEpisodeLeadTime.ToString());
        SeasonLead.SelectedItem = SeasonLead.Items.OfType<ComboBoxItem>().First(i => (string)i.Tag == s.LocalNotificationSeasonLeadTime.ToString());
        Specials.IsOn = s.LocalNotificationIncludeAnimeSpecials; _setting = false;
        Pending.Text = $"{EpisodeReminderService.Shared.ScheduledCount} scheduled alerts · Up to 48 upcoming alerts are kept in Windows.";
        if (EpisodeReminderService.Shared.Error is { } error) { Notice.Message = error; Notice.IsOpen = true; }
        else if(Notice.Message==_serviceError)Notice.IsOpen=false;
        _serviceError=EpisodeReminderService.Shared.Error;
        if (Following.IsExpanded) RenderFollowing(); if (Individual.IsExpanded) RenderEpisodes(); if (Center.IsExpanded) RenderHistory();
    }
    private async Task RunAsync(Func<Task> action)
    {
        if (_busy) return; _busy = true; SetBusy(true);Notice.IsOpen=false; Busy.Visibility = Visibility.Visible; Busy.IsIndeterminate = true;
        try { await action(); Access.Text = await EpisodeReminderService.Shared.AvailabilityAsync() ?? "Windows notifications are enabled for Eclipse."; }
        catch (OperationCanceledException) { }
        catch (Exception e) when (e is IOException or InvalidOperationException or ProviderException or TmdbException or System.Runtime.InteropServices.COMException)
        { if (IsLoaded) { Notice.Message = e.Message; Notice.IsOpen = true; } }
        finally { _busy = false; if (IsLoaded) { SetBusy(false); Busy.IsIndeterminate = false; Busy.Visibility = Visibility.Collapsed; Render(); } }
    }
    private void SetBusy(bool busy){foreach(var control in new Control[]{Refresh,EpisodeLead,SeasonLead,Specials,Following,Individual,Center,ClearSelections})control.IsEnabled=!busy;}
    private static TextBlock Label(string text, bool heading = false) => heading ? new() { Text = text, TextWrapping = TextWrapping.Wrap, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold } : new() { Text = text, Style = (Style)Application.Current.Resources["SettingsDescriptionStyle"] };
    private static StackPanel Row(StackPanel parent, string title, string subtitle)
    {
        var row = new StackPanel { Spacing = 8 };
        row.Children.Add(Label(title, true)); row.Children.Add(Label(subtitle));
        parent.Children.Add(new Border { Style = (Style)Application.Current.Resources["SettingsCardStyle"], Child = row }); return row;
    }
    private void RenderFollowing()
    {
        Follows.Children.Clear(); var items = EpisodeReminderService.Shared.State.Subscriptions;
        if (items.Count == 0) Follows.Children.Add(Label("Follow shows from Notifications on their Details page."));
        foreach (var item in items)
        {
            var row = Row(Follows, item.Title, string.Join(" · ", new[] { item.EpisodeNotifications ? "Upcoming episodes" : "", item.FutureSeasonNotifications ? "Future seasons" : "", item.MutedEpisodes.Count > 0 ? $"{item.MutedEpisodes.Count} muted episode keys" : "" }.Where(s => s.Length > 0)));
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 }; row.Children.Add(buttons);
            var options = new Button { Content = "Options" }; options.Click += async (_, _) => await RunAsync(async () => { if (await NotificationOptions.ShowAsync(XamlRoot, item)) await EpisodeReminderService.Shared.RefreshAsync(_lifetime.Token); }); buttons.Children.Add(options);
            var remove = new Button { Content = "Remove" }; remove.Click += async (_, _) => await RunAsync(() => EpisodeReminderService.Shared.RemoveFollowAsync(item.Id)); buttons.Children.Add(remove);
        }
    }
    private void RenderEpisodes()
    {
        Episodes.Children.Clear(); var items = EpisodeReminderService.Shared.State.Reminders;
        if (items.Count == 0) Episodes.Children.Add(Label("Use an episode's bell in Schedule to add an individual reminder."));
        foreach (var item in items.OrderBy(r => r.Entry.AiringAt))
        {
            var row = Row(Episodes, item.Entry.Title, $"{item.Entry.EpisodeLabel} · {(item.Entry.KnownTime ? item.Entry.AiringAt.ToLocalTime().ToString("g") : "Time withdrawn — waiting for an update")}");
            var remove = new Button { Content = "Remove", HorizontalAlignment = HorizontalAlignment.Left }; remove.Click += async (_, _) => await RunAsync(() => EpisodeReminderService.Shared.RemoveAsync(item.Id)); row.Children.Add(remove);
        }
    }
    private void RenderHistory()
    {
        History.Children.Clear(); var items = EpisodeReminderService.Shared.State.History;
        if (items.Count == 0) History.Children.Add(Label("No notifications recorded yet."));
        foreach (var item in items.Take(_historyLimit))
        {
            var row = Row(History, item.Entry.Title, $"{item.Body}\nRecorded {item.RecordedAt.ToLocalTime():g}" + (item.WasOpened ? " · Opened" : ""));
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 }; row.Children.Add(buttons);
            var open = new Button { Content = "Open" }; open.Click += async (_, _) => { await RunAsync(() => EpisodeReminderService.Shared.SyncHistoryAsync("eclipse-reminder=" + item.RouteToken)); if (IsLoaded) HistoryRequested?.Invoke(this, item.Kind=="batch"?item.Entry with{Episode=0,Id="batch:"+item.Entry.Id}:item.Entry); }; buttons.Children.Add(open);
            var delete = new Button { Content = "Delete" }; delete.Click += async (_, _) => await RunAsync(() => EpisodeReminderService.Shared.DeleteHistoryAsync(item.Id)); buttons.Children.Add(delete);
        }
        More.Visibility = items.Count > _historyLimit ? Visibility.Visible : Visibility.Collapsed;
    }
    private async void Timing_Changed(object sender, SelectionChangedEventArgs args)
    {
        if (_setting || !IsLoaded) return;
        if (((ComboBox)sender).SelectedItem is ComboBoxItem { Tag: string value }) await RunAsync(() => ReferenceEquals(sender,EpisodeLead) ? EpisodeReminderService.Shared.SetLeadAsync(int.Parse(value)) : EpisodeReminderService.Shared.SetSeasonLeadAsync(int.Parse(value)));
    }
    private async void Specials_Toggled(object sender, RoutedEventArgs args) { if (!_setting && IsLoaded) await RunAsync(() => EpisodeReminderService.Shared.SetSpecialsAsync(Specials.IsOn)); }
    private async void Refresh_Click(object sender, RoutedEventArgs args) => await RunAsync(() => EpisodeReminderService.Shared.RefreshAsync(_lifetime.Token));
    private async void SystemSettings_Click(object sender, RoutedEventArgs args) => await global::Windows.System.Launcher.LaunchUriAsync(new Uri("ms-settings:notifications"));
    private void Section_Expanding(Expander sender, ExpanderExpandingEventArgs args) { if (sender == Following) RenderFollowing(); else if (sender == Individual) RenderEpisodes(); else RenderHistory(); }
    private void More_Click(object sender, RoutedEventArgs args) { _historyLimit += 40; RenderHistory(); }
    private async Task<bool> ConfirmAsync(string title) => await new ContentDialog { XamlRoot = XamlRoot, Title = title, PrimaryButtonText = "Remove", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close }.ShowAsync() == ContentDialogResult.Primary;
    private async void ClearSelections_Click(object sender, RoutedEventArgs args) { if (!_busy&&await ConfirmAsync(EpisodeReminderService.Shared.ReadError is null?"Remove all follows and individual reminders?":"Reset unreadable notifications? The original file will be preserved.")) await RunAsync(() => EpisodeReminderService.Shared.ClearSelectionsAsync()); }
    private async void ClearHistory_Click(object sender, RoutedEventArgs args) { if (!_busy&&await ConfirmAsync("Clear notification history?")) await RunAsync(() => EpisodeReminderService.Shared.ClearHistoryAsync()); }
}
