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
    private readonly CancellationTokenSource _lifetime=new();
    private bool _scheduleWarmupStarted;
    private DateTimeOffset _lastNotificationRefresh;
    private string? _lastNotificationArgument;
    private DateTimeOffset _lastNotificationActivation;
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
        Activated+=(_,args)=>{if(ContentFrame.Content is SchedulePage schedule)schedule.CheckCalendarDate();if(args.WindowActivationState!=WindowActivationState.Deactivated&&_scheduleWarmupStarted&&DateTimeOffset.UtcNow-_lastNotificationRefresh>TimeSpan.FromMinutes(10))_=RefreshNotificationsAsync();};
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Eclipse.ico"));
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        { presenter.PreferredMinimumWidth = 420; presenter.PreferredMinimumHeight = 480; }
        NavigateRoot("Home");
        ((FrameworkElement)Content).Loaded+=Startup_Loaded;
        Closed+=(_,_)=>_lifetime.Cancel();
    }

    private async void Startup_Loaded(object sender,RoutedEventArgs args)
    {
        if(_scheduleWarmupStarted)return;_scheduleWarmupStarted=true;
        try
        {
            // SoraApp.warmSchedulesAfterStartup waits 750 ms after startup readiness.
            await Task.Delay(750,_lifetime.Token);
            var p=PreferenceStore.Shared.Value;
            try{var result=await ScheduleService.Shared.LoadAsync(p.DefaultScheduleMode,p.ScheduleWindowDays,_lifetime.Token);await EpisodeReminderService.Shared.ConsumeAsync(result);}
            catch(ProviderException){} // A calendar outage must not prevent other reminder discovery.
            await RefreshNotificationsAsync();
        }
        catch(OperationCanceledException){}
        catch(ProviderException){} // Schedule presents its normal retry/error state when opened.
        catch(Exception e)when(e is IOException or InvalidOperationException){}
    }
    private async Task RefreshNotificationsAsync()
    {
        _lastNotificationRefresh=DateTimeOffset.UtcNow;
        try{await EpisodeReminderService.Shared.RefreshAsync(_lifetime.Token,false);}catch(OperationCanceledException){}catch(Exception e)when(e is IOException or InvalidOperationException or ProviderException or TmdbException or System.Runtime.InteropServices.COMException){}
    }
    public async Task OpenNotificationAsync(string? argument)
    {
        var now=DateTimeOffset.UtcNow;if(argument==_lastNotificationArgument&&now-_lastNotificationActivation<TimeSpan.FromSeconds(2))return;
        _lastNotificationArgument=argument;_lastNotificationActivation=now;
        var entry=EpisodeReminderService.Shared.ResolveArgument(argument);
        try{await EpisodeReminderService.Shared.SyncHistoryAsync(argument);}catch(Exception e)when(e is IOException or System.Runtime.InteropServices.COMException){}
        OpenReminder(entry);
    }
    private void OpenReminder(Eclipse.Windows.Models.ScheduleEntry? entry)
    {
        if(entry is not null){_scheduleState.SelectedDay=DateOnly.FromDateTime(PreferenceStore.Shared.Value.ShowLocalScheduleTime?entry.AiringAt.LocalDateTime:entry.AiringAt.UtcDateTime);_scheduleState.SourceOverride=entry.Source=="Anime"?"anime":"western";_scheduleState.FocusEntryId=entry.Id;}
        _currentRoot="";NavigateRoot("Schedule");
        if(entry is not null&&entry.TitleId.Length>0)Browse_TitleRequested(this,new(entry.TitleId,entry));
        Activate();
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
        else if (args.Content is SettingsPage or LegalPage or AcknowledgementsPage or AppearancePage or CatalogSettingsPage or NotificationsPage)
        {
            _currentRoot = "Settings";
            SelectTab("Settings");
            Title = args.Content switch
            {
                LegalPage => "Legal & Source — Eclipse",
                AppearancePage=>"Appearance — Eclipse", CatalogSettingsPage=>"Catalogs — Eclipse",
                NotificationsPage=>"Notifications — Eclipse",
                AcknowledgementsPage => "Third-Party Notices — Eclipse", _ => "Settings — Eclipse"
            };
            if(args.Content is NotificationsPage notifications)notifications.HistoryRequested+=(_,entry)=>OpenReminder(entry);
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
