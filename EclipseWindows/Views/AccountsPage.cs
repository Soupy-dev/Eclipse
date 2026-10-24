using Eclipse.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
namespace Eclipse.Windows.Views;

public sealed partial class AccountsPage : Page
{
    private readonly StackPanel _body = new() { Margin = new(36, 28, 36, 48), HorizontalAlignment = HorizontalAlignment.Left };
    private readonly InfoBar _notice = new() { IsClosable = false, Margin = new(0, 16, 0, 0) };
    private readonly Button _cancel = new() { Content = "Cancel sign-in" };
    private CancellationTokenSource? _connect;
    public AccountsPage()
    {
        InitializeComponent();
        var scroll = new ScrollViewer { Content = _body, Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent), HorizontalScrollMode = ScrollMode.Disabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        Content = scroll; SettingsUI.Fit(scroll, _body); _cancel.Click += (_, _) => _connect?.Cancel();
    }
    protected override void OnNavigatedTo(NavigationEventArgs args) { base.OnNavigatedTo(args); Render(); }
    protected override void OnNavigatedFrom(NavigationEventArgs args) { _connect?.Cancel(); base.OnNavigatedFrom(args); }
    private static string ServiceName(TrackerKind kind) => kind == TrackerKind.MAL ? "MyAnimeList" : kind.ToString();
    private void Render()
    {
        _body.Children.Clear(); _body.Children.Add(new SettingsHeader { Trail = "Settings|Connected accounts" }); _body.Children.Add(_notice);
        _body.Children.Add(SettingsUI.Note("Connect your own account to browse and manage its library. Sign-in opens your browser. Tokens are encrypted for this Windows user and kept on this device."));
        _body.Children.Add(SettingsUI.Section("Accounts"));
        var group = SettingsUI.Group();
        foreach (var kind in Enum.GetValues<TrackerKind>())
        {
            var session = TrackerAccounts.Shared.Session(kind); var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            var button = new Button { Content = session is null ? "Connect" : "Reconnect" }; buttons.Children.Add(button);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, $"{(session is null ? "Connect" : "Reconnect")} {ServiceName(kind)}");
            button.Click += async (_, _) => { _connect?.Cancel(); _connect?.Dispose(); _connect = new(); button.IsEnabled = false; _notice.Severity = InfoBarSeverity.Informational; _notice.Message = "Finish signing in in your browser."; _notice.ActionButton = _cancel; _notice.IsOpen = true; try { await TrackerAccounts.Shared.ConnectAsync(kind, _connect.Token); _notice.IsOpen = false; Render(); } catch (OperationCanceledException) { _notice.Message = "Sign-in cancelled."; _notice.ActionButton = null; } catch (Exception e) when (e is TrackerException or TrackerUnauthorizedException or IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException) { _notice.Severity = InfoBarSeverity.Warning; _notice.ActionButton = null; _notice.Message = e is TrackerUnauthorizedException ? "The provider rejected sign-in. Check the public-client registration and callback URI." : e is System.Runtime.InteropServices.COMException ? "Windows could not save the account credentials." : e.Message; } finally { button.IsEnabled = true; } };
            if (session is not null) { var disconnect = new Button { Content = "Disconnect" }; Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(disconnect, $"Disconnect {ServiceName(kind)}"); buttons.Children.Add(disconnect); disconnect.Click += async (_, _) => { if (await new EclipseDialog { XamlRoot = XamlRoot, Title = $"Disconnect {ServiceName(kind)}?", Content = "Local collections and ratings are kept. The remote account is unchanged.", PrimaryButtonText = "Disconnect", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close }.ShowAsync() == ContentDialogResult.Primary) try { TrackerAccounts.Shared.Disconnect(kind); Render(); } catch (Exception e) when (e is IOException or System.Runtime.InteropServices.COMException) { _notice.Severity = InfoBarSeverity.Warning; _notice.ActionButton = null; _notice.Message = "Windows could not remove this connection. Try again."; _notice.IsOpen = true; } }; }
            group.Children.Add(SettingsUI.Card(ServiceName(kind), session is null ? "Not connected" : $"Connected as {session.Name}", buttons));
        }
        _body.Children.Add(group);
    }
}
