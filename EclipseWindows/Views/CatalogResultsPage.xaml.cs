using System.Collections.ObjectModel;
using Eclipse.Windows.Models;
using Eclipse.Windows.Navigation;
using Eclipse.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Media;
namespace Eclipse.Windows.Views;
public sealed partial class CatalogResultsPage : Page
{
    public event EventHandler<TitleRequestedEventArgs>? TitleRequested;
    private readonly ObservableCollection<MediaTitle> _titles=[];
    private CancellationTokenSource? _load;
    private CatalogRequest _request=new("trending");
    private int _page,_pages;
    private bool _busy,_active;
    private int _generation;
    public CatalogResultsPage(){InitializeComponent();Titles.ItemsSource=_titles;}
    protected override void OnNavigatedTo(NavigationEventArgs args)
    {
        base.OnNavigatedTo(args);_active=true;_request=args.Parameter as CatalogRequest??new("trending");
        Heading.Text=PreferenceStore.Shared.Value.EnabledCatalogs.FirstOrDefault(c=>c.Id==_request.CatalogId)?.Name??"Catalog";
        _=RestoreAsync();
    }
    private async Task RestoreAsync()
    {
        var pages=Math.Clamp(_request.LoadedPages,1,5);
        for(var i=0;i<pages&&_active;i++){await LoadAsync();if(_page<=i)break;}
        if(!_active)return;
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,()=>
        {if(!_active)return;FindScroll(Titles)?.ChangeView(null,_request.Offset,null,true);if(_titles.FirstOrDefault(t=>t.Id==_request.FocusTitleId) is {} title){Titles.ScrollIntoView(title);DispatcherQueue.TryEnqueue(()=>{if(_active)(Titles.ContainerFromItem(title) as Control)?.Focus(FocusState.Keyboard);});}});
    }
    private async Task LoadAsync()
    {
        if(_busy)return;_busy=true;_load?.Cancel();_load?.Dispose();_load=new();var token=_load.Token;var generation=++_generation;
        BusyBar.Visibility=Visibility.Visible;BusyBar.IsIndeterminate=true;Error.IsOpen=false;More.IsEnabled=false;
        try
        {
            var result=_page==0?await HomeCatalogCache.LoadAsync(_request,token):await CatalogService.LoadAsync(_request,_page+1,token);token.ThrowIfCancellationRequested();
            if(!_active||generation!=_generation)return;
            foreach(var title in result.Titles)if(_titles.Count<100&&!_titles.Any(t=>t.Id==title.Id))_titles.Add(title.Detached());
            _page=result.Page;_pages=Math.Min(5,result.TotalPages);More.Visibility=_page<_pages&&_titles.Count<100 ? Visibility.Visible : Visibility.Collapsed;
            if(_titles.Count==0){Error.Message="No titles are available for this catalog.";Error.IsOpen=true;}
        }
        catch(OperationCanceledException){}
        catch(Exception error) when(error is TmdbException or ProviderException){if(!token.IsCancellationRequested){Error.Message=error.Message;Error.IsOpen=true;}}
        finally{if(generation==_generation){BusyBar.IsIndeterminate=false;BusyBar.Visibility=Visibility.Collapsed;More.IsEnabled=true;_busy=false;}}
    }
    protected override void OnNavigatedFrom(NavigationEventArgs args)
    {_request.Offset=FindScroll(Titles)?.VerticalOffset??0;_request.LoadedPages=Math.Max(1,_page);_active=false;++_generation;_busy=false;_load?.Cancel();BusyBar.IsIndeterminate=false;PosterImages.Clear(Titles);_titles.Clear();_page=0;base.OnNavigatedFrom(args);}
    private void More_Click(object sender,RoutedEventArgs args)=>_=LoadAsync();
    private void Title_Click(object sender,ItemClickEventArgs args){if(args.ClickedItem is MediaTitle title){_request.FocusTitleId=title.Id;TitleRequested?.Invoke(this,new(title.Id));}}
    private void Title_Changing(ListViewBase sender,ContainerContentChangingEventArgs args)
    {
        if(!args.InRecycleQueue&&args.Item is MediaTitle title)AutomationProperties.SetName(args.ItemContainer,title.AccessibleName);
        PosterImages.Update(args,(args.Item as MediaTitle)?.PosterUri,Titles.ItemsPanelRoot is ItemsWrapGrid panel?(panel.ItemWidth-16)*1.5:246);
    }
    private void Back_Click(object sender,RoutedEventArgs args){if(Frame.CanGoBack)Frame.GoBack(new SuppressNavigationTransitionInfo());}
    private void Titles_SizeChanged(object sender,SizeChangedEventArgs args)
    {if(Titles.ItemsPanelRoot is ItemsWrapGrid panel){var width=Math.Max(160,Titles.ActualWidth-16);var columns=Math.Max(1,Math.Floor(width/180));panel.ItemWidth=width/columns;panel.ItemHeight=(panel.ItemWidth-16)*1.5+84;}}
    private static ScrollViewer? FindScroll(DependencyObject root){for(var i=0;i<VisualTreeHelper.GetChildrenCount(root);i++){var child=VisualTreeHelper.GetChild(root,i);if(child is ScrollViewer scroll)return scroll;if(FindScroll(child)is{} found)return found;}return null;}
}
