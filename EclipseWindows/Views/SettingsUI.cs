using System.Text.Json;
using Eclipse.Windows.Models;
using Eclipse.Windows.Services;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Windows.UI;

namespace Eclipse.Windows.Views;

public sealed class SettingsCrumb
{
    public string Text {get;init;}="";
    public AutomationHeadingLevel Heading {get;init;}
    public override string ToString()=>Text;
}

public sealed partial class SettingsHeader : UserControl
{
    public static readonly DependencyProperty TrailProperty=DependencyProperty.Register(nameof(Trail),typeof(string),typeof(SettingsHeader),new PropertyMetadata("",(d,_)=>((SettingsHeader)d).Render()));
    private readonly BreadcrumbBar _crumbs=new(){VerticalAlignment=VerticalAlignment.Center};
    private readonly Button _back=new(){Padding=new(10,8,10,8),VerticalAlignment=VerticalAlignment.Center,Content=new FontIcon{Glyph="",FontSize=16}};
    public string Trail{get=>(string)GetValue(TrailProperty);set=>SetValue(TrailProperty,value);}

    public SettingsHeader()
    {
        AutomationProperties.SetName(_back,"Back");ToolTipService.SetToolTip(_back,"Back (Alt+Left)");_back.Click+=(_,_)=>GoBack(1);
        _crumbs.Resources["BreadcrumbBarItemThemeFontSize"]=28.0;_crumbs.Resources["BreadcrumbBarItemFontWeight"]=FontWeights.SemiBold;_crumbs.Resources["BreadcrumbBarChevronFontSize"]=16.0;
        _crumbs.ItemTemplate=(DataTemplate)XamlReader.Load("<DataTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'><TextBlock Text='{Binding Text}' AutomationProperties.HeadingLevel='{Binding Heading}'/></DataTemplate>");
        _crumbs.ItemClicked+=(_,args)=>GoBack(Trail.Split('|').Length-1-args.Index);
        var grid=new Grid{ColumnSpacing=12};grid.ColumnDefinitions.Add(new(){Width=GridLength.Auto});grid.ColumnDefinitions.Add(new());
        Grid.SetColumn(_crumbs,1);grid.Children.Add(_back);grid.Children.Add(_crumbs);Content=grid;Render();
    }

    private void Render()
    {
        var items=Trail.Split('|');_back.Visibility=items.Length>1?Visibility.Visible:Visibility.Collapsed;
        _crumbs.ItemsSource=items.Select((text,index)=>new SettingsCrumb{Text=text,Heading=index==items.Length-1?AutomationHeadingLevel.Level1:AutomationHeadingLevel.None}).ToArray();
    }

    private void GoBack(int steps)
    {
        DependencyObject? node=this;while(node is not null and not Page)node=VisualTreeHelper.GetParent(node);
        if(node is not Page{Frame:{} frame})return;
        for(var i=0;i<steps&&frame.CanGoBack;i++)frame.GoBack(new SuppressNavigationTransitionInfo());
    }
}

internal sealed class SettingsSaver
{
    private readonly DispatcherTimer _timer=new(){Interval=TimeSpan.FromMilliseconds(300)};
    private readonly Action _save;
    public SettingsSaver(Action save){_save=save;_timer.Tick+=(_,_)=>Now();}
    public void Later(){_timer.Stop();_timer.Start();}
    public void Now(){_timer.Stop();_save();}
    public void Flush(){if(_timer.IsEnabled)Now();}
}

internal static class SettingsUI
{
    private static Style Style(string key)=>(Style)Application.Current.Resources[key];

    public static void Fit(ScrollViewer scroll,FrameworkElement content,double maximum=1000)
    {
        void Size()=>content.Width=Math.Max(1,Math.Min(maximum,scroll.ActualWidth-content.Margin.Left-content.Margin.Right));
        scroll.SizeChanged+=(_,_)=>Size();if(scroll.ActualWidth>0)Size();
    }

    public static TextBlock Section(string text)
    {var block=new TextBlock{Text=text,Style=Style("SettingsSectionHeaderStyle")};AutomationProperties.SetHeadingLevel(block,AutomationHeadingLevel.Level2);return block;}

    public static TextBlock Note(string text)=>new(){Text=text,Style=Style("SettingsDescriptionStyle"),Margin=new(2,10,0,0)};

    public static StackPanel Group(params UIElement[] items){var panel=new StackPanel{Spacing=4};foreach(var item in items)panel.Children.Add(item);return panel;}

    public static StackPanel Text(string title,string? description)
    {
        var text=new StackPanel{Spacing=2,VerticalAlignment=VerticalAlignment.Center};
        text.Children.Add(new TextBlock{Text=title,TextWrapping=TextWrapping.Wrap});
        if(description is{Length:>0})text.Children.Add(new TextBlock{Text=description,Style=Style("SettingsDescriptionStyle")});
        return text;
    }

    public static Border Card(string title,string? description,FrameworkElement? control=null,UIElement? below=null)
    {
        var row=new Grid{ColumnSpacing=16};row.ColumnDefinitions.Add(new());row.ColumnDefinitions.Add(new(){Width=GridLength.Auto});row.Children.Add(Text(title,description));
        if(control is not null)
        {
            Grid.SetColumn(control,1);control.VerticalAlignment=VerticalAlignment.Center;row.Children.Add(control);
            if(string.IsNullOrEmpty(AutomationProperties.GetName(control)))AutomationProperties.SetName(control,title);
        }
        UIElement child=row;
        if(below is not null){var stack=new StackPanel{Spacing=14};stack.Children.Add(row);stack.Children.Add(below);child=stack;}
        return new Border{Style=Style("SettingsCardStyle"),Child=child};
    }

    public static Border Panel(UIElement content)=>new(){Style=Style("SettingsCardStyle"),Child=content};

    public static Button Navigation(string title,string? description,Action open,string glyph="")
    {
        var grid=new Grid{ColumnSpacing=16};grid.ColumnDefinitions.Add(new());grid.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
        var chevron=new FontIcon{Glyph=glyph,FontSize=12,VerticalAlignment=VerticalAlignment.Center};Grid.SetColumn(chevron,1);
        grid.Children.Add(Text(title,description));grid.Children.Add(chevron);
        var button=new Button{Style=Style("SettingsNavigationCardStyle"),Content=grid};
        AutomationProperties.SetName(button,title);if(description is not null)AutomationProperties.SetHelpText(button,description);
        button.Click+=(_,_)=>open();return button;
    }

    public static ToggleSwitch Toggle(bool value,Action<bool> changed)
    {var toggle=new ToggleSwitch{IsOn=value,MinWidth=0};toggle.Toggled+=(_,_)=>changed(toggle.IsOn);return toggle;}

    public static ComboBox Choice(IReadOnlyList<(string Tag,string Label)> options,string current,Action<string> changed)
    {
        var items=options.Select(o=>new ComboBoxItem{Tag=o.Tag,Content=o.Label}).ToArray();
        var box=new ComboBox{ItemsSource=items,SelectedItem=items.FirstOrDefault(i=>(string)i.Tag==current)??items.FirstOrDefault(),MinWidth=200};
        box.SelectionChanged+=(_,_)=>{if(box.SelectedItem is ComboBoxItem{Tag:string tag})changed(tag);};return box;
    }

    public static Slider Slider(double minimum,double maximum,double step,double value,Action<double> changed)
    {
        var slider=new Slider{Minimum=minimum,Maximum=maximum,StepFrequency=step,Value=value,Width=220};
        slider.ValueChanged+=(_,args)=>changed(args.NewValue);return slider;
    }

    public static Button ColorButton(Color color,Action<Color> changed,Action? closed=null)
    {
        var swatch=new Border{Width=24,Height=24,CornerRadius=new(4),Background=new SolidColorBrush(color),BorderBrush=(Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"],BorderThickness=new(1)};
        var label=new TextBlock{Text=AtmospherePalette.Hex(color),VerticalAlignment=VerticalAlignment.Center};
        var content=new StackPanel{Orientation=Orientation.Horizontal,Spacing=10};content.Children.Add(swatch);content.Children.Add(label);
        var picker=new ColorPicker{Color=color,IsAlphaEnabled=false,IsMoreButtonVisible=false,IsColorChannelTextInputVisible=false,IsHexInputVisible=true};
        picker.ColorChanged+=(_,args)=>{var next=Color.FromArgb(255,args.NewColor.R,args.NewColor.G,args.NewColor.B);((SolidColorBrush)swatch.Background).Color=next;label.Text=AtmospherePalette.Hex(next);changed(next);};
        var flyout=new Flyout{Content=picker};if(closed is not null)flyout.Closed+=(_,_)=>closed();
        return new Button{Content=content,Flyout=flyout};
    }

    public static void Save(BrowsingPreferences value,InfoBar notice)
    {
        try{PreferenceStore.Shared.Save(JsonSerializer.Deserialize<BrowsingPreferences>(JsonSerializer.Serialize(value,PreferenceStore.JsonOptions),PreferenceStore.JsonOptions)!);notice.IsOpen=false;}
        catch(Exception error) when(error is IOException or UnauthorizedAccessException)
        {notice.Severity=InfoBarSeverity.Error;notice.Title="Settings could not be saved";notice.Message="Your previous settings are preserved.";notice.IsOpen=true;}
    }
}
