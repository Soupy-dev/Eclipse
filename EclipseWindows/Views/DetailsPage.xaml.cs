using Eclipse.Windows.Models;
using Eclipse.Windows.Navigation;
using Eclipse.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.UI.Xaml.Input;
using System.Runtime.InteropServices;
using Windows.UI.ViewManagement;
using static Eclipse.Windows.Services.JsonValue;

namespace Eclipse.Windows.Views;

public sealed partial class DetailsPage : Page
{
    private readonly BitmapImage _backdrop=new(){DecodePixelType=DecodePixelType.Logical,DecodePixelWidth=1280};
    private readonly BitmapImage _logo=new(){DecodePixelType=DecodePixelType.Logical,DecodePixelWidth=380};
    private readonly UISettings _uiSettings=new();
    private CancellationTokenSource? _detailCts,_seasonCts;
    private int _generation,_seasonGeneration;
    private string _id="";
    private TitleRequestedEventArgs _request=new("");
    private MediaTitle? _title;
    private IReadOnlyList<MediaEpisode> _episodes=[];
    private IReadOnlyList<MediaTitle> _similar=[];
    private readonly List<BitmapImage> _stills=[];
    private bool _matchingLoaded,_stillsLoaded,_trailersLoaded,_similarLoaded;
    private bool _structureLoading;
    public string DisplayTitle{get;private set;}="";
    public event EventHandler? TitleLoaded;
    public event EventHandler<TitleRequestedEventArgs>? TitleRequested;
    public DetailsPage()
    {
        InitializeComponent();Backdrop.ImageSource=_backdrop;TitleArtwork.Source=_logo;
        foreach(var shelf in new[]{EpisodeList,CastList,SimilarList})shelf.AddHandler(PointerWheelChangedEvent,new PointerEventHandler(Shelf_Wheel),true);
        _logo.ImageOpened+=(_,_)=>{if(_title is not null && PreferenceStore.Shared.Value.MediaDetailTitleArtworkEnabled&&!new AccessibilitySettings().HighContrast){TitleArtwork.Visibility=Visibility.Visible;TitleText.Visibility=Visibility.Collapsed;}};
        _logo.ImageFailed+=(_,_)=>{TitleArtwork.Visibility=Visibility.Collapsed;TitleText.Visibility=Visibility.Visible;};
        Loaded+=(_,_)=>{_uiSettings.TextScaleFactorChanged+=TextScale_Changed;UpdateEpisodeLayout();BackButton.Focus(FocusState.Programmatic);};
        Unloaded+=(_,_)=>_uiSettings.TextScaleFactorChanged-=TextScale_Changed;
    }
    protected override void OnNavigatedTo(NavigationEventArgs args)
    {base.OnNavigatedTo(args);_request=args.Parameter as TitleRequestedEventArgs??new(args.Parameter as string??"");_id=_request.TitleId;_=LoadAsync();}
    private async Task LoadAsync(bool refresh=false)
    {
        _detailCts?.Cancel();_detailCts?.Dispose();_detailCts=new();var token=_detailCts.Token;var generation=++_generation;
        _seasonCts?.Cancel();ClearArtwork();_title=null;_matchingLoaded=_stillsLoaded=_trailersLoaded=_similarLoaded=false;
        HeroFrame.Visibility=BodySections.Visibility=Visibility.Collapsed;LoadError.IsOpen=false;BusyBar.Visibility=Visibility.Visible;BusyBar.IsIndeterminate=true;
        try
        {
            var title=await AnimeMetadataService.Shared.DetailsAsync(_id,token,refresh,_request.Airing?.MalId);token.ThrowIfCancellationRequested();if(generation!=_generation)return;
            _title=title;DisplayTitle=title.Title;TitleLoaded?.Invoke(this,EventArgs.Empty);
            var preferences=PreferenceStore.Shared.Value;
            KindText.Text=title.Kind.ToUpperInvariant();TitleText.Text=title.Title;TitleText.Visibility=Visibility.Visible;TitleArtwork.Visibility=Visibility.Collapsed;
            AutomationProperties.SetName(TitleArtwork,title.Title);AutomationProperties.SetHeadingLevel(TitleArtwork,AutomationHeadingLevel.Level1);
            MetadataText.Text=title.Metadata;TaglineText.Text=title.Tagline;TaglineText.Visibility=title.Tagline.Length>0?Visibility.Visible:Visibility.Collapsed;
            ScheduleContext.Visibility=_request.Airing is null?Visibility.Collapsed:Visibility.Visible;
            if(_request.Airing is {} airing)ScheduleContext.Text=$"{airing.EpisodeLabel} · {airing.TimetableProvider??airing.Provider} · {airing.DisplayTime(preferences.ShowLocalScheduleTime)}";
            OverviewText.Text=string.IsNullOrWhiteSpace(title.Synopsis)?"No overview available.":title.Synopsis;OverviewText.MaxLines=3;OverviewMore.Content="Read more";
            OverviewMore.Visibility=title.Synopsis.Length>150?Visibility.Visible:Visibility.Collapsed;
            _backdrop.DecodePixelWidth=preferences.ImageDataSaverEnabled?780:1280;_backdrop.UriSource=title.ArtworkUri;
            if(preferences.MediaDetailTitleArtworkEnabled&&!new AccessibilitySettings().HighContrast)_logo.UriSource=MediaTitle.ImageUri(title.LogoPath,"w500");
            TmdbLink.Visibility=title.TmdbId>0?Visibility.Visible:Visibility.Collapsed;TmdbLink.NavigateUri=title.TmdbId>0?new Uri($"https://www.themoviedb.org/{title.MediaType}/{title.TmdbId}"):null;
            AniListLink.Visibility=title.AniListId is not null?Visibility.Visible:Visibility.Collapsed;AniListLink.NavigateUri=title.AniListId is {} ani?new Uri($"https://anilist.co/anime/{ani}"):null;
            MalLink.Visibility=title.MalId is not null?Visibility.Visible:Visibility.Collapsed;MalLink.NavigateUri=title.MalId is {} mal?new Uri($"https://myanimelist.net/anime/{mal}"):null;
            RatingText.Text=$"{title.ScoreProvider} rating: {title.Rating}"+(title.Status.Length>0?$"\nStatus: {title.Status.Replace('_',' ')}":"")+
                (title.ReleaseDate.Length>0?$"\n{(title.MediaType=="movie"?"Release date":"First aired")}: {title.ReleaseDate}":"");
            IdentityText.Text=title.IdentityNotice;MatchingSection.Visibility=title.IdentityNotice.Length>0||title.AnimeMappings.Count>0?Visibility.Visible:Visibility.Collapsed;
            while(MatchingContent.Children.Count>2)MatchingContent.Children.RemoveAt(2);
            foreach(var mapping in title.AnimeMappings.Take(60))
            {
                var row=new StackPanel{Spacing=4};
                row.Children.Add(new TextBlock{Text=mapping.TmdbSeason is {} s?$"Season {s}":title.MediaType=="movie"?"Movie":"Series · season unspecified",VerticalAlignment=VerticalAlignment.Center});
                if(mapping.AniListId is {} a)row.Children.Add(new HyperlinkButton{Content=$"AniList {a}",NavigateUri=new Uri($"https://anilist.co/anime/{a}")});
                if(mapping.MalId is {} m)row.Children.Add(new HyperlinkButton{Content=$"MAL {m}",NavigateUri=new Uri($"https://myanimelist.net/anime/{m}")});
                MatchingContent.Children.Add(row);
            }
            CastList.ItemsSource=title.Cast;
            ApplySections(preferences,title);UpdateEpisodeLayout();
            var hasAnime=title.MediaType=="tv"&&(title.AniListId is not null||title.MalId is not null||title.AnimeMappings.Count>0);
            _structureLoading=hasAnime;SeasonPicker.IsEnabled=!hasAnime;SeasonPicker.ItemsSource=null;
            if(!hasAnime)SelectSeason(title);
            if(title.MediaType=="tv"&&title.Seasons.Count==0){SeasonError.Message="Episode metadata is not available for this provider identity.";SeasonError.IsOpen=true;}
            HeroGrid.MinHeight=Math.Clamp(Root.ActualWidth*.4,360,580)*preferences.ExperimentalHeroHeightScale;
            HeroFrame.Visibility=BodySections.Visibility=Visibility.Visible;
            if(hasAnime)_=LoadStructureAsync(title,token,generation,refresh);
        }
        catch(OperationCanceledException){}
        catch(Exception error) when(error is TmdbException or ProviderException)
        {if(!token.IsCancellationRequested&&generation==_generation){LoadError.Message=error.Message;LoadError.IsOpen=true;}}
        finally{if(generation==_generation){BusyBar.IsIndeterminate=false;BusyBar.Visibility=Visibility.Collapsed;}}
    }
    private void SelectSeason(MediaTitle title)
    {
        var selected=_request.Airing is{Source:"Western",Season:{} western}?western:title.MappedSeason;
        var anime=_request.Airing is{Source:"Anime"}airing?title.Seasons.FirstOrDefault(s=>s.Cour is {} c&&(airing.Provider=="MAL"?c.Node.MalId==airing.MediaId:c.Node.AniListId==airing.MediaId)):null;
        if(anime is null&&title.Provider is "AniList" or "MAL")anime=title.Seasons.FirstOrDefault(s=>s.Cour is {} c&&(title.Provider=="MAL"?c.Node.MalId==title.ProviderId:c.Node.AniListId==title.ProviderId));
        SeasonPicker.ItemsSource=title.Seasons;SeasonPicker.SelectedItem=anime??title.Seasons.FirstOrDefault(s=>s.Cour is null?s.Number==selected:s.Cour.Mapping?.TmdbSeason==selected)??title.Seasons.FirstOrDefault();
    }
    private async Task LoadStructureAsync(MediaTitle title,CancellationToken token,int generation,bool refresh)
    {
        EpisodeBusy.Visibility=Visibility.Visible;EpisodeBusy.IsIndeterminate=true;
        try
        {
            var reconciled=await AnimeStructureService.Shared.LoadAsync(title,token,refresh);token.ThrowIfCancellationRequested();if(generation!=_generation)return;
            _title=reconciled;IdentityText.Text=title.IdentityNotice+"\n\n"+reconciled.AnimeStructure?.Notice;
            _structureLoading=false;SeasonPicker.IsEnabled=true;SelectSeason(reconciled);
            if(reconciled.Seasons.Count==0){SeasonError.Message=reconciled.AnimeStructure?.Notice??"Episode counts are unavailable.";SeasonError.IsOpen=true;EpisodeBusy.IsIndeterminate=false;EpisodeBusy.Visibility=Visibility.Collapsed;}
        }
        catch(OperationCanceledException){}
        catch(Exception error)when(error is ProviderException or TmdbException)
        {if(generation==_generation&&!token.IsCancellationRequested){_structureLoading=false;SeasonPicker.IsEnabled=true;SelectSeason(title);SeasonError.Message=error.Message;SeasonError.IsOpen=true;}}
    }
    public void RefreshContrast(){if(new AccessibilitySettings().HighContrast){_logo.UriSource=null;TitleArtwork.Visibility=Visibility.Collapsed;TitleText.Visibility=Visibility.Visible;}}
    private void ApplySections(BrowsingPreferences p,MediaTitle title)
    {
        bool Visible(string key)=>!p.MediaDetailHiddenElements.Contains(key);
        OverviewSection.Visibility=Visible("overview")?Visibility.Visible:Visibility.Collapsed;ActionsSection.Visibility=Visible("actions")?Visibility.Visible:Visibility.Collapsed;
        var sections=new Dictionary<string,FrameworkElement>{{"details",MetadataSection},{"cast",CastSection},{"episodes",SeriesSection},{"stills",StillsSection},{"trailers",TrailersSection},{"similarTitles",SimilarSection}};
        BodySections.Children.Clear();
        foreach(var key in p.MediaDetailElementOrder.Concat(sections.Keys).Distinct())if(sections.TryGetValue(key,out var section))
        {
            var available=key switch{"cast"=>title.Cast.Count>0,"episodes"=>title.MediaType=="tv","stills" or "trailers" or "similarTitles"=>title.TmdbId>0,_=>true};
            section.Visibility=Visible(key)&&available?Visibility.Visible:Visibility.Collapsed;BodySections.Children.Add(section);
        }
        BodySections.Spacing=28*p.ExperimentalSectionSpacingScale;
    }
    private async Task LoadSeasonAsync(bool refresh=false)
    {
        _seasonCts?.Cancel();_seasonCts?.Dispose();_seasonCts=new();var token=_seasonCts.Token;var generation=++_seasonGeneration;
        if(_structureLoading||_title is not {MediaType:"tv"}title||SeasonPicker.SelectedItem is not MediaSeason season)return;
        ReleaseEpisodes();SeasonError.IsOpen=false;EpisodeSummary.Visibility=Visibility.Collapsed;EpisodeBusy.Visibility=Visibility.Visible;EpisodeBusy.IsIndeterminate=true;
        try
        {
            var all=await AnimeStructureService.Shared.EpisodesAsync(title,season,token,refresh);token.ThrowIfCancellationRequested();if(generation!=_seasonGeneration)return;
            _episodes=all.Where(e=>PreferenceStore.Shared.Value.ShowUnairedEpisodes||e.HasAired).ToArray();EpisodeList.ItemsSource=_episodes;UpdateEpisodeLayout();
            if(_request.Airing is{Source:"Western",Episode:>0}airing&&airing.Season==season.Number&&_episodes.FirstOrDefault(e=>e.Number==airing.Episode)is{} selected)
            {EpisodeList.SelectedItem=selected;EpisodeList.ScrollIntoView(selected);}
            if(_request.Airing is{Source:"Anime",Episode:>0}anime&&season.Cour is{} cour&&(anime.Provider=="MAL"?cour.Node.MalId==anime.MediaId:cour.Node.AniListId==anime.MediaId))
            {
                var selectedAnime=_episodes.FirstOrDefault(e=>e.Unit is {} u?(anime.Provider=="MAL"?u.Mal:u.AniList).Contains(anime.Episode):e.Number==anime.Episode);
                if(selectedAnime is not null){EpisodeList.SelectedItem=selectedAnime;EpisodeList.ScrollIntoView(selectedAnime);}
            }
            if(season.Cour is{} c&&(c.Node.Upcoming||all.Count==0||all.Any(e=>e.TmdbEpisodeNumber is null&&e.Unit is null)))
            {SeasonError.Message=c.Node.Upcoming?"Upcoming anime · no episode rows have been published.":all.Count==0?"The provider has not published an episode count.":"Provider episode numbering is preserved. TMDB episode metadata is withheld until its inventory can be reconciled.";SeasonError.IsOpen=true;}
            else if(_episodes.Count==0){SeasonError.Message="No episodes are available with the current appearance settings.";SeasonError.IsOpen=true;}
        }
        catch(OperationCanceledException){}
        catch(Exception error)when(error is TmdbException or ProviderException){if(!token.IsCancellationRequested&&generation==_seasonGeneration){SeasonError.Message=error.Message;SeasonError.IsOpen=true;}}
        finally{if(generation==_seasonGeneration){EpisodeBusy.IsIndeterminate=false;EpisodeBusy.Visibility=Visibility.Collapsed;}}
    }
    private async void Matching_Expanding(Expander sender,ExpanderExpandingEventArgs args)
    {
        if(_matchingLoaded||_title is not {} title||_detailCts is null)return;_matchingLoaded=true;var token=_detailCts.Token;var generation=_generation;
        MatchingBusy.Visibility=Visibility.Visible;MatchingBusy.IsIndeterminate=true;
        try
        {
            MediaTitle? native;
            if(title.AniListId is {} ani)
            {
                try{native=await AnimeMetadataService.Shared.AniListAsync(ani,token);}
                catch(ProviderException)when(title.MalId is not null){native=await AnimeMetadataService.Shared.MalAsync(title.MalId.Value,token);}
            }
            else native=title.MalId is {} mal?await AnimeMetadataService.Shared.MalAsync(mal,token):null;
            if(!token.IsCancellationRequested&&generation==_generation&&native is not null)MatchingContent.Children.Add(new TextBlock{Text=$"{native.ScoreProvider}: {native.Title} · {native.Rating}",TextWrapping=TextWrapping.Wrap});
        }
        catch(OperationCanceledException){}
        catch(ProviderException error){if(!token.IsCancellationRequested&&generation==_generation){MatchingContent.Children.Add(new TextBlock{Text=error.Message,TextWrapping=TextWrapping.Wrap});_matchingLoaded=false;}}
        finally{if(generation==_generation){MatchingBusy.IsIndeterminate=false;MatchingBusy.Visibility=Visibility.Collapsed;}}
    }
    private async void Stills_Expanding(Expander sender,ExpanderExpandingEventArgs args)
    {
        if(_stillsLoaded||_title is not {TmdbId:>0} title||_detailCts is null)return;_stillsLoaded=true;var token=_detailCts.Token;
        await ExtraAsync(StillsContent,async()=>
        {
            var data=await TmdbService.Shared.ExtraAsync(title,"images",token);token.ThrowIfCancellationRequested();
            var paths=Array(data,"backdrops").Select(x=>Text(x,"file_path")).Where(x=>x.Length>0).Take(12).ToArray();
            if(paths.Length==0)StillsContent.Children.Add(new TextBlock{Text="No stills are available."});
            else
            {
                var list=new ListView{Height=210,SelectionMode=ListViewSelectionMode.None,ItemsPanel=(ItemsPanelTemplate)XamlReader.Load("<ItemsPanelTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'><ItemsStackPanel Orientation='Horizontal'/></ItemsPanelTemplate>")};
                ScrollViewer.SetHorizontalScrollMode(list,ScrollMode.Enabled);ScrollViewer.SetVerticalScrollMode(list,ScrollMode.Enabled);ScrollViewer.SetVerticalScrollBarVisibility(list,ScrollBarVisibility.Disabled);ScrollViewer.SetIsVerticalScrollChainingEnabled(list,false);ScrollViewer.SetHorizontalScrollBarVisibility(list,ScrollBarVisibility.Auto);
                list.AddHandler(PointerWheelChangedEvent,new PointerEventHandler(Shelf_Wheel),true);
                // Twelve explicitly requested thumbnails; no original-resolution image downloads.
                foreach(var path in paths){var bitmap=new BitmapImage{DecodePixelWidth=300,UriSource=MediaTitle.ImageUri(path,"w300")};_stills.Add(bitmap);list.Items.Add(new Image{Source=bitmap,Width=300,Height=169,Margin=new Thickness(4),Stretch=Microsoft.UI.Xaml.Media.Stretch.UniformToFill});}
                StillsContent.Children.Add(list);
            }
        },()=>_stillsLoaded=false);
    }
    private async void Trailers_Expanding(Expander sender,ExpanderExpandingEventArgs args)
    {
        if(_trailersLoaded||_title is not {TmdbId:>0}title||_detailCts is null)return;_trailersLoaded=true;var token=_detailCts.Token;
        await ExtraAsync(TrailersContent,async()=>
        {
            var data=await TmdbService.Shared.ExtraAsync(title,"videos",token);token.ThrowIfCancellationRequested();
            var links=0;foreach(var row in Array(data,"results").Where(r=>Text(r,"site")=="YouTube"&&Text(r,"type") is "Trailer" or "Teaser").Take(8))
            {var key=Text(row,"key");if(key.Length is >0 and <40&&key.All(c=>char.IsAsciiLetterOrDigit(c)||c is '_' or '-')){TrailersContent.Children.Add(new HyperlinkButton{Content=Text(row,"name"),NavigateUri=new Uri("https://www.youtube.com/watch?v="+key)});++links;}}
            if(links==0)TrailersContent.Children.Add(new TextBlock{Text="No trailers are available."});
        },()=>_trailersLoaded=false);
    }
    private async Task ExtraAsync(StackPanel content,Func<Task> load,Action retry)
    {
        var generation=_generation;var token=_detailCts!.Token;content.Children.Clear();var progress=new ProgressBar{IsIndeterminate=true,Height=3};content.Children.Add(progress);
        try{await load();}
        catch(OperationCanceledException){}
        catch(TmdbException error){if(!token.IsCancellationRequested&&generation==_generation){content.Children.Add(new TextBlock{Text=error.Message,TextWrapping=TextWrapping.Wrap});retry();}}
        finally{progress.IsIndeterminate=false;if(generation==_generation)content.Children.Remove(progress);}
    }
    private async void Similar_Expanding(Expander sender,ExpanderExpandingEventArgs args)
    {
        if(_similarLoaded||_title is not {TmdbId:>0}title||_detailCts is null)return;_similarLoaded=true;var token=_detailCts.Token;var generation=_generation;SimilarNotice.Text="Loading similar titles…";
        try{var result=await TmdbService.Shared.RelatedAsync(title,token);token.ThrowIfCancellationRequested();if(generation!=_generation)return;_similar=result.Titles.Take(20).ToArray();SimilarList.ItemsSource=_similar;SimilarNotice.Text=_similar.Count==0?"No similar titles are available.":"";}
        catch(OperationCanceledException){}
        catch(TmdbException error){if(!token.IsCancellationRequested&&generation==_generation){SimilarNotice.Text=error.Message;_similarLoaded=false;}}
    }
    private void Similar_Click(object sender,ItemClickEventArgs args){if(args.ClickedItem is MediaTitle title)TitleRequested?.Invoke(this,new(title.Id));}
    private void OverviewMore_Click(object sender,RoutedEventArgs args){var expanded=OverviewText.MaxLines==0;OverviewText.MaxLines=expanded?3:0;OverviewMore.Content=expanded?"Read more":"Show less";}
    private void Episode_SelectionChanged(object sender,SelectionChangedEventArgs args)
    {if(EpisodeList.SelectedItem is not MediaEpisode episode)return;EpisodeSummary.Visibility=Visibility.Visible;EpisodeHeading.Text=$"{episode.Number}. {episode.Title}";EpisodeSynopsis.Text=(episode.Synopsis.Length>0?episode.Synopsis:"No episode overview available.")+$"\n\n{episode.AirLabel} · {episode.Duration}"+(episode.CoordinateLabel.Length>0?$"\n{episode.CoordinateLabel}":"");}
    private void Episode_Changing(ListViewBase sender,ContainerContentChangingEventArgs args)
    {
        if(args.Item is not MediaEpisode episode)return;
        if(args.InRecycleQueue)episode.ReleaseArtwork();
        else AutomationProperties.SetName(args.ItemContainer,episode.AccessibleName);
    }
    private void Season_SelectionChanged(object sender,SelectionChangedEventArgs args)=>_=LoadSeasonAsync();
    private void Retry_Click(object sender,RoutedEventArgs args)=>_=LoadAsync(true);
    private void RetrySeason_Click(object sender,RoutedEventArgs args)=>_=LoadSeasonAsync(true);
    private void Back_Click(object sender,RoutedEventArgs args){if(Frame.CanGoBack)Frame.GoBack(new SuppressNavigationTransitionInfo());}
    private void TextScale_Changed(UISettings sender,object args)=>DispatcherQueue.TryEnqueue(UpdateEpisodeLayout);
    private bool? _horizontal;
    private void UpdateEpisodeLayout()
    {
        CastList.Height=170+84*_uiSettings.TextScaleFactor;
        var horizontal=PreferenceStore.Shared.Value.HorizontalEpisodeList;
        if(_horizontal!=horizontal)
        {
            _horizontal=horizontal;EpisodeList.ItemTemplate=(DataTemplate)Resources[horizontal?"EpisodeCard":"EpisodeRow"];
            EpisodeList.ItemsPanel=(ItemsPanelTemplate)XamlReader.Load($"<ItemsPanelTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'><ItemsStackPanel Orientation='{(horizontal?"Horizontal":"Vertical")}'/></ItemsPanelTemplate>");
            ScrollViewer.SetHorizontalScrollMode(EpisodeList,horizontal?ScrollMode.Enabled:ScrollMode.Disabled);ScrollViewer.SetVerticalScrollMode(EpisodeList,ScrollMode.Enabled);ScrollViewer.SetIsVerticalScrollChainingEnabled(EpisodeList,!horizontal);
        }
        EpisodeList.Height=horizontal?Math.Max(305,305*_uiSettings.TextScaleFactor):Math.Min(480,Math.Max(1,_episodes.Count)*84*_uiSettings.TextScaleFactor);
    }
    private void Root_SizeChanged(object sender,SizeChangedEventArgs args)
    {var compact=args.NewSize.Width<720;ActionsSection.Orientation=compact?Orientation.Vertical:Orientation.Horizontal;PageLayout.Margin=new Thickness(compact?16:32,24,compact?16:32,40);HeroCard.Margin=new Thickness(compact?14:28);HeroCard.Padding=new Thickness(compact?18:24);TitleText.FontSize=compact?32:42;HeroGrid.MinHeight=Math.Clamp(args.NewSize.Width*.4,360,580)*PreferenceStore.Shared.Value.ExperimentalHeroHeightScale;}
    private void Shelf_Wheel(object sender,PointerRoutedEventArgs args)
    {
        if(ReferenceEquals(sender,EpisodeList)&&_horizontal!=true)return;
        var pointer=args.GetCurrentPoint((UIElement)sender).Properties;
        if(pointer.IsHorizontalMouseWheel||(args.KeyModifiers&(global::Windows.System.VirtualKeyModifiers.Control|global::Windows.System.VirtualKeyModifiers.Shift))!=0)return;
        DependencyObject? parent=(DependencyObject)sender;
        while((parent=Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(parent))is not null)
            if(parent is ScrollViewer scroll)
            {if(!SystemParametersInfo(0x0068,0,out var lines,0))lines=3;var distance=pointer.MouseWheelDelta/120d*(lines==uint.MaxValue?scroll.ViewportHeight:lines*16d);scroll.ChangeView(null,Math.Clamp(scroll.VerticalOffset-distance,0,scroll.ScrollableHeight),null,true);args.Handled=true;break;}
    }
    [DllImport("user32.dll",EntryPoint="SystemParametersInfoW",ExactSpelling=true)] [return:MarshalAs(UnmanagedType.Bool)] private static extern bool SystemParametersInfo(uint action,uint parameter,out uint value,uint flags);
    private void ReleaseEpisodes(){EpisodeList.ItemsSource=null;foreach(var episode in _episodes)episode.ReleaseArtwork();_episodes=[];}
    private void ClearArtwork()
    {
        _backdrop.UriSource=_logo.UriSource=null;ReleaseEpisodes();foreach(var item in _similar)item.ReleaseArtwork();_similar=[];SimilarList.ItemsSource=null;
        foreach(var image in _stills)image.UriSource=null;_stills.Clear();StillsContent.Children.Clear();TrailersContent.Children.Clear();if(_title is {} title)foreach(var member in title.Cast)member.ReleaseArtwork();CastList.ItemsSource=null;_title?.ReleaseArtwork();
    }
    protected override void OnNavigatedFrom(NavigationEventArgs args)
    {_detailCts?.Cancel();_seasonCts?.Cancel();++_generation;++_seasonGeneration;BusyBar.IsIndeterminate=EpisodeBusy.IsIndeterminate=MatchingBusy.IsIndeterminate=false;ClearArtwork();SeasonPicker.ItemsSource=null;_title=null;base.OnNavigatedFrom(args);}
}
