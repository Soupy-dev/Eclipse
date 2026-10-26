using Eclipse.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Navigation;

namespace Eclipse.Windows.Views;

public sealed partial class NuvioPluginsPage : Page
{
    private readonly StackPanel _body=new(){Margin=new(36,28,36,48),HorizontalAlignment=HorizontalAlignment.Left};
    private readonly InfoBar _notice=new(){IsClosable=true,Margin=new(0,16,0,0)};
    private readonly TextBox _url=new(){PlaceholderText="Manifest URL",IsSpellCheckEnabled=false,MinWidth=360};
    private readonly Button _add=new(){Content="Add Repository",IsEnabled=false};
    private readonly StackPanel _progress=new(){Spacing=6,Visibility=Visibility.Collapsed};
    private readonly TextBlock _progressText=new();
    private CancellationTokenSource _lifetime=new();

    public NuvioPluginsPage()
    {
        InitializeComponent();
        AutomationProperties.SetName(_url,"Manifest URL");
        _url.TextChanged+=(_,_)=>_add.IsEnabled=_url.Text.Trim().Length>0&&_progress.Visibility==Visibility.Collapsed;
        _url.KeyDown+=async(_,args)=>{if(args.Key==global::Windows.System.VirtualKey.Enter&&_add.IsEnabled){args.Handled=true;await AddAsync();}};
        _add.Click+=async(_,_)=>await AddAsync();
        _progress.Children.Add(new ProgressBar{IsIndeterminate=true});_progress.Children.Add(_progressText);
        var scroll=new ScrollViewer{Content=_body,Background=new SolidColorBrush(Microsoft.UI.Colors.Transparent),HorizontalScrollMode=ScrollMode.Disabled,HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled};
        Content=scroll;SettingsUI.Fit(scroll,_body);
    }
    protected override void OnNavigatedTo(NavigationEventArgs args){base.OnNavigatedTo(args);_lifetime=new();NuvioPlugins.Shared.Changed+=Plugins_Changed;Render();}
    protected override void OnNavigatedFrom(NavigationEventArgs args){NuvioPlugins.Shared.Changed-=Plugins_Changed;_lifetime.Cancel();base.OnNavigatedFrom(args);}
    private void Plugins_Changed(object? sender,EventArgs args)=>DispatcherQueue.TryEnqueue(()=>{if(_lifetime.IsCancellationRequested)return;if(NuvioPlugins.Shared.Progress is {} p){_progressText.Text=p;}else Render();});
    private void Render()
    {
        _body.Children.Clear();
        _body.Children.Add(new SettingsHeader{Trail="Settings|Services|Nuvio Plugins"});_body.Children.Add(_notice);
        var plugins=NuvioPlugins.Shared;
        if(plugins.ReadError is {} error)
        {
            _body.Children.Add(SettingsUI.Section("Plugin Data Preserved"));
            var reset=new Button{Content="Reset Nuvio Plugin Data"};
            reset.Click+=async(_,_)=>{if(await SourceDialogs.ConfirmAsync(XamlRoot,"Reset Nuvio Plugin Data?","This clears Nuvio repositories, provider settings, and downloaded code on this device.","Reset Nuvio Plugin Data")){try{plugins.ResetData();}catch(Exception e) when(e is IOException or UnauthorizedAccessException){Show(e.Message);}Render();}};
            _body.Children.Add(SettingsUI.Card("Changes are blocked",error,reset));
            return;
        }
        _body.Children.Add(SettingsUI.Section("Add Repository"));
        var row=new Grid{ColumnSpacing=8};row.ColumnDefinitions.Add(new());row.ColumnDefinitions.Add(new(){Width=GridLength.Auto});row.Children.Add(_url);Grid.SetColumn(_add,1);row.Children.Add(_add);
        var addPanel=new StackPanel{Spacing=10};addPanel.Children.Add(row);addPanel.Children.Add(_progress);
        _body.Children.Add(SettingsUI.Panel(addPanel));
        _body.Children.Add(SettingsUI.Note("Paste a Nuvio manifest URL. Every provider it lists becomes its own source in Services."));
        var repositories=plugins.Repositories.ToList();
        _body.Children.Add(SettingsUI.Section("Installed"));
        if(repositories.Count==0){_body.Children.Add(SettingsUI.Card("No Repositories","Providers from installed repositories appear in Services alongside your other sources."));return;}
        var group=SettingsUI.Group();
        foreach(var repository in repositories)
        {
            var scrapers=plugins.ScrapersFor(repository.Id).ToList();
            var summary=$"{scrapers.Count(s=>s.IsRunnable&&plugins.HasCode(s))} of {scrapers.Count} providers on · {repository.HostLabel}{(repository.IsEnabled?"":" · Disabled")}";
            group.Children.Add(SettingsUI.Navigation(repository.DisplayName,summary,()=>Frame.Navigate(typeof(NuvioRepositoryPage),repository.Id,new SuppressNavigationTransitionInfo())));
        }
        _body.Children.Add(group);
        _body.Children.Add(SettingsUI.Note("Refresh sources in Services, or open a repository to refresh it and toggle individual providers."));
    }
    private void Show(string message){_notice.Severity=InfoBarSeverity.Warning;_notice.Title="Nuvio";_notice.Message=message;_notice.IsOpen=true;}
    private async Task AddAsync()
    {
        var url=_url.Text.Trim();if(url.Length==0)return;
        _add.IsEnabled=false;_url.IsEnabled=false;_progress.Visibility=Visibility.Visible;_progressText.Text="Reading manifest";
        try
        {
            var (installed,failed)=await NuvioPlugins.Shared.AddRepositoryAsync(url,_lifetime.Token);
            _url.Text="";
            if(failed>0){_notice.Severity=InfoBarSeverity.Warning;_notice.Title="Repository added";_notice.Message=$"{installed} providers are ready. {failed} could not be downloaded; open the repository to refresh it.";_notice.IsOpen=true;}
            else _notice.IsOpen=false;
        }
        catch(OperationCanceledException){}
        catch(Exception error) when(error is SourceException or IOException or UnauthorizedAccessException){if(!_lifetime.IsCancellationRequested)await SourceDialogs.MessageAsync(XamlRoot,"Plugin Repository",error.Message);}
        finally{if(!_lifetime.IsCancellationRequested){_progress.Visibility=Visibility.Collapsed;_url.IsEnabled=true;_add.IsEnabled=_url.Text.Trim().Length>0;Render();}}
    }
}

public sealed partial class NuvioRepositoryPage : Page
{
    private readonly StackPanel _body=new(){Margin=new(36,28,36,48),HorizontalAlignment=HorizontalAlignment.Left};
    private readonly InfoBar _notice=new(){IsClosable=true,Margin=new(0,16,0,0)};
    private string _id="";
    private bool _refreshing;
    private CancellationTokenSource _lifetime=new();
    public NuvioRepositoryPage()
    {
        InitializeComponent();
        var scroll=new ScrollViewer{Content=_body,Background=new SolidColorBrush(Microsoft.UI.Colors.Transparent),HorizontalScrollMode=ScrollMode.Disabled,HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled};
        Content=scroll;SettingsUI.Fit(scroll,_body);
    }
    protected override void OnNavigatedTo(NavigationEventArgs args){base.OnNavigatedTo(args);_id=args.Parameter as string??"";_lifetime=new();NuvioPlugins.Shared.Changed+=Plugins_Changed;Render();}
    protected override void OnNavigatedFrom(NavigationEventArgs args){NuvioPlugins.Shared.Changed-=Plugins_Changed;_lifetime.Cancel();base.OnNavigatedFrom(args);}
    private void Plugins_Changed(object? sender,EventArgs args)=>DispatcherQueue.TryEnqueue(()=>{if(!_lifetime.IsCancellationRequested&&NuvioPlugins.Shared.Progress is null)Render();});
    private void Guarded(Action action){try{action();}catch(Exception error) when(error is IOException or UnauthorizedAccessException){_notice.Severity=InfoBarSeverity.Error;_notice.Title="The change could not be saved";_notice.Message=error.Message;_notice.IsOpen=true;}}
    private void Render()
    {
        var plugins=NuvioPlugins.Shared;var repository=plugins.Repository(_id);
        _body.Children.Clear();_body.Children.Add(new SettingsHeader{Trail=$"Settings|Services|Nuvio Plugins|{repository?.DisplayName??"Repository"}"});_body.Children.Add(_notice);
        if(repository is null){_body.Children.Add(SettingsUI.Note("Plugin repository was not found."));return;}
        var scrapers=plugins.ScrapersFor(_id).ToList();
        _body.Children.Add(SettingsUI.Section("Repository"));
        var refresh=new Button{Content=_refreshing?"Refreshing Providers…":"Refresh Providers",IsEnabled=!_refreshing};
        refresh.Click+=async(_,_)=>{_refreshing=true;Render();try{await plugins.RefreshAsync(_id,_lifetime.Token);}catch(OperationCanceledException){}finally{_refreshing=false;if(!_lifetime.IsCancellationRequested)Render();}};
        var bulk=new StackPanel{Orientation=Orientation.Horizontal,Spacing=8};
        var enableAll=new Button{Content="Enable All Providers"};enableAll.Click+=(_,_)=>Guarded(()=>plugins.SetAllScrapersEnabled(_id,true));
        var disableAll=new Button{Content="Disable All Providers"};disableAll.Click+=(_,_)=>Guarded(()=>plugins.SetAllScrapersEnabled(_id,false));
        var remove=new Button{Content="Remove Repository"};
        remove.Click+=async(_,_)=>{if(await SourceDialogs.ConfirmAsync(XamlRoot,"Remove Repository?","This removes every provider in the repository and its downloaded code.","Remove")){Guarded(()=>plugins.Uninstall(_id));if(Frame.CanGoBack)Frame.GoBack(new SuppressNavigationTransitionInfo());}};
        foreach(var b in new[]{refresh,enableAll,disableAll,remove})bulk.Children.Add(b);
        var ready=scrapers.Count(plugins.HasCode);
        _body.Children.Add(SettingsUI.Group(
            SettingsUI.Card("Enabled",repository.Description,SettingsUI.Toggle(repository.IsEnabled,on=>Guarded(()=>plugins.SetRepositoryEnabled(_id,on)))),
            SettingsUI.Card("Version",repository.ManifestUrl,new TextBlock{Text=repository.Version??"—"}),
            SettingsUI.Card("Providers",$"{ready} ready · {repository.ScraperCount} eligible",new TextBlock{Text=$"{ready} of {repository.ScraperCount}"}),
            SettingsUI.Panel(bulk)));
        if(repository.ErrorMessage is {Length:>0} error)_body.Children.Add(SettingsUI.Note(error));
        _body.Children.Add(SettingsUI.Section("Providers"));
        var visible=scrapers.Where(plugins.HasCode).ToList();
        if(visible.Count==0){_body.Children.Add(SettingsUI.Note("No providers are ready yet. Refresh the repository to retry the failed downloads."));return;}
        var group=SettingsUI.Group();
        foreach(var scraper in visible)
        {
            var parts=new List<string>();if(!scraper.ManifestEnabled)parts.Add("Disabled by repository");
            var types=scraper.SupportedTypes.Select(NuvioPlugins.NormalizeType).Distinct().Select(t=>t=="tv"?"TV":System.Globalization.CultureInfo.CurrentCulture.TextInfo.ToTitleCase(t)).ToList();if(types.Count>0)parts.Add(string.Join(", ",types));
            if(scraper.ContentLanguage.Count>0)parts.Add(string.Join("/",scraper.ContentLanguage.Take(4)).ToUpperInvariant());
            var controls=new StackPanel{Orientation=Orientation.Horizontal,Spacing=8};
            if(scraper.DeclaresSettings){var settings=new Button{Content=new FontIcon{Glyph="",FontSize=14}};AutomationProperties.SetName(settings,$"{scraper.DisplayName} settings");ToolTipService.SetToolTip(settings,"Plugin Settings");settings.Click+=async(_,_)=>await SourceDialogs.NuvioSettingsAsync(XamlRoot,scraper);controls.Children.Add(settings);}
            var toggle=SettingsUI.Toggle(scraper.IsRunnable,on=>Guarded(()=>plugins.SetScraperEnabled(scraper.Id,on)));toggle.IsEnabled=scraper.ManifestEnabled;AutomationProperties.SetName(toggle,scraper.DisplayName);
            controls.Children.Add(toggle);
            group.Children.Add(SettingsUI.Card(scraper.DisplayName,string.Join(" · ",parts),controls));
        }
        _body.Children.Add(group);
    }
}
