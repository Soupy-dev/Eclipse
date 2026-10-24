using System.Collections.ObjectModel;
using System.Globalization;
using Eclipse.Windows.Models;
using Eclipse.Windows.Navigation;
using Eclipse.Windows.Services;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;

namespace Eclipse.Windows.Views;

public sealed partial class BrowsePage : Page
{
    private static readonly Dictionary<string,int?> Keywords=[];
    private readonly ObservableCollection<MediaTitle> _results=[];
    private readonly HashSet<string> _seen=[];
    private readonly DispatcherTimer _apply=new(){Interval=TimeSpan.FromMilliseconds(500)};
    private Dictionary<string,BrowseFilterConfiguration>? _configs;
    private CancellationTokenSource? _load;
    private string _type="Movies";
    private int _page,_generation;
    private bool _hasMore,_loading,_setting,_released,_active,_flyoutOpen,_stale,_resume;
    private double _offset;
    public event EventHandler<TitleRequestedEventArgs>? TitleRequested;
    private BrowseFilterConfiguration Current=>_configs![_type];

    public BrowsePage()
    {
        InitializeComponent();
        ResultsGrid.ItemsSource=_results;
        _apply.Tick+=(_,_)=>{_apply.Stop();Save();Reload();};
    }

    protected override void OnNavigatedTo(NavigationEventArgs args)
    {
        base.OnNavigatedTo(args);_active=true;
        if(Frame is not null)Frame.Navigated-=Frame_Navigated;
        if(_configs is null)
        {
            var saved=PreferenceStore.Shared.Value.BrowseFilterPreferences;
            _configs=BrowseOptions.MediaTypes.ToDictionary(type=>type,type=>BrowseOptions.Sanitized(saved.ConfigurationsByMediaType.GetValueOrDefault(type),type));
            _type=saved.MediaTypeRawValue;
            _setting=true;TypeBar.SelectedItem=TypeBar.Items.First(i=>(string)i.Tag==_type);_setting=false;
            BuildFilters();Reload();return;
        }
        if(_released)
        {
            _released=false;ResultsGrid.ItemsSource=_results;
            var offset=_offset;if(args.NavigationMode!=NavigationMode.New)DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,()=>FindScroll(ResultsGrid)?.ChangeView(null,offset,null,true));
        }
        if(_stale){_stale=_resume=false;Reload();}
        else if(_resume&&_results.Count>0){_resume=false;LoadMore();}
        else if(_results.Count==0&&!_loading){_resume=false;Reload();}
        else if(args.NavigationMode==NavigationMode.New)FindScroll(ResultsGrid)?.ChangeView(null,0,null,true);
    }

    protected override void OnNavigatedFrom(NavigationEventArgs args)
    {
        _active=false;
        if(_apply.IsEnabled){_apply.Stop();Save();_stale=true;}
        if(args.SourcePageType==typeof(DetailsPage)){Frame.Navigated-=Frame_Navigated;Frame.Navigated+=Frame_Navigated;}
        else Release();
        base.OnNavigatedFrom(args);
    }

    private void Frame_Navigated(object sender,NavigationEventArgs args)
    {
        if(ReferenceEquals(args.Content,this)){Frame.Navigated-=Frame_Navigated;return;}
        if(args.Content is DetailsPage)return;
        ((Frame)sender).Navigated-=Frame_Navigated;Release();
    }

    private void Release()
    {
        if(_released)return;
        _offset=FindScroll(ResultsGrid)?.VerticalOffset??0;
        if(_loading){_load?.Cancel();++_generation;_loading=false;LoadingBar.IsIndeterminate=false;LoadingBar.Visibility=Visibility.Collapsed;_resume=true;}
        _released=true;PosterImages.Clear(ResultsGrid);ResultsGrid.ItemsSource=null;
    }

    private void Save()
    {
        if(_configs is null)return;
        var preferences=PreferenceStore.Shared.Copy();
        preferences.BrowseFilterPreferences=new(){MediaTypeRawValue=_type,ConfigurationsByMediaType=_configs.ToDictionary(pair=>pair.Key,pair=>BrowseOptions.Sanitized(pair.Value,pair.Key))};
        try{PreferenceStore.Shared.Save(preferences);}catch(Exception error) when(error is IOException or UnauthorizedAccessException){}
    }

    private void Changed(bool immediate)
    {
        if(!_flyoutOpen)BuildFilters();
        _apply.Stop();
        if(immediate){Save();Reload();}else _apply.Start();
    }

    private void BuildFilters()
    {
        var config=Current;var genres=BrowseOptions.Genres(_type);var countries=BrowseOptions.Countries(_type);var anime=_type=="Anime";
        var genreOptions=genres.Select(g=>(g.Key,g.Name)).ToArray();
        var yearOptions=BrowseOptions.Years.Select(y=>(y.ToString(CultureInfo.InvariantCulture),y.ToString(CultureInfo.InvariantCulture))).ToArray();
        Filters.Children.Clear();
        Filters.Children.Add(Multi(anime?"Anime Genres":"Genres",BrowseOptions.Summary(genres.Where(g=>config.SelectedGenreKeys.Contains(g.Key)).Select(g=>g.Name),anime?"Any Anime Genre":"Any Genre"),"Any Genre",genreOptions,
            ()=>config.SelectedGenreKeys,(key,on)=>{Toggle(config.SelectedGenreKeys,key,on);if(on)config.ExcludedGenreKeys.Remove(key);},()=>config.SelectedGenreKeys.Clear()));
        Filters.Children.Add(Multi("Exclude Genres",BrowseOptions.Summary(genres.Where(g=>config.ExcludedGenreKeys.Contains(g.Key)).Select(g=>g.Name),"None"),"Exclude None",genreOptions,
            ()=>config.ExcludedGenreKeys,(key,on)=>{Toggle(config.ExcludedGenreKeys,key,on);if(on)config.SelectedGenreKeys.Remove(key);},()=>config.ExcludedGenreKeys.Clear()));
        Filters.Children.Add(Multi("Year",BrowseOptions.Summary(config.SelectedYears.OrderDescending().Select(y=>y.ToString(CultureInfo.InvariantCulture)),"Any Year"),"Any Year",yearOptions,
            ()=>config.SelectedYears.Select(y=>y.ToString(CultureInfo.InvariantCulture)).ToArray(),(key,on)=>{var year=int.Parse(key,CultureInfo.InvariantCulture);Toggle(config.SelectedYears,year,on);if(on)config.ExcludedYears.Remove(year);},()=>config.SelectedYears.Clear()));
        Filters.Children.Add(Multi("Exclude Years",BrowseOptions.Summary(config.ExcludedYears.OrderDescending().Select(y=>y.ToString(CultureInfo.InvariantCulture)),"None"),"Exclude None",yearOptions,
            ()=>config.ExcludedYears.Select(y=>y.ToString(CultureInfo.InvariantCulture)).ToArray(),(key,on)=>{var year=int.Parse(key,CultureInfo.InvariantCulture);Toggle(config.ExcludedYears,year,on);if(on)config.SelectedYears.Remove(year);},()=>config.ExcludedYears.Clear()));
        Filters.Children.Add(Multi("Countries",BrowseOptions.Summary(countries.Where(c=>config.SelectedCountryCodes.Contains(c.Code)).Select(c=>c.Name),"Any Country"),"Any Country",countries.Select(c=>(c.Code,c.Name)).ToArray(),
            ()=>config.SelectedCountryCodes,(key,on)=>Toggle(config.SelectedCountryCodes,key,on),()=>config.SelectedCountryCodes.Clear()));
        Filters.Children.Add(Single("Order",BrowseOptions.Sorts,config.SortRawValue,value=>config.SortRawValue=value));
        Filters.Children.Add(Single("Rating",new[]{("0","Any Rating")}.Concat(new[]{5,6,7,8,9}.Select(star=>(star.ToString(CultureInfo.InvariantCulture),$"{star}+ Stars"))).ToArray(),((int)config.MinimumRating).ToString(CultureInfo.InvariantCulture),value=>config.MinimumRating=int.Parse(value,CultureInfo.InvariantCulture)));
        Filters.Children.Add(Single("Age Rating",BrowseOptions.AgeRatings,config.AgeRatingRawValue,value=>config.AgeRatingRawValue=value));
        if(config.HasActiveFilters)
        {
            var reset=new Button{Content=new StackPanel{Orientation=Orientation.Horizontal,Spacing=8,Children={new FontIcon{Glyph="",FontSize=14},new TextBlock{Text="Reset",FontWeight=FontWeights.SemiBold}}},HorizontalAlignment=HorizontalAlignment.Stretch,VerticalAlignment=VerticalAlignment.Stretch,HorizontalContentAlignment=HorizontalAlignment.Left,Margin=new(0,0,8,8)};
            AutomationProperties.SetName(reset,"Reset filters");
            reset.Click+=(_,_)=>{_configs![_type]=BrowseOptions.Default(_type);Changed(true);};
            Filters.Children.Add(reset);
        }
    }

    private static void Toggle<T>(List<T> list,T value,bool on){if(on){if(!list.Contains(value))list.Add(value);}else list.Remove(value);}

    private DropDownButton Chip(string title,string value,FlyoutBase flyout)
    {
        var content=new StackPanel();
        content.Children.Add(new TextBlock{Text=title,Style=(Style)Application.Current.Resources["CaptionTextBlockStyle"],Foreground=(Brush)Application.Current.Resources["TextFillColorSecondaryBrush"]});
        content.Children.Add(new TextBlock{Text=value,FontWeight=FontWeights.SemiBold,TextTrimming=TextTrimming.CharacterEllipsis,MaxLines=1});
        var button=new DropDownButton{Content=content,Flyout=flyout,HorizontalAlignment=HorizontalAlignment.Stretch,VerticalAlignment=VerticalAlignment.Stretch,HorizontalContentAlignment=HorizontalAlignment.Left,Margin=new(0,0,8,8)};
        AutomationProperties.SetName(button,$"{title}: {value}");
        return button;
    }

    private DropDownButton Multi(string title,string value,string clear,IReadOnlyList<(string Key,string Name)> options,Func<IReadOnlyCollection<string>> current,Action<string,bool> toggle,Action reset)
    {
        var flyout=new Flyout();
        var list=new StackPanel{Spacing=2};
        var selected=current();
        var boxes=options.Select(option=>new CheckBox{Content=option.Name,Tag=option.Key,IsChecked=selected.Contains(option.Key)}).ToArray();
        var clearButton=new Button{Content=clear,HorizontalAlignment=HorizontalAlignment.Stretch,Margin=new(0,0,0,8)};
        clearButton.Click+=(_,_)=>{reset();_setting=true;foreach(var box in boxes)box.IsChecked=false;_setting=false;Changed(false);};
        foreach(var box in boxes)
        {
            box.Checked+=(_,_)=>{if(!_setting){toggle((string)box.Tag,true);Sync();Changed(false);}};
            box.Unchecked+=(_,_)=>{if(!_setting){toggle((string)box.Tag,false);Changed(false);}};
            list.Children.Add(box);
        }
        void Sync(){var now=current();_setting=true;foreach(var box in boxes)box.IsChecked=now.Contains((string)box.Tag);_setting=false;}
        var panel=new StackPanel{MinWidth=220};panel.Children.Add(clearButton);panel.Children.Add(new ScrollViewer{Content=list,MaxHeight=360});
        flyout.Content=panel;
        flyout.Opened+=(_,_)=>_flyoutOpen=true;
        var chip=Chip(title,value,flyout);
        flyout.Closed+=(_,_)=>
        {
            _flyoutOpen=false;var index=Filters.Children.IndexOf(chip);BuildFilters();
            if(Filters.Children.ElementAtOrDefault(index) is Control replacement)replacement.Focus(FocusState.Programmatic);
            if(_apply.IsEnabled){_apply.Stop();Save();Reload();}
        };
        return chip;
    }

    private DropDownButton Single(string title,IReadOnlyList<(string Raw,string Title)> options,string current,Action<string> select)
    {
        var flyout=new MenuFlyout();
        var chip=Chip(title,options.FirstOrDefault(o=>o.Raw==current).Title??options[0].Title,flyout);
        foreach(var option in options)
        {
            var item=new RadioMenuFlyoutItem{Text=option.Title,GroupName=title,IsChecked=option.Raw==current};
            item.Click+=(_,_)=>
            {
                if(option.Raw==current)return;
                var index=Filters.Children.IndexOf(chip);select(option.Raw);Changed(true);
                if(Filters.Children.ElementAtOrDefault(index) is Control replacement)replacement.Focus(FocusState.Programmatic);
            };
            flyout.Items.Add(item);
        }
        return chip;
    }

    private void Type_Changed(SelectorBar sender,SelectorBarSelectionChangedEventArgs args)
    {
        if(_setting||_configs is null||sender.SelectedItem is not {Tag:string type}||type==_type)return;
        _type=type;BuildFilters();Changed(true);
    }

    private void Reload()
    {
        _load?.Cancel();++_generation;_loading=false;
        PosterImages.Clear(ResultsGrid);_results.Clear();_seen.Clear();_page=0;_hasMore=true;
        LoadError.IsOpen=false;EmptyText.Visibility=Visibility.Collapsed;
        FindScroll(ResultsGrid)?.ChangeView(null,0,null,true);
        _=LoadPageAsync(1);
    }

    private void LoadMore(){if(!_loading&&_hasMore&&!_released&&_active)_=LoadPageAsync(_page+1);}

    private async Task LoadPageAsync(int page)
    {
        _load?.Cancel();_load?.Dispose();_load=new();var token=_load.Token;var generation=_generation;
        _loading=true;LoadingBar.IsIndeterminate=true;LoadingBar.Visibility=Visibility.Visible;LoadError.IsOpen=false;
        var type=_type;var config=BrowseOptions.Sanitized(Current,type);var continueLoading=false;
        try
        {
            var genres=BrowseOptions.Genres(type);
            var selected=genres.Where(g=>config.SelectedGenreKeys.Contains(g.Key)).ToArray();var excluded=genres.Where(g=>config.ExcludedGenreKeys.Contains(g.Key)).ToArray();
            foreach(var keyword in selected.Concat(excluded).Select(g=>g.Keyword).OfType<string>().Distinct())
                if(!Keywords.ContainsKey(keyword))Keywords[keyword]=await TmdbService.Shared.KeywordIdAsync(keyword,token);
            int[] KeywordIds(IEnumerable<BrowseGenre> source)=>source.Select(g=>g.Keyword is{} k?Keywords.GetValueOrDefault(k):null).OfType<int>().Distinct().Order().ToArray();
            var withGenres=selected.Select(g=>g.GenreId).OfType<int>().Concat(type=="Anime"?[16]:[]).Distinct().Order().ToArray();
            var withoutGenres=excluded.Select(g=>g.GenreId).OfType<int>().Distinct().Order().ToArray();
            var countries=config.SelectedCountryCodes.Order(StringComparer.Ordinal).ToArray();
            var tmdbType=BrowseOptions.TmdbType(type);
            var filters=new Dictionary<string,string>{["sort_by"]=BrowseOptions.TmdbSort(config.SortRawValue,type)};
            if(withGenres.Length>0)filters["with_genres"]=string.Join(',',withGenres);
            if(withoutGenres.Length>0)filters["without_genres"]=string.Join(',',withoutGenres);
            if(KeywordIds(selected) is{Length:>0} withKeywords)filters["with_keywords"]=string.Join(',',withKeywords);
            if(KeywordIds(excluded) is{Length:>0} withoutKeywords)filters["without_keywords"]=string.Join(',',withoutKeywords);
            if(countries.Length>0)filters["with_origin_country"]=string.Join('|',countries);
            if(type=="Anime"&&countries.Length==1&&countries[0] switch{"JP"=>"ja","CN" or "TW"=>"zh","KR"=>"ko",_=>null} is{} language)filters["with_original_language"]=language;
            if(config.SortRawValue=="vote_average.desc")filters["vote_count.gte"]="100";
            if(config.MinimumRating>0)filters["vote_average.gte"]=config.MinimumRating.ToString(CultureInfo.InvariantCulture);
            var years=config.SelectedYears.Where(y=>!config.ExcludedYears.Contains(y)).OrderDescending().ToArray();
            IEnumerable<MediaTitle> fetched;bool hasMore;
            if(config.SelectedYears.Count>0&&years.Length==0){fetched=[];hasMore=false;}
            else if(years.Length==0){var result=await TmdbService.Shared.BrowseDiscoverAsync(tmdbType,filters,page,token);fetched=result.Titles;hasMore=page<result.TotalPages;}
            else
            {
                var results=await Task.WhenAll(years.Select(year=>TmdbService.Shared.BrowseDiscoverAsync(tmdbType,new(filters){[tmdbType=="tv"?"first_air_date_year":"primary_release_year"]=year.ToString(CultureInfo.InvariantCulture)},page,token)));
                fetched=results.SelectMany(r=>r.Titles);hasMore=results.Any(r=>page<r.TotalPages);
            }
            var typed=fetched.Where(t=>type=="Movies"||Classify(t)==(type=="Anime"?"anime":"nonAnime")).ToArray();
            if(config.AgeRatingRawValue!="all")
            {
                await MaturityRatings.ResolveAsync(typed,token);
                typed=typed.Where(t=>MaturityRatings.Includes(config.AgeRatingRawValue,MaturityRatings.Cached(t),type=="Anime"&&MaturityRatings.HasExplicitAnimeMetadata(t))).ToArray();
            }
            var excludedYears=config.ExcludedYears.ToHashSet();var excludedIds=withoutGenres.ToHashSet();
            typed=typed.Where(t=>!(t.ReleaseDate.Length>=4&&int.TryParse(t.ReleaseDate[..4],out var year)&&excludedYears.Contains(year))&&!t.GenreIds.Any(excludedIds.Contains)).ToArray();
            if(generation!=_generation||token.IsCancellationRequested)return;
            var sort=config.SortRawValue;
            foreach(var title in RegionGuarded(typed,countries))
            {
                if(_results.Count>=1000||!_seen.Add(title.Id))continue;
                int low=0,high=_results.Count;
                while(low<high){var middle=(low+high)/2;if(Compare(_results[middle],title,sort)<=0)low=middle+1;else high=middle;}
                _results.Insert(low,title);
            }
            _page=page;_hasMore=hasMore&&_results.Count<1000;
            EmptyText.Visibility=_results.Count==0&&!_hasMore?Visibility.Visible:Visibility.Collapsed;
            continueLoading=_hasMore&&_results.Count<12&&page<8;
        }
        catch(OperationCanceledException){}
        catch(TmdbException error) when(generation==_generation&&!token.IsCancellationRequested){LoadError.Message=error.Message;LoadError.IsOpen=true;}
        finally
        {
            if(generation==_generation){_loading=false;LoadingBar.IsIndeterminate=false;LoadingBar.Visibility=Visibility.Collapsed;}
        }
        if(continueLoading&&generation==_generation)LoadMore();
    }

    private static string Classify(MediaTitle title)
    {
        if(title.MediaType!="tv"||!title.GenreIds.Contains(16))return "nonAnime";
        if(title.OriginCountries.Length>0)return title.OriginCountries.Any(c=>c is "JP" or "CN" or "KR" or "TW")?"anime":"nonAnime";
        if(title.OriginalLanguage.Length>0)return title.OriginalLanguage.ToLowerInvariant() is "ja" or "zh" or "ko"?"anime":"nonAnime";
        return "unknown";
    }

    private static string[]? ExpectedLanguages(string country)=>country switch{"US" or "GB" or "AU"=>["en"],"CA"=>["en","fr"],"JP"=>["ja"],"KR"=>["ko"],"CN" or "TW"=>["zh","cn"],"FR"=>["fr"],"DE"=>["de"],"ES"=>["es","ca"],"MX"=>["es"],"BR"=>["pt"],"TH"=>["th"],_=>null};

    private static IEnumerable<MediaTitle> RegionGuarded(IEnumerable<MediaTitle> titles,string[] countries)
    {
        if(countries.Length==0)return titles;
        var languages=countries.Select(ExpectedLanguages).ToArray();var acceptable=languages.OfType<string[]>().SelectMany(set=>set).ToHashSet();var fallback=languages.All(set=>set is not null);
        return titles.Where(t=>t.OriginCountries.Length>0?t.OriginCountries.Intersect(countries).Any():!fallback||t.OriginalLanguage.Length==0||acceptable.Contains(t.OriginalLanguage.ToLowerInvariant()));
    }

    private static int Compare(MediaTitle a,MediaTitle b,string sort)
    {
        if(sort is "newest" or "oldest"&&a.ReleaseDate!=b.ReleaseDate)
        {
            if(a.ReleaseDate.Length==0)return 1;if(b.ReleaseDate.Length==0)return -1;
            return sort=="newest"?string.CompareOrdinal(b.ReleaseDate,a.ReleaseDate):string.CompareOrdinal(a.ReleaseDate,b.ReleaseDate);
        }
        if(sort=="vote_average.desc"&&a.Score!=b.Score)return b.Score.CompareTo(a.Score);
        if(sort=="title.asc"&&string.Compare(a.Title,b.Title,CultureInfo.CurrentCulture,CompareOptions.IgnoreCase) is var order and not 0)return order;
        if(a.Popularity!=b.Popularity)return b.Popularity.CompareTo(a.Popularity);
        return string.Compare(a.Title,b.Title,CultureInfo.CurrentCulture,CompareOptions.IgnoreCase);
    }

    private void Retry_Click(object sender,RoutedEventArgs args){if(_results.Count==0)Reload();else LoadMore();}
    private void Title_ItemClick(object sender,ItemClickEventArgs args){if(args.ClickedItem is MediaTitle title)TitleRequested?.Invoke(this,new(title.Id));}
    private void Results_ContainerContentChanging(ListViewBase sender,ContainerContentChangingEventArgs args)
    {
        if(!args.InRecycleQueue&&args.Item is MediaTitle title){AutomationProperties.SetName(args.ItemContainer,title.AccessibleName);if(args.ItemIndex>=_results.Count-6)LoadMore();}
        PosterImages.Update(args,(args.Item as MediaTitle)?.PosterUri,ResultsGrid.ItemsPanelRoot is ItemsWrapGrid panel?(panel.ItemWidth-16)*1.5:246);
    }
    private void ResultsGrid_SizeChanged(object sender,SizeChangedEventArgs args)
    {
        if(ResultsGrid.ItemsPanelRoot is not ItemsWrapGrid panel||ResultsGrid.ActualWidth<=0)return;
        var available=Math.Max(160,ResultsGrid.ActualWidth-16);var columns=Math.Max(1,Math.Floor(available/180));var width=available/columns;
        var height=(width-16)*1.5+84+80*Math.Max(0,new global::Windows.UI.ViewManagement.UISettings().TextScaleFactor-1);
        if(Math.Abs(panel.ItemWidth-width)>.5)panel.ItemWidth=width;if(Math.Abs(panel.ItemHeight-height)>.5)panel.ItemHeight=height;
    }
    private void Root_SizeChanged(object sender,SizeChangedEventArgs args)
    {
        var compact=args.NewSize.Width<720;
        HeaderLayout.Margin=compact?new Thickness(8,20,8,12):new Thickness(8,28,8,12);
        ResultsGrid.Margin=compact?new Thickness(8,0,8,0):new Thickness(24,0,24,0);
        Filters.ItemWidth=compact?Math.Max(150,(args.NewSize.Width-32)/2):200;
    }
    private static ScrollViewer? FindScroll(DependencyObject root)
    {for(var i=0;i<VisualTreeHelper.GetChildrenCount(root);i++){var child=VisualTreeHelper.GetChild(root,i);if(child is ScrollViewer scroll)return scroll;if(FindScroll(child) is{} found)return found;}return null;}
}
