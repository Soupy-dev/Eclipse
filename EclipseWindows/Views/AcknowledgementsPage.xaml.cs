using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Animation;

namespace Eclipse.Windows.Views;

public sealed partial class AcknowledgementsPage : Page
{
    public AcknowledgementsPage() => InitializeComponent();
    private void Back_Click(object sender, RoutedEventArgs args) { if (Frame.CanGoBack) Frame.GoBack(new SuppressNavigationTransitionInfo()); }
}
