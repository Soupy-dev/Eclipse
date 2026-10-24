using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace Eclipse.Windows.Views;

public sealed partial class SearchPage : Page, IBrowsePage
{
    public BrowseView Browser => BrowseContent;
    public SearchPage() => InitializeComponent();
    protected override void OnNavigatedTo(NavigationEventArgs args)
    { base.OnNavigatedTo(args); Frame.Navigated -= Frame_Navigated; Browser.Enter(args.NavigationMode); }
    protected override void OnNavigatingFrom(NavigatingCancelEventArgs args)
    { Browser.CapturePosition(); base.OnNavigatingFrom(args); }
    protected override void OnNavigatedFrom(NavigationEventArgs args)
    {
        Browser.Leave();
        if (args.SourcePageType == typeof(DetailsPage) || args.SourcePageType == typeof(BrowsePage)) { Frame.Navigated -= Frame_Navigated; Frame.Navigated += Frame_Navigated; }
        else Browser.ReleaseArtwork();
        base.OnNavigatedFrom(args);
    }
    private void Frame_Navigated(object sender, NavigationEventArgs args)
    {
        if (ReferenceEquals(args.Content, this)) { Frame.Navigated -= Frame_Navigated; return; }
        if (args.Content is DetailsPage or BrowsePage) return;
        ((Frame)sender).Navigated -= Frame_Navigated; Browser.ReleaseArtwork();
    }
}
