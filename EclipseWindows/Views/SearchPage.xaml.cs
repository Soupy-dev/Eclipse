using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace Eclipse.Windows.Views;

public sealed partial class SearchPage : Page, IBrowsePage
{
    public BrowseView Browser => BrowseContent;
    public SearchPage() => InitializeComponent();
    protected override void OnNavigatedTo(NavigationEventArgs args)
    { base.OnNavigatedTo(args); Browser.Enter(true, args.NavigationMode); }
    protected override void OnNavigatingFrom(NavigatingCancelEventArgs args)
    { Browser.CapturePosition(); base.OnNavigatingFrom(args); }
    protected override void OnNavigatedFrom(NavigationEventArgs args)
    { Browser.Leave(); base.OnNavigatedFrom(args); }
}
