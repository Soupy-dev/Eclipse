using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Eclipse.Windows.Views;
using Eclipse.Windows.Navigation;
using Windows.Graphics;
using Eclipse.Windows.Services;
using Windows.UI;

namespace Eclipse.Windows;

public sealed partial class MainWindow : Window
{
    private string _currentRoot = "Home";
    private readonly ScheduleNavigationState _scheduleState=new();
    private readonly LibraryNavigationState _libraryState=new();
    private readonly CancellationTokenSource _lifetime=new();
    private bool _scheduleWarmupStarted;
    private DateTimeOffset _lastNotificationRefresh;
    private string? _lastNotificationArgument;
    private DateTimeOffset _lastNotificationActivation;
    private readonly global::Windows.UI.ViewManagement.UISettings _uiSettings=new();
    private readonly AmbientBackdrop _ambient;
    private readonly AtmosphereBackdrop _atmosphere;
    private readonly MouseDragScroll _dragScroll;
    private readonly Vector3Transition _lensMotion=new(){Duration=TimeSpan.FromMilliseconds(320)};
    private RadioButton[] _railItems=[];
    private bool _windowActive=true;
    private object? _lastContent;
    private int _collection;
    public MainWindow()
    {
        InitializeComponent();
        _railItems=RailItems.Children.SelectMany<UIElement,UIElement>(child=>child is Panel panel?panel.Children:[child]).OfType<RadioButton>().ToArray();
        _atmosphere=new(AtmosphereHost);_ambient=new(AmbientHost);_dragScroll=new((UIElement)Content);
        AppWindow.TitleBar.PreferredTheme=TitleBarTheme.Dark;
        RailItems.PreviewKeyDown+=RailItems_PreviewKeyDown;
        UpdateAppearance();
        PreferenceStore.Shared.Changed+=(_,_)=>UpdateAppearance();
        _uiSettings.ColorValuesChanged+=(_,_)=>DispatcherQueue.TryEnqueue(UpdateAppearance);
        var browserBack = new KeyboardAccelerator { Key = global::Windows.System.VirtualKey.GoBack };
        browserBack.Invoked += Back_Invoked;
        ((FrameworkElement)Content).KeyboardAccelerators.Add(browserBack);
        AppWindow.Resize(new SizeInt32(1120, 760));
        UpdateAppearance();
        Activated+=(_,args)=>{_windowActive=args.WindowActivationState!=WindowActivationState.Deactivated;UpdateAmbient();if(ContentFrame.Content is HomePage home)home.SetWindowActive(_windowActive);if(ContentFrame.Content is SchedulePage schedule)schedule.CheckCalendarDate();if(args.WindowActivationState!=WindowActivationState.Deactivated&&_scheduleWarmupStarted&&DateTimeOffset.UtcNow-_lastNotificationRefresh>TimeSpan.FromMinutes(10))_=RefreshNotificationsAsync();};
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
        AtmosphereHost.Visibility=new global::Windows.UI.ViewManagement.AccessibilitySettings().HighContrast?Visibility.Collapsed:Visibility.Visible;
        _atmosphere.Update(AppearanceService.Atmosphere);
        if(ContentFrame.Content is HomePage home)home.RefreshAppearance();else if(ContentFrame.Content is DetailsPage details)details.RefreshAppearance();
        UpdateRailAppearance();UpdateAmbient();
    }
    private void UpdateRailAppearance()
    {
        if(new global::Windows.UI.ViewManagement.AccessibilitySettings().HighContrast)
        {
            RailGlow.Fill=null;RailLens.BorderBrush=null;
            RailLens.Background=new SolidColorBrush(_uiSettings.UIElementColor(global::Windows.UI.ViewManagement.UIElementType.Highlight));return;
        }
        var accent=AppearanceService.Accent;
        RailGlow.Fill=new RadialGradientBrush{Center=new(.5,42/132.0),GradientOrigin=new(.5,42/132.0),RadiusX=66/80.0,RadiusY=.5,GradientStops={new(){Color=Tint(accent,.30),Offset=0},new(){Color=Tint(accent,.09),Offset=.55},new(){Color=Tint(accent,0),Offset=1}}};
        RailLens.Background=Vertical(Tint(accent,.26),Tint(accent,.13));
        RailLens.BorderBrush=Vertical(Color.FromArgb(70,255,255,255),Color.FromArgb(10,255,255,255));
        static Color Tint(Color color,double alpha)=>Color.FromArgb((byte)(alpha*255),color.R,color.G,color.B);
        static LinearGradientBrush Vertical(Color top,Color bottom)=>new(){StartPoint=new(.5,0),EndPoint=new(.5,1),GradientStops={new(){Color=top,Offset=0},new(){Color=bottom,Offset=1}}};
    }
    // Apple pauses ambient motion when the scene is inactive, hidden, or Reduce Motion is on.
    private void UpdateAmbient()
    {
        var preferences=PreferenceStore.Shared.Value;
        var enabled=preferences.HomeAnimatedBackgroundEnabled&&!new global::Windows.UI.ViewManagement.AccessibilitySettings().HighContrast;
        var visible=enabled&&ContentFrame.Content is not (null or DetailsPage);
        AmbientHost.Visibility=visible?Visibility.Visible:Visibility.Collapsed;
        _ambient.Update(enabled,AppearanceService.Accent,AppearanceService.AmbientSecondary,_atmosphere.Brush);
        _ambient.SetFrameRate(int.Parse(preferences.HomeAnimatedBackgroundFrameRate.AsSpan(3)));
        _ambient.SetRunning(visible&&_windowActive&&_uiSettings.AnimationsEnabled);
    }
    private void NavigateRoot(string destination)
    {
        var target = destination switch
        {
            "Home" => typeof(HomePage), "Search" => typeof(SearchPage),
            "Settings" => typeof(SettingsPage), "Schedule"=>typeof(SchedulePage), "Library"=>typeof(LibraryPage), _ => typeof(CollectionPage)
        };
        if (ContentFrame.Content?.GetType() == target && _currentRoot == destination) return;
        _currentRoot = destination;
        ContentFrame.Navigate(target, destination=="Schedule"?_scheduleState:destination=="Library"?_libraryState:destination, new SuppressNavigationTransitionInfo());
        ContentFrame.BackStack.Clear();
        ContentFrame.ForwardStack.Clear();
    }

    private void ContentFrame_Navigated(object sender, NavigationEventArgs args)
    {
        ContentFrame.ForwardStack.Clear();UpdateAmbient();_atmosphere.SetDominant(null);
        if(_lastContent is not (null or HomePage or SearchPage or BrowsePage))_=CollectDiscardedPageAsync(++_collection);
        _lastContent=args.Content;
        if(args.Content is not HomePage)_ambient.SetClearance(0);
        if(args.Content is HomePage home)
        {
            _currentRoot="Home";SelectTab("Home");Title="Eclipse";home.RefreshAppearance();
            home.TitleRequested-=Browse_TitleRequested;home.TitleRequested+=Browse_TitleRequested;
            home.SearchRequested-=Browse_SearchRequested;home.SearchRequested+=Browse_SearchRequested;
            home.CatalogRequested-=Home_CatalogRequested;home.CatalogRequested+=Home_CatalogRequested;
            home.AmbientClearanceChanged-=Home_AmbientClearanceChanged;home.AmbientClearanceChanged+=Home_AmbientClearanceChanged;home.ReportAmbientClearance();
            home.AtmosphereToneChanged-=Page_AtmosphereToneChanged;home.AtmosphereToneChanged+=Page_AtmosphereToneChanged;home.ReportAtmosphereTone();
        }
        else if (args.Content is IBrowsePage page)
        {
            _currentRoot = args.Content is SearchPage ? "Search" : "Home";
            var browser = page.Browser;
            browser.TitleRequested -= Browse_TitleRequested;
            browser.TitleRequested += Browse_TitleRequested;
            browser.BrowseRequested -= Browse_BrowseRequested;
            browser.BrowseRequested += Browse_BrowseRequested;
            SelectTab(args.Content is SearchPage ? "Search" : "Home");
            Title = args.Content is SearchPage ? "Search — Eclipse" : "Eclipse";
        }
        else if (args.Content is DetailsPage details)
        {
            details.TitleLoaded -= Details_TitleLoaded;
            details.TitleLoaded += Details_TitleLoaded;
            details.TitleRequested -= Browse_TitleRequested;
            details.TitleRequested += Browse_TitleRequested;
            details.AtmosphereToneChanged-=Page_AtmosphereToneChanged;details.AtmosphereToneChanged+=Page_AtmosphereToneChanged;
            Title = details.DisplayTitle.Length > 0 ? $"{details.DisplayTitle} — Eclipse" : "Eclipse";
        }
        else if(args.Content is SchedulePage schedule)
        {
            _currentRoot="Schedule";SelectTab("Schedule");Title="Schedule — Eclipse";
            schedule.TitleRequested-=Browse_TitleRequested;schedule.TitleRequested+=Browse_TitleRequested;
        }
        else if(args.Content is BrowsePage browse)
        {
            _currentRoot="Search";SelectTab("Search");Title="Browse — Eclipse";
            browse.TitleRequested-=Browse_TitleRequested;browse.TitleRequested+=Browse_TitleRequested;
        }
        else if(args.Content is CatalogResultsPage catalog)
        {
            SelectTab("Home");Title="Catalog — Eclipse";
            catalog.TitleRequested-=Browse_TitleRequested;catalog.TitleRequested+=Browse_TitleRequested;
        }
        else if(args.Content is LibraryPage library)
        {_currentRoot="Library";SelectTab("Library");Title="Library — Eclipse";library.TitleRequested-=Browse_TitleRequested;library.TitleRequested+=Browse_TitleRequested;}
        else if (args.Content is CollectionPage collection)
        {
            _currentRoot = args.Parameter as string ?? "Library";
            SelectTab(args.Parameter as string ?? "Library");
            collection.BrowseRequested += Browse_SearchRequested;
            Title = $"{args.Parameter} — Eclipse";
        }
        else if (args.Content is SettingsPage or LegalPage or AcknowledgementsPage or AppearancePage or CatalogSettingsPage or NotificationsPage or AccountsPage or RatingsPage)
        {
            _currentRoot = "Settings";
            SelectTab("Settings");
            Title = args.Content switch
            {
                LegalPage => "Legal & Source — Eclipse",
                AppearancePage=>"Appearance — Eclipse", CatalogSettingsPage=>"Catalogs — Eclipse",
                NotificationsPage=>"Notifications — Eclipse",AccountsPage=>"Connected accounts — Eclipse",RatingsPage=>"Ratings & notes — Eclipse",
                AcknowledgementsPage => "Third-Party Notices — Eclipse", _ => "Settings — Eclipse"
            };
            if(args.Content is NotificationsPage notifications)notifications.HistoryRequested+=(_,entry)=>OpenReminder(entry);
        }
    }
    private async Task CollectDiscardedPageAsync(int collection)
    {
        await Task.Delay(2000);if(collection!=_collection)return;
        GC.Collect(2,GCCollectionMode.Forced,false);
        await Task.Delay(1000);if(collection!=_collection)return;
        GC.Collect(2,GCCollectionMode.Forced,false);
    }
    private void SelectTab(string tag)
    {
        foreach(var item in _railItems)if(item.Tag as string==tag)item.IsChecked=true;
        MoveLens(true);
    }
    private void MoveLens(bool animate)
    {
        var item=_railItems.FirstOrDefault(i=>i.IsChecked==true);
        if(item is null||item.ActualHeight==0){RailLens.Opacity=0;return;}
        // The lens is laid out centered at the top of the rail, so it only travels vertically.
        var top=item.TransformToVisual(RailItems).TransformPoint(default).Y-RailItems.Padding.Top;
        RailLens.TranslationTransition=animate&&_uiSettings.AnimationsEnabled&&RailLens.Opacity>0?_lensMotion:null;
        RailLens.Translation=new(0,(float)top,0);RailLens.Opacity=1;
    }
    private void RailItems_SizeChanged(object sender,SizeChangedEventArgs args)=>MoveLens(false);
    private void Rail_Click(object sender,RoutedEventArgs args)
    { if(sender is RadioButton{Tag:string destination})NavigateRoot(destination); }
    private void RailItems_PreviewKeyDown(object sender,KeyRoutedEventArgs args)
    {
        // Match NavigationView: arrows move focus along the rail without wrapping; Enter, like Space, invokes.
        // Handled while tunneling so RadioButton's own group-arrow handling never runs.
        if(args.OriginalSource is not RadioButton{Tag:string destination} item)return;
        if(args.Key is global::Windows.System.VirtualKey.Up or global::Windows.System.VirtualKey.Down)
        {
            var index=Array.IndexOf(_railItems,item)+(args.Key==global::Windows.System.VirtualKey.Down?1:-1);
            if(index>=0&&index<_railItems.Length)_railItems[index].Focus(FocusState.Keyboard);
            args.Handled=true;
        }
        else if(args.Key==global::Windows.System.VirtualKey.Enter){item.IsChecked=true;NavigateRoot(destination);args.Handled=true;}
    }
    private void Details_TitleLoaded(object? sender, EventArgs args)
    { if (sender is DetailsPage details && ReferenceEquals(ContentFrame.Content, details)) Title = $"{details.DisplayTitle} — Eclipse"; }
    private void Browse_TitleRequested(object? sender, TitleRequestedEventArgs args)
    { ContentFrame.Navigate(typeof(DetailsPage), args, new SuppressNavigationTransitionInfo()); }
    private void Home_AmbientClearanceChanged(object? sender,double clearance){if(ReferenceEquals(sender,ContentFrame.Content))_ambient.SetClearance(clearance);}
    private void Page_AtmosphereToneChanged(object? sender,Color? tone){if(ReferenceEquals(sender,ContentFrame.Content))_atmosphere.SetDominant(tone);}
    private void Browse_BrowseRequested(object? sender,EventArgs args)=>ContentFrame.Navigate(typeof(BrowsePage),null,new SuppressNavigationTransitionInfo());
    private void Home_CatalogRequested(object? sender,CatalogRequest args)=>ContentFrame.Navigate(typeof(CatalogResultsPage),args,new SuppressNavigationTransitionInfo());
    private void Browse_SearchRequested(object? sender, EventArgs args)
    {
        NavigateRoot("Search");
        if (ContentFrame.Content is SearchPage page) page.Browser.FocusSearch();
    }
    private void Back_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (!ContentFrame.CanGoBack) return;
        ContentFrame.GoBack(new SuppressNavigationTransitionInfo());
        args.Handled = true;
    }
}
