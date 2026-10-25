using Eclipse.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace Eclipse.Windows.Views;

public static class ComboDropDown
{
    public static readonly DependencyProperty IsEnabledProperty=DependencyProperty.RegisterAttached("IsEnabled",typeof(bool),typeof(ComboDropDown),new PropertyMetadata(false,Enabled_Changed));
    public static bool GetIsEnabled(DependencyObject element)=>(bool)element.GetValue(IsEnabledProperty);
    public static void SetIsEnabled(DependencyObject element,bool value)=>element.SetValue(IsEnabledProperty,value);

    private static void Enabled_Changed(DependencyObject element,DependencyPropertyChangedEventArgs args)
    {
        if(element is not ComboBox combo)return;
        combo.DropDownOpened-=Combo_Opened;combo.Loaded-=Combo_Loaded;
        if(args.NewValue is not true)return;
        combo.DropDownOpened+=Combo_Opened;combo.Loaded+=Combo_Loaded;
        if(combo.IsLoaded)HideNative(combo);
    }

    private static void Combo_Loaded(object sender,RoutedEventArgs args)=>HideNative((ComboBox)sender);

    private static void Combo_Opened(object? sender,object args)
    {
        var combo=(ComboBox)sender!;
        if(!InScaledShell(combo))return;
        var focus=combo.FocusState;
        combo.IsDropDownOpen=false;
        Show(combo,focus);
    }

    private static void HideNative(ComboBox combo)
    {if(InScaledShell(combo))HidePopup(combo);}

    private static bool HidePopup(DependencyObject node)
    {
        for(var i=0;i<VisualTreeHelper.GetChildrenCount(node);i++)
        {
            var child=VisualTreeHelper.GetChild(node,i);
            if(child is Popup{Child:{} content}){content.Visibility=Visibility.Collapsed;return true;}
            if(HidePopup(child))return true;
        }
        return false;
    }

    private static bool InScaledShell(DependencyObject node)
    {
        for(var parent=VisualTreeHelper.GetParent(node);parent is not null;parent=VisualTreeHelper.GetParent(parent))
            if(parent is ContentScale)return true;
        return false;
    }

    private static void Show(ComboBox combo,FocusState focus)
    {
        var list=new ListView{SelectionMode=ListViewSelectionMode.Single,IsItemClickEnabled=true,MinWidth=combo.ActualWidth,MaxHeight=Math.Max(160,(combo.XamlRoot?.Size.Height??900)*.6/ContentScale.Factor),ItemContainerStyle=ItemStyle()};
        ScrollViewer.SetHorizontalScrollMode(list,ScrollMode.Disabled);ScrollViewer.SetHorizontalScrollBarVisibility(list,ScrollBarVisibility.Disabled);
        if(combo.ItemTemplate is not null)list.ItemTemplate=combo.ItemTemplate;
        else if(!string.IsNullOrEmpty(combo.DisplayMemberPath))list.DisplayMemberPath=combo.DisplayMemberPath;
        if(combo.ItemTemplateSelector is not null)list.ItemTemplateSelector=combo.ItemTemplateSelector;
        foreach(var pair in AppearanceService.Current)list.Resources[pair.Key]=pair.Value;
        AutomationProperties.SetName(list,AutomationProperties.GetName(combo));
        var source=combo.Items.Cast<object>().ToArray();
        var shown=source.Select(item=>item is ComboBoxItem entry?new ListViewItem{Content=entry.Content,IsEnabled=entry.IsEnabled}:item).ToArray();
        foreach(var item in shown)list.Items.Add(item);
        list.SelectedIndex=combo.SelectedIndex;
        var flyout=new Flyout{Placement=FlyoutPlacementMode.BottomEdgeAlignedLeft,Content=new ScaledHost{Children={list}},FlyoutPresenterStyle=PresenterStyle()};
        var chosen=false;
        list.ItemClick+=(_,args)=>
        {
            var index=Array.FindIndex(shown,item=>Equals(item,args.ClickedItem));
            chosen=true;flyout.Hide();
            if(index<0)return;
            var current=combo.Items;
            for(var i=0;i<current.Count;i++)
                if(Equals(current[i],source[index])){if(i!=combo.SelectedIndex)combo.SelectedIndex=i;return;}
        };
        flyout.Opened+=(_,_)=>
        {
            if(list.Items.Count==0)return;
            var target=Math.Max(0,list.SelectedIndex);
            list.ScrollIntoView(list.Items[target]);list.UpdateLayout();
            if(list.ContainerFromIndex(target) is Control container)container.Focus(FocusState.Programmatic);
        };
        flyout.Closed+=(_,_)=>{if(chosen)combo.Focus(focus==FocusState.Keyboard?FocusState.Keyboard:FocusState.Programmatic);};
        flyout.ShowAt(combo);
    }

    private static Style ItemStyle()
    {
        var style=new Style(typeof(ListViewItem)){BasedOn=(Style)Application.Current.Resources["DefaultListViewItemStyle"]};
        style.Setters.Add(new Setter(FrameworkElement.MinHeightProperty,32.0));
        style.Setters.Add(new Setter(Control.PaddingProperty,new Thickness(11,0,11,0)));
        style.Setters.Add(new Setter(FrameworkElement.MarginProperty,new Thickness(5,2,5,2)));
        return style;
    }

    private static Style PresenterStyle()
    {
        var style=new Style(typeof(FlyoutPresenter));
        style.Setters.Add(new Setter(Control.PaddingProperty,new Thickness(0,2,0,2)));
        style.Setters.Add(new Setter(Control.BackgroundProperty,(Brush)Application.Current.Resources["SolidBackgroundFillColorQuarternaryBrush"]));
        style.Setters.Add(new Setter(FrameworkElement.MinWidthProperty,0.0));
        style.Setters.Add(new Setter(FrameworkElement.MaxWidthProperty,double.PositiveInfinity));
        style.Setters.Add(new Setter(ScrollViewer.HorizontalScrollBarVisibilityProperty,ScrollBarVisibility.Disabled));
        style.Setters.Add(new Setter(ScrollViewer.VerticalScrollBarVisibilityProperty,ScrollBarVisibility.Disabled));
        return style;
    }
}

internal sealed partial class ScaledHost : Panel
{
    private readonly ScaleTransform _transform=new();

    protected override Size MeasureOverride(Size available)
    {
        var factor=ContentScale.Factor;
        if(_transform.ScaleX!=factor)_transform.ScaleX=_transform.ScaleY=factor;
        var inner=new Size(available.Width/factor,available.Height/factor);
        double width=0,height=0;
        foreach(var child in Children){child.Measure(inner);width=Math.Max(width,child.DesiredSize.Width);height=Math.Max(height,child.DesiredSize.Height);}
        return new(width*factor,height*factor);
    }

    protected override Size ArrangeOverride(Size final)
    {
        var factor=ContentScale.Factor;
        foreach(var child in Children){if(!ReferenceEquals(child.RenderTransform,_transform))child.RenderTransform=_transform;child.Arrange(new Rect(0,0,final.Width/factor,final.Height/factor));}
        return final;
    }
}
