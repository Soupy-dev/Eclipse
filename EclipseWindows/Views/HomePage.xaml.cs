using Eclipse.Windows.Models;
using Eclipse.Windows.Services;
using Eclipse.Windows.Navigation;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Navigation;
namespace Eclipse.Windows.Views;
public sealed partial class HomePage : Page
{
    public event EventHandler<TitleRequestedEventArgs>? TitleRequested;
    public event EventHandler<CatalogRequest>? CatalogRequested;
    public event EventHandler? SearchRequested;
    // Viewport y where the hero's bleed ends; the shell keeps ambient motion hidden above it.
    public event EventHandler<double>? AmbientClearanceChanged;
    // One slot shows the current hero; the others hold the next two titles, matching Apple's
    // upcomingHeroCarouselItems(limit: 2) prefetch, so a carousel step crossfades decoded artwork.
    private sealed class HeroSlot
    {
        public HeroSlot()=>Artwork=new(Art);
        public readonly BitmapImage Logo=new(){DecodePixelWidth=380};
        public readonly Grid Art=new(){Opacity=0,RenderTransformOrigin=new(.5,.5),RenderTransform=new ScaleTransform()};
        public readonly HeroArtwork Artwork;
        public readonly Image LogoPreload=new(){Width=360,Height=112,Stretch=Stretch.Uniform};
        public int Index=-1;
        public bool ArtSettled,LogoSettled,LogoReady;
        public CancellationTokenSource? LogoLoad;
        public TaskCompletionSource Changed=new(TaskCreationOptions.RunContinuationsAsynchronously);
        public bool Settled=>ArtSettled&&LogoSettled;
        public void Signal(){var previous=Changed;Changed=new(TaskCreationOptions.RunContinuationsAsynchronously);previous.TrySetResult();}
    }
    private readonly HeroSlot[] _slots=[new(),new(),new()];
    private readonly HeroShade _shade;
    private HeroSlot? _shown,_pendingContent;
    private Storyboard? _artStory,_contentStory;
    private readonly global::Windows.UI.ViewManagement.UISettings _uiSettings=new();
    private CancellationTokenSource? _load;
    private int _revision=-1,_heroIndex,_generation,_heroGeneration;
    private bool _active,_returnHero;
    private bool _hover,_heroFocus,_windowActive=true,_heroInView=true;
    private ScrollViewer? _homeScroll;
    private readonly DispatcherTimer _carousel=new(){Interval=TimeSpan.FromSeconds(7)};
    private double _offset;
    private IReadOnlyList<MediaTitle> _heroes=[];
    private List<HomeCatalog> _catalogs=[];
    public HomePage()
    {
        InitializeComponent();_shade=new(HeroShadeHost);
        foreach(var slot in _slots)
        {
            HeroArt.Children.Add(slot.Art);
            slot.LogoPreload.Source=slot.Logo;HeroLogoPreload.Children.Add(slot.LogoPreload);
            slot.Artwork.Settled+=(_,_)=>{slot.ArtSettled=true;slot.Signal();};
            slot.Logo.ImageOpened+=(_,_)=>{slot.LogoReady=slot.LogoSettled=slot.Logo.UriSource is not null;slot.Signal();LogoChanged(slot);};
            slot.Logo.ImageFailed+=(_,_)=>{slot.LogoReady=false;slot.LogoSettled=true;slot.Signal();LogoChanged(slot);};
        }
        Hero.SizeChanged+=(_,_)=>{_heroInView=Hero.ActualHeight>0&&(_homeScroll?.VerticalOffset??0)<Hero.ActualHeight;ResetCarousel();ReportAmbientClearance();};
        RefreshAppearance();
        _carousel.Tick+=(_,_)=>{_carousel.Stop();if(CanAdvance())ShowHero((_heroIndex+1)%_heroes.Count,true);};
    }
    protected override void OnNavigatedTo(NavigationEventArgs args)
    {
        base.OnNavigatedTo(args);_active=true;_hover=_heroFocus=false;
        if(_revision!=PreferenceStore.Shared.Revision || _heroes.Count==0) _=LoadAsync();
        else ShowHero(_heroIndex,false);
    }
    private async Task LoadAsync()
    {
        _load?.Cancel();_load?.Dispose();_load=new();var token=_load.Token;var generation=++_generation;
        var revision=PreferenceStore.Shared.Revision;var preferences=PreferenceStore.Shared.Value;
        _catalogs=preferences.EnabledCatalogs.Where(c=>c.IsEnabled&&c.IsAvailable).OrderBy(c=>c.Order).ToList();
        HomeList.ItemsSource=_catalogs;Error.IsOpen=false;Error.Visibility=Visibility.Collapsed;Empty.Visibility=_catalogs.Count==0 ? Visibility.Visible : Visibility.Collapsed;
        var hero=_catalogs.FirstOrDefault(c=>c.Id==preferences.HeroBannerCatalogId) ?? _catalogs.FirstOrDefault(c=>c.DisplayStyle=="standard");
        if(hero is null){_heroes=[];_revision=revision;Hero.Visibility=Visibility.Collapsed;ReportAmbientClearance();return;}
        BusyBar.IsIndeterminate=true;BusyBar.Visibility=Visibility.Visible;
        try
        {
            var result=await CatalogService.LoadAsync(new(hero.Id),1,token);
            if(token.IsCancellationRequested||generation!=_generation||!_active)return;
            foreach(var previous in _heroes)previous.ReleaseArtwork();
            ++_heroGeneration;FinishTransition();ReleaseSlots();
            _heroes=result.Titles.Where(t=>t.ArtworkUri is not null).Take(10).ToArray();_revision=revision;_heroIndex=0;ShowHero(0,false);
        }
        catch(OperationCanceledException){}
        catch(Exception e) when(e is TmdbException or ProviderException){if(!token.IsCancellationRequested){Error.Message=e.Message;Error.Visibility=Visibility.Visible;Error.IsOpen=true;}}
        finally{if(generation==_generation){BusyBar.IsIndeterminate=false;BusyBar.Visibility=Visibility.Collapsed;}}
    }
    public void RefreshAppearance()
    {
        var light=AppearanceService.Theme==ElementTheme.Light;_shade.SetTheme(light);
        foreach(var slot in _slots)slot.Artwork.SetTheme(light);
        // High contrast replaces artwork with the system window colour.
        var contrast=HighContrast;HeroArt.Visibility=HeroShadeHost.Visibility=contrast?Visibility.Collapsed:Visibility.Visible;HeroContrastPlate.Visibility=contrast?Visibility.Visible:Visibility.Collapsed;
        if(!contrast)return;
        foreach(var slot in _slots){slot.LogoLoad?.Cancel();slot.Logo.UriSource=null;slot.LogoReady=false;slot.LogoSettled=true;}
        HeroLogo.Source=null;HeroLogo.Visibility=Visibility.Collapsed;HeroTitle.Visibility=Visibility.Visible;
    }
    public void ReportAmbientClearance()
    {
        var clearance=_active&&Hero.Visibility==Visibility.Visible&&Hero.ActualHeight>0?Hero.TransformToVisual(Root).TransformPoint(new(0,Hero.ActualHeight)).Y+HeroArtwork.Tail:0;
        AmbientClearanceChanged?.Invoke(this,clearance);
    }
    private static bool HighContrast=>new global::Windows.UI.ViewManagement.AccessibilitySettings().HighContrast;
    private static bool LogosEnabled=>PreferenceStore.Shared.Value.MediaDetailTitleArtworkEnabled&&!HighContrast;

    private async void ShowHero(int target,bool slide)
    {
        if(_heroes.Count==0||!_active){Hero.Visibility=Visibility.Collapsed;return;}
        var generation=++_heroGeneration;
        FinishTransition();_carousel.Stop();
        _heroIndex=target;if(Hero.Visibility!=Visibility.Visible){Hero.Visibility=Visibility.Visible;ReportAmbientClearance();}UpdateHeroLayout();
        HeroPosition.Text=$"{target+1} / {_heroes.Count}";HeroPaging.Visibility=_heroes.Count>1?Visibility.Visible:Visibility.Collapsed;
        var slot=Acquire(target);
        if(ReferenceEquals(slot,_shown)){ApplyHero(slot);ResetCarousel();Preload(target);return;}
        if(_shown is null)HeroCard.Opacity=0;
        // Hold the current slide until the next artwork and title logo are ready, so nothing pops in mid-transition.
        var deadline=DateTime.UtcNow.AddSeconds(2.5);
        while(!slot.Settled&&DateTime.UtcNow<deadline)
        {
            await Task.WhenAny(slot.Changed.Task,Task.Delay(deadline-DateTime.UtcNow));
            if(generation!=_heroGeneration||!_active)return;
        }
        if(generation==_heroGeneration&&_active)BeginTransition(slot,slide);
    }
    private void BeginTransition(HeroSlot slot,bool slide)
    {
        var outgoing=_shown;_shown=slot;
        var motion=_uiSettings.AnimationsEnabled;slide&=motion&&outgoing is not null;
        // Local values hold the end state; the storyboards animate from the old state, so stopping one snaps cleanly.
        foreach(var other in _slots){Canvas.SetZIndex(other.Art,ReferenceEquals(other,slot)?1:0);if(!ReferenceEquals(other,slot))other.Art.Opacity=0;}
        slot.Art.Opacity=1;HeroCard.Opacity=1;HeroCardShift.X=0;
        var art=new Storyboard();var fade=motion?(slide?520:360):120;
        Animate(art,slot.Art,"Opacity",0,1,fade,new CubicEase{EasingMode=EasingMode.EaseInOut});
        if(outgoing is not null)Animate(art,outgoing.Art,"Opacity",1,0,fade,new CubicEase{EasingMode=EasingMode.EaseInOut});
        if(slide){var scale=(ScaleTransform)slot.Art.RenderTransform;var settle=new ExponentialEase{EasingMode=EasingMode.EaseOut,Exponent=4};Animate(art,scale,"ScaleX",1.05,1,900,settle);Animate(art,scale,"ScaleY",1.05,1,900,settle);}
        art.Completed+=(_,_)=>{if(!ReferenceEquals(art,_artStory))return;art.Stop();_artStory=null;ResetCarousel();Preload(_heroIndex);};
        if(slide)
        {
            _pendingContent=slot;
            var leave=new Storyboard();
            Animate(leave,HeroCard,"Opacity",1,0,170,new CubicEase{EasingMode=EasingMode.EaseIn});Animate(leave,HeroCardShift,"X",0,-18,170,new CubicEase{EasingMode=EasingMode.EaseIn});
            leave.Completed+=(_,_)=>
            {
                if(!ReferenceEquals(leave,_contentStory))return;
                ApplyHero(slot);_pendingContent=null;
                var enter=new Storyboard();
                Animate(enter,HeroCard,"Opacity",0,1,320,new CubicEase{EasingMode=EasingMode.EaseOut});Animate(enter,HeroCardShift,"X",18,0,320,new CubicEase{EasingMode=EasingMode.EaseOut});
                enter.Completed+=(_,_)=>{if(ReferenceEquals(enter,_contentStory)){enter.Stop();_contentStory=null;}};
                leave.Stop();_contentStory=enter;enter.Begin();
            };
            _contentStory=leave;leave.Begin();
        }
        else
        {
            ApplyHero(slot);
            var reveal=new Storyboard();Animate(reveal,HeroCard,"Opacity",outgoing is null?0:.35,1,fade,new CubicEase{EasingMode=EasingMode.EaseOut});
            reveal.Completed+=(_,_)=>{if(ReferenceEquals(reveal,_contentStory)){reveal.Stop();_contentStory=null;}};
            _contentStory=reveal;reveal.Begin();
        }
        _artStory=art;art.Begin();
    }
    private void FinishTransition()
    {
        _contentStory?.Stop();_contentStory=null;_artStory?.Stop();_artStory=null;
        if(_pendingContent is { } pending){_pendingContent=null;ApplyHero(pending);}
    }
    private static void Animate(Storyboard story,DependencyObject target,string property,double from,double to,int milliseconds,EasingFunctionBase easing)
    {
        var animation=new DoubleAnimation{From=from,To=to,Duration=TimeSpan.FromMilliseconds(milliseconds),EasingFunction=easing};
        Storyboard.SetTarget(animation,target);Storyboard.SetTargetProperty(animation,property);story.Children.Add(animation);
    }
    private void ApplyHero(HeroSlot slot)
    {
        if(slot.Index<0||slot.Index>=_heroes.Count)return;
        var item=_heroes[slot.Index];
        HeroTitle.Text=item.Title;HeroMetadata.Text=item.Subtitle;HeroSynopsis.Text=item.Synopsis;HeroRatings.SetTitle(item);
        AutomationProperties.SetName(HeroLogo,item.Title);ShowLogo(slot);
    }
    private void ShowLogo(HeroSlot slot)
    {
        var logo=slot.LogoReady&&LogosEnabled;
        HeroLogo.Source=logo?slot.Logo:null;HeroLogo.Visibility=logo?Visibility.Visible:Visibility.Collapsed;HeroTitle.Visibility=logo?Visibility.Collapsed:Visibility.Visible;
    }
    private void LogoChanged(HeroSlot slot){if(_active&&ReferenceEquals(slot,_shown)&&!ReferenceEquals(slot,_pendingContent))ShowLogo(slot);}

    private int[] Upcoming(int target)=>Enumerable.Range(1,2).Select(offset=>(target+offset)%_heroes.Count).Where(index=>index!=target).Distinct().ToArray();
    private HeroSlot Acquire(int target)
    {
        if(_slots.FirstOrDefault(s=>s.Index==target) is { } loaded)return loaded;
        var upcoming=Upcoming(target);
        var slot=_slots.Where(s=>!ReferenceEquals(s,_shown)).OrderBy(s=>s.Index<0?0:upcoming.Contains(s.Index)?2:1).First();
        Load(slot,target);return slot;
    }
    private void Preload(int target)
    {
        if(!_active||_heroes.Count<2||PreferenceStore.Shared.Value.HeroBannerBehavior!="carousel")return;
        var upcoming=Upcoming(target);
        foreach(var index in upcoming)
        {
            if(_slots.Any(s=>s.Index==index))continue;
            if(_slots.FirstOrDefault(s=>!ReferenceEquals(s,_shown)&&!upcoming.Contains(s.Index)) is not { } slot)break;
            Load(slot,index);
        }
    }
    private void Load(HeroSlot slot,int index)
    {
        var title=_heroes[index];
        slot.Index=index;slot.ArtSettled=slot.LogoReady=false;slot.Art.Opacity=0;
        slot.Artwork.Load(title.ArtworkUri,MediaTitle.ImageUri(title.BackdropPath,"w300"),PreferenceStore.Shared.Value.ImageDataSaverEnabled?780:1280);
        slot.LogoLoad?.Cancel();slot.LogoLoad?.Dispose();slot.LogoLoad=null;slot.Logo.UriSource=null;
        slot.LogoSettled=!LogosEnabled;
        if(!slot.LogoSettled){slot.LogoLoad=new();_=LoadLogoAsync(slot,title,slot.LogoLoad.Token);}
        slot.Signal();
    }
    private void ReleaseSlots()
    {
        foreach(var slot in _slots)
        {
            slot.LogoLoad?.Cancel();slot.LogoLoad?.Dispose();slot.LogoLoad=null;
            slot.Index=-1;slot.ArtSettled=slot.LogoSettled=slot.LogoReady=false;slot.Art.Opacity=0;
            slot.Artwork.Release();slot.Logo.UriSource=null;slot.Signal();
        }
        _shown=null;HeroLogo.Source=null;
    }
    private async Task LoadLogoAsync(HeroSlot slot,MediaTitle title,CancellationToken token)
    {
        try
        {
            var data=await TmdbService.Shared.ExtraAsync(title,"images",token);
            var path=JsonValue.Array(data,"logos").OrderByDescending(e=>JsonValue.Text(e,"iso_639_1")=="en").Select(e=>JsonValue.Text(e,"file_path")).FirstOrDefault();
            if(token.IsCancellationRequested)return;
            // ImageOpened/ImageFailed settle the slot once the logo itself has loaded.
            if(MediaTitle.ImageUri(path,"w500") is { } uri){slot.Logo.UriSource=uri;return;}
        }
        catch(OperationCanceledException){return;}catch(TmdbException){}
        if(!token.IsCancellationRequested){slot.LogoSettled=true;slot.Signal();}
    }
    protected override void OnNavigatingFrom(NavigatingCancelEventArgs args)
    {_offset=FindScroll(HomeList)?.VerticalOffset??0;base.OnNavigatingFrom(args);}
    protected override void OnNavigatedFrom(NavigationEventArgs args)
    {_active=false;_carousel.Stop();_load?.Cancel();++_heroGeneration;FinishTransition();ReleaseSlots();BusyBar.IsIndeterminate=false;base.OnNavigatedFrom(args);}
    public void SetWindowActive(bool active){_windowActive=active;ResetCarousel();}
    private bool CanAdvance()=>_active&&_windowActive&&_heroInView&&!_hover&&!_heroFocus&&_heroes.Count>1&&PreferenceStore.Shared.Value.HeroBannerBehavior=="carousel"&&_uiSettings.AnimationsEnabled;
    private void ResetCarousel(){_carousel.Stop();if(CanAdvance()&&_artStory is null&&_pendingContent is null)_carousel.Start();}
    private void Hero_Entered(object sender,PointerRoutedEventArgs args){_hover=true;ResetCarousel();}
    private void Hero_Exited(object sender,PointerRoutedEventArgs args){_hover=false;ResetCarousel();}
    private void Hero_GotFocus(object sender,RoutedEventArgs args){_heroFocus=true;ResetCarousel();}
    private void Hero_LostFocus(object sender,RoutedEventArgs args){_heroFocus=false;ResetCarousel();}
    private void List_Loaded(object sender,RoutedEventArgs args)=>DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,()=>
    {if(!_active)return;if(_homeScroll is not null)_homeScroll.ViewChanged-=Scroll_Changed;_homeScroll=FindScroll(HomeList);if(_homeScroll is not null){_homeScroll.ViewChanged+=Scroll_Changed;_homeScroll.ChangeView(null,_offset,null,true);_heroInView=_homeScroll.VerticalOffset<Hero.ActualHeight;}ResetCarousel();if(_returnHero){Explore.Focus(FocusState.Keyboard);_returnHero=false;}});
    private void Scroll_Changed(object? sender,ScrollViewerViewChangedEventArgs args){ReportAmbientClearance();var visible=(_homeScroll?.VerticalOffset??0)<Hero.ActualHeight;if(visible!=_heroInView){_heroInView=visible;ResetCarousel();}}
    private void Explore_Click(object sender,RoutedEventArgs args){if(_heroes.Count>0){_returnHero=true;TitleRequested?.Invoke(this,new(_heroes[_heroIndex].Id));}}
    private void Row_TitleRequested(object? sender,TitleRequestedEventArgs args){_returnHero=false;TitleRequested?.Invoke(this,args);}
    private void Row_CatalogRequested(object? sender,CatalogRequest args)=>CatalogRequested?.Invoke(this,args);
    private void Previous_Click(object sender,RoutedEventArgs args){if(_heroes.Count>0)ShowHero((_heroIndex+_heroes.Count-1)%_heroes.Count,true);}
    private void Next_Click(object sender,RoutedEventArgs args){if(_heroes.Count>0)ShowHero((_heroIndex+1)%_heroes.Count,true);}
    private void Retry_Click(object sender,RoutedEventArgs args)=>_=LoadAsync();
    private void Search_Invoked(KeyboardAccelerator sender,KeyboardAcceleratorInvokedEventArgs args){SearchRequested?.Invoke(this,EventArgs.Empty);args.Handled=true;}
    private void Root_SizeChanged(object sender,SizeChangedEventArgs args)
    {UpdateHeroLayout();}
    // The settle zoom grows artwork past its slot; keep it inside the banner and its bleed.
    private void HeroGrid_SizeChanged(object sender,SizeChangedEventArgs args)=>HeroGrid.Clip=new RectangleGeometry{Rect=new(0,0,args.NewSize.Width,args.NewSize.Height+HeroArtwork.Tail)};
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
