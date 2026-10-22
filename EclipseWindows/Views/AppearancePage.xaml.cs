using Eclipse.Windows.Models;
using Eclipse.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Animation;
namespace Eclipse.Windows.Views;
public sealed partial class AppearancePage : Page
{
    private readonly BrowsingPreferences _value=PreferenceStore.Shared.Copy();
    public AppearancePage()
    {
        InitializeComponent();
        Choice("Theme",["system","dark","light"],_value.Appearance,v=>_value.Appearance=v);
        Choice("Background style",["gradient","multiGradient","aurora","ember","solid"],_value.AtmosphereStyle,v=>_value.AtmosphereStyle=v);
        Choice("Palette",["midnightPurple","nocturne","velvet","mutedAurora"],_value.AppearancePalette,v=>_value.AppearancePalette=v);
        Choice("Accent color",["purple","blue","pink","green","orange"],_value.AccentColor,v=>_value.AccentColor=v);
        Toggle("Animated background",_value.HomeAnimatedBackgroundEnabled,v=>_value.HomeAnimatedBackgroundEnabled=v);
        Choice("Animation frame rate",["fps20","fps30","fps60","fps120"],_value.HomeAnimatedBackgroundFrameRate,v=>_value.HomeAnimatedBackgroundFrameRate=v);
        Choice("Layout",["cinematic","balanced","compact"],_value.ExperimentalMediaDesignPreset,v=>_value.ExperimentalMediaDesignPreset=v);
        Choice("Home card orientation",["automatic","poster","landscape"],_value.ExperimentalHomeCardShape,v=>_value.ExperimentalHomeCardShape=v);
        AddScale("Card size",_value.ExperimentalMediaCardScale,v=>_value.ExperimentalMediaCardScale=v);
        AddScale("Section spacing",_value.ExperimentalSectionSpacingScale,v=>_value.ExperimentalSectionSpacingScale=v);
        AddScale("Card corners",_value.ExperimentalCardRadiusScale,v=>_value.ExperimentalCardRadiusScale=v);
        AddScale("Hero height",_value.ExperimentalHeroHeightScale,v=>_value.ExperimentalHeroHeightScale=v);
        var catalogs=_value.EnabledCatalogs.Where(c=>c.IsAvailable&&c.DisplayStyle is not ("network" or "genre" or "company")).ToArray();
        var hero=new ComboBox{Header="Hero catalog",ItemsSource=catalogs,SelectedItem=catalogs.FirstOrDefault(c=>c.Id==_value.HeroBannerCatalogId),HorizontalAlignment=HorizontalAlignment.Stretch};
        hero.SelectionChanged+=(_,_)=>{if(hero.SelectedItem is HomeCatalog c)_value.HeroBannerCatalogId=c.Id;};Form.Children.Add(hero);
        Choice("Hero behavior",["carousel","static"],_value.HeroBannerBehavior,v=>_value.HeroBannerBehavior=v);
        Toggle("Image Data Saver",_value.ImageDataSaverEnabled,v=>_value.ImageDataSaverEnabled=v);
        Toggle("TMDB title artwork",_value.MediaDetailTitleArtworkEnabled,v=>_value.MediaDetailTitleArtworkEnabled=v);
        Toggle("Horizontal episode cards",_value.HorizontalEpisodeList,v=>_value.HorizontalEpisodeList=v);
        Toggle("Show unaired episodes",_value.ShowUnairedEpisodes,v=>_value.ShowUnairedEpisodes=v);
        Form.Children.Add(new TextBlock{Text="Detail sections",FontSize=20,FontWeight=Microsoft.UI.Text.FontWeights.SemiBold});
        foreach(var key in new[]{"overview","actions","details","cast","ratingNotes","episodes","stills","trailers","similarTitles"})
            Toggle(Label(key),!_value.MediaDetailHiddenElements.Contains(key),visible=>{_value.MediaDetailHiddenElements=visible?_value.MediaDetailHiddenElements.Where(x=>x!=key).ToArray():_value.MediaDetailHiddenElements.Append(key).Distinct().ToArray();});
        var orderPanel=new StackPanel{Spacing=6};
        var known=new[]{"overview","actions","details","cast","episodes","stills","trailers","similarTitles"};
        var order=_value.MediaDetailElementOrder.Concat(known).Distinct().ToList();
        void RenderOrder()
        {
            orderPanel.Children.Clear();
            foreach(var key in order.Where(known.Contains))
            {
                var row=new StackPanel{Orientation=Orientation.Horizontal,Spacing=8};
                row.Children.Add(new TextBlock{Text=Label(key),Width=128,VerticalAlignment=VerticalAlignment.Center});
                foreach(var delta in new[]{-1,1})
                {
                    var button=new Button{Content=delta<0?"Up":"Down"};Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button,$"Move {Label(key)} {(delta<0?"up":"down")}");
                    button.Click+=(_,_)=>{var index=order.IndexOf(key);var next=index+delta;if(next<0||next>=order.Count)return;order.RemoveAt(index);order.Insert(next,key);_value.MediaDetailElementOrder=order.ToArray();RenderOrder();};row.Children.Add(button);
                }
                orderPanel.Children.Add(row);
            }
        }
        RenderOrder();Form.Children.Add(new Expander{Header="Detail section order",Content=orderPanel,HorizontalAlignment=HorizontalAlignment.Stretch});
        var save=new Button{Content="Save appearance",HorizontalAlignment=HorizontalAlignment.Left,Style=(Style)Application.Current.Resources["AccentButtonStyle"]};
        save.Click+=(_,_)=>{try{PreferenceStore.Shared.Save(_value);Notice.Severity=InfoBarSeverity.Success;Notice.Message="Appearance saved.";}catch{Notice.Severity=InfoBarSeverity.Error;Notice.Message="Appearance could not be saved. Your previous settings are preserved.";}Notice.IsOpen=true;};Form.Children.Add(save);
    }
    private static string Label(string key)=>key=="similarTitles"?"Similar titles":char.ToUpperInvariant(key[0])+key[1..];
    private void Choice(string name,string[] options,string current,Action<string> set)
    {
        string Name(string value)=>value switch{"midnightPurple"=>"Midnight Purple","mutedAurora"=>"Muted Aurora","multiGradient"=>"Multi Gradient",_ when value.StartsWith("fps",StringComparison.Ordinal)=>$"{value[3..]} FPS",_=>char.ToUpperInvariant(value[0])+value[1..]};
        var items=options.Select(o=>new ComboBoxItem{Tag=o,Content=Name(o)}).ToArray();
        var box=new ComboBox{Header=name,ItemsSource=items,SelectedItem=items.FirstOrDefault(i=>(string)i.Tag==current)??items[0],HorizontalAlignment=HorizontalAlignment.Stretch};
        box.SelectionChanged+=(_,_)=>{if(box.SelectedItem is ComboBoxItem{Tag:string s})set(s);};Form.Children.Add(box);
    }
    private void AddScale(string name,double value,Action<double> set)
    {var slider=new Slider{Header=name,Minimum=.75,Maximum=1.35,StepFrequency=.05,Value=value,HorizontalAlignment=HorizontalAlignment.Stretch};slider.ValueChanged+=(_,a)=>set(a.NewValue);Form.Children.Add(slider);}
    private void Toggle(string name,bool value,Action<bool> set)
    {var toggle=new ToggleSwitch{Header=name,IsOn=value};toggle.Toggled+=(_,_)=>set(toggle.IsOn);Form.Children.Add(toggle);}
    private void Back_Click(object sender,RoutedEventArgs args){if(Frame.CanGoBack)Frame.GoBack(new SuppressNavigationTransitionInfo());}
}
