using Microsoft.UI.Xaml.Controls;

namespace Eclipse.Windows.Views;

public sealed partial class AcknowledgementsPage : Page
{
    public AcknowledgementsPage(){InitializeComponent();SettingsUI.Fit(Scroll,Form);}
}
