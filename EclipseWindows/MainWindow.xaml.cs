using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.UI.Xaml.Media.Animation;
using Eclipse.Windows.Views;
using Eclipse.Windows.Navigation;
using Windows.Graphics;
using Eclipse.Windows.Services;

namespace Eclipse.Windows;

public sealed partial class MainWindow : Window
{
    private string _currentRoot = "Home";
    private readonly ScheduleNavigationState _scheduleState=new();
    private readonly global::Windows.UI.ViewManagement.UISettings _uiSettings=new();
    public MainWindow()
    {
        InitializeComponent();
        UpdateAppearance();
        PreferenceStore.Shared.Changed+=(_,_)=>UpdateAppearance();
        _uiSettings.ColorValuesChanged+=(_,_)=>DispatcherQueue.TryEnqueue(UpdateAppearance);
        var browserBack = new KeyboardAccelerator { Key = global::Windows.System.VirtualKey.GoBack };
        browserBack.Invoked += Back_Invoked;
        ((FrameworkElement)Content).KeyboardAccelerators.Add(browserBack);
        AppWindow.Resize(new SizeInt32(1120, 760));
        UpdateAppearance();
        Activated+=(_,_)=>{if(ContentFrame.Content is SchedulePage schedule)schedule.CheckCalendarDate();};
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Eclipse.ico"));
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        { presenter.PreferredMinimumWidth = 420; presenter.PreferredMinimumHeight = 480; }
        NavigateRoot("Home");
    }

    private void UpdateAppearance()
    {
        var root=(FrameworkElement)Content;AppearanceService.Apply(root);
        var theme=AppearanceService.Theme;ContentFrame.RequestedTheme=theme;
        if(ContentFrame.Content is FrameworkElement page){page.RequestedTheme=theme==ElementTheme.Light?ElementTheme.Dark:ElementTheme.Light;page.RequestedTheme=theme;}
        if(ContentFrame.Content is HomePage home)home.RefreshContrast();else if(ContentFrame.Content is DetailsPage details)details.RefreshContrast();
        AppWindow.TitleBar.PreferredTheme=theme==ElementTheme.Light?TitleBarTheme.Light:TitleBarTheme.Dark;
    }
    private void NavigateRoot(string destination)
    {
        var target = destination switch
        {
            "Home" => typeof(HomePage), "Search" => typeof(SearchPage),
            "Settings" => typeof(SettingsPage), "Schedule"=>typeof(SchedulePage), _ => typeof(CollectionPage)
        };
        if (ContentFrame.Content?.GetType() == target && _currentRoot == destination) return;
        _currentRoot = destination;
        ContentFrame.Navigate(target, destination=="Schedule"?_scheduleState:destination, new SuppressNavigationTransitionInfo());
        ContentFrame.BackStack.Clear();
        ContentFrame.ForwardStack.Clear();
    }

    private void ContentFrame_Navigated(object sender, NavigationEventArgs args)
    {
        if(args.Content is FrameworkElement themedPage)themedPage.RequestedTheme=AppearanceService.Theme;
        ContentFrame.ForwardStack.Clear();
        if(args.Content is HomePage home)
        {
            _currentRoot="Home";SelectTab("Home");Title="Eclipse";
            home.TitleRequested-=Browse_TitleRequested;home.TitleRequested+=Browse_TitleRequested;
            home.SearchRequested-=Browse_SearchRequested;home.SearchRequested+=Browse_SearchRequested;
            home.CatalogRequested-=Home_CatalogRequested;home.CatalogRequested+=Home_CatalogRequested;
        }
        else if (args.Content is IBrowsePage page)
        {
            _currentRoot = args.Content is SearchPage ? "Search" : "Home";
            var browser = page.Browser;
            browser.TitleRequested -= Browse_TitleRequested;
            browser.TitleRequested += Browse_TitleRequested;
            browser.SearchRequested -= Browse_SearchRequested;
            browser.SearchRequested += Browse_SearchRequested;
            SelectTab(args.Content is SearchPage ? "Search" : "Home");
            Title = args.Content is SearchPage ? "Search — Eclipse" : "Eclipse";
        }
        else if (args.Content is DetailsPage details)
        {
            details.TitleLoaded -= Details_TitleLoaded;
            details.TitleLoaded += Details_TitleLoaded;
            details.TitleRequested -= Browse_TitleRequested;
            details.TitleRequested += Browse_TitleRequested;
            Title = details.DisplayTitle.Length > 0 ? $"{details.DisplayTitle} — Eclipse" : "Eclipse";
        }
        else if(args.Content is SchedulePage schedule)
        {
            _currentRoot="Schedule";SelectTab("Schedule");Title="Schedule — Eclipse";
            schedule.TitleRequested-=Browse_TitleRequested;schedule.TitleRequested+=Browse_TitleRequested;
        }
        else if(args.Content is CatalogResultsPage catalog)
        {
            SelectTab("Home");Title="Catalog — Eclipse";
            catalog.TitleRequested-=Browse_TitleRequested;catalog.TitleRequested+=Browse_TitleRequested;
        }
        else if (args.Content is CollectionPage collection)
        {
            _currentRoot = args.Parameter as string ?? "Library";
            SelectTab(args.Parameter as string ?? "Library");
            collection.BrowseRequested += Browse_SearchRequested;
            Title = $"{args.Parameter} — Eclipse";
        }
        else if (args.Content is SettingsPage or LegalPage or AcknowledgementsPage or AppearancePage or CatalogSettingsPage)
        {
            _currentRoot = "Settings";
            SelectTab("Settings");
            Title = args.Content switch
            {
                LegalPage => "Legal & Source — Eclipse",
                AppearancePage=>"Appearance — Eclipse", CatalogSettingsPage=>"Catalogs — Eclipse",
                AcknowledgementsPage => "Third-Party Notices — Eclipse", _ => "Settings — Eclipse"
            };
        }
    }
    private void SelectTab(string tag)
    {
        ShellNavigation.SelectedItem = ShellNavigation.MenuItems.Concat(ShellNavigation.FooterMenuItems)
            .OfType<NavigationViewItem>().FirstOrDefault(item => item.Tag as string == tag);
    }
    private void Details_TitleLoaded(object? sender, EventArgs args)
    { if (sender is DetailsPage details && ReferenceEquals(ContentFrame.Content, details)) Title = $"{details.DisplayTitle} — Eclipse"; }
    private void Browse_TitleRequested(object? sender, TitleRequestedEventArgs args)
    { ContentFrame.Navigate(typeof(DetailsPage), args, new SuppressNavigationTransitionInfo()); }
    private void Home_CatalogRequested(object? sender,CatalogRequest args)=>ContentFrame.Navigate(typeof(CatalogResultsPage),args,new SuppressNavigationTransitionInfo());
    private void Browse_SearchRequested(object? sender, EventArgs args)
    {
        NavigateRoot("Search");
        if (ContentFrame.Content is SearchPage page) page.Browser.FocusSearch();
    }
    private void Navigation_ItemInvoked(NavigationView sender, NavigationViewItemInvokedEventArgs args)
    {
        if (args.InvokedItemContainer?.Tag is string destination) NavigateRoot(destination);
    }
    private void Back_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (!ContentFrame.CanGoBack) return;
        ContentFrame.GoBack(new SuppressNavigationTransitionInfo());
        args.Handled = true;
    }
}
