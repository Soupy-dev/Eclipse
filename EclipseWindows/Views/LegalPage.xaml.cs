using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Animation;

namespace Eclipse.Windows.Views;

public sealed partial class LegalPage : Page
{
    public LegalPage() => InitializeComponent();
    private void Back_Click(object sender, RoutedEventArgs args) { if (Frame.CanGoBack) Frame.GoBack(new SuppressNavigationTransitionInfo()); }
    private void Notices_Click(object sender, RoutedEventArgs args) => Frame.Navigate(typeof(AcknowledgementsPage), null, new SuppressNavigationTransitionInfo());
}
