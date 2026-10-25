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
using Windows.UI.ViewManagement;
using static Eclipse.Windows.Services.JsonValue;

namespace Eclipse.Windows.Views;

public sealed partial class DetailsPage : Page
{
    private readonly HeroArtwork _artwork;
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
    private bool _stillsLoaded,_trailersLoaded,_similarLoaded;
    private bool _structureLoading,_choosing;
    private MediaSeason? _season;
    private readonly MouseShelfDrag _episodeDrag,_castDrag,_similarDrag;
    public string DisplayTitle{get;private set;}="";
    public event EventHandler? TitleLoaded;
    public event EventHandler<TitleRequestedEventArgs>? TitleRequested;
    public event EventHandler<global::Windows.UI.Color?>? AtmosphereToneChanged;
    public DetailsPage()
    {
        InitializeComponent();_artwork=new(HeroArt);HeroShade.Attach(HeroShadeHost);TitleArtwork.Source=_logo;RefreshAppearance();
        _artwork.Settled+=(_,_)=>AtmosphereToneChanged?.Invoke(this,_artwork.Tone);
        OverviewText.IsTextTrimmedChanged+=(_,_)=>UpdateOverviewMore();
        ShelfWheel.Attach(EpisodeList,()=>_horizontal==true);ShelfWheel.Attach(CastList);ShelfWheel.Attach(SimilarList);
        _episodeDrag=new(EpisodeList);_castDrag=new(CastList);_similarDrag=new(SimilarList);
        _logo.ImageOpened+=(_,_)=>{if(_title is not null && PreferenceStore.Shared.Value.MediaDetailTitleArtworkEnabled&&!new AccessibilitySettings().HighContrast){TitleArtwork.Visibility=Visibility.Visible;TitleText.Visibility=Visibility.Collapsed;}};
        _logo.ImageFailed+=(_,_)=>{TitleArtwork.Visibility=Visibility.Collapsed;TitleText.Visibility=Visibility.Visible;};
        Loaded+=(_,_)=>{_uiSettings.TextScaleFactorChanged+=TextScale_Changed;UpdateEpisodeLayout();ShelfWheel.AttachPage(DetailsScroll);BackButton.Focus(FocusState.Programmatic);};
        Unloaded+=(_,_)=>_uiSettings.TextScaleFactorChanged-=TextScale_Changed;
    }
    protected override void OnNavigatedTo(NavigationEventArgs args)
    {base.OnNavigatedTo(args);_request=args.Parameter as TitleRequestedEventArgs??new(args.Parameter as string??"");_id=_request.TitleId;_=LoadAsync();}
    private async Task LoadAsync(bool refresh=false)
    {
        _detailCts?.Cancel();_detailCts?.Dispose();_detailCts=new();var token=_detailCts.Token;var generation=++_generation;
        _seasonCts?.Cancel();ClearArtwork();_title=null;_stillsLoaded=_trailersLoaded=_similarLoaded=false;
        HeroFrame.Visibility=BodySections.Visibility=LoadError.Visibility=Visibility.Collapsed;LoadError.IsOpen=false;BusyBar.Visibility=Visibility.Visible;BusyBar.IsIndeterminate=true;
        try
        {
            var title=_request.ManualTmdbMatch is {} manual?await TmdbService.Shared.DetailsAsync(manual,token,refresh):await AnimeMetadataService.Shared.DetailsAsync(_id,token,refresh,_request.Airing?.MalId);
            if(_request.ManualTmdbMatch is not null&&(_id.StartsWith("anilist:")||_id.StartsWith("mal:"))){var original=await AnimeMetadataService.Shared.DetailsAsync(_id,token,refresh);title=title with{AniListId=original.AniListId,MalId=original.MalId,Provider=original.Provider,ProviderId=original.ProviderId,Format=original.Format,IdentityNotice="User-selected TMDB title. Season and episode coordinates still require reconciliation."};}
            token.ThrowIfCancellationRequested();if(generation!=_generation)return;
            _title=title;DisplayTitle=title.Title;TitleLoaded?.Invoke(this,EventArgs.Empty);
            NotificationsButton.Visibility=title.MediaType=="tv"&&(title.TmdbId>0||title.AniListId is >0||title.MalId is >0)?Visibility.Visible:Visibility.Collapsed;
            var preferences=PreferenceStore.Shared.Value;
            TitleText.Text=title.Title;TitleText.Visibility=Visibility.Visible;TitleArtwork.Visibility=Visibility.Collapsed;
            AutomationProperties.SetName(TitleArtwork,title.Title);AutomationProperties.SetHeadingLevel(TitleArtwork,AutomationHeadingLevel.Level1);
            // iPad's detailMetadataValues: date, runtime/count, status, then genres.
            MetadataText.Text=string.Join("  ·  ",new[]{title.ReleaseDate,title.Duration,title.Status.Replace('_',' '),title.Genre}.Where(s=>!string.IsNullOrWhiteSpace(s)));
            ScheduleContext.Visibility=_request.Airing is null?Visibility.Collapsed:Visibility.Visible;
            if(_request.Airing is {} airing)ScheduleContext.Text=airing.Id.StartsWith("announcement:",StringComparison.Ordinal)?"New season announcement":$"{(airing.Episode>0?airing.EpisodeLabel:airing.Id.StartsWith("season:",StringComparison.Ordinal)?"Season premiere":airing.Id.Contains("batch:",StringComparison.Ordinal)?"Episode release batch":"Episode TBA")} · {airing.TimetableProvider??airing.Provider} · {airing.DisplayTime(preferences.ShowLocalScheduleTime)}";
            OverviewText.Text=string.IsNullOrWhiteSpace(title.Synopsis)?"No overview available.":title.Synopsis;OverviewText.MaxLines=3;OverviewMore.Content="Read more";
            UpdateOverviewMore();
            _artwork.Load(title.BackdropPath);
            if(preferences.MediaDetailTitleArtworkEnabled&&!new AccessibilitySettings().HighContrast)_logo.UriSource=MediaTitle.ImageUri(title.LogoPath,"w500");
            RatingChip.SetTitle(title);
            CastList.ItemsSource=title.Cast;
            ApplySections(preferences,title);UpdateEpisodeLayout();
            var hasAnime=title.MediaType=="tv"&&(title.AniListId is not null||title.MalId is not null||title.AnimeMappings.Count>0);
            NotificationsButton.IsEnabled=!hasAnime;
            _structureLoading=hasAnime;SeasonPicker.IsEnabled=SpecialPicker.IsEnabled=!hasAnime;ClearSeasons();
            if(!hasAnime)SelectSeason(title);
            if(title.MediaType=="tv"&&title.Seasons.Count==0){SeasonError.Message="Episode metadata is not available for this provider identity.";SeasonError.Visibility=Visibility.Visible;SeasonError.IsOpen=true;}
            UpdateHeroLayout();
            HeroFrame.Visibility=BodySections.Visibility=Visibility.Visible;
            if(hasAnime)_=LoadStructureAsync(title,token,generation,refresh);
        }
        catch(OperationCanceledException){}
        catch(Exception error) when(error is TmdbException or ProviderException)
        {if(!token.IsCancellationRequested&&generation==_generation){LoadError.Message=error.Message;LoadError.Visibility=Visibility.Visible;LoadError.IsOpen=true;}}
        finally{if(generation==_generation){BusyBar.IsIndeterminate=false;BusyBar.Visibility=Visibility.Collapsed;}}
    }
    private void SelectSeason(MediaTitle title)
    {
        var selected=_request.Airing is{Source:"Western",Season:{} western}?western:title.MappedSeason;
        var anime=_request.Airing is{Source:"Anime"}airing?title.Seasons.FirstOrDefault(s=>s.Cour is {} c&&(airing.Provider=="MAL"?c.Node.MalId==airing.MediaId:c.Node.AniListId==airing.MediaId)):null;
        if(anime is null&&title.Provider is "AniList" or "MAL")anime=title.Seasons.FirstOrDefault(s=>s.Cour is {} c&&(title.Provider=="MAL"?c.Node.MalId==title.ProviderId:c.Node.AniListId==title.ProviderId));
        var regular=title.Seasons.Where(s=>!s.IsSpecial).ToArray();
        var specials=title.Seasons.Where(s=>s.IsSpecial).OrderBy(s=>s.Cour!.Node.StartDate.Length==0).ThenBy(s=>s.Cour!.Node.StartDate,StringComparer.Ordinal).ThenBy(s=>s.Cour!.Mapping?.TmdbSeason??s.Cour.Mapping?.TvdbSeason??0).ThenBy(s=>MediaSeason.FormatLabel(s.Cour!.Node.Format),StringComparer.Ordinal).ThenBy(s=>s.Name,StringComparer.CurrentCultureIgnoreCase).ToArray();
        var choice=anime??regular.FirstOrDefault(s=>s.Cour is null?s.Number==selected:s.Cour.Mapping?.TmdbSeason==selected)??regular.FirstOrDefault()??specials.FirstOrDefault();
        _choosing=true;
        SeasonPicker.ItemsSource=regular;SpecialPicker.ItemsSource=specials;
        SeasonPicker.Visibility=regular.Length>0?Visibility.Visible:Visibility.Collapsed;
        SpecialsSection.Visibility=specials.Length>0?Visibility.Visible:Visibility.Collapsed;
        SpecialsCount.Text=specials.Length.ToString();AutomationProperties.SetName(SpecialsCount,$"{specials.Length} specials and OVAs");
        SeasonPicker.SelectedItem=choice is{IsSpecial:false}?choice:null;SpecialPicker.SelectedItem=choice is{IsSpecial:true}?choice:null;
        _choosing=false;
        Choose(choice);
    }
    private void Choose(MediaSeason? season)
    {
        _season=season;EpisodesHeading.Text=season is{IsSpecial:true}?season.Name:"Episodes";
        if(season is not null)_=LoadSeasonAsync();
    }
    private void ClearSeasons()
    {
        _choosing=true;SeasonPicker.ItemsSource=SpecialPicker.ItemsSource=null;_choosing=false;
        _season=null;EpisodesHeading.Text="Episodes";SpecialsSection.Visibility=Visibility.Collapsed;SeasonPicker.Visibility=Visibility.Visible;
    }
    private async void Collections_Click(object sender,RoutedEventArgs args)
    {
        if(_title is null||_detailCts is null)return;var title=_title;
        if(title.MediaType=="tv"&&(title.AniListId is not null||title.MalId is not null))title=_season is{Cour:{HasIdentityConflict:false} cour}&&!_structureLoading?title with{AniListId=cour.Node.AniListId,MalId=cour.Node.MalId}:title with{AniListId=null,MalId=null};
        try{await LibraryDialogs.MembershipAsync(XamlRoot,title,_title.AnimeStructure?.Cours,_detailCts.Token);}catch(OperationCanceledException){}catch(IOException e){await ShowLocalErrorAsync(e.Message);}
    }
    private async void YourRating_Click(object sender,RoutedEventArgs args)
    {if(_title is null)return;try{if(_season is{Cour:{} cour}&&!_structureLoading)UserRatingStore.Shared.ReconcileMal(_title,cour);await LibraryDialogs.RatingAsync(XamlRoot,_title,_season,_structureLoading);}catch(IOException e){await ShowLocalErrorAsync(e.Message);}}
    private async Task ShowLocalErrorAsync(string message)=>await new EclipseDialog{XamlRoot=XamlRoot,Title="Library",Content=message,CloseButtonText="Close"}.ShowAsync();
    private async Task LoadStructureAsync(MediaTitle title,CancellationToken token,int generation,bool refresh)
    {
        EpisodeBusy.Visibility=Visibility.Visible;EpisodeBusy.IsIndeterminate=true;
        try
        {
            var reconciled=await AnimeStructureService.Shared.LoadAsync(title,token,refresh);token.ThrowIfCancellationRequested();if(generation!=_generation)return;
            _title=reconciled;
            NotificationsButton.IsEnabled=true;
            _structureLoading=false;SeasonPicker.IsEnabled=SpecialPicker.IsEnabled=true;SelectSeason(reconciled);
            if(reconciled.Seasons.Count==0){SeasonError.Message=reconciled.AnimeStructure?.Notice??"Episode counts are unavailable.";SeasonError.Visibility=Visibility.Visible;SeasonError.IsOpen=true;EpisodeBusy.IsIndeterminate=false;EpisodeBusy.Visibility=Visibility.Collapsed;}
        }
        catch(OperationCanceledException){}
        catch(Exception error)when(error is ProviderException or TmdbException)
        {if(generation==_generation&&!token.IsCancellationRequested){_structureLoading=false;SeasonPicker.IsEnabled=SpecialPicker.IsEnabled=true;NotificationsButton.IsEnabled=true;SelectSeason(title);SeasonError.Message=error.Message;SeasonError.Visibility=Visibility.Visible;SeasonError.IsOpen=true;}}
    }
    private async void Notifications_Click(object sender,RoutedEventArgs args)
    {
        if(_title is null||_detailCts is null)return;
        NotificationsButton.IsEnabled=false;var token=_detailCts.Token;
        try{if(await NotificationOptions.ShowAsync(XamlRoot,NotificationOptions.Selection(_title)))await EpisodeReminderService.Shared.RefreshAsync(token);}
        catch(OperationCanceledException){}
        catch(Exception e)when(e is IOException or InvalidOperationException or ProviderException or TmdbException)
        {if(IsLoaded){SeasonError.Message=e.Message;SeasonError.IsOpen=true;SeasonError.Visibility=Visibility.Visible;}}
        finally{if(IsLoaded)NotificationsButton.IsEnabled=true;}
    }
    public void RefreshAppearance()
    {
        _artwork.SetBleed(AppearanceService.BleedStrength);
        // High contrast replaces artwork with the system window colour.
        var contrast=new AccessibilitySettings().HighContrast;HeroArt.Visibility=HeroShadeHost.Visibility=contrast?Visibility.Collapsed:Visibility.Visible;HeroContrastPlate.Visibility=contrast?Visibility.Visible:Visibility.Collapsed;
        if(contrast){_logo.UriSource=null;TitleArtwork.Visibility=Visibility.Collapsed;TitleText.Visibility=Visibility.Visible;}
    }
    private void ApplySections(BrowsingPreferences p,MediaTitle title)
    {
        bool Visible(string key)=>!p.MediaDetailHiddenElements.Contains(key);
        OverviewSection.Visibility=Visible("overview")?Visibility.Visible:Visibility.Collapsed;
        HeroDetails.Visibility=Visible("details")?Visibility.Visible:Visibility.Collapsed;RatingChip.Visibility=Visible("details")?Visibility.Visible:Visibility.Collapsed;
        LibraryActions.Visibility=Visible("actions")?Visibility.Visible:Visibility.Collapsed;YourRatingButton.Visibility=Visible("ratingNotes")?Visibility.Visible:Visibility.Collapsed;
        var sections=new Dictionary<string,FrameworkElement>{{"cast",CastSection},{"episodes",SeriesSection},{"stills",StillsSection},{"trailers",TrailersSection},{"similarTitles",SimilarSection}};
        BodySections.Children.Clear();
        // iPad's immersive layout places episodes immediately after the title summary.
        foreach(var key in new[]{"episodes"}.Concat(p.MediaDetailElementOrder).Concat(sections.Keys).Distinct())if(sections.TryGetValue(key,out var section))
        {
            var available=key switch{"cast"=>title.Cast.Count>0,"episodes"=>title.MediaType=="tv","stills" or "trailers" or "similarTitles"=>title.TmdbId>0,_=>true};
            section.Visibility=Visible(key)&&available?Visibility.Visible:Visibility.Collapsed;BodySections.Children.Add(section);
        }
        BodySections.Spacing=28*p.ExperimentalSectionSpacingScale;
    }
    private async Task LoadSeasonAsync(bool refresh=false)
    {
        _seasonCts?.Cancel();_seasonCts?.Dispose();_seasonCts=new();var token=_seasonCts.Token;var generation=++_seasonGeneration;
        if(_structureLoading||_title is not {MediaType:"tv"}title||_season is not{} season)return;
        ReleaseEpisodes();SeasonError.Visibility=Visibility.Collapsed;SeasonError.IsOpen=false;EpisodeSummary.Visibility=Visibility.Collapsed;EpisodeBusy.Visibility=Visibility.Visible;EpisodeBusy.IsIndeterminate=true;
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
            {SeasonError.Message=c.Node.Upcoming?"Upcoming anime · no episode rows have been published.":all.Count==0?"The provider has not published an episode count.":"Provider episode numbering is preserved. TMDB episode metadata is withheld until its inventory can be reconciled.";SeasonError.Visibility=Visibility.Visible;SeasonError.IsOpen=true;}
            else if(_episodes.Count==0){SeasonError.Message="No episodes are available with the current appearance settings.";SeasonError.Visibility=Visibility.Visible;SeasonError.IsOpen=true;}
        }
        catch(OperationCanceledException){}
        catch(Exception error)when(error is TmdbException or ProviderException){if(!token.IsCancellationRequested&&generation==_seasonGeneration){SeasonError.Message=error.Message;SeasonError.Visibility=Visibility.Visible;SeasonError.IsOpen=true;}}
        finally{if(generation==_seasonGeneration){EpisodeBusy.IsIndeterminate=false;EpisodeBusy.Visibility=Visibility.Collapsed;}}
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
                ShelfWheel.Attach(list);_=new MouseShelfDrag(list);
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
    private void Similar_Click(object sender,ItemClickEventArgs args){if(!_similarDrag.SuppressClick&&args.ClickedItem is MediaTitle title)TitleRequested?.Invoke(this,new(title.Id));}
    private void OverviewMore_Click(object sender,RoutedEventArgs args)
    {
        var expanded=OverviewText.MaxLines==0;
        // Expand downward from where the copy sits, over the fade and bleed, so the logo and artwork stay put.
        if(!expanded){var top=HeroCard.TransformToVisual(HeroGrid).TransformPoint(default).Y;HeroCard.VerticalAlignment=VerticalAlignment.Top;HeroCard.Margin=new Thickness(HeroCard.Margin.Left,top,HeroCard.Margin.Right,HeroCard.Margin.Bottom);}
        OverviewText.MaxLines=expanded?3:0;OverviewMore.Content=expanded?"Read more":"Show less";
        if(expanded)UpdateHeroLayout();
    }
    // Offer the toggle only when the collapsed overview is actually truncated.
    private void UpdateOverviewMore()=>OverviewMore.Visibility=OverviewText.MaxLines==0||OverviewText.IsTextTrimmed?Visibility.Visible:Visibility.Collapsed;
    private void Episode_SelectionChanged(object sender,SelectionChangedEventArgs args)
    {if(EpisodeList.SelectedItem is not MediaEpisode episode)return;EpisodeSummary.Visibility=Visibility.Visible;EpisodeHeading.Text=$"{episode.Number}. {episode.Title}";EpisodeSynopsis.Text=episode.Synopsis.Length>0?episode.Synopsis:"No episode overview available.";}
    private void Episode_Changing(ListViewBase sender,ContainerContentChangingEventArgs args)
    {
        if(args.Item is not MediaEpisode episode)return;
        if(args.InRecycleQueue)episode.ReleaseArtwork();
        else AutomationProperties.SetName(args.ItemContainer,episode.AccessibleName);
    }
    private void Cast_Changing(ListViewBase sender,ContainerContentChangingEventArgs args)
    {if(args.InRecycleQueue&&args.Item is CastMember member)member.ReleaseArtwork();}
    private void Season_SelectionChanged(object sender,SelectionChangedEventArgs args)
    {if(_choosing||SeasonPicker.SelectedItem is not MediaSeason season)return;_choosing=true;SpecialPicker.SelectedItem=null;_choosing=false;Choose(season);}
    private void Special_SelectionChanged(object sender,SelectionChangedEventArgs args)
    {if(_choosing||SpecialPicker.SelectedItem is not MediaSeason special)return;_choosing=true;SeasonPicker.SelectedItem=null;_choosing=false;Choose(special);}
    private void Retry_Click(object sender,RoutedEventArgs args)=>_=LoadAsync(true);
    private void RetrySeason_Click(object sender,RoutedEventArgs args)=>_=LoadSeasonAsync(true);
    private void Back_Click(object sender,RoutedEventArgs args){if(Frame.CanGoBack)Frame.GoBack(new SuppressNavigationTransitionInfo());}
    private void TextScale_Changed(UISettings sender,object args)=>DispatcherQueue.TryEnqueue(UpdateEpisodeLayout);
    private bool? _horizontal;
    private void UpdateEpisodeLayout()
    {
        CastList.Height=96+84*_uiSettings.TextScaleFactor;
        var horizontal=PreferenceStore.Shared.Value.HorizontalEpisodeList;
        if(_horizontal!=horizontal)
        {
            _horizontal=horizontal;EpisodeList.ItemTemplate=(DataTemplate)Resources[horizontal?"EpisodeCard":"EpisodeRow"];
            EpisodeList.ItemsPanel=(ItemsPanelTemplate)XamlReader.Load($"<ItemsPanelTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'><ItemsStackPanel Orientation='{(horizontal?"Horizontal":"Vertical")}' CacheLength='1'/></ItemsPanelTemplate>");
            ScrollViewer.SetHorizontalScrollMode(EpisodeList,horizontal?ScrollMode.Enabled:ScrollMode.Disabled);ScrollViewer.SetVerticalScrollMode(EpisodeList,ScrollMode.Enabled);ScrollViewer.SetIsVerticalScrollChainingEnabled(EpisodeList,!horizontal);
            ScrollViewer.SetVerticalScrollBarVisibility(EpisodeList,horizontal?ScrollBarVisibility.Disabled:ScrollBarVisibility.Auto);
        }
        EpisodeList.Height=horizontal?Math.Max(305,305*_uiSettings.TextScaleFactor):Math.Min(480,Math.Max(1,_episodes.Count)*84*_uiSettings.TextScaleFactor);
    }
    private void Root_SizeChanged(object sender,SizeChangedEventArgs args)
    {UpdateHeroLayout();}
    private void UpdateHeroLayout()
    {
        var width=Root.ActualWidth;var compact=width<720;var inset=compact?16:32;
        BusyBar.Margin=LoadError.Margin=new Thickness(inset,64,inset,0);
        BodySections.Margin=new Thickness(inset,0,inset,0);BodySections.Width=Math.Max(1,width-inset*2);
        foreach(var section in new FrameworkElement[]{CastSection,StillsSection,TrailersSection,SimilarSection})section.Width=Math.Min(1100,BodySections.Width);
        var expanded=OverviewText.MaxLines==0;
        BackButton.Margin=new Thickness(inset,16,0,0);HeroCard.Margin=new Thickness(inset,expanded?HeroCard.Margin.Top:100,inset,48);TitleText.FontSize=compact?32:44;
        if(!expanded)HeroCard.VerticalAlignment=VerticalAlignment.Bottom;
        var height=Math.Max(400,Math.Min(width*9/16,Math.Max(400,Root.ActualHeight)*.72))*PreferenceStore.Shared.Value.ExperimentalHeroHeightScale;
        var tail=Math.Round(height*HeroArtwork.TailRatio);
        HeroGrid.MinHeight=HeroShadeHost.Height=height;HeroArt.Height=height+tail;HeroArt.Margin=new Thickness(0,0,0,-tail);_artwork.Tail=tail;
    }
    private void ReleaseEpisodes(){EpisodeList.ItemsSource=null;foreach(var episode in _episodes)episode.ReleaseArtwork();_episodes=[];}
    private void ClearArtwork()
    {
        _artwork.Release();_logo.UriSource=null;ReleaseEpisodes();foreach(var item in _similar)item.ReleaseArtwork();_similar=[];SimilarList.ItemsSource=null;
        foreach(var image in _stills)image.UriSource=null;_stills.Clear();StillsContent.Children.Clear();TrailersContent.Children.Clear();if(_title is {} title)foreach(var member in title.Cast)member.ReleaseArtwork();CastList.ItemsSource=null;_title?.ReleaseArtwork();
    }
    protected override void OnNavigatedFrom(NavigationEventArgs args)
    {_detailCts?.Cancel();_seasonCts?.Cancel();++_generation;++_seasonGeneration;BusyBar.IsIndeterminate=EpisodeBusy.IsIndeterminate=false;ClearArtwork();ClearSeasons();_episodeDrag.Reset();_castDrag.Reset();_similarDrag.Reset();_title=null;base.OnNavigatedFrom(args);}
}
