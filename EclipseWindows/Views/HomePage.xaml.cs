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
    private double _offset;
    private IReadOnlyList<MediaTitle> _heroes=[];
    private List<HomeCatalog> _catalogs=[];
    public HomePage()
    {
        InitializeComponent();HeroArtwork.ImageSource=_backdrop;HeroLogo.Source=_logo;
        _logo.ImageOpened+=(_,_)=>{if(_active&&_logo.UriSource is not null&&!new global::Windows.UI.ViewManagement.AccessibilitySettings().HighContrast){HeroLogo.Visibility=Visibility.Visible;HeroTitle.Visibility=Visibility.Collapsed;}};
        _logo.ImageFailed+=(_,_)=>{HeroLogo.Visibility=Visibility.Collapsed;HeroTitle.Visibility=Visibility.Visible;};
    }
    protected override void OnNavigatedTo(NavigationEventArgs args)
    {
        base.OnNavigatedTo(args);_active=true;
        if(_revision!=PreferenceStore.Shared.Revision || _heroes.Count==0) _=LoadAsync();
        else ShowHero();
    }
    private async Task LoadAsync()
    {
        _load?.Cancel();_load?.Dispose();_load=new();var token=_load.Token;var generation=++_generation;
        var revision=PreferenceStore.Shared.Revision;var preferences=PreferenceStore.Shared.Value;
        _catalogs=preferences.EnabledCatalogs.Where(c=>c.IsEnabled&&c.IsAvailable).OrderBy(c=>c.Order).ToList();
        HomeList.ItemsSource=_catalogs;Error.IsOpen=false;Empty.Visibility=_catalogs.Count==0 ? Visibility.Visible : Visibility.Collapsed;
        var hero=_catalogs.FirstOrDefault(c=>c.Id==preferences.HeroBannerCatalogId) ?? _catalogs.FirstOrDefault(c=>c.DisplayStyle=="standard");
        if(hero is null){_heroes=[];_revision=revision;Hero.Visibility=Visibility.Collapsed;return;}
        BusyBar.IsIndeterminate=true;BusyBar.Visibility=Visibility.Visible;
        try
        {
            var result=await CatalogService.LoadAsync(new(hero.Id),1,token);
            if(token.IsCancellationRequested||generation!=_generation||!_active)return;
            foreach(var previous in _heroes)previous.ReleaseArtwork();
            _heroes=result.Titles.Where(t=>t.ArtworkUri is not null).Take(10).ToArray();_revision=revision;_heroIndex=0;HeroSource.Text=hero.Name.ToUpperInvariant();ShowHero();
        }
        catch(OperationCanceledException){}
        catch(Exception e) when(e is TmdbException or ProviderException){if(!token.IsCancellationRequested){Error.Message=e.Message;Error.IsOpen=true;}}
        finally{if(generation==_generation){BusyBar.IsIndeterminate=false;BusyBar.Visibility=Visibility.Collapsed;}}
    }
    public void RefreshContrast(){if(new global::Windows.UI.ViewManagement.AccessibilitySettings().HighContrast){_logo.UriSource=null;HeroLogo.Visibility=Visibility.Collapsed;HeroTitle.Visibility=Visibility.Visible;}}
    private void ShowHero()
    {
        if(_heroes.Count==0||!_active){Hero.Visibility=Visibility.Collapsed;return;}
        var p=PreferenceStore.Shared.Value;var item=_heroes[_heroIndex];Hero.Visibility=Visibility.Visible;
        HeroGrid.MinHeight=(p.ExperimentalMediaDesignPreset=="compact" ? 330 : p.ExperimentalMediaDesignPreset=="balanced" ? 390 : 440)*p.ExperimentalHeroHeightScale;
        HeroTitle.Text=item.Title;HeroTitle.Visibility=Visibility.Visible;HeroMetadata.Text=item.Subtitle+" · "+item.Rating;HeroSynopsis.Text=item.Synopsis;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(HeroLogo,item.Title);
        _backdrop.DecodePixelWidth=p.ImageDataSaverEnabled?780:1280;
        HeroPosition.Text=$"{_heroIndex+1} / {_heroes.Count}";_backdrop.UriSource=item.ArtworkUri;
        _logoLoad?.Cancel();_logoLoad?.Dispose();_logoLoad=new();_logo.UriSource=null;HeroLogo.Visibility=Visibility.Collapsed;
        if(p.MediaDetailTitleArtworkEnabled&&!new global::Windows.UI.ViewManagement.AccessibilitySettings().HighContrast)_=LoadLogoAsync(item,_logoLoad.Token);
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
    {_active=false;_load?.Cancel();_logoLoad?.Cancel();_backdrop.UriSource=_logo.UriSource=null;BusyBar.IsIndeterminate=false;base.OnNavigatedFrom(args);}
    private void List_Loaded(object sender,RoutedEventArgs args)=>DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,()=>
    {if(!_active)return;FindScroll(HomeList)?.ChangeView(null,_offset,null,true);if(_returnHero){Explore.Focus(FocusState.Keyboard);_returnHero=false;}});
    private void Explore_Click(object sender,RoutedEventArgs args){if(_heroes.Count>0){_returnHero=true;TitleRequested?.Invoke(this,new(_heroes[_heroIndex].Id));}}
    private void Row_TitleRequested(object? sender,TitleRequestedEventArgs args){_returnHero=false;TitleRequested?.Invoke(this,args);}
    private void Row_CatalogRequested(object? sender,CatalogRequest args)=>CatalogRequested?.Invoke(this,args);
    private void Previous_Click(object sender,RoutedEventArgs args){if(_heroes.Count>0){_heroIndex=(_heroIndex+_heroes.Count-1)%_heroes.Count;ShowHero();}}
    private void Next_Click(object sender,RoutedEventArgs args){if(_heroes.Count>0){_heroIndex=(_heroIndex+1)%_heroes.Count;ShowHero();}}
    private void Retry_Click(object sender,RoutedEventArgs args)=>_=LoadAsync();
    private void Search_Invoked(KeyboardAccelerator sender,KeyboardAcceleratorInvokedEventArgs args){SearchRequested?.Invoke(this,EventArgs.Empty);args.Handled=true;}
    private void Root_SizeChanged(object sender,SizeChangedEventArgs args)
    {var compact=args.NewSize.Width<720;HomeList.Padding=compact ? new Thickness(12,16,12,24) : new Thickness(28,20,28,32);HeroCard.Margin=compact ? new Thickness(12,30,12,72) : new Thickness(28,44,28,76);HeroCard.Padding=new Thickness(compact ? 18 : 24);HeroTitle.FontSize=compact ? 30 : 40;}
    private static ScrollViewer? FindScroll(DependencyObject root)
    {for(var i=0;i<VisualTreeHelper.GetChildrenCount(root);i++){var child=VisualTreeHelper.GetChild(root,i);if(child is ScrollViewer scroll)return scroll;if(FindScroll(child) is { } found)return found;}return null;}
}
