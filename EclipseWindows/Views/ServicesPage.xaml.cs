using System.Collections.ObjectModel;
using Eclipse.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Navigation;
using Windows.System;

namespace Eclipse.Windows.Views;

public sealed class SourceRow(SourceEntry entry)
{
    public SourceEntry Entry {get;}=entry;
    public string Title=>Entry.Name;
    public string Subtitle=>Entry.Kind switch
    {
        SourceKind.Service=>$"{Entry.Service!.Metadata.Author.Name} • {Entry.Service.Metadata.Language} • v{Entry.Service.Metadata.Version}",
        SourceKind.Stremio=>string.Join(" • ",new[]{Entry.Addon!.Manifest.Version is {} v?$"v{v}":null,Entry.Addon.Manifest.Description is {Length:>0} d?d.ReplaceLineEndings(" "):null}.Where(x=>x is not null)) is {Length:>0} s?s:"Stremio addon",
        _=>string.Join(" • ",new[]{"Nuvio",NuvioPlugins.Shared.Repository(Entry.Scraper!.RepositoryId)?.DisplayName,Entry.Scraper.ManifestEnabled?null:"disabled by repository"}.Where(x=>x is not null))
    };
    public string Detail
    {
        get
        {
            if(Entry.Addon is not {} addon)return "";
            var p=ServicesPreferenceStore.Shared.Value;var labels=new List<string>();
            if(addon.Manifest.SupportsStreams)labels.Add("Streams");
            if(addon.Manifest.SupportsSubtitles)labels.Add(p.StremioComponent("subtitles",addon.SourceId)?"Subtitles":"Subtitles (Off)");
            if(addon.Manifest.HomeCatalogs.Count>0)labels.Add(p.StremioComponent("catalogs",addon.SourceId)?"Catalogs":"Catalogs (Off)");
            else if(addon.Manifest.SupportsCatalogs&&addon.Manifest.Configurable==true)labels.Add("Needs Config");
            return string.Join("  ·  ",labels);
        }
    }
    public Visibility DetailVisibility=>Detail.Length>0?Visibility.Visible:Visibility.Collapsed;
    public Visibility ActiveVisibility=>Entry.IsActive?Visibility.Visible:Visibility.Collapsed;
    public string Glyph=>Entry.Kind switch{SourceKind.Stremio=>"",SourceKind.Nuvio=>"",_=>""};
    private BitmapImage? _icon;
    public ImageSource? Icon
    {
        get
        {
            if(_icon is not null)return _icon;
            var raw=Entry.Kind switch{SourceKind.Service=>Entry.Service!.Metadata.IconUrl,SourceKind.Stremio=>Entry.Addon!.Manifest.Logo,_=>null};
            if(string.IsNullOrWhiteSpace(raw))return null;
            Uri? uri=SourceHttp.HttpUri(raw);
            if(uri is null&&Entry.Addon is {} addon&&Uri.TryCreate(StremioClient.NormalizedConfiguredUrl(addon.ConfiguredUrl).TrimEnd('/')+"/",UriKind.Absolute,out var root)&&Uri.TryCreate(root,raw.TrimStart('/'),out var relative))uri=SourceHttp.HttpUri(relative.AbsoluteUri);
            return uri is null?null:_icon=new BitmapImage{DecodePixelWidth=80,DecodePixelType=DecodePixelType.Physical,UriSource=uri};
        }
    }
    public void Release(){if(_icon is not null)_icon.UriSource=null;_icon=null;}
    public override string ToString()=>$"{Title}, {(Entry.IsActive?"enabled":"disabled")}";
}

public sealed partial class ServicesPage : Page
{
    private readonly ListView _list=new(){SelectionMode=ListViewSelectionMode.None,IsItemClickEnabled=true,CanReorderItems=true,CanDragItems=true,AllowDrop=true,Padding=new(36,28,36,48),Background=new SolidColorBrush(Microsoft.UI.Colors.Transparent),KeyboardAcceleratorPlacementMode=KeyboardAcceleratorPlacementMode.Hidden};
    private readonly ObservableCollection<SourceRow> _rows=[];
    private readonly InfoBar _notice=new(){IsClosable=true,Margin=new(0,16,0,0)};
    private readonly TextBlock _status=new(){TextWrapping=TextWrapping.Wrap,Margin=new(2,4,0,8),Style=(Style)Application.Current.Resources["SettingsDescriptionStyle"]};
    private readonly ProgressBar _progress=new(){IsIndeterminate=true,Visibility=Visibility.Collapsed,Margin=new(0,0,0,8)};
    private readonly Button _enableAll=new(){Content="Enable All Sources"};
    private readonly Button _disableAll=new(){Content="Disable All Sources"};
    private readonly Button _refresh=new(){Content="Refresh Sources"};
    private CancellationTokenSource _lifetime=new();
    private bool _busy;

    public ServicesPage()
    {
        InitializeComponent();
        SourceRegistry.Hook();StremioCatalogs.Hook();
        var header=new StackPanel();header.Children.Add(new SettingsHeader{Trail="Settings|Services"});header.Children.Add(_notice);
        var preferences=ServicesPreferenceStore.Shared.Value;
        header.Children.Add(SettingsUI.Section("Updates"));
        header.Children.Add(SettingsUI.Card("Auto-Update Sources","Automatically check for source updates when the app is opened.",SettingsUI.Toggle(preferences.AutoUpdate,on=>Save(p=>p.AutoUpdate=on))));
        header.Children.Add(SettingsUI.Section("Stream rules"));
        header.Children.Add(SettingsUI.Navigation("Extra Source Settings","Configure the stream list layout, language, quality, and source rules.",()=>Frame.Navigate(typeof(ExtraSourceSettingsPage),null,new SuppressNavigationTransitionInfo())));
        header.Children.Add(SettingsUI.Section("Sources"));
        var add=new DropDownButton{Content="Add Source"};AutomationProperties.SetName(add,"Add Source");
        var menu=new MenuFlyout{Placement=Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedLeft};
        foreach(var (text,glyph,action) in new (string,string,Func<Task>)[]{("Add Service","",AddServiceAsync),("Add Stremio Addon","",AddStremioAsync),("Add Nuvio Plugin","",()=>{Frame.Navigate(typeof(NuvioPluginsPage),null,new SuppressNavigationTransitionInfo());return Task.CompletedTask;})})
        {var item=new MenuFlyoutItem{Text=text,Icon=new FontIcon{Glyph=glyph}};item.Click+=async(_,_)=>await action();menu.Items.Add(item);}
        add.Flyout=menu;
        _refresh.Click+=async(_,_)=>await RefreshAsync();
        _enableAll.Click+=(_,_)=>SetAll(true);_disableAll.Click+=(_,_)=>SetAll(false);
        var commands=new StackPanel{Orientation=Orientation.Horizontal,Spacing=8,Margin=new(0,0,0,8)};
        foreach(var control in new Control[]{add,_refresh,_enableAll,_disableAll})commands.Children.Add(control);
        header.Children.Add(commands);header.Children.Add(_progress);header.Children.Add(_status);
        _list.Header=header;_list.ItemContainerStyle=(Style)Application.Current.Resources["SettingsListItemStyle"];
        _list.ItemTemplate=(DataTemplate)Resources["SourceRowTemplate"];_list.ItemsSource=_rows;
        _list.ItemClick+=(_,args)=>{if(args.ClickedItem is SourceRow row)Toggle(row);};
        _list.DragItemsCompleted+=(_,_)=>Persist();
        _list.ContextRequested+=Row_ContextRequested;
        _list.ContainerContentChanging+=(_,args)=>{if(args.InRecycleQueue&&args.Item is SourceRow row)row.Release();};
        var up=new KeyboardAccelerator{Key=VirtualKey.Up,Modifiers=VirtualKeyModifiers.Menu};up.Invoked+=(_,args)=>args.Handled=Move(Focused(),i=>i-1);
        var down=new KeyboardAccelerator{Key=VirtualKey.Down,Modifiers=VirtualKeyModifiers.Menu};down.Invoked+=(_,args)=>args.Handled=Move(Focused(),i=>i+1);
        var delete=new KeyboardAccelerator{Key=VirtualKey.Delete};delete.Invoked+=async(_,args)=>{if(Focused() is {} row){args.Handled=true;await RemoveAsync(row);}};
        _list.KeyboardAccelerators.Add(up);_list.KeyboardAccelerators.Add(down);_list.KeyboardAccelerators.Add(delete);
        AutomationProperties.SetName(_list,"Sources");
        SizeChanged+=(_,args)=>_list.Padding=new(36,28,Math.Max(36,args.NewSize.Width-1036),48);
        Content=_list;
    }
    protected override void OnNavigatedTo(NavigationEventArgs args)
    {
        base.OnNavigatedTo(args);_lifetime=new();
        SourceRegistry.Changed+=Registry_Changed;ServicesPreferenceStore.Shared.Changed+=Registry_Changed;
        Render();
        var error=ServicesPreferenceStore.Shared.ReadError??StremioAddonStore.Shared.ReadError??JsServices.Shared.ReadError;
        if(error is not null)Show(InfoBarSeverity.Error,"Some source data could not be read",error);
    }
    protected override void OnNavigatedFrom(NavigationEventArgs args)
    {
        SourceRegistry.Changed-=Registry_Changed;ServicesPreferenceStore.Shared.Changed-=Registry_Changed;
        _lifetime.Cancel();foreach(var row in _rows)row.Release();base.OnNavigatedFrom(args);
    }
    private void Registry_Changed(object? sender,EventArgs args)=>DispatcherQueue.TryEnqueue(()=>{if(!_lifetime.IsCancellationRequested)Render();});
    private void Render()
    {
        var focused=Focused()?.Entry.SourceId;
        var entries=SourceRegistry.Unified();
        if(entries.Select(e=>e.SourceId).SequenceEqual(_rows.Select(r=>r.Entry.SourceId))&&entries.Zip(_rows).All(p=>p.First.IsActive==p.Second.Entry.IsActive&&p.First.Name==p.Second.Entry.Name&&ReferenceEquals(p.First.Model,p.Second.Entry.Model)))
        {UpdateStatus();return;}
        foreach(var row in _rows)row.Release();
        _rows.Clear();foreach(var entry in entries)_rows.Add(new(entry));
        UpdateStatus();
        if(focused is not null&&_rows.FirstOrDefault(r=>r.Entry.SourceId==focused) is {} target)DispatcherQueue.TryEnqueue(()=>{if(_list.ContainerFromItem(target) is ListViewItem item)item.Focus(FocusState.Programmatic);});
    }
    private void UpdateStatus()
    {
        var progress=JsServices.Shared.Progress??NuvioPlugins.Shared.Progress;
        _progress.Visibility=_busy||progress is not null?Visibility.Visible:Visibility.Collapsed;
        _status.Text=progress??(_rows.Count==0?"No stream sources installed":"Select a source to turn it on or off. Drag sources, or press Alt+Up and Alt+Down, to set their order. Right-click a source for more options.");
        _enableAll.IsEnabled=SourceRegistry.HasDisabledSource;_disableAll.IsEnabled=SourceRegistry.HasEnabledSource;_refresh.IsEnabled=!_busy&&_rows.Count>0;
    }
    private void Show(InfoBarSeverity severity,string title,string message){_notice.Severity=severity;_notice.Title=title;_notice.Message=message;_notice.IsOpen=true;}
    private void Save(Action<ServicesPreferences> change)
    {
        try{ServicesPreferenceStore.Shared.Update(change);}
        catch(Exception error) when(error is IOException or UnauthorizedAccessException){Show(InfoBarSeverity.Error,"Settings could not be saved","Your previous settings are preserved.");}
    }
    private void Guarded(Action action)
    {
        try{action();}
        catch(Exception error) when(error is IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException){Show(InfoBarSeverity.Error,"The change could not be saved",error.Message);}
    }
    private void Toggle(SourceRow row)=>Guarded(()=>SourceRegistry.SetActive(row.Entry,!row.Entry.IsActive));
    private void SetAll(bool active)=>Guarded(()=>SourceRegistry.SetAllEnabled(active));
    private void Persist()=>Guarded(()=>SourceRegistry.SaveOrder(_rows.Select(r=>r.Entry).ToArray()));
    private SourceRow? Focused()
    {
        if(XamlRoot is null)return null;
        for(var node=FocusManager.GetFocusedElement(XamlRoot) as DependencyObject;node is not null;node=VisualTreeHelper.GetParent(node))
            if(node is ListViewItem item)return _list.ItemFromContainer(item) as SourceRow;
        return null;
    }
    private bool Move(SourceRow? row,Func<int,int> destination)
    {
        if(row is null)return false;
        var from=_rows.IndexOf(row);var to=Math.Clamp(destination(from),0,_rows.Count-1);
        if(from<0||from==to)return true;
        _rows.Move(from,to);Persist();_list.ScrollIntoView(row);
        DispatcherQueue.TryEnqueue(()=>{if(_list.ContainerFromItem(row) is ListViewItem item)item.Focus(FocusState.Keyboard);});
        return true;
    }
    private void Row_ContextRequested(UIElement sender,ContextRequestedEventArgs args)
    {
        ListViewItem? container=null;
        for(var node=args.OriginalSource as DependencyObject;node is not null&&container is null;node=VisualTreeHelper.GetParent(node))container=node as ListViewItem;
        if(container is null||_list.ItemFromContainer(container) is not SourceRow row)return;
        var menu=new MenuFlyout();var entry=row.Entry;
        void Add(string text,string glyph,Action action){var item=new MenuFlyoutItem{Text=text,Icon=new FontIcon{Glyph=glyph}};item.Click+=(_,_)=>action();menu.Items.Add(item);}
        switch(entry.Kind)
        {
            case SourceKind.Service when entry.Service!.Metadata.Settings==true:
                Add("Edit Settings","",async()=>await SourceDialogs.ServiceSettingsAsync(XamlRoot,entry.Service));break;
            case SourceKind.Stremio:
                var addon=entry.Addon!;var p=ServicesPreferenceStore.Shared.Value;
                if(addon.Manifest.Configurable==true)Add("Configure","",async()=>await SourceDialogs.StremioConfigureAsync(XamlRoot,addon));
                Add("Update URL","",async()=>await ReconfigureAsync(addon));
                if(addon.Manifest.SupportsSubtitles){var on=p.StremioComponent("subtitles",addon.SourceId);Add(on?"Disable Subtitles":"Enable Subtitles","",()=>Save(x=>x.SetStremioComponent("subtitles",addon.SourceId,!on)));}
                if(addon.Manifest.SupportsCatalogs&&addon.Manifest.HomeCatalogs.Count>0){var on=p.StremioComponent("catalogs",addon.SourceId);Add(on?"Disable Catalogs":"Enable Catalogs","",()=>Save(x=>x.SetStremioComponent("catalogs",addon.SourceId,!on)));}
                break;
            case SourceKind.Nuvio:
                var scraper=entry.Scraper!;
                if(scraper.DeclaresSettings)Add("Plugin Settings","",async()=>await SourceDialogs.NuvioSettingsAsync(XamlRoot,scraper));
                Add("Open Repository","",()=>Frame.Navigate(typeof(NuvioRepositoryPage),scraper.RepositoryId,new SuppressNavigationTransitionInfo()));
                break;
        }
        if(menu.Items.Count>0)menu.Items.Add(new MenuFlyoutSeparator());
        Add(entry.IsActive?"Disable":"Enable",entry.IsActive?"":"",()=>Toggle(row));
        menu.Items.Add(new MenuFlyoutSeparator());
        foreach(var (text,target) in new (string,Func<int,int>)[]{("Move to top",_=>0),("Move up",i=>i-1),("Move down",i=>i+1),("Move to bottom",_=>_rows.Count-1)})
        {var item=new MenuFlyoutItem{Text=text};item.Click+=(_,_)=>Move(row,target);menu.Items.Add(item);}
        menu.Items.Add(new MenuFlyoutSeparator());
        Add(entry.Kind==SourceKind.Nuvio?"Remove from Sources":"Remove","",async()=>await RemoveAsync(row));
        if(args.TryGetPosition(container,out var point))menu.ShowAt(container,point);else menu.ShowAt(container);
        args.Handled=true;
    }
    private async Task RemoveAsync(SourceRow row)
    {
        var entry=row.Entry;
        var (title,message)=entry.Kind switch
        {
            SourceKind.Stremio=>("Remove Stremio Addon?",$"Remove {entry.Name} from Eclipse on this device? Its configured URL is removed too."),
            SourceKind.Nuvio=>("Remove Provider?",$"{entry.Name} is turned off and leaves Sources. You can turn it back on from its Nuvio repository."),
            _=>("Remove Service?",$"Remove {entry.Name} from Eclipse on this device?")
        };
        if(!await SourceDialogs.ConfirmAsync(XamlRoot,title,message,"Remove"))return;
        Guarded(()=>SourceRegistry.Remove(entry));
    }
    private async Task AddServiceAsync()
    {
        if(await SourceDialogs.UrlAsync(XamlRoot,"Add Service","Enter the direct JSON file URL","JSON URL") is not {} url)return;
        if(!JsServices.LooksLikeServiceUrl(url)){await SourceDialogs.MessageAsync(XamlRoot,"Service Download Failed","Enter a direct JSON service URL.");return;}
        _busy=true;UpdateStatus();
        try{await JsServices.Shared.DownloadAsync(url,_lifetime.Token);await SourceDialogs.MessageAsync(XamlRoot,"Service Downloaded","The service has been successfully downloaded and saved.");}
        catch(OperationCanceledException){}
        catch(Exception error) when(error is SourceException or IOException or UnauthorizedAccessException){if(!_lifetime.IsCancellationRequested)await SourceDialogs.MessageAsync(XamlRoot,"Service Download Failed",error.Message);}
        finally{_busy=false;if(!_lifetime.IsCancellationRequested)UpdateStatus();}
    }
    private async Task AddStremioAsync()
    {
        if(await SourceDialogs.UrlAsync(XamlRoot,"Add Stremio Addon","Enter the Stremio addon manifest URL","Addon URL") is not {} url)return;
        _busy=true;UpdateStatus();StremioAddon? added=null;
        try{added=await StremioAddonStore.Shared.AddAsync(url,_lifetime.Token);}
        catch(OperationCanceledException){}
        catch(Exception error) when(error is SourceException or IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException){if(!_lifetime.IsCancellationRequested)await SourceDialogs.MessageAsync(XamlRoot,"Stremio Error",error.Message);}
        finally{_busy=false;if(!_lifetime.IsCancellationRequested)UpdateStatus();}
        if(added is {Manifest.Configurable:true}&&(added.Manifest.ConfigurationRequired==true||added.Manifest.SupportsCatalogs&&added.Manifest.HomeCatalogs.Count==0)&&!_lifetime.IsCancellationRequested)
            await SourceDialogs.StremioConfigureAsync(XamlRoot,added);
    }
    private async Task ReconfigureAsync(StremioAddon addon)
    {
        if(await SourceDialogs.UrlAsync(XamlRoot,"Reconfigure Addon","Paste the new configured addon URL","New Addon URL","Save") is not {} url)return;
        _busy=true;UpdateStatus();
        try{await StremioAddonStore.Shared.ReconfigureAsync(addon,url,_lifetime.Token);}
        catch(OperationCanceledException){}
        catch(Exception error) when(error is SourceException or IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException){if(!_lifetime.IsCancellationRequested)await SourceDialogs.MessageAsync(XamlRoot,"Reconfigure Error",error.Message);}
        finally{_busy=false;if(!_lifetime.IsCancellationRequested)UpdateStatus();}
    }
    private async Task RefreshAsync()
    {
        _busy=true;UpdateStatus();
        try{await SourceRegistry.RefreshAllAsync(_lifetime.Token);}
        catch(OperationCanceledException){}
        catch(Exception error) when(error is SourceException or IOException or UnauthorizedAccessException){if(!_lifetime.IsCancellationRequested)Show(InfoBarSeverity.Warning,"Some sources could not be refreshed",error.Message);}
        finally{_busy=false;if(!_lifetime.IsCancellationRequested)UpdateStatus();}
    }
}
