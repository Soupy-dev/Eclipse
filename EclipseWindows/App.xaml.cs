using Microsoft.UI.Xaml;

namespace Eclipse.Windows;

public partial class App : Application
{
    private MainWindow? _window;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new MainWindow();
#if ECLIPSE_LOCAL_DIAGNOSTICS
        Diagnostics.StartupProbe.Attach(_window.Content);
#endif
        _window.Activate();
    }
}
