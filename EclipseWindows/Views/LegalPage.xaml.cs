using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Animation;
using Windows.System;

namespace Eclipse.Windows.Views;

public sealed partial class LegalPage : Page
{
    public LegalPage()
    {
        InitializeComponent();
        SettingsUI.Fit(Scroll,Form);
        Form.Children.Add(SettingsUI.Section("License & source"));
        Form.Children.Add(SettingsUI.Group(
            SettingsUI.Navigation("Eclipse source code","github.com/Soupy-dev/Eclipse",()=>Open("https://github.com/Soupy-dev/Eclipse"),""),
            SettingsUI.Navigation("License","Read the license on GitHub",()=>Open("https://github.com/Soupy-dev/Eclipse/blob/main/LICENSE"),"")));
        Form.Children.Add(SettingsUI.Section("Notices"));
        Form.Children.Add(SettingsUI.Group(SettingsUI.Navigation("Third-Party Notices","Acknowledgements for services and components",()=>Frame.Navigate(typeof(AcknowledgementsPage),null,new SuppressNavigationTransitionInfo()))));
    }
    private static async void Open(string uri)=>await Launcher.LaunchUriAsync(new Uri(uri));
}
