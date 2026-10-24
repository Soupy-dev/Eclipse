using Eclipse.Windows.Models;
using Eclipse.Windows.Services;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Navigation;
using Windows.System;
using Windows.UI;

namespace Eclipse.Windows.Views;

public sealed partial class AppearancePage : Page
{
    private static readonly string[] BodySections=["cast","stills","trailers","similarTitles"];
    private readonly BrowsingPreferences _value=PreferenceStore.Shared.Copy();
    private readonly SettingsSaver _saver;
    private Button? _sectionsReset;

    public AppearancePage()
    {
        InitializeComponent();
        _saver=new(()=>SettingsUI.Save(_value,Notice));
        SettingsUI.Fit(Scroll,Form);
    }

    protected override void OnNavigatedTo(NavigationEventArgs args)
    {
        base.OnNavigatedTo(args);
        var section=args.Parameter as string??"";
        var title=section switch{"theme"=>"Theme","motion"=>"Motion","home"=>"Home layout","details"=>"Detail pages","sections"=>"Media detail layout",_=>""};
        Header.Trail=title.Length==0?"Settings|Appearance":$"Settings|Appearance|{title}";
        switch(section){case "theme":Theme();break;case "motion":Motion();break;case "home":HomeLayout();break;case "details":DetailPages();break;case "sections":Sections();break;default:Overview();break;}
    }

    protected override void OnNavigatedFrom(NavigationEventArgs args){_saver.Flush();base.OnNavigatedFrom(args);}

    private void Add(UIElement element)=>Body.Children.Add(element);
    private void Open(string section)=>Frame.Navigate(typeof(AppearancePage),section,new SuppressNavigationTransitionInfo());

    private void Overview()
    {
        Add(SettingsUI.Section("Customize"));
        Add(SettingsUI.Group(SettingsUI.Navigation("Theme","Palette, background style, color bleed and accent color",()=>Open("theme"))));
        Add(SettingsUI.Section("Behavior"));
        Add(SettingsUI.Group(SettingsUI.Navigation("Motion","Animated background and frame rate",()=>Open("motion"))));
        Add(SettingsUI.Section("Layout & details"));
        Add(SettingsUI.Group(
            SettingsUI.Navigation("Home layout","Card size and orientation, globally or per catalog, and the hero banner",()=>Open("home")),
            SettingsUI.Navigation("Detail pages","Title artwork, episode lists and image data saver",()=>Open("details")),
            SettingsUI.Navigation("Media detail layout","Choose and order the sections on detail pages",()=>Open("sections"))));
    }

    private void Theme()
    {
        Add(SettingsUI.Section("Palette"));
        var palettes=new GridView{SelectionMode=ListViewSelectionMode.Single,IsItemClickEnabled=false,Margin=new(-4,-4,0,-4)};
        AutomationProperties.SetName(palettes,"Palette");
        Border? customSwatch=null;
        foreach(var id in AtmospherePalette.Ids)
        {
            var palette=Palette(id);
            var swatch=new Border{Width=64,Height=64,CornerRadius=new(8),Background=Gradient(palette),BorderThickness=new(1),BorderBrush=new SolidColorBrush(Color.FromArgb(36,255,255,255))};
            if(id=="custom")customSwatch=swatch;
            var stack=new StackPanel{Spacing=6,Width=96,Padding=new(0,6,0,6)};stack.Children.Add(swatch);
            stack.Children.Add(new TextBlock{Text=palette.Name,FontSize=12,HorizontalAlignment=HorizontalAlignment.Center,TextTrimming=TextTrimming.CharacterEllipsis});
            swatch.HorizontalAlignment=HorizontalAlignment.Center;
            var item=new GridViewItem{Content=stack,Tag=id};AutomationProperties.SetName(item,palette.Name);palettes.Items.Add(item);
            if(id==_value.AppearancePalette)palettes.SelectedItem=item;
        }
        var colors=new StackPanel{Orientation=Orientation.Horizontal,Spacing=8};
        for(var i=0;i<3;i++)
        {
            var index=i;
            var button=SettingsUI.ColorButton(AtmospherePalette.Parse(_value.AppearanceCustomColors[index]),color=>
            {_value.AppearanceCustomColors[index]=AtmospherePalette.Hex(color);if(customSwatch is not null)customSwatch.Background=Gradient(Palette("custom"));_saver.Later();});
            AutomationProperties.SetName(button,$"Custom color {index+1}");colors.Children.Add(button);
        }
        var custom=SettingsUI.Card("Custom colors","Custom palette colors blend into a multi-gradient. Pick three.",null,colors);
        custom.Visibility=_value.AppearancePalette=="custom"?Visibility.Visible:Visibility.Collapsed;
        palettes.SelectionChanged+=(_,_)=>
        {
            if(palettes.SelectedItem is not GridViewItem{Tag:string id})return;
            _value.AppearancePalette=id;custom.Visibility=id=="custom"?Visibility.Visible:Visibility.Collapsed;_saver.Now();
        };
        Add(SettingsUI.Group(SettingsUI.Panel(palettes),custom));

        Add(SettingsUI.Section("Background"));
        Border source=null!,solid=null!,bleed=null!,intensity=null!;
        source=SettingsUI.Card("Solid color source","Use the poster's color where available, or a custom color everywhere.",SettingsUI.Choice([("dominant","Poster dominant"),("custom","Custom color")],_value.AtmosphereSolidColorSource,value=>{_value.AtmosphereSolidColorSource=value;Refresh();_saver.Now();}));
        solid=SettingsUI.Card("Background color",null,SettingsUI.ColorButton(AtmospherePalette.Parse(_value.AtmosphereSolidColor),color=>{_value.AtmosphereSolidColor=AtmospherePalette.Hex(color);_saver.Later();}));
        bleed=SettingsUI.Card("Color bleed","How strongly the banner color washes down the page.",SettingsUI.Slider(0,1.2,.05,_value.AppearanceBleedStrength,value=>{_value.AppearanceBleedStrength=value;_saver.Later();}));
        intensity=SettingsUI.Card("Background intensity","Lighten or deepen the overall background.",SettingsUI.Slider(.6,1.3,.05,_value.AppearanceBackgroundIntensity,value=>{_value.AppearanceBackgroundIntensity=value;_saver.Later();}));
        var style=SettingsUI.Card("Background style","Multi-gradient blends smoothly; Classic uses a single-color gradient; Solid is flat.",
            SettingsUI.Choice([("multiGradient","Multi gradient"),("gradient","Classic gradient"),("solid","Solid color")],_value.AtmosphereStyle is "aurora" or "ember"?"multiGradient":_value.AtmosphereStyle,value=>{_value.AtmosphereStyle=value;Refresh();_saver.Now();}));
        void Refresh()
        {
            var isSolid=_value.AtmosphereStyle=="solid";
            source.Visibility=isSolid?Visibility.Visible:Visibility.Collapsed;
            solid.Visibility=isSolid&&_value.AtmosphereSolidColorSource=="custom"?Visibility.Visible:Visibility.Collapsed;
            bleed.Visibility=intensity.Visibility=isSolid?Visibility.Collapsed:Visibility.Visible;
        }
        Refresh();Add(SettingsUI.Group(style,source,solid,bleed,intensity));

        Add(SettingsUI.Section("Accent color"));
        var accents=new GridView{SelectionMode=ListViewSelectionMode.Single,Margin=new(-4,0,0,-4)};
        AutomationProperties.SetName(accents,"Accent color");
        foreach(var (id,name,_) in AtmospherePalette.Accents)
        {
            var item=new GridViewItem{Tag=id,Content=new Border{Width=40,Height=40,CornerRadius=new(6),Background=new SolidColorBrush(AppearanceService.AccentFor(id))}};
            AutomationProperties.SetName(item,name);ToolTipService.SetToolTip(item,name);accents.Items.Add(item);
            if(id==_value.AccentColor)accents.SelectedItem=item;
        }
        accents.SelectionChanged+=(_,_)=>{if(accents.SelectedItem is GridViewItem{Tag:string id}&&id!=_value.AccentColor){_value.AccentColor=id;_saver.Now();}};
        var customAccent=SettingsUI.ColorButton(BrowsingPreferences.IsHexColor(_value.AccentColor)?AtmospherePalette.Parse(_value.AccentColor):AppearanceService.Accent,color=>
        {_value.AccentColor=AtmospherePalette.Hex(color);accents.SelectedItem=null;_saver.Later();});
        Add(SettingsUI.Group(
            SettingsUI.Card("Accent color","Affects buttons, links, selection and the navigation rail. Windows follows your system accent.",null,accents),
            SettingsUI.Card("Custom color","Very dark colors are lightened so text stays readable.",customAccent)));
    }

    private void Motion()
    {
        Add(SettingsUI.Section("Background motion"));
        Add(SettingsUI.Group(
            SettingsUI.Card("Animated background","Show ambient motion behind broad app surfaces.",SettingsUI.Toggle(_value.HomeAnimatedBackgroundEnabled,value=>{_value.HomeAnimatedBackgroundEnabled=value;_saver.Now();})),
            SettingsUI.Card("Animation frame rate","Higher rates use more power; the display may limit the actual rate.",
                SettingsUI.Choice([("fps20","20 FPS"),("fps30","30 FPS"),("fps60","60 FPS"),("fps120","120 FPS")],_value.HomeAnimatedBackgroundFrameRate,value=>{_value.HomeAnimatedBackgroundFrameRate=value;_saver.Now();}))));
    }

    private void HomeLayout()
    {
        Add(SettingsUI.Section("Global"));
        Add(SettingsUI.Group(
            SettingsUI.Card("Orientation","Whether shelves prefer poster (tall) or landscape (wide) artwork.",SettingsUI.Choice([("automatic","Automatic"),("poster","Poster"),("landscape","Landscape")],_value.ExperimentalHomeCardShape,value=>{_value.ExperimentalHomeCardShape=value;_saver.Now();})),
            SettingsUI.Card("Size","Scale every Home row's cards.",SettingsUI.Slider(.75,1.35,.05,_value.ExperimentalMediaCardScale,value=>{_value.ExperimentalMediaCardScale=value;_saver.Later();})),
            SettingsUI.Card("Layout density","Controls hero scale, spacing and base card sizing.",SettingsUI.Choice([("cinematic","Cinematic"),("balanced","Balanced"),("compact","Compact")],_value.ExperimentalMediaDesignPreset,value=>{_value.ExperimentalMediaDesignPreset=value;_saver.Now();})),
            SettingsUI.Card("Card roundness","Corner radius of cards.",SettingsUI.Slider(.5,1.5,.05,_value.ExperimentalCardRadiusScale,value=>{_value.ExperimentalCardRadiusScale=value;_saver.Later();})),
            SettingsUI.Card("Section spacing","Vertical rhythm between shelves.",SettingsUI.Slider(.75,1.35,.05,_value.ExperimentalSectionSpacingScale,value=>{_value.ExperimentalSectionSpacingScale=value;_saver.Later();}))));

        Add(SettingsUI.Section("Hero"));
        var heroCatalogs=_value.EnabledCatalogs.Where(c=>c.IsAvailable&&c.DisplayStyle is not ("network" or "genre" or "company")).Select(c=>(c.Id,c.Name)).ToArray();
        var hero=heroCatalogs.Any(c=>c.Id==_value.HeroBannerCatalogId)?_value.HeroBannerCatalogId:_value.EnabledCatalogs.Where(c=>c.IsEnabled&&c.IsAvailable).OrderBy(c=>c.Order).FirstOrDefault(c=>c.DisplayStyle=="standard")?.Id??"";
        Add(SettingsUI.Group(
            SettingsUI.Card("Hero size","Scale the large banner artwork.",SettingsUI.Slider(.75,1.35,.05,_value.ExperimentalHeroHeightScale,value=>{_value.ExperimentalHeroHeightScale=value;_saver.Later();})),
            SettingsUI.Card("Hero banner","The Home catalog used for the large banner.",SettingsUI.Choice(heroCatalogs,hero,value=>{_value.HeroBannerCatalogId=value;_saver.Now();})),
            SettingsUI.Card("Hero behavior","When the banner changes.",SettingsUI.Choice([("carousel","Carousel"),("static","Static")],_value.HeroBannerBehavior,value=>{_value.HeroBannerBehavior=value;_saver.Now();}))));

        Add(SettingsUI.Section("Per catalog"));
        var rows=new StackPanel{Spacing=4};
        void Fill(){rows.Children.Clear();foreach(var catalog in _value.EnabledCatalogs.Where(c=>c.IsEnabled&&c.IsAvailable).OrderBy(c=>c.Order))rows.Children.Add(PerCatalog(catalog.Id,catalog.Name));}
        Fill();Add(rows);
        Add(SettingsUI.Note("Rows set to Global follow the settings above."));
        var reset=new Button{Content="Reset all catalogs",Margin=new(0,12,0,0)};
        reset.Click+=(_,_)=>{_value.HomeCatalogLayoutOverrides.Clear();_saver.Now();Fill();};
        Add(reset);
    }

    private Expander PerCatalog(string id,string name)
    {
        CatalogLayout Current()=>_value.HomeCatalogLayoutOverrides.GetValueOrDefault(id)??new();
        string Summary(){var layout=Current();var parts=new List<string>();if(layout.Orientation!="global")parts.Add(char.ToUpperInvariant(layout.Orientation[0])+layout.Orientation[1..]);if(layout.SizeScale is{} scale)parts.Add($"{scale:P0}");return parts.Count==0?"Global":string.Join(" · ",parts);}
        var summary=new TextBlock{Text=Summary(),Style=(Style)Application.Current.Resources["SettingsDescriptionStyle"],VerticalAlignment=VerticalAlignment.Center};
        var header=new Grid{ColumnSpacing=16};header.ColumnDefinitions.Add(new());header.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
        header.Children.Add(new TextBlock{Text=name,VerticalAlignment=VerticalAlignment.Center,TextTrimming=TextTrimming.CharacterEllipsis});Grid.SetColumn(summary,1);header.Children.Add(summary);
        void Store(Action<CatalogLayout> change)
        {
            var layout=Current();change(layout);
            if(layout.Orientation=="global"&&layout.SizeScale is null)_value.HomeCatalogLayoutOverrides.Remove(id);else _value.HomeCatalogLayoutOverrides[id]=layout;
            summary.Text=Summary();_saver.Later();
        }
        var size=SettingsUI.Slider(.75,1.35,.05,Current().SizeScale??_value.ExperimentalMediaCardScale,value=>Store(layout=>layout.SizeScale=value));
        size.Visibility=Current().SizeScale is null?Visibility.Collapsed:Visibility.Visible;AutomationProperties.SetName(size,$"{name} size");
        var custom=SettingsUI.Toggle(Current().SizeScale is not null,on=>{size.Visibility=on?Visibility.Visible:Visibility.Collapsed;Store(layout=>layout.SizeScale=on?size.Value:null);});
        AutomationProperties.SetName(custom,$"{name} custom size");
        var orientation=SettingsUI.Choice([("global","Global"),("automatic","Automatic"),("poster","Poster"),("landscape","Landscape")],Current().Orientation,value=>Store(layout=>layout.Orientation=value));
        AutomationProperties.SetName(orientation,$"{name} orientation");
        var content=new StackPanel{Spacing=12};
        content.Children.Add(Row("Orientation",orientation));content.Children.Add(Row("Custom size",custom));content.Children.Add(Row("Size",size));
        var reset=new Button{Content="Reset to Global"};
        reset.Click+=(_,_)=>{_value.HomeCatalogLayoutOverrides.Remove(id);custom.IsOn=false;orientation.SelectedIndex=0;_value.HomeCatalogLayoutOverrides.Remove(id);summary.Text=Summary();_saver.Now();};
        content.Children.Add(reset);
        var expander=new Expander{Header=header,Content=content,HorizontalAlignment=HorizontalAlignment.Stretch,HorizontalContentAlignment=HorizontalAlignment.Stretch};
        AutomationProperties.SetName(expander,name);return expander;
    }

    private static Grid Row(string title,FrameworkElement control)
    {
        var grid=new Grid{ColumnSpacing=16};grid.ColumnDefinitions.Add(new());grid.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
        grid.Children.Add(new TextBlock{Text=title,VerticalAlignment=VerticalAlignment.Center});Grid.SetColumn(control,1);grid.Children.Add(control);
        grid.SetBinding(VisibilityProperty,new Microsoft.UI.Xaml.Data.Binding{Source=control,Path=new(nameof(Visibility))});
        return grid;
    }

    private void DetailPages()
    {
        Add(SettingsUI.Section("Detail pages"));
        Add(SettingsUI.Group(
            SettingsUI.Card("Image data saver","Load smaller TMDB artwork on this device. Applies to newly loaded images.",SettingsUI.Toggle(_value.ImageDataSaverEnabled,value=>{_value.ImageDataSaverEnabled=value;_saver.Now();})),
            SettingsUI.Card("TMDB title artwork","Show the title's logo instead of plain text on the Home banner and detail pages.",SettingsUI.Toggle(_value.MediaDetailTitleArtworkEnabled,value=>{_value.MediaDetailTitleArtworkEnabled=value;_saver.Now();})),
            SettingsUI.Card("Horizontal episode cards","Show episodes as a row of cards instead of a vertical list.",SettingsUI.Toggle(_value.HorizontalEpisodeList,value=>{_value.HorizontalEpisodeList=value;_saver.Now();})),
            SettingsUI.Card("Show unaired episodes","Include episodes that have not aired yet.",SettingsUI.Toggle(_value.ShowUnairedEpisodes,value=>{_value.ShowUnairedEpisodes=value;_saver.Now();}))));
    }

    private void Sections()
    {
        bool Visible(string key)=>!_value.MediaDetailHiddenElements.Contains(key);
        void SetVisible(string key,bool visible){_value.MediaDetailHiddenElements=visible?_value.MediaDetailHiddenElements.Where(x=>x!=key).ToArray():_value.MediaDetailHiddenElements.Append(key).Distinct().ToArray();_saver.Now();}
        Border VisibilityCard(string key,string title,string description){var toggle=SettingsUI.Toggle(Visible(key),on=>SetVisible(key,on));return SettingsUI.Card(title,description,toggle);}

        Add(SettingsUI.Section("Title summary"));
        Add(SettingsUI.Group(
            VisibilityCard("overview","Overview","The synopsis under the title."),
            VisibilityCard("details","Details & ratings","Release information, genres and rating chips."),
            VisibilityCard("actions","Library actions","Collections and rating buttons."),
            VisibilityCard("ratingNotes","Your rating & notes","The button for your rating and private notes.")));

        Add(SettingsUI.Section("Sections"));
        Add(VisibilityCard("episodes","Episodes","Series always list episodes right after the summary."));
        var list=new ListView{SelectionMode=ListViewSelectionMode.None,CanReorderItems=true,CanDragItems=true,AllowDrop=true,Margin=new(0,4,0,0),ItemContainerStyle=(Style)Application.Current.Resources["SettingsListItemStyle"],KeyboardAcceleratorPlacementMode=KeyboardAcceleratorPlacementMode.Hidden};
        AutomationProperties.SetName(list,"Section order");
        var order=_value.MediaDetailElementOrder.Concat(new BrowsingPreferences().MediaDetailElementOrder).Distinct().ToList();
        foreach(var key in order.Where(BodySections.Contains))
        {
            var title=key switch{"similarTitles"=>"Similar titles",_=>char.ToUpperInvariant(key[0])+key[1..]};
            var grid=new Grid{ColumnSpacing=14};grid.ColumnDefinitions.Add(new(){Width=GridLength.Auto});grid.ColumnDefinitions.Add(new());grid.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
            var gripper=new FontIcon{Glyph="",FontSize=16,Foreground=(Brush)Application.Current.Resources["TextFillColorTertiaryBrush"],VerticalAlignment=VerticalAlignment.Center};
            var label=new TextBlock{Text=title,VerticalAlignment=VerticalAlignment.Center};Grid.SetColumn(label,1);
            var toggle=SettingsUI.Toggle(Visible(key),on=>SetVisible(key,on));AutomationProperties.SetName(toggle,$"Show {title}");Grid.SetColumn(toggle,2);
            grid.Children.Add(gripper);grid.Children.Add(label);grid.Children.Add(toggle);
            var item=new ListViewItem{Content=grid,Tag=key};AutomationProperties.SetName(item,title);list.Items.Add(item);
        }
        void Commit()
        {
            var moved=list.Items.OfType<ListViewItem>().Select(i=>(string)i.Tag).ToArray();var index=0;
            _value.MediaDetailElementOrder=order.Select(key=>BodySections.Contains(key)?moved[index++]:key).ToArray();
            order=_value.MediaDetailElementOrder.ToList();_saver.Now();
        }
        void Move(int delta)
        {
            if(FocusManager.GetFocusedElement(XamlRoot) is not DependencyObject focused)return;
            for(DependencyObject? node=focused;node is not null;node=VisualTreeHelper.GetParent(node))
                if(node is ListViewItem item&&list.Items.IndexOf(item) is var from and >=0)
                {
                    var to=from+delta;if(to<0||to>=list.Items.Count)return;
                    list.Items.RemoveAt(from);list.Items.Insert(to,item);Commit();
                    DispatcherQueue.TryEnqueue(()=>item.Focus(FocusState.Keyboard));return;
                }
        }
        list.DragItemsCompleted+=(_,_)=>Commit();
        foreach(var (key,delta) in new[]{(VirtualKey.Up,-1),(VirtualKey.Down,1)})
        {var accelerator=new KeyboardAccelerator{Key=key,Modifiers=VirtualKeyModifiers.Menu};accelerator.Invoked+=(_,args)=>{Move(delta);args.Handled=true;};list.KeyboardAccelerators.Add(accelerator);}
        Add(list);
        Add(SettingsUI.Note("Drag rows to change their order. With a row focused, Alt+Up and Alt+Down move it."));

        Add(SettingsUI.Section("Reset"));
        var reset=new Button{Content="Reset"};
        reset.Click+=(_,_)=>
        {
            var defaults=new BrowsingPreferences();_value.MediaDetailElementOrder=defaults.MediaDetailElementOrder;_value.MediaDetailHiddenElements=defaults.MediaDetailHiddenElements;_saver.Now();
            Body.Children.Clear();Sections();DispatcherQueue.TryEnqueue(()=>_sectionsReset?.Focus(FocusState.Programmatic));
        };
        _sectionsReset=reset;
        Add(SettingsUI.Card("Reset media detail layout","Restore the default order and visibility.",reset));
    }

    private AtmospherePalette Palette(string id)=>AtmospherePalette.Resolve(id,_value.AppearanceCustomColors.Select(AtmospherePalette.Parse).ToArray());
    private static LinearGradientBrush Gradient(AtmospherePalette palette)
    {
        var brush=new LinearGradientBrush{StartPoint=new(0,0),EndPoint=new(0,1)};
        foreach(var (color,offset) in palette.Stops)brush.GradientStops.Add(new GradientStop{Color=color,Offset=offset});
        return brush;
    }
}
