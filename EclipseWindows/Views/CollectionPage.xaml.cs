using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace Eclipse.Windows.Views;

public sealed partial class CollectionPage : Page
{
    public event EventHandler? BrowseRequested;
    public CollectionPage() => InitializeComponent();
    protected override void OnNavigatedTo(NavigationEventArgs args)
    {
        base.OnNavigatedTo(args);
        var destination = args.Parameter as string ?? "Library";
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, destination);
        (EmptyIcon.Glyph, EmptyTitle.Text, EmptyDescription.Text) = destination switch
        {
            "Schedule" => ("\uE787", "Nothing scheduled", "Your followed series and upcoming episodes will appear here. Schedule support on Windows is still being built."),
            "Downloads" => ("\uE896", "No downloads", "Downloaded movies and episodes will appear here. Downloading on Windows is not available yet."),
            _ => ("\uE8F1", "Your library is empty", "Saved titles and viewing history will appear here when library support is available on Windows.")
        };
    }
    private void Browse_Click(object sender, RoutedEventArgs args) => BrowseRequested?.Invoke(this, EventArgs.Empty);
}
