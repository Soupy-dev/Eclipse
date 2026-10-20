using Eclipse.Windows.Models;
using Eclipse.Windows.Services;
using Eclipse.Windows.Navigation;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Navigation;
namespace Eclipse.Windows.Views;
public sealed partial class HomePage : Page
{
    public event EventHandler<TitleRequestedEventArgs>? TitleRequested;
    public event EventHandler<CatalogRequest>? CatalogRequested;
    public event EventHandler? SearchRequested;
    private readonly BitmapImage _backdrop=new() {DecodePixelWidth=1280};
    private readonly BitmapImage _logo=new() {DecodePixelWidth=380};
    private CancellationTokenSource? _load,_logoLoad;
    private int _revision=-1,_heroIndex,_generation;
    private bool _active,_returnHero;
    private bool _hover,_heroFocus,_windowActive=true,_heroInView=true;
    private ScrollViewer? _homeScroll;
    private readonly DispatcherTimer _carousel=new(){Interval=TimeSpan.FromSeconds(7)};
    private double _offset;
    private IReadOnlyList<MediaTitle> _heroes=[];
    private List<HomeCatalog> _catalogs=[];
    public HomePage()
    {
        InitializeComponent();HeroArtwork.ImageSource=_backdrop;HeroLogo.Source=_logo;
        Hero.SizeChanged+=(_,_)=>{_heroInView=Hero.ActualHeight>0&&(_homeScroll?.VerticalOffset??0)<Hero.ActualHeight;ResetCarousel();};
        _carousel.Tick+=(_,_)=>{_carousel.Stop();if(CanAdvance()){_heroIndex=(_heroIndex+1)%_heroes.Count;ShowHero();}};
        _logo.ImageOpened+=(_,_)=>{if(_active&&_logo.UriSource is not null&&!new global::Windows.UI.ViewManagement.AccessibilitySettings().HighContrast){HeroLogo.Visibility=Visibility.Visible;HeroTitle.Visibility=Visibility.Collapsed;}};
        _logo.ImageFailed+=(_,_)=>{HeroLogo.Visibility=Visibility.Collapsed;HeroTitle.Visibility=Visibility.Visible;};
    }
    protected override void OnNavigatedTo(NavigationEventArgs args)
    {
        base.OnNavigatedTo(args);_active=true;_hover=_heroFocus=false;
        if(_revision!=PreferenceStore.Shared.Revision || _heroes.Count==0) _=LoadAsync();
        else ShowHero();
    }
    private async Task LoadAsync()
    {
        _load?.Cancel();_load?.Dispose();_load=new();var token=_load.Token;var generation=++_generation;
        var revision=PreferenceStore.Shared.Revision;var preferences=PreferenceStore.Shared.Value;
        _catalogs=preferences.EnabledCatalogs.Where(c=>c.IsEnabled&&c.IsAvailable).OrderBy(c=>c.Order).ToList();
        HomeList.ItemsSource=_catalogs;Error.IsOpen=false;Error.Visibility=Visibility.Collapsed;Empty.Visibility=_catalogs.Count==0 ? Visibility.Visible : Visibility.Collapsed;
        var hero=_catalogs.FirstOrDefault(c=>c.Id==preferences.HeroBannerCatalogId) ?? _catalogs.FirstOrDefault(c=>c.DisplayStyle=="standard");
        if(hero is null){_heroes=[];_revision=revision;Hero.Visibility=Visibility.Collapsed;return;}
        BusyBar.IsIndeterminate=true;BusyBar.Visibility=Visibility.Visible;
        try
        {
            var result=await CatalogService.LoadAsync(new(hero.Id),1,token);
            if(token.IsCancellationRequested||generation!=_generation||!_active)return;
            foreach(var previous in _heroes)previous.ReleaseArtwork();
            _heroes=result.Titles.Where(t=>t.ArtworkUri is not null).Take(10).ToArray();_revision=revision;_heroIndex=0;ShowHero();
        }
        catch(OperationCanceledException){}
        catch(Exception e) when(e is TmdbException or ProviderException){if(!token.IsCancellationRequested){Error.Message=e.Message;Error.Visibility=Visibility.Visible;Error.IsOpen=true;}}
        finally{if(generation==_generation){BusyBar.IsIndeterminate=false;BusyBar.Visibility=Visibility.Collapsed;}}
    }
    public void RefreshContrast(){if(new global::Windows.UI.ViewManagement.AccessibilitySettings().HighContrast){_logo.UriSource=null;HeroLogo.Visibility=Visibility.Collapsed;HeroTitle.Visibility=Visibility.Visible;}}
    private void ShowHero()
    {
        if(_heroes.Count==0||!_active){Hero.Visibility=Visibility.Collapsed;return;}
        var p=PreferenceStore.Shared.Value;var item=_heroes[_heroIndex];Hero.Visibility=Visibility.Visible;
        UpdateHeroLayout();
        HeroTitle.Text=item.Title;HeroTitle.Visibility=Visibility.Visible;HeroMetadata.Text=item.Subtitle;HeroSynopsis.Text=item.Synopsis;
        HeroRatings.SetTitle(item);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(HeroLogo,item.Title);
        _backdrop.DecodePixelWidth=p.ImageDataSaverEnabled?780:1280;
        HeroPosition.Text=$"{_heroIndex+1} / {_heroes.Count}";HeroPaging.Visibility=_heroes.Count>1?Visibility.Visible:Visibility.Collapsed;_backdrop.UriSource=item.ArtworkUri;
        _logoLoad?.Cancel();_logoLoad?.Dispose();_logoLoad=new();_logo.UriSource=null;HeroLogo.Visibility=Visibility.Collapsed;
        if(p.MediaDetailTitleArtworkEnabled&&!new global::Windows.UI.ViewManagement.AccessibilitySettings().HighContrast)_=LoadLogoAsync(item,_logoLoad.Token);
        ResetCarousel();
    }
    private async Task LoadLogoAsync(MediaTitle title,CancellationToken token)
    {
        try
        {
            var data=await TmdbService.Shared.ExtraAsync(title,"images",token);
            var path=JsonValue.Array(data,"logos").OrderByDescending(e=>JsonValue.Text(e,"iso_639_1")=="en").Select(e=>JsonValue.Text(e,"file_path")).FirstOrDefault();
            if(!token.IsCancellationRequested&&_active&&MediaTitle.ImageUri(path,"w500") is { } uri)
            {_logo.UriSource=uri;}
        }
        catch(OperationCanceledException){}catch(TmdbException){}
    }
    protected override void OnNavigatingFrom(NavigatingCancelEventArgs args)
    {_offset=FindScroll(HomeList)?.VerticalOffset??0;base.OnNavigatingFrom(args);}
    protected override void OnNavigatedFrom(NavigationEventArgs args)
    {_active=false;_carousel.Stop();_load?.Cancel();_logoLoad?.Cancel();_backdrop.UriSource=_logo.UriSource=null;BusyBar.IsIndeterminate=false;base.OnNavigatedFrom(args);}
    public void SetWindowActive(bool active){_windowActive=active;ResetCarousel();}
    private bool CanAdvance()=>_active&&_windowActive&&_heroInView&&!_hover&&!_heroFocus&&_heroes.Count>1&&PreferenceStore.Shared.Value.HeroBannerBehavior=="carousel"&&new global::Windows.UI.ViewManagement.UISettings().AnimationsEnabled;
    private void ResetCarousel(){_carousel.Stop();if(CanAdvance())_carousel.Start();}
    private void Hero_Entered(object sender,PointerRoutedEventArgs args){_hover=true;ResetCarousel();}
    private void Hero_Exited(object sender,PointerRoutedEventArgs args){_hover=false;ResetCarousel();}
    private void Hero_GotFocus(object sender,RoutedEventArgs args){_heroFocus=true;ResetCarousel();}
    private void Hero_LostFocus(object sender,RoutedEventArgs args){_heroFocus=false;ResetCarousel();}
    private void List_Loaded(object sender,RoutedEventArgs args)=>DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,()=>
    {if(!_active)return;if(_homeScroll is not null)_homeScroll.ViewChanged-=Scroll_Changed;_homeScroll=FindScroll(HomeList);if(_homeScroll is not null){_homeScroll.ViewChanged+=Scroll_Changed;_homeScroll.ChangeView(null,_offset,null,true);_heroInView=_homeScroll.VerticalOffset<Hero.ActualHeight;}ResetCarousel();if(_returnHero){Explore.Focus(FocusState.Keyboard);_returnHero=false;}});
    private void Scroll_Changed(object? sender,ScrollViewerViewChangedEventArgs args){var visible=(_homeScroll?.VerticalOffset??0)<Hero.ActualHeight;if(visible!=_heroInView){_heroInView=visible;ResetCarousel();}}
    private void Explore_Click(object sender,RoutedEventArgs args){if(_heroes.Count>0){_returnHero=true;TitleRequested?.Invoke(this,new(_heroes[_heroIndex].Id));}}
    private void Row_TitleRequested(object? sender,TitleRequestedEventArgs args){_returnHero=false;TitleRequested?.Invoke(this,args);}
    private void Row_CatalogRequested(object? sender,CatalogRequest args)=>CatalogRequested?.Invoke(this,args);
    private void Previous_Click(object sender,RoutedEventArgs args){if(_heroes.Count>0){_heroIndex=(_heroIndex+_heroes.Count-1)%_heroes.Count;ShowHero();}}
    private void Next_Click(object sender,RoutedEventArgs args){if(_heroes.Count>0){_heroIndex=(_heroIndex+1)%_heroes.Count;ShowHero();}}
    private void Retry_Click(object sender,RoutedEventArgs args)=>_=LoadAsync();
    private void Search_Invoked(KeyboardAccelerator sender,KeyboardAcceleratorInvokedEventArgs args){SearchRequested?.Invoke(this,EventArgs.Empty);args.Handled=true;}
    private void Root_SizeChanged(object sender,SizeChangedEventArgs args)
    {UpdateHeroLayout();}
    private void UpdateHeroLayout()
    {
        var width=Math.Max(1,Root.ActualWidth);var compact=width<720;var inset=compact?16:28;
        HomeList.Padding=new Thickness(inset,0,inset,32);Hero.Margin=new Thickness(-inset,0,-inset,8);
        HeroCard.Margin=new Thickness(compact?24:40,64,compact?24:40,66);
        HeroCard.MaxWidth=compact?Math.Max(1,width-48):Math.Clamp(width*.48,380,520);HeroTitle.FontSize=compact?32:44;
        // Match Apple's viewport-aware desktop hero without a fixed-height crop at large text sizes.
        var p=PreferenceStore.Shared.Value;var preset=p.ExperimentalMediaDesignPreset=="compact"?.85:p.ExperimentalMediaDesignPreset=="balanced"?.95:1;
        HeroGrid.MinHeight=Math.Clamp(Math.Min(width*.56,Math.Max(400,Root.ActualHeight)*.72),360,580)*preset*p.ExperimentalHeroHeightScale;
    }
    private static ScrollViewer? FindScroll(DependencyObject root)
    {for(var i=0;i<VisualTreeHelper.GetChildrenCount(root);i++){var child=VisualTreeHelper.GetChild(root,i);if(child is ScrollViewer scroll)return scroll;if(FindScroll(child) is { } found)return found;}return null;}
}
