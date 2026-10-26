using Eclipse.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Navigation;

namespace Eclipse.Windows.Views;

public sealed partial class ExtraSourceSettingsPage : Page
{
    private readonly StackPanel _body=new(){Margin=new(36,28,36,48),HorizontalAlignment=HorizontalAlignment.Left};
    private readonly InfoBar _notice=new(){IsClosable=true,Margin=new(0,16,0,0)};
    private bool _rendering;
    public ExtraSourceSettingsPage()
    {
        InitializeComponent();
        var scroll=new ScrollViewer{Content=_body,Background=new SolidColorBrush(Microsoft.UI.Colors.Transparent),HorizontalScrollMode=ScrollMode.Disabled,HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled};
        Content=scroll;SettingsUI.Fit(scroll,_body);
    }
    protected override void OnNavigatedTo(NavigationEventArgs args){base.OnNavigatedTo(args);Render();}
    private void Save(Action<ServicesPreferences> change)
    {
        if(_rendering)return;
        try{ServicesPreferenceStore.Shared.Update(change);_notice.IsOpen=false;}
        catch(Exception error) when(error is IOException or UnauthorizedAccessException){_notice.Severity=InfoBarSeverity.Error;_notice.Title="Settings could not be saved";_notice.Message="Your previous settings are preserved.";_notice.IsOpen=true;}
    }
    private void Render()
    {
        _rendering=true;_body.Children.Clear();
        var p=ServicesPreferenceStore.Shared.Value;
        _body.Children.Add(new SettingsHeader{Trail="Settings|Services|Extra Source Settings"});_body.Children.Add(_notice);
        if(ServicesPreferenceStore.Shared.ReadError is {} error){_notice.Severity=InfoBarSeverity.Error;_notice.Title="Saved settings could not be read";_notice.Message=error;_notice.IsOpen=true;}

        _body.Children.Add(SettingsUI.Section("Stream list"));
        _body.Children.Add(SettingsUI.Card("Stremio-Style Stream List","Shows one compact, filterable list of results and streams instead of grouping them into separate source sections.",SettingsUI.Toggle(p.StremioStyleList,on=>Save(x=>x.StremioStyleList=on))));

        _body.Children.Add(SettingsUI.Section("Content Blocking"));
        _body.Children.Add(SettingsUI.Group(
            SettingsUI.Card("Block Add-on Subtitles",null,SettingsUI.Toggle(p.BlockAddonSubtitles,on=>Save(x=>x.BlockAddonSubtitles=on))),
            SettingsUI.Card("Block Add-on Catalogs",null,SettingsUI.Toggle(p.BlockAddonCatalogs,on=>Save(x=>x.BlockAddonCatalogs=on)))));
        _body.Children.Add(SettingsUI.Note("Master switches that block all add-on subtitles or catalogs, no matter how individual sources are configured. The app's default catalogs are never affected."));

        _body.Children.Add(SettingsUI.Section("Ranking"));
        var percent=new TextBlock{Text=$"{(int)Math.Round(p.MinimumSimilarity*100)}%",VerticalAlignment=VerticalAlignment.Center,MinWidth=40};
        var slider=SettingsUI.Slider(.5,1,.01,p.MinimumSimilarity,value=>{percent.Text=$"{(int)Math.Round(value*100)}%";Save(x=>x.MinimumSimilarity=Math.Round(value,2));});
        slider.ThumbToolTipValueConverter=new PercentConverter();
        var similarity=new StackPanel{Orientation=Orientation.Horizontal,Spacing=12};similarity.Children.Add(slider);similarity.Children.Add(percent);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(slider,"Ranking Similarity");
        _body.Children.Add(SettingsUI.Group(
            SettingsUI.Card("Ranking Similarity",null,similarity),
            SettingsUI.Card("Drop Unmatched Search Results",null,SettingsUI.Toggle(p.DropMismatchedResults,on=>Save(x=>x.DropMismatchedResults=on)))));
        _body.Children.Add(SettingsUI.Note("Service results at or above this percentage are prioritized by similarity. When dropping is enabled, weaker search matches are hidden. Stremio and Nuvio stream lookups use title IDs and are unaffected by this percentage."));

        _body.Children.Add(SettingsUI.Section("Language and quality rules"));
        var rules=SettingsUI.Group(
            SettingsUI.Navigation("Languages to Include",p.IncludedLanguages.Count==0?"All languages":string.Join(", ",p.IncludedLanguages.Select(MediaLanguages.FilterDisplayName)),()=>Frame.Navigate(typeof(LanguageRulesPage),true,new SuppressNavigationTransitionInfo())),
            SettingsUI.Navigation("Languages to Exclude",p.HiddenLanguages.Count==0?"None":string.Join(", ",p.HiddenLanguages.Select(MediaLanguages.FilterDisplayName)),()=>Frame.Navigate(typeof(LanguageRulesPage),false,new SuppressNavigationTransitionInfo())));
        if(ConflictingNames(p) is {Count:>0} conflicts)rules.Children.Add(SettingsUI.Note("Excluded languages take priority: "+string.Join(", ",conflicts)));
        rules.Children.Add(SettingsUI.Card("Hide Streams Without Language Data",null,SettingsUI.Toggle(p.HideUnknownLanguage,on=>Save(x=>x.HideUnknownLanguage=on))));
        rules.Children.Add(SettingsUI.Card("Assume Original Language for Untagged Streams",null,SettingsUI.Toggle(p.AssumeOriginalAudio,on=>Save(x=>x.AssumeOriginalAudio=on))));
        rules.Children.Add(SettingsUI.Card("Treat Dubbed Anime Streams as English",null,SettingsUI.Toggle(p.TreatDubbedAnimeAsEnglish,on=>Save(x=>x.TreatDubbedAnimeAsEnglish=on))));
        var clears=new StackPanel{Orientation=Orientation.Horizontal,Spacing=8};
        if(p.IncludedLanguages.Count>0){var clear=new Button{Content="Clear Included Languages"};clear.Click+=(_,_)=>{Save(x=>x.IncludedLanguages=[]);Render();};clears.Children.Add(clear);}
        if(p.HiddenLanguages.Count>0){var clear=new Button{Content="Clear Excluded Languages"};clear.Click+=(_,_)=>{Save(x=>x.HiddenLanguages=[]);Render();};clears.Children.Add(clear);}
        if(clears.Children.Count>0)rules.Children.Add(SettingsUI.Panel(clears));
        var qualities=new StackPanel{Spacing=4};
        var qualityExpander=new Expander{Header=QualityTitle(),Content=qualities,HorizontalAlignment=HorizontalAlignment.Stretch,HorizontalContentAlignment=HorizontalAlignment.Left};
        void UpdateQualityTitle()=>qualityExpander.Header=QualityTitle();
        foreach(var height in ServicesPreferences.SupportedQualityHeights)
        {
            var box=new CheckBox{Content=ServicesPreferences.QualityLabel(height),IsChecked=p.HiddenQualities.Contains(height)};
            box.Checked+=(_,_)=>{Save(x=>{if(!x.HiddenQualities.Contains(height))x.HiddenQualities.Add(height);});UpdateQualityTitle();};
            box.Unchecked+=(_,_)=>{Save(x=>x.HiddenQualities.Remove(height));UpdateQualityTitle();};
            qualities.Children.Add(box);
        }
        rules.Children.Add(qualityExpander);
        rules.Children.Add(SettingsUI.Card("Hide Streams Without Detected Quality",null,SettingsUI.Toggle(p.HideUnknownQuality,on=>Save(x=>x.HideUnknownQuality=on))));
        rules.Children.Add(ScopeExpander(p));
        _body.Children.Add(rules);
        _body.Children.Add(SettingsUI.Note("Best-effort stream rules for the selected sources. An Include list requires at least one matching audio language when languages are identified, including streams that also offer other languages. Untagged streams stay available unless Hide Streams Without Language Data is enabled. Exclude always takes priority, even when a stream has an included language. Dual or Multi Audio alone does not identify a language. Labeled subtitle languages are ignored. When Assume Original Language for Untagged Streams is enabled, a stream with no language data is evaluated using the media's TMDB original language before Include and Exclude rules run. When Treat Dubbed Anime Streams as English is enabled, anime streams labeled dubbed or dub are assumed English only when no audio language is identified. Quality and language detection use stream tags, filenames, and labels; a stream URL contributes only its path, and two-letter codes must be reported as language data or appear as deliberate release tags."));
        _rendering=false;
    }
    private static string QualityTitle(){var count=ServicesPreferenceStore.Shared.Value.HiddenQualities.Count;return count==0?"Qualities to Hide":$"Qualities to Hide ({count})";}
    private static List<string> ConflictingNames(ServicesPreferences p)
    {
        var hiddenIds=p.HiddenLanguages.Select(MediaLanguages.FilterCanonicalId).Where(i=>i is not null).Select(i=>i!).ToList();
        return p.IncludedLanguages.Where(value=>
        {
            if(MediaLanguages.FilterCanonicalId(value) is not {} included)
            {
                var tag=StreamDetection.NormalizedLanguageName(value);
                return tag is "Dual Audio" or "Multi Audio"&&p.HiddenLanguages.Any(h=>StreamDetection.NormalizedLanguageName(h)==tag);
            }
            return hiddenIds.Any(h=>MediaLanguages.RuleMatches(h,included)||MediaLanguages.RuleMatches(included,h));
        }).Select(MediaLanguages.FilterDisplayName).ToList();
    }
    private sealed record RuleSource(string Id,string Name,string Kind,bool IsActive);
    private Expander ScopeExpander(ServicesPreferences p)
    {
        var sources=new List<(string Group,RuleSource Source)>();
        sources.AddRange(JsServices.Shared.Services.Select(s=>("Services",new RuleSource(s.SourceId,s.Metadata.SourceName,"Service",s.IsActive))));
        sources.AddRange(StremioAddonStore.Shared.Addons.Where(a=>a.Manifest.SupportsStreams).Select(a=>("Stremio Addons",new RuleSource(a.SourceId,a.Manifest.Name,"Stremio Addon",a.IsActive))));
        sources.AddRange(NuvioPlugins.Shared.ActiveScrapers.Select(s=>("Nuvio Plugins",new RuleSource(s.Id,s.DisplayName,"Nuvio Provider",true))));
        var visible=sources.Select(s=>s.Source.Id).ToHashSet();
        string Summary(){var selected=ServicesPreferenceStore.Shared.Value.ExtraRulesSourceIds;return selected is null?"All":$"{selected.Count(visible.Contains)} of {visible.Count}";}
        var panel=new StackPanel{Spacing=6};var expander=new Expander{Header=$"Apply Extra Rules To: {Summary()}",Content=panel,HorizontalAlignment=HorizontalAlignment.Stretch,HorizontalContentAlignment=HorizontalAlignment.Left};
        if(sources.Count==0)panel.Children.Add(new TextBlock{Text="No connected stream sources.",Style=(Style)Application.Current.Resources["SettingsDescriptionStyle"]});
        foreach(var group in sources.GroupBy(s=>s.Group))
        {
            panel.Children.Add(new TextBlock{Text=group.Key,Style=(Style)Application.Current.Resources["BodyStrongTextBlockStyle"],Margin=new(0,6,0,0)});
            foreach(var (_,source) in group)
            {
                var content=SettingsUI.Text(source.Name,source.IsActive?source.Kind:$"{source.Kind} · Disabled");
                var box=new CheckBox{Content=content,IsChecked=p.ExtraRulesSourceIds?.Contains(source.Id)??true};
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box,source.Name);
                void Changed(bool selected)
                {
                    Save(x=>
                    {
                        if(x.ExtraRulesSourceIds is null&&selected)return;
                        var preserved=x.SourceOrder.Where(id=>(ServicesPreferences.ValidScopedSource(id,"nuvio:")||ServicesPreferences.ValidScopedSource(id,"skystream:"))&&!visible.Contains(id));
                        var set=(x.ExtraRulesSourceIds??visible.Concat(preserved).ToList()).ToHashSet();
                        if(selected)set.Add(source.Id);else set.Remove(source.Id);
                        x.ExtraRulesSourceIds=ServicesPreferences.SanitizedRuleSources(set).Order(StringComparer.Ordinal).ToList();
                    });
                    expander.Header=$"Apply Extra Rules To: {Summary()}";
                }
                box.Checked+=(_,_)=>Changed(true);box.Unchecked+=(_,_)=>Changed(false);
                panel.Children.Add(box);
            }
        }
        if(p.ExtraRulesSourceIds is not null){var all=new Button{Content="Apply to All Connected Sources",Margin=new(0,8,0,0)};all.Click+=(_,_)=>{Save(x=>x.ExtraRulesSourceIds=null);Render();};panel.Children.Add(all);}
        return expander;
    }
    private sealed partial class PercentConverter : Microsoft.UI.Xaml.Data.IValueConverter
    {
        public object Convert(object value,Type targetType,object parameter,string language)=>value is double d?$"{(int)Math.Round(d*100)}%":"";
        public object ConvertBack(object value,Type targetType,object parameter,string language)=>throw new NotSupportedException();
    }
}
