using System.Collections.ObjectModel;
using Eclipse.Windows.Models;
using Eclipse.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Animation;

namespace Eclipse.Windows.Views;
public sealed partial class CatalogSettingsPage : Page
{
    private readonly BrowsingPreferences _value=PreferenceStore.Shared.Copy();
    private readonly ObservableCollection<HomeCatalog> _rows;
    private bool _initializing;
    public CatalogSettingsPage() {InitializeComponent();_rows=new(_value.EnabledCatalogs.OrderBy(c=>c.Order));CatalogList.ItemsSource=_rows;}
    private void Save()
    {
        for(var i=0;i<_rows.Count;i++)_rows[i].Order=i;
        _value.EnabledCatalogs=_rows.ToList();
        try {PreferenceStore.Shared.Save(_value);Notice.IsOpen=false;} catch {Notice.Message="Catalog settings could not be saved.";Notice.Severity=InfoBarSeverity.Error;Notice.IsOpen=true;}
    }
    private void Enabled_Click(object sender,RoutedEventArgs args) {if(sender is CheckBox {Tag:HomeCatalog c} box){c.IsEnabled=box.IsChecked==true;Save();}}
    private void Move(object sender,int delta)
    {if(sender is Button {Tag:HomeCatalog c}){var old=_rows.IndexOf(c);var next=old+delta;if(next>=0&&next<_rows.Count){_rows.Move(old,next);Save();}}}
    private void Up_Click(object sender,RoutedEventArgs args)=>Move(sender,-1);
    private void Down_Click(object sender,RoutedEventArgs args)=>Move(sender,1);
    private void Orientation_Loaded(object sender,RoutedEventArgs args)
    {
        if(sender is not ComboBox {Tag:HomeCatalog c} box)return;
        _initializing=true;var selected=_value.HomeCatalogLayoutOverrides.GetValueOrDefault(c.Id)?.Orientation ?? "global";
        box.SelectedItem=box.Items.OfType<ComboBoxItem>().FirstOrDefault(i=>(string)i.Tag==selected);_initializing=false;
    }
    private void Orientation_Changed(object sender,SelectionChangedEventArgs args)
    {if(!_initializing&&sender is ComboBox {IsLoaded:true,Tag:HomeCatalog c,SelectedItem:ComboBoxItem {Tag:string orientation}}){var layout=_value.HomeCatalogLayoutOverrides.GetValueOrDefault(c.Id)??new();layout.Orientation=orientation;_value.HomeCatalogLayoutOverrides[c.Id]=layout;Save();}}
    private void Size_Loaded(object sender,RoutedEventArgs args)
    {
        if(sender is not ComboBox{Tag:HomeCatalog c}box)return;
        _initializing=true;var scale=_value.HomeCatalogLayoutOverrides.GetValueOrDefault(c.Id)?.SizeScale;
        box.SelectedItem=box.Items.OfType<ComboBoxItem>().FirstOrDefault(i=>scale is null?(string)i.Tag=="global":double.TryParse((string)i.Tag,System.Globalization.CultureInfo.InvariantCulture,out var n)&&Math.Abs(n-scale.Value)<.001)??box.Items[0];_initializing=false;
    }
    private void Size_Changed(object sender,SelectionChangedEventArgs args)
    {if(!_initializing&&sender is ComboBox{IsLoaded:true,Tag:HomeCatalog c,SelectedItem:ComboBoxItem{Tag:string size}}){var layout=_value.HomeCatalogLayoutOverrides.GetValueOrDefault(c.Id)??new();layout.SizeScale=double.TryParse(size,System.Globalization.CultureInfo.InvariantCulture,out var n)?n:null;_value.HomeCatalogLayoutOverrides[c.Id]=layout;Save();}}
    private void Back_Click(object sender,RoutedEventArgs args) {if(Frame.CanGoBack)Frame.GoBack(new SuppressNavigationTransitionInfo());}
}
