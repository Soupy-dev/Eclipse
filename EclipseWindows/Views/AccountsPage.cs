using Eclipse.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
namespace Eclipse.Windows.Views;

public sealed partial class AccountsPage : Page
{
    private readonly StackPanel _body = new() { Spacing = 16, Margin = new(24), MaxWidth = 900, HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly InfoBar _notice = new() { IsClosable = false };
    private CancellationTokenSource? _connect;
    public AccountsPage() { InitializeComponent(); Content = new ScrollViewer { Content = _body, Background = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["EclipsePageBrush"] }; }
    protected override void OnNavigatedTo(NavigationEventArgs args) { base.OnNavigatedTo(args); Render(); }
    protected override void OnNavigatedFrom(NavigationEventArgs args) { _connect?.Cancel(); base.OnNavigatedFrom(args); }
    private void Render()
    {
        _body.Children.Clear(); var back = new Button { Content = "Back" }; back.Click += (_, _) => { if (Frame.CanGoBack) Frame.GoBack(); }; _body.Children.Add(back); _body.Children.Add(new TextBlock { Text = "Connected accounts", FontSize = 28, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold }); _body.Children.Add(new TextBlock { Text = "Connect your own account to browse and manage its library. Sign-in opens your browser. Tokens are encrypted for this Windows user and kept on this device.", TextWrapping = TextWrapping.Wrap }); _body.Children.Add(_notice);
        foreach (var kind in Enum.GetValues<TrackerKind>())
        {
            var session = TrackerAccounts.Shared.Session(kind); var panel = new StackPanel { Spacing = 8, Padding = new(16) }; panel.Children.Add(new TextBlock { Text = kind.ToString(), FontSize = 20 }); panel.Children.Add(new TextBlock { Text = session is null ? "Not connected" : session.Name, TextWrapping = TextWrapping.Wrap }); var button = new Button { Content = session is null ? "Connect" : "Reconnect" }; panel.Children.Add(button); button.Click += async (_, _) => { _connect?.Cancel(); _connect?.Dispose(); _connect = new(); button.IsEnabled = false; _notice.Message = "Finish signing in in your browser. You can cancel here."; _notice.IsOpen = true; try { await TrackerAccounts.Shared.ConnectAsync(kind, _connect.Token); _notice.IsOpen = false; Render(); } catch (OperationCanceledException) { _notice.Message = "Sign-in cancelled."; } catch (Exception e) when (e is TrackerException or TrackerUnauthorizedException or IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException) { _notice.Message = e is TrackerUnauthorizedException ? "The provider rejected sign-in. Check the public-client registration and callback URI." : e is System.Runtime.InteropServices.COMException ? "Windows could not save the account credentials." : e.Message; } finally { button.IsEnabled = true; } };
            if (session is not null) { var disconnect = new Button { Content = "Disconnect" }; panel.Children.Add(disconnect); disconnect.Click += async (_, _) => { if (await new ContentDialog { XamlRoot = XamlRoot, Title = $"Disconnect {kind}?", Content = "Local collections and ratings are kept. The remote account is unchanged.", PrimaryButtonText = "Disconnect", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close }.ShowAsync() == ContentDialogResult.Primary) try { TrackerAccounts.Shared.Disconnect(kind); Render(); } catch (Exception e) when (e is IOException or System.Runtime.InteropServices.COMException) { _notice.Message = "Windows could not remove this connection. Try again."; _notice.IsOpen = true; } }; }
            _body.Children.Add(new Border { CornerRadius = new(10), Background = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"], Child = panel });
        }
        var cancel = new Button { Content = "Cancel sign-in" }; cancel.Click += (_, _) => _connect?.Cancel(); _body.Children.Add(cancel);
    }
}
