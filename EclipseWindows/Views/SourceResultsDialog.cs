using Eclipse.Windows.Models;
using Eclipse.Windows.Services;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.ApplicationModel.DataTransfer;

namespace Eclipse.Windows.Views;

internal sealed class SourceResultsDialog
{
    private readonly XamlRoot _root;
    private readonly SourceSearchSession _session;
    private readonly SourceSearchContext _context;
    private readonly EclipseDialog _dialog;
    private readonly CancellationTokenSource _lifetime=new();
    private readonly Grid _host=new();
    private readonly Grid _resultsView=new(){RowSpacing=12};
    private readonly StackPanel _sections=new(){Spacing=18};
    private readonly Dictionary<string,StackPanel> _sectionBodies=[];
    private readonly Dictionary<string,TextBlock> _sectionCounts=[];
    private readonly TextBlock _status=new(){VerticalAlignment=VerticalAlignment.Center};
    private readonly ProgressRing _statusRing=new(){Width=16,Height=16,IsActive=true};
    private readonly ScrollViewer _scroll=new(){HorizontalScrollMode=ScrollMode.Disabled,HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled};
    private readonly Grid _overlay=new(){Visibility=Visibility.Collapsed};
    private readonly TextBlock _overlayTitle=new(){Text="Fetching Streams",Style=(Style)Application.Current.Resources["SubtitleTextBlockStyle"],HorizontalAlignment=HorizontalAlignment.Center};
    private readonly TextBlock _overlayItem=new(){TextWrapping=TextWrapping.Wrap,HorizontalAlignment=HorizontalAlignment.Center,TextAlignment=TextAlignment.Center};
    private readonly TextBlock _overlayProgress=new(){TextWrapping=TextWrapping.Wrap,HorizontalAlignment=HorizontalAlignment.Center,TextAlignment=TextAlignment.Center};
    private readonly HashSet<string> _expanded=[];
    private readonly List<BitmapImage> _images=[];
    private string? _filter;
    private CancellationTokenSource? _resolution;

    private SourceResultsDialog(XamlRoot root,SourceSearchRequest request)
    {
        _root=root;_context=new(request);_session=new(_context);
        _dialog=new EclipseDialog{XamlRoot=root,Title="Source Results",CloseButtonText="Done",DefaultButton=ContentDialogButton.Close};
        _dialog.Resources["ContentDialogMaxWidth"]=1000.0;_dialog.Resources["ContentDialogMaxHeight"]=1000.0;
        var width=Math.Clamp(root.Size.Width-120,360,900);var height=Math.Max(320,root.Size.Height-220);
        _host.Width=width;_host.Height=height;
        _resultsView.RowDefinitions.Add(new(){Height=GridLength.Auto});_resultsView.RowDefinitions.Add(new());
        _resultsView.Children.Add(Header());
        _scroll.Content=_sections;Grid.SetRow(_scroll,1);_resultsView.Children.Add(_scroll);
        _host.Children.Add(_resultsView);_host.Children.Add(Overlay());
        _dialog.Content=_host;
        _session.Updated+=Update;_session.Completed+=UpdateStatus;
        _dialog.Closing+=(_,_)=>{_lifetime.Cancel();_resolution?.Cancel();foreach(var image in _images)image.UriSource=null;_images.Clear();};
    }
    public static async Task ShowAsync(XamlRoot root,SourceSearchRequest request)
    {
        var dialog=new SourceResultsDialog(root,request);
        dialog.Build();
        var run=dialog._session.RunAsync(dialog._lifetime.Token);
        await dialog._dialog.ShowAsync();
        dialog._lifetime.Cancel();
        try{await run;}catch(OperationCanceledException){}
    }
    private static Style Style(string key)=>(Style)Application.Current.Resources[key];
    private static TextBlock Caption(string text)=>new(){Text=text,Style=Style("SettingsDescriptionStyle"),TextWrapping=TextWrapping.Wrap};
    private static Border Badge(string text,Brush? background=null)=>new(){Padding=new(8,2,8,2),CornerRadius=new(8),Background=background??(Brush)Application.Current.Resources["ControlFillColorSecondaryBrush"],VerticalAlignment=VerticalAlignment.Center,Child=new TextBlock{Text=text,FontSize=12,FontWeight=FontWeights.SemiBold}};

    private FrameworkElement Header()
    {
        var p=ServicesPreferenceStore.Shared.Value;var r=_context.Request;
        var panel=new StackPanel{Spacing=8};
        var top=new Grid{ColumnSpacing=12};top.ColumnDefinitions.Add(new());top.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
        var info=new StackPanel{Spacing=4};info.Children.Add(Caption("Searching for:"));
        info.Children.Add(new TextBlock{Text=_context.DisplayTitle,FontWeight=FontWeights.SemiBold,TextWrapping=TextWrapping.Wrap,IsTextSelectionEnabled=true});
        top.Children.Add(info);
        if(!p.StremioStyleList||p.DropMismatchedResults){var filter=FilterButton();Grid.SetColumn(filter,1);top.Children.Add(filter);}
        panel.Children.Add(top);
        if(_context.HasEpisode&&r.EpisodeName is {Length:>0} name)
        {
            var episode=new Grid{ColumnSpacing=8};episode.ColumnDefinitions.Add(new());episode.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
            episode.Children.Add(new TextBlock{Text=name,FontWeight=FontWeights.SemiBold,TextWrapping=TextWrapping.Wrap});
            var badge=Badge(_context.EpisodeSeasonInfo);Grid.SetColumn(badge,1);episode.Children.Add(badge);panel.Children.Add(episode);
            if(r.EpisodeOverview is {Length:>0} overview)panel.Children.Add(new TextBlock{Text=overview,TextWrapping=TextWrapping.Wrap,MaxLines=3,TextTrimming=TextTrimming.WordEllipsis,Style=Style("SettingsDescriptionStyle")});
        }
        var status=new Grid{ColumnSpacing=8};status.ColumnDefinitions.Add(new(){Width=GridLength.Auto});status.ColumnDefinitions.Add(new());status.ColumnDefinitions.Add(new(){Width=GridLength.Auto});status.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
        status.Children.Add(Badge(_context.MediaTypeText,new SolidColorBrush(_context.IsMovie?global::Windows.UI.Color.FromArgb(70,160,90,230):global::Windows.UI.Color.FromArgb(70,60,180,90))));
        Grid.SetColumn(_statusRing,2);Grid.SetColumn(_status,3);status.Children.Add(_statusRing);status.Children.Add(_status);
        panel.Children.Add(status);
        if(p.StremioStyleList&&_session.Results.Count>0)panel.Children.Add(FilterChips());
        return panel;
    }
    private FrameworkElement FilterChips()
    {
        var chips=new StackPanel{Orientation=Orientation.Horizontal,Spacing=8};
        var buttons=new List<ToggleButton>();
        void Add(string title,string? id)
        {
            var chip=new ToggleButton{Content=title,IsChecked=_filter==id,CornerRadius=new(14)};buttons.Add(chip);
            chip.Click+=(_,_)=>{_filter=id;foreach(var b in buttons)b.IsChecked=ReferenceEquals(b,chip);RenderAll();};chips.Children.Add(chip);
        }
        Add("All",null);foreach(var result in _session.Results)Add(result.Source.Name,result.Source.SourceId);
        var scroller=new ScrollViewer{Content=chips,HorizontalScrollMode=ScrollMode.Enabled,HorizontalScrollBarVisibility=ScrollBarVisibility.Auto,VerticalScrollMode=ScrollMode.Disabled,VerticalScrollBarVisibility=ScrollBarVisibility.Disabled};
        return scroller;
    }
    private Button FilterButton()
    {
        var button=new Button{Content=new FontIcon{Glyph="",FontSize=16}};AutomationProperties.SetName(button,"Filter results");ToolTipService.SetToolTip(button,"Filter results");
        button.Click+=(_,_)=>
        {
            var p=ServicesPreferenceStore.Shared.Value;var menu=new MenuFlyout();
            if(!p.StremioStyleList)
            {
                menu.Items.Add(new MenuFlyoutItem{Text="Matching Algorithm",IsEnabled=false});
                foreach(var (id,label) in TitleSimilarity.Algorithms)
                {
                    var item=new RadioMenuFlyoutItem{Text=label,GroupName="algorithm",IsChecked=p.SimilarityAlgorithm==id};
                    item.Click+=(_,_)=>{Save(x=>x.SimilarityAlgorithm=id);_session.Rerank(_lifetime.Token);};menu.Items.Add(item);
                }
                menu.Items.Add(new MenuFlyoutSeparator());
            }
            var ranking=p.StremioStyleList;var current=ranking?p.MinimumSimilarity:p.HighQualityThreshold;
            var threshold=new MenuFlyoutItem{Text=$"{(ranking?"Ranking Similarity":"Quality Threshold")}: {(int)Math.Round(current*100)}%",Icon=new FontIcon{Glyph=""}};
            threshold.Click+=(_,_)=>ThresholdEditor(button,ranking);
            menu.Items.Add(threshold);menu.ShowAt(button);
        };
        return button;
    }
    private void ThresholdEditor(FrameworkElement anchor,bool ranking)
    {
        var p=ServicesPreferenceStore.Shared.Value;
        var box=new NumberBox{Header=ranking?"Threshold (0.5 - 1.0)":"Threshold (0.0 - 1.0)",Minimum=ranking?.5:0,Maximum=1,SmallChange=.01,LargeChange=.05,Value=ranking?p.MinimumSimilarity:p.HighQualityThreshold,SpinButtonPlacementMode=NumberBoxSpinButtonPlacementMode.Inline,MinWidth=220};
        var save=new Button{Content="Save",Style=Style("AccentButtonStyle"),HorizontalAlignment=HorizontalAlignment.Right};
        var panel=new StackPanel{Spacing=10};panel.Children.Add(box);panel.Children.Add(save);
        var flyout=new Flyout{Content=panel};
        save.Click+=(_,_)=>{if(!double.IsNaN(box.Value)){var v=Math.Round(box.Value,2);Save(x=>{if(ranking)x.MinimumSimilarity=v;else x.HighQualityThreshold=v;});RenderAll();}flyout.Hide();};
        flyout.ShowAt(anchor);
    }
    private static void Save(Action<ServicesPreferences> change){try{ServicesPreferenceStore.Shared.Update(change);}catch(Exception error) when(error is IOException or UnauthorizedAccessException){}}

    private FrameworkElement Overlay()
    {
        _overlay.Background=new SolidColorBrush(global::Windows.UI.Color.FromArgb(150,0,0,0));
        var card=new StackPanel{Spacing=10,Padding=new(30),MaxWidth=420,HorizontalAlignment=HorizontalAlignment.Center,VerticalAlignment=VerticalAlignment.Center,CornerRadius=new(16),Background=(Brush)Application.Current.Resources["SolidBackgroundFillColorBaseBrush"]};
        card.Children.Add(new ProgressRing{IsActive=true,Width=32,Height=32});card.Children.Add(_overlayTitle);card.Children.Add(_overlayItem);card.Children.Add(_overlayProgress);
        var cancel=new Button{Content="Cancel",HorizontalAlignment=HorizontalAlignment.Center};cancel.Click+=(_,_)=>{_resolution?.Cancel();HideOverlay();};card.Children.Add(cancel);
        _overlay.Children.Add(card);
        return _overlay;
    }
    private void ShowOverlay(string item,string progress){_overlayItem.Text=item;_overlayProgress.Text=progress;_overlay.Visibility=Visibility.Visible;}
    private void HideOverlay()=>_overlay.Visibility=Visibility.Collapsed;

    private void Build()
    {
        _sections.Children.Clear();_sectionBodies.Clear();_sectionCounts.Clear();
        if(_session.Results.Count==0)
        {
            var empty=new StackPanel{Spacing=8,HorizontalAlignment=HorizontalAlignment.Center,Margin=new(0,40,0,0)};
            empty.Children.Add(new FontIcon{Glyph="",FontSize=36});empty.Children.Add(new TextBlock{Text="No Active Sources",FontWeight=FontWeights.SemiBold,HorizontalAlignment=HorizontalAlignment.Center});
            empty.Children.Add(new TextBlock{Text="You don't have any active services or addons. Add or enable a source in Settings.",TextWrapping=TextWrapping.Wrap,TextAlignment=TextAlignment.Center});
            _sections.Children.Add(empty);UpdateStatus();return;
        }
        if(ServicesPreferenceStore.Shared.Value.StremioStyleList){var body=new StackPanel{Spacing=8};_sectionBodies[""]=body;_sections.Children.Add(body);}
        else foreach(var result in _session.Results)
        {
            var section=new StackPanel{Spacing=6};
            var header=new Grid{ColumnSpacing=8};header.ColumnDefinitions.Add(new());header.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
            var title=new TextBlock{Text=result.Source.Name,Style=Style("BodyStrongTextBlockStyle"),TextTrimming=TextTrimming.CharacterEllipsis};AutomationProperties.SetHeadingLevel(title,Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level2);
            var count=new TextBlock{Style=Style("SettingsDescriptionStyle"),VerticalAlignment=VerticalAlignment.Center};Grid.SetColumn(count,1);
            header.Children.Add(title);header.Children.Add(count);section.Children.Add(header);
            var body=new StackPanel{Spacing=4};section.Children.Add(body);
            _sectionBodies[result.Source.SourceId]=body;_sectionCounts[result.Source.SourceId]=count;_sections.Children.Add(section);
        }
        RenderAll();
    }
    private void Update(SourceSearchResult result)
    {
        if(_lifetime.IsCancellationRequested)return;
        if(ServicesPreferenceStore.Shared.Value.StremioStyleList)RenderAll();else Render(result);
        UpdateStatus();
    }
    private void UpdateStatus()
    {
        var searching=!_session.IsComplete&&_session.Results.Count>0;
        _statusRing.IsActive=searching;_statusRing.Visibility=searching?Visibility.Visible:Visibility.Collapsed;
        _status.Text=_session.Results.Count==0?"":searching?$"Searching... ({_session.CompletedCount}/{_session.Results.Count})":"Search complete";
    }
    private void RenderAll()
    {
        if(ServicesPreferenceStore.Shared.Value.StremioStyleList){RenderStremioStyle();return;}
        foreach(var result in _session.Results)Render(result);
    }
    private void Render(SourceSearchResult result)
    {
        if(!_sectionBodies.TryGetValue(result.Source.SourceId,out var body))return;
        body.Children.Clear();var count=_sectionCounts[result.Source.SourceId];count.Text="";
        if(result.State!=SourceSearchState.Done){body.Children.Add(StateRow(result.State==SourceSearchState.Waiting?"":null,result.State==SourceSearchState.Waiting?"Not searched":"Searching..."));return;}
        switch(result.Source.Kind)
        {
            case SourceKind.Service:
                var (high,low)=_session.Buckets(result);
                count.Text=high.Count+low.Count==0?"":$"{high.Count} result{(high.Count==1?"":"s")}";
                if(high.Count+low.Count==0){body.Children.Add(StateRow("","No results found"));break;}
                foreach(var item in high)body.Children.Add(ServiceRow(result,item,false));
                if(low.Count>0)
                {
                    var expanded=_expanded.Contains(result.Source.SourceId);
                    var percentage=(int)Math.Round(ServicesPreferenceStore.Shared.Value.HighQualityThreshold*100);
                    var toggle=new Button{HorizontalAlignment=HorizontalAlignment.Stretch,HorizontalContentAlignment=HorizontalAlignment.Left,Content=$"{low.Count} lower quality result{(low.Count==1?"":"s")} (<{percentage}%)  {(expanded?"▴":"▾")}"};
                    toggle.Click+=(_,_)=>{if(!_expanded.Remove(result.Source.SourceId))_expanded.Add(result.Source.SourceId);Render(result);};
                    body.Children.Add(toggle);
                    if(expanded)foreach(var item in low)body.Children.Add(ServiceRow(result,item,true));
                }
                break;
            case SourceKind.Stremio:
                count.Text=result.StremioStreams.Count==0?"":$"{result.StremioStreams.Count} stream{(result.StremioStreams.Count==1?"":"s")}";
                foreach(var stream in result.StremioStreams)body.Children.Add(StremioRow(result,stream,false));
                if(result.StremioStreams.Count==0)body.Children.Add(result.HiddenCount>0?FilteredRow(result.HiddenCount):result.StremioOutcome is {} outcome&&outcome is not StremioOutcome.Results?OutcomeRow(outcome.DisplayMessage,outcome.DisplayDetail):StateRow("","No results found"));
                break;
            case SourceKind.Nuvio:
                count.Text=result.NuvioStreams.Count==0?"":$"{result.NuvioStreams.Count} stream{(result.NuvioStreams.Count==1?"":"s")}";
                foreach(var stream in result.NuvioStreams)body.Children.Add(NuvioRow(result,stream,false));
                if(result.NuvioStreams.Count==0)body.Children.Add(result.HiddenCount>0?FilteredRow(result.HiddenCount):result.NuvioOutcome is {} n?OutcomeRow(n.DisplayMessage,n.DisplayDetail):StateRow("","No results found"));
                break;
        }
    }
    private void RenderStremioStyle()
    {
        if(!_sectionBodies.TryGetValue("",out var body))return;
        body.Children.Clear();var any=false;
        foreach(var result in _session.Results.Where(r=>_filter is null||r.Source.SourceId==_filter))
        {
            if(result.State!=SourceSearchState.Done)continue;
            switch(result.Source.Kind)
            {
                case SourceKind.Service:
                    var (high,low)=_session.Buckets(result);foreach(var item in high.Concat(low)){body.Children.Add(ServiceRow(result,item,false,true));any=true;}
                    break;
                case SourceKind.Stremio:
                    foreach(var stream in result.StremioStreams.Take(30)){body.Children.Add(StremioRow(result,stream,true));any=true;}
                    if(result.StremioStreams.Count==0&&result.StremioOutcome is {ExplainsEmptyList:true} o){body.Children.Add(OutcomeRow($"{result.Source.Name}: {o.DisplayMessage}",o.DisplayDetail));any=true;}
                    break;
                case SourceKind.Nuvio:
                    foreach(var stream in result.NuvioStreams){body.Children.Add(NuvioRow(result,stream,true));any=true;}
                    if(result.NuvioStreams.Count==0&&result.NuvioOutcome is {IsFailure:true} n){body.Children.Add(OutcomeRow($"{result.Source.Name}: {n.DisplayMessage}",n.DisplayDetail));any=true;}
                    break;
            }
        }
        if(!any&&_session.IsComplete)body.Children.Add(StateRow("","No results found"));
    }
    private static FrameworkElement StateRow(string? glyph,string text)
    {
        var row=new StackPanel{Orientation=Orientation.Horizontal,Spacing=10,Padding=new(4,6,4,6)};
        row.Children.Add(glyph is null?new ProgressRing{IsActive=true,Width=16,Height=16}:new FontIcon{Glyph=glyph,FontSize=16});
        row.Children.Add(new TextBlock{Text=text,VerticalAlignment=VerticalAlignment.Center});
        return row;
    }
    private static FrameworkElement OutcomeRow(string message,string? detail)
    {
        var row=new Grid{ColumnSpacing=10,Padding=new(4,6,4,6)};row.ColumnDefinitions.Add(new(){Width=GridLength.Auto});row.ColumnDefinitions.Add(new());
        row.Children.Add(new FontIcon{Glyph="",FontSize=16,VerticalAlignment=VerticalAlignment.Top});
        var text=new StackPanel{Spacing=2};text.Children.Add(new TextBlock{Text=message,TextWrapping=TextWrapping.Wrap});if(detail is {Length:>0})text.Children.Add(Caption(detail));
        Grid.SetColumn(text,1);row.Children.Add(text);return row;
    }
    private static FrameworkElement FilteredRow(int count)=>OutcomeRow(count==1?"1 stream returned, hidden by your stream filters":$"{count} streams returned, all hidden by your stream filters",null);
    private Button Card(UIElement content,string accessibleName)
    {
        var button=new Button{Content=content,HorizontalAlignment=HorizontalAlignment.Stretch,HorizontalContentAlignment=HorizontalAlignment.Stretch,Padding=new(12,10,12,10),Style=Style("SettingsNavigationCardStyle")};
        AutomationProperties.SetName(button,accessibleName);return button;
    }
    private Button ServiceRow(SourceSearchResult result,RankedServiceResult item,bool compact,bool stremioStyle=false)
    {
        var threshold=ServicesPreferenceStore.Shared.Value.HighQualityThreshold;var score=item.DisplaySimilarity;
        var grid=new Grid{ColumnSpacing=12};grid.ColumnDefinitions.Add(new(){Width=GridLength.Auto});grid.ColumnDefinitions.Add(new());grid.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
        var image=new Image{Width=compact?36:50,Height=compact?54:75,Stretch=Stretch.UniformToFill};
        if(SourceHttp.HttpUri(item.Item.ImageUrl) is {} uri){var bitmap=new BitmapImage{DecodePixelWidth=compact?72:100,UriSource=uri};_images.Add(bitmap);image.Source=bitmap;}
        grid.Children.Add(new Border{CornerRadius=new(6),Background=(Brush)Application.Current.Resources["ControlFillColorSecondaryBrush"],Child=image});
        var text=new StackPanel{Spacing=3,VerticalAlignment=VerticalAlignment.Center};
        if(stremioStyle)text.Children.Add(new TextBlock{Text=result.Source.Name,FontWeight=FontWeights.Bold});
        text.Children.Add(new TextBlock{Text=item.Item.Title,TextWrapping=TextWrapping.Wrap,MaxLines=stremioStyle?3:2,TextTrimming=TextTrimming.CharacterEllipsis,FontWeight=compact?FontWeights.Normal:FontWeights.SemiBold});
        var color=score>=threshold?global::Windows.UI.Color.FromArgb(255,52,199,89):score>=.75?global::Windows.UI.Color.FromArgb(255,255,149,0):global::Windows.UI.Color.FromArgb(255,255,69,58);
        var line=$"{(int)(score*100)}%{(stremioStyle?" match":"")}{(stremioStyle&&_context.HasEpisode&&!_context.IsMovie?$" • Episode {_context.Request.EpisodeNumber}":"")}";
        text.Children.Add(new TextBlock{Text=line,FontWeight=FontWeights.SemiBold,Foreground=stremioStyle?(Brush)Application.Current.Resources["TextFillColorSecondaryBrush"]:new SolidColorBrush(color)});
        Grid.SetColumn(text,1);grid.Children.Add(text);
        var play=new FontIcon{Glyph="",FontSize=18,VerticalAlignment=VerticalAlignment.Center};Grid.SetColumn(play,2);grid.Children.Add(play);
        var button=Card(grid,$"{item.Item.Title}, {(int)(score*100)} percent match, {result.Source.Name}");
        button.Click+=(_,_)=>ConfirmPlay(button,result,item.Item);
        return button;
    }
    private Button StremioRow(SourceSearchResult result,StremioStream stream,bool stremioStyle)
    {
        var label=StreamDetection.StremioLabel(stream);
        var text=new StackPanel{Spacing=3};
        if(stremioStyle)text.Children.Add(new TextBlock{Text=result.Source.Name,FontWeight=FontWeights.Bold});
        text.Children.Add(new TextBlock{Text=label,TextWrapping=TextWrapping.Wrap,FontWeight=FontWeights.SemiBold});
        var detail=new[]{stream.Title,stream.Description}.FirstOrDefault(d=>d?.Trim().Length>0);
        if(detail is not null&&!label.Contains(detail.Trim().Split('\n')[0]))text.Children.Add(new TextBlock{Text=detail.Trim(),TextWrapping=TextWrapping.Wrap,MaxLines=3,TextTrimming=TextTrimming.CharacterEllipsis,Style=Style("SettingsDescriptionStyle")});
        var button=Card(Row(text),$"{label}, {result.Source.Name}");
        button.Click+=(_,_)=>ShowStream(result.Source.Name,label,stream.Url!,stream.ProxyHeaders);
        AttachCopy(button,stream.Url);
        return button;
    }
    private Button NuvioRow(SourceSearchResult result,NuvioStream stream,bool stremioStyle)
    {
        var text=new StackPanel{Spacing=3};
        if(stremioStyle)text.Children.Add(new TextBlock{Text=result.Source.Name,FontWeight=FontWeights.Bold});
        text.Children.Add(new TextBlock{Text=stream.DisplayName,TextWrapping=TextWrapping.Wrap,FontWeight=FontWeights.SemiBold});
        if(stream.Name is {Length:>0}&&stream.Title!=stream.Name)text.Children.Add(new TextBlock{Text=stream.Title,TextWrapping=TextWrapping.Wrap,MaxLines=3,TextTrimming=TextTrimming.CharacterEllipsis,Style=Style("SettingsDescriptionStyle")});
        if(stream.MetadataLabel.Length>0)text.Children.Add(Caption(stream.MetadataLabel));
        var button=Card(Row(text),$"{stream.DisplayName}, {result.Source.Name}");
        button.Click+=(_,_)=>ShowStream(result.Source.Name,stream.DisplayName,stream.Url,stream.Headers);
        AttachCopy(button,stream.Url);
        return button;
    }
    private static Grid Row(UIElement text)
    {
        var grid=new Grid{ColumnSpacing=12};grid.ColumnDefinitions.Add(new());grid.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
        grid.Children.Add(text);var play=new FontIcon{Glyph="",FontSize=18,VerticalAlignment=VerticalAlignment.Center};Grid.SetColumn(play,1);grid.Children.Add(play);
        return grid;
    }
    private static void AttachCopy(FrameworkElement element,string? url)
    {
        if(string.IsNullOrEmpty(url))return;
        var menu=new MenuFlyout();var copy=new MenuFlyoutItem{Text="Copy Stream URL",Icon=new FontIcon{Glyph=""}};copy.Click+=(_,_)=>Copy(url);menu.Items.Add(copy);
        element.ContextFlyout=menu;
    }
    private static void Copy(string text){var package=new DataPackage();package.SetText(text);Clipboard.SetContent(package);}

    private void ConfirmPlay(FrameworkElement anchor,SourceSearchResult result,ServiceSearchItem item)
    {
        var message=_context.HasEpisode&&!_context.IsMovie?$"Play Episode {_context.Request.EpisodeNumber} of '{item.Title}'?":$"Play '{item.Title}'?";
        var panel=new StackPanel{Spacing=12,MaxWidth=360};
        panel.Children.Add(new TextBlock{Text="Play Content",Style=Style("BodyStrongTextBlockStyle")});panel.Children.Add(new TextBlock{Text=message,TextWrapping=TextWrapping.Wrap});
        var buttons=new StackPanel{Orientation=Orientation.Horizontal,Spacing=8,HorizontalAlignment=HorizontalAlignment.Right};
        var play=new Button{Content="Play",Style=Style("AccentButtonStyle")};var cancel=new Button{Content="Cancel"};buttons.Children.Add(play);buttons.Children.Add(cancel);panel.Children.Add(buttons);
        var flyout=new Flyout{Content=panel,Placement=FlyoutPlacementMode.Bottom};
        play.Click+=async(_,_)=>{flyout.Hide();await ResolveServiceAsync(result,item);};cancel.Click+=(_,_)=>flyout.Hide();
        flyout.Opened+=(_,_)=>play.Focus(FocusState.Programmatic);
        flyout.ShowAt(anchor);
    }
    private async Task ResolveServiceAsync(SourceSearchResult result,ServiceSearchItem item)
    {
        var service=result.Source.Service!;
        _resolution?.Cancel();_resolution=CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);var token=_resolution.Token;
        ShowOverlay(item.Title,$"Loading service: {service.Metadata.SourceName}");
        try
        {
            _overlayProgress.Text="Fetching episodes...";
            var (episodes,href)=await _session.EpisodeTargetAsync(service,item,token);
            if(token.IsCancellationRequested)return;
            if(episodes.Count==0){HideOverlay();await FailureAsync(service,$"No episodes found for '{item.Title}'. The source may be unavailable.");return;}
            _overlayProgress.Text=$"Found {episodes.Count} episode{(episodes.Count==1?"":"s")}";
            if(href is null)
            {
                if(!_context.IsMovie&&!_context.HasEpisode){HideOverlay();await FailureAsync(service,"No episode selected. Please select an episode first.");return;}
                HideOverlay();ShowEpisodePicker(service,item,episodes);return;
            }
            await FetchStreamAsync(service,href,token);
        }
        catch(OperationCanceledException){HideOverlay();}
    }
    private async Task FetchStreamAsync(JsService service,string href,CancellationToken token)
    {
        ShowOverlay(_overlayItem.Text,_context.IsMovie?"Preparing movie stream...":"Found episode, fetching stream...");
        var options=await JsServices.StreamsAsync(service,href,token);
        if(token.IsCancellationRequested)return;
        _overlayProgress.Text="Processing stream data...";
        var visible=_session.FilterServiceStreams(options,service);
        HideOverlay();
        if(options.Count>0&&visible.Count==0){await FailureAsync(service,$"All streams from {service.Metadata.SourceName} are hidden by your Extra Source Settings.");return;}
        if(visible.Count==0){await FailureAsync(service,"Failed to get a valid stream URL. The source may be temporarily unavailable.");return;}
        if(visible.Count==1){ShowStream(service.Metadata.SourceName,visible[0].Name,visible[0].Url,visible[0].Headers);return;}
        ShowStreamChoices(service,visible);
    }
    private async Task FailureAsync(JsService service,string message)
    {
        var bar=new InfoBar{Severity=InfoBarSeverity.Warning,Title=service.Metadata.SourceName,Message=message,IsOpen=true,IsClosable=true};
        bar.Closed+=(_,_)=>_sections.Children.Remove(bar);
        _sections.Children.Insert(0,bar);_scroll.ChangeView(null,0,null);
        await Task.CompletedTask;
    }
    private void ShowPanel(string title,UIElement body)
    {
        var view=new Grid{RowSpacing=12};view.RowDefinitions.Add(new(){Height=GridLength.Auto});view.RowDefinitions.Add(new());
        var header=new Grid{ColumnSpacing=8};header.ColumnDefinitions.Add(new(){Width=GridLength.Auto});header.ColumnDefinitions.Add(new());
        var back=new Button{Content=new FontIcon{Glyph="",FontSize=14}};AutomationProperties.SetName(back,"Back to results");ToolTipService.SetToolTip(back,"Back to results");
        back.Click+=(_,_)=>ClosePanel(view);header.Children.Add(back);
        var heading=new TextBlock{Text=title,Style=Style("SubtitleTextBlockStyle"),VerticalAlignment=VerticalAlignment.Center,TextWrapping=TextWrapping.Wrap};Grid.SetColumn(heading,1);header.Children.Add(heading);
        view.Children.Add(header);
        var scroll=new ScrollViewer{Content=body,HorizontalScrollMode=ScrollMode.Disabled,HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled};Grid.SetRow(scroll,1);view.Children.Add(scroll);
        _resultsView.Visibility=Visibility.Collapsed;
        foreach(var old in _host.Children.OfType<Grid>().Where(g=>g!=_resultsView&&g!=_overlay).ToArray())_host.Children.Remove(old);
        _host.Children.Insert(_host.Children.Count-1,view);
        back.Focus(FocusState.Programmatic);
    }
    private void ClosePanel(Grid view){_host.Children.Remove(view);_resultsView.Visibility=Visibility.Visible;}
    private void ShowEpisodePicker(JsService service,ServiceSearchItem item,IReadOnlyList<ServiceEpisodeLink> episodes)
    {
        var panel=new StackPanel{Spacing=8};
        panel.Children.Add(Caption($"{service.Metadata.SourceName} · {item.Title}"));
        var seasons=SourceSearchSession.Seasons(episodes);
        for(var i=0;i<seasons.Count;i++)
        {
            if(seasons.Count>1)panel.Children.Add(new TextBlock{Text=$"Season {i+1}",Style=Style("BodyStrongTextBlockStyle"),Margin=new(0,8,0,0)});
            var grid=new VariableSizedWrapGrid{Orientation=Orientation.Horizontal,ItemWidth=110,ItemHeight=44};
            foreach(var episode in seasons[i])
            {
                var button=new Button{Content=$"Episode {episode.Number}",HorizontalAlignment=HorizontalAlignment.Stretch,Margin=new(0,0,6,6)};
                button.Click+=async(_,_)=>
                {
                    _resolution?.Cancel();_resolution=CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
                    foreach(var g in _host.Children.OfType<Grid>().Where(g=>g!=_resultsView&&g!=_overlay).ToArray())_host.Children.Remove(g);
                    _resultsView.Visibility=Visibility.Visible;
                    _overlayItem.Text=item.Title;
                    try{await FetchStreamAsync(service,episode.Href,_resolution.Token);}catch(OperationCanceledException){HideOverlay();}
                };
                grid.Children.Add(button);
            }
            panel.Children.Add(grid);
        }
        ShowPanel("Select Episode",panel);
    }
    private void ShowStreamChoices(JsService service,IReadOnlyList<ServiceStreamOption> options)
    {
        var panel=new StackPanel{Spacing=6};
        panel.Children.Add(Caption($"{service.Metadata.SourceName} needs a stream choice."));
        foreach(var option in options)
        {
            var text=new StackPanel{Spacing=2};text.Children.Add(new TextBlock{Text=option.Name,FontWeight=FontWeights.SemiBold,TextWrapping=TextWrapping.Wrap});
            if(option.MetadataHints.Where(h=>h!=option.Name).Take(3).ToArray() is {Length:>0} hints)text.Children.Add(Caption(string.Join(" · ",hints)));
            var button=Card(Row(text),option.Name);button.Click+=(_,_)=>ShowStream(service.Metadata.SourceName,option.Name,option.Url,option.Headers);AttachCopy(button,option.Url);
            panel.Children.Add(button);
        }
        ShowPanel("Select Stream",panel);
    }
    private void ShowStream(string source,string name,string url,IReadOnlyDictionary<string,string>? headers)
    {
        var panel=new StackPanel{Spacing=12};
        panel.Children.Add(new InfoBar{Severity=InfoBarSeverity.Informational,IsOpen=true,IsClosable=false,Title="Playback isn't available yet",Message="Eclipse for Windows can find and filter streams, but its player hasn't been built yet."});
        panel.Children.Add(SettingsUI.Card("Source",null,new TextBlock{Text=source,TextWrapping=TextWrapping.Wrap}));
        panel.Children.Add(SettingsUI.Card("Stream",null,new TextBlock{Text=name,TextWrapping=TextWrapping.Wrap,MaxWidth=480}));
        var link=new TextBlock{Text=url,TextWrapping=TextWrapping.Wrap,IsTextSelectionEnabled=true,Style=Style("SettingsDescriptionStyle")};
        panel.Children.Add(SettingsUI.Panel(link));
        if(headers is {Count:>0})panel.Children.Add(Caption($"This stream requires {headers.Count} request header{(headers.Count==1?"":"s")} from its source."));
        var buttons=new StackPanel{Orientation=Orientation.Horizontal,Spacing=8};
        var copy=new Button{Content="Copy Stream URL",Style=Style("AccentButtonStyle")};copy.Click+=(_,_)=>{Copy(url);copy.Content="Copied";};
        buttons.Children.Add(copy);panel.Children.Add(buttons);
        ShowPanel(name,panel);
    }
}
