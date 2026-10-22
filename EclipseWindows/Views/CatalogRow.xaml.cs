using System.Runtime.InteropServices;
using Eclipse.Windows.Models;
using Eclipse.Windows.Navigation;
using Eclipse.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.UI.ViewManagement;
namespace Eclipse.Windows.Views;
public sealed partial class CatalogRow : UserControl
{
    public static readonly DependencyProperty CatalogProperty=DependencyProperty.Register(nameof(Catalog),typeof(HomeCatalog),typeof(CatalogRow),new PropertyMetadata(null,(d,_)=>{if(d is CatalogRow {IsLoaded:true} row)row.Configure();}));
    public HomeCatalog Catalog {get=>(HomeCatalog)GetValue(CatalogProperty);set=>SetValue(CatalogProperty,value);}
    public event EventHandler<TitleRequestedEventArgs>? TitleRequested;
    public event EventHandler<CatalogRequest>? CatalogRequested;
    private CancellationTokenSource? _load;
    private int _generation;
    private bool _setting;
    private readonly MouseShelfDrag _drag;
    private IReadOnlyList<MediaTitle> _titles=[];
    public CatalogRow()
    {InitializeComponent();_drag=new(Cards,()=>FindScroll(Cards));Loaded+=(_,_)=>Configure();Unloaded+=(_,_)=>Release();Cards.AddHandler(PointerWheelChangedEvent,new PointerEventHandler(Wheel_Changed),true);}
    private void Configure()
    {
        if(Catalog is null)return;
        Heading.Text=Catalog.Name;
        _setting=true;var facets=CatalogService.Facets(Catalog.Id);FacetPicker.ItemsSource=facets;FacetPicker.Visibility=facets.Count>0 ? Visibility.Visible : Visibility.Collapsed;
        FacetPicker.SelectedItem=facets.FirstOrDefault(f=>f.Id==Catalog.FacetId)??facets.FirstOrDefault();_setting=false;
        _=LoadAsync();
    }
    private async Task LoadAsync()
    {
        _drag.Reset();
        _load?.Cancel();_load?.Dispose();_load=new();var token=_load.Token;var generation=++_generation;
        foreach(var title in _titles)title.ReleaseArtwork();_titles=[];Cards.ItemsSource=null;
        BusyBar.IsIndeterminate=true;BusyBar.Visibility=Visibility.Visible;Error.IsOpen=false;Empty.Visibility=Visibility.Collapsed;
        try
        {
            var result=await CatalogService.LoadAsync(new(Catalog.Id,(FacetPicker.SelectedItem as CatalogFacet)?.Id??0),1,token);
            if(token.IsCancellationRequested||generation!=_generation||!IsLoaded)return;
            _titles=result.Titles.Take(20).ToArray();
            var settings=PreferenceStore.Shared.Value;var layout=settings.HomeCatalogLayoutOverrides.GetValueOrDefault(Catalog.Id);
            var orientation=layout?.Orientation is { } o && o!="global" ? o : settings.ExperimentalHomeCardShape;
            var landscape=orientation=="landscape" || orientation=="automatic" && Catalog.DisplayStyle=="featured";
            var scale=Math.Clamp(layout?.SizeScale??settings.ExperimentalMediaCardScale,.75,1.35);
            var width=(landscape ? 300 : 164)*scale;var height=(landscape ? 169 : 246)*scale;
            Cards.Height=height+6+84*new UISettings().TextScaleFactor;MinHeight=0;
            Row.Margin=new Thickness(0,12,0,20*settings.ExperimentalSectionSpacingScale);
            Cards.ItemsSource=_titles.Select((t,i)=>new MediaCard(t,width,height,12*settings.ExperimentalCardRadiusScale,landscape,Catalog.DisplayStyle=="ranked" ? i+1 : 0)).ToArray();
            Empty.Visibility=_titles.Count==0 ? Visibility.Visible : Visibility.Collapsed;
            DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,Restore);
        }
        catch(OperationCanceledException){}
        catch(Exception e) when(e is TmdbException or ProviderException)
        {if(!token.IsCancellationRequested&&generation==_generation){Error.Message=e.Message;Error.IsOpen=true;}}
        finally{if(generation==_generation){BusyBar.IsIndeterminate=false;BusyBar.Visibility=Visibility.Collapsed;}}
    }
    private void Release()
    {
        if(Catalog is not null)Catalog.HorizontalOffset=FindScroll(Cards)?.HorizontalOffset??0;
        _load?.Cancel();++_generation;BusyBar.IsIndeterminate=false;Cards.ItemsSource=null;
        foreach(var title in _titles)title.ReleaseArtwork();_titles=[];
    }
    private void Restore()
    {
        if(!IsLoaded)return;FindScroll(Cards)?.ChangeView(Catalog.HorizontalOffset,null,null,true);
        if(Catalog.FocusTitleId is { } id && Cards.Items.Cast<MediaCard>().FirstOrDefault(c=>c.Media.Id==id) is { } card)
        {Cards.ScrollIntoView(card);Cards.UpdateLayout();if(Cards.ContainerFromItem(card) is Control control)control.Focus(Catalog.RestoreKeyboardFocus ? FocusState.Keyboard : FocusState.Programmatic);Catalog.FocusTitleId=null;}
    }
    private void Card_Click(object sender,ItemClickEventArgs args)
    {
        if(_drag.SuppressClick||args.ClickedItem is not MediaCard card)return;
        Catalog.FocusTitleId=card.Media.Id;Catalog.RestoreKeyboardFocus=(FocusManager.GetFocusedElement(XamlRoot) as Control)?.FocusState==FocusState.Keyboard;
        TitleRequested?.Invoke(this,new(card.Media.Id));
    }
    private void Card_Changing(ListViewBase sender,ContainerContentChangingEventArgs args)
    {if(!args.InRecycleQueue&&args.Item is MediaCard card)AutomationProperties.SetName(args.ItemContainer,card.Media.AccessibleName);}
    private void Facet_Changed(object sender,SelectionChangedEventArgs args) {if(!_setting&&IsLoaded){Catalog.FacetId=(FacetPicker.SelectedItem as CatalogFacet)?.Id??0;Catalog.HorizontalOffset=0;_=LoadAsync();}}
    private void Retry_Click(object sender,RoutedEventArgs args)=>_=LoadAsync();
    private void SeeAll_Click(object sender,RoutedEventArgs args)=>CatalogRequested?.Invoke(this,new(Catalog.Id,(FacetPicker.SelectedItem as CatalogFacet)?.Id??0));
    private void Wheel_Changed(object sender,PointerRoutedEventArgs args)
    {
        var pointer=args.GetCurrentPoint(this).Properties;
        if(pointer.IsHorizontalMouseWheel || (args.KeyModifiers&(global::Windows.System.VirtualKeyModifiers.Control|global::Windows.System.VirtualKeyModifiers.Shift))!=0)return;
        DependencyObject? parent=this;
        while((parent=VisualTreeHelper.GetParent(parent)) is not null)
            if(parent is ScrollViewer scroll)
            {if(!SystemParametersInfo(0x0068,0,out var lines,0))lines=3;var distance=pointer.MouseWheelDelta/120.0*(lines==uint.MaxValue ? scroll.ViewportHeight : lines*16.0);scroll.ChangeView(null,Math.Clamp(scroll.VerticalOffset-distance,0,scroll.ScrollableHeight),null,true);args.Handled=true;break;}
    }
    [DllImport("user32.dll",EntryPoint="SystemParametersInfoW",ExactSpelling=true)] [return:MarshalAs(UnmanagedType.Bool)] private static extern bool SystemParametersInfo(uint action,uint parameter,out uint value,uint flags);
    private static ScrollViewer? FindScroll(DependencyObject root)
    {for(var i=0;i<VisualTreeHelper.GetChildrenCount(root);i++){var child=VisualTreeHelper.GetChild(root,i);if(child is ScrollViewer scroll)return scroll;if(FindScroll(child) is { } found)return found;}return null;}
}
