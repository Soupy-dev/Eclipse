using System.Collections.ObjectModel;
using Eclipse.Windows.Models;
using Eclipse.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace Eclipse.Windows.Views;
public sealed partial class CatalogSettingsPage : Page
{
    private readonly BrowsingPreferences _value=PreferenceStore.Shared.Copy();
    private readonly ObservableCollection<HomeCatalog> _rows;
    public CatalogSettingsPage() {InitializeComponent();_rows=new(_value.EnabledCatalogs.OrderBy(c=>c.Order));CatalogList.ItemsSource=_rows;}
    private void Save()
    {
        for(var i=0;i<_rows.Count;i++)_rows[i].Order=i;
        _value.EnabledCatalogs=_rows.ToList();
        SettingsUI.Save(_value,Notice);
    }
    private void Page_SizeChanged(object sender,SizeChangedEventArgs args)
    {var padding=CatalogList.Padding;CatalogList.Padding=new Thickness(padding.Left,padding.Top,Math.Max(36,args.NewSize.Width-padding.Left-1000),padding.Bottom);}
    private void Enabled_Toggled(object sender,RoutedEventArgs args) {if(sender is ToggleSwitch{DataContext:HomeCatalog c} toggle&&c.IsEnabled!=toggle.IsOn){c.IsEnabled=toggle.IsOn;Save();}}
    private void Catalogs_Reordered(ListViewBase sender,DragItemsCompletedEventArgs args)=>Save();
    private void MoveUp_Invoked(KeyboardAccelerator sender,KeyboardAcceleratorInvokedEventArgs args){args.Handled=Move(Focused(),index=>index-1);}
    private void MoveDown_Invoked(KeyboardAccelerator sender,KeyboardAcceleratorInvokedEventArgs args){args.Handled=Move(Focused(),index=>index+1);}
    private HomeCatalog? Focused()
    {
        for(var node=FocusManager.GetFocusedElement(XamlRoot) as DependencyObject;node is not null;node=VisualTreeHelper.GetParent(node))
            if(node is ListViewItem item)return CatalogList.ItemFromContainer(item) as HomeCatalog;
        return null;
    }
    private bool Move(HomeCatalog? catalog,Func<int,int> destination)
    {
        if(catalog is null)return false;
        var from=_rows.IndexOf(catalog);var to=Math.Clamp(destination(from),0,_rows.Count-1);
        if(from<0||from==to)return true;
        _rows.Move(from,to);Save();
        CatalogList.ScrollIntoView(catalog);
        DispatcherQueue.TryEnqueue(()=>{if(CatalogList.ContainerFromItem(catalog) is ListViewItem item)item.Focus(FocusState.Keyboard);});
        return true;
    }
    private void Catalogs_ContextRequested(UIElement sender,ContextRequestedEventArgs args)
    {
        ListViewItem? container=null;
        for(var node=args.OriginalSource as DependencyObject;node is not null&&container is null;node=VisualTreeHelper.GetParent(node))container=node as ListViewItem;
        if(container is null||CatalogList.ItemFromContainer(container) is not HomeCatalog catalog)return;
        var menu=new MenuFlyout();
        foreach(var (text,target) in new (string,Func<int,int>)[]{("Move to top",_=>0),("Move up",i=>i-1),("Move down",i=>i+1),("Move to bottom",_=>_rows.Count-1)})
        {var item=new MenuFlyoutItem{Text=text};item.Click+=(_,_)=>Move(catalog,target);menu.Items.Add(item);}
        if(args.TryGetPosition(container,out var point))menu.ShowAt(container,point);else menu.ShowAt(container);
        args.Handled=true;
    }
}
