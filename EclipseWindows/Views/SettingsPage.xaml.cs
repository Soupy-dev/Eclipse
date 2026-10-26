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
        SettingsUI.Fit(Scroll,Form);
        Form.Children.Add(SettingsUI.Section("Basic"));
        Form.Children.Add(SettingsUI.Group(
            SettingsUI.Navigation("Services","Services, Stremio addons, Nuvio plugins and stream rules",()=>Open(typeof(ServicesPage))),
            SettingsUI.Navigation("Appearance","Theme, palette, accent color, Home layout and detail pages",()=>Open(typeof(AppearancePage))),
            SettingsUI.Navigation("Catalogs","Choose which rows appear on Home and their order",()=>Open(typeof(CatalogSettingsPage))),
            SettingsUI.Navigation("Notifications","Episode reminders, followed shows and alert history",()=>Open(typeof(NotificationsPage))),
            SettingsUI.Navigation("Connected accounts","Trakt, AniList and MyAnimeList libraries",()=>Open(typeof(AccountsPage))),
            SettingsUI.Navigation("Ratings & notes","Your ratings and private notes",()=>Open(typeof(RatingsPage)))));
        Form.Children.Add(SettingsUI.Section("Others"));
        Form.Children.Add(SettingsUI.Group(SettingsUI.Navigation("Legal & Source","Licenses, source code and third-party notices",()=>Open(typeof(LegalPage)))));
    }
    private void Open(Type page)=>Frame.Navigate(page,null,new SuppressNavigationTransitionInfo());
}
