using Eclipse.Windows.Models;
using Eclipse.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Eclipse.Windows.Views;

public sealed partial class ScheduleReminderButton : UserControl
{
    public static readonly DependencyProperty RowProperty = DependencyProperty.Register(nameof(Row), typeof(ScheduleDisplayRow), typeof(ScheduleReminderButton), new PropertyMetadata(null, (d, _) => ((ScheduleReminderButton)d).Refresh()));
    public ScheduleDisplayRow? Row { get => (ScheduleDisplayRow?)GetValue(RowProperty); set => SetValue(RowProperty, value); }
    private bool _busy;
    public ScheduleReminderButton()
    {
        InitializeComponent();
        Loaded += (_, _) => { EpisodeReminderService.Shared.Changed += Changed; Refresh(); };
        Unloaded += (_, _) => EpisodeReminderService.Shared.Changed -= Changed;
    }
    private void Changed(object? sender, EventArgs args) => DispatcherQueue.TryEnqueue(() => { if (IsLoaded) Refresh(); });
    private void Refresh()
    {
        if (Bell is null || Row is null) return;
        var state = EpisodeReminderService.Shared.Status(Row.Entry);
        Bell.Visibility = state == EpisodeNotificationState.Unavailable ? Visibility.Collapsed : Visibility.Visible;
        Bell.IsEnabled = !_busy;
        Glyph.Glyph = state switch { EpisodeNotificationState.Explicit => "\uE73E", EpisodeNotificationState.Followed => "\uEA8F", EpisodeNotificationState.Muted => "\uE7ED", _ => "\uEA8F" };
        var selected=state is EpisodeNotificationState.Explicit or EpisodeNotificationState.Followed;
        Glyph.Visibility=selected?Visibility.Collapsed:Visibility.Visible;SelectedGlyph.Visibility=selected?Visibility.Visible:Visibility.Collapsed;SelectedGlyph.Glyph=Glyph.Glyph;
        var action = state switch { EpisodeNotificationState.Explicit => "Remove reminder", EpisodeNotificationState.Followed => "Mute this episode", EpisodeNotificationState.Muted => "Restore this episode", _ => "Remind me" };
        AutomationProperties.SetName(Bell, $"{action}: {Row.Title}, {Row.Episode}"); ToolTipService.SetToolTip(Bell, action);
    }
    private async void Bell_Click(object sender, RoutedEventArgs args)
    {
        if (_busy || Row is null) return;
        _busy = true; Refresh(); var entry = Row.Entry;
        try { await EpisodeReminderService.Shared.ToggleAsync(entry); }
        catch (Exception e) when (e is InvalidOperationException or IOException)
        { if (IsLoaded) await new ContentDialog { XamlRoot = XamlRoot, Title = "Notifications", Content = e.Message, CloseButtonText = "Close" }.ShowAsync(); }
        finally { _busy = false; if (IsLoaded) Refresh(); }
    }
}
