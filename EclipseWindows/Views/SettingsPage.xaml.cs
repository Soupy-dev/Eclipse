using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Animation;
using Windows.ApplicationModel;

namespace Eclipse.Windows.Views;

public sealed partial class SettingsPage : Page
{
    public SettingsPage()
    {
        InitializeComponent();
        var version = Package.Current.Id.Version;
        VersionText.Text = $"Version {version.Major}.{version.Minor}.{version.Build}.{version.Revision}";
    }
    private void Legal_Click(object sender, RoutedEventArgs args) => Frame.Navigate(typeof(LegalPage), null, new SuppressNavigationTransitionInfo());
    private void Appearance_Click(object sender,RoutedEventArgs args)=>Frame.Navigate(typeof(AppearancePage),null,new SuppressNavigationTransitionInfo());
    private void Catalogs_Click(object sender,RoutedEventArgs args)=>Frame.Navigate(typeof(CatalogSettingsPage),null,new SuppressNavigationTransitionInfo());
}
