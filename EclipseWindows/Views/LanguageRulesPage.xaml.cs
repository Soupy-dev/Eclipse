using Eclipse.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;

namespace Eclipse.Windows.Views;

public sealed partial class LanguageRulesPage : Page
{
    private const int Maximum=40;
    private static readonly string[] AudioTags=["Dual Audio","Multi Audio"];
    private readonly StackPanel _body=new(){Margin=new(36,28,36,48),HorizontalAlignment=HorizontalAlignment.Left};
    private readonly StackPanel _results=new(){Spacing=4};
    private readonly InfoBar _notice=new(){IsClosable=true,Margin=new(0,16,0,0)};
    private readonly TextBox _search=new(){PlaceholderText="Search languages",Margin=new(0,16,0,0)};
    private readonly TextBlock _count=new(){Margin=new(2,10,0,0)};
    private bool _included;
    private CancellationTokenSource? _debounce;

    public LanguageRulesPage()
    {
        InitializeComponent();
        _count.Style=(Style)Application.Current.Resources["SettingsDescriptionStyle"];
        AutomationProperties.SetName(_search,"Search languages");
        _search.TextChanged+=async(_,_)=>{_debounce?.Cancel();_debounce=new();var token=_debounce.Token;try{await Task.Delay(150,token);RenderResults();}catch(TaskCanceledException){}};
        var scroll=new ScrollViewer{Content=_body,Background=new SolidColorBrush(Microsoft.UI.Colors.Transparent),HorizontalScrollMode=ScrollMode.Disabled,HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled};
        Content=scroll;SettingsUI.Fit(scroll,_body);
    }
    protected override void OnNavigatedTo(NavigationEventArgs args)
    {
        base.OnNavigatedTo(args);_included=args.Parameter is true;
        var title=_included?"Languages to Include":"Languages to Exclude";
        _body.Children.Clear();_body.Children.Add(new SettingsHeader{Trail=$"Settings|Services|Extra Source Settings|{title}"});
        _body.Children.Add(_notice);_body.Children.Add(_search);_body.Children.Add(_count);_body.Children.Add(_results);
        RenderResults();
    }
    private List<string> Selected=>_included?ServicesPreferenceStore.Shared.Value.IncludedLanguages:ServicesPreferenceStore.Shared.Value.HiddenLanguages;
    private List<string> Conflicting=>_included?ServicesPreferenceStore.Shared.Value.HiddenLanguages:ServicesPreferenceStore.Shared.Value.IncludedLanguages;
    private void Store(List<string> values)
    {
        try{ServicesPreferenceStore.Shared.Update(p=>{if(_included)p.IncludedLanguages=values;else p.HiddenLanguages=values;});_notice.IsOpen=false;}
        catch(Exception error) when(error is IOException or UnauthorizedAccessException){_notice.Severity=InfoBarSeverity.Error;_notice.Title="Settings could not be saved";_notice.Message="Your previous settings are preserved.";_notice.IsOpen=true;}
    }
    private static string? AudioTag(string value)=>StreamDetection.NormalizedLanguageName(value) is var tag&&tag is "Dual Audio" or "Multi Audio"?tag:null;
    private bool Conflicts(string id)=>Conflicting.Select(MediaLanguages.FilterCanonicalId).Where(c=>c is not null).Any(c=>MediaLanguages.RuleMatches(c!,id)||MediaLanguages.RuleMatches(id,c!));
    private void RenderResults()
    {
        _results.Children.Clear();
        var selected=Selected;var query=_search.Text.Trim();
        var selectedIds=selected.Select(MediaLanguages.FilterCanonicalId).Where(i=>i is not null).ToHashSet();
        _count.Text=$"{selected.Count} of {Maximum} rules selected. Changes save immediately.";
        var review=selected.Where(v=>MediaLanguages.FilterCanonicalId(v) is null&&AudioTag(v) is null).Distinct().ToList();
        if(review.Count>0)
        {
            _results.Children.Add(SettingsUI.Section("Needs Review"));
            foreach(var value in review)_results.Children.Add(Row(value,"Remove saved language rule",true,()=>Store(selected.Where(s=>s!=value).ToList())));
            _results.Children.Add(SettingsUI.Note("These saved rules are not recognized languages. They stay active until you remove them."));
        }
        var catalogIds=MediaLanguages.All.Select(l=>l.Id).ToHashSet();
        var variants=selected.Select(MediaLanguages.FilterLanguage).Where(l=>l is not null&&!catalogIds.Contains(l.Id)).Select(l=>l!).DistinctBy(l=>l.Id).ToList();
        if(variants.Count>0)
        {
            _results.Children.Add(SettingsUI.Section("Saved Language Variants"));
            foreach(var language in variants)_results.Children.Add(Row(language.Name,Detail(language),true,()=>Toggle(language)));
            _results.Children.Add(SettingsUI.Note("Select a saved variant to remove it."));
        }
        _results.Children.Add(SettingsUI.Section("Languages"));
        var visible=(query.Length==0?MediaLanguages.All:MediaLanguages.Search(query)).ToList();
        foreach(var language in visible)
        {
            var isSelected=selectedIds.Contains(language.Id);
            var row=Row(language.Name,Detail(language),isSelected,()=>Toggle(language));
            row.IsEnabled=isSelected||selected.Count<Maximum;
            _results.Children.Add(row);
        }
        var tags=AudioTags.Where(t=>query.Length==0||t.Contains(query,StringComparison.CurrentCultureIgnoreCase)).ToList();
        if(visible.Count==0&&tags.Count==0)_results.Children.Add(SettingsUI.Note("No matching languages"));
        if(tags.Count>0)
        {
            _results.Children.Add(SettingsUI.Section("Audio Tags"));
            foreach(var tag in tags)
            {
                var isSelected=selected.Any(s=>AudioTag(s)==tag);
                var row=Row(tag,null,isSelected,()=>Store(isSelected?selected.Where(s=>AudioTag(s)!=tag).ToList():ServicesPreferences.SanitizedLanguages([..selected,tag])));
                row.IsEnabled=isSelected||selected.Count<Maximum;_results.Children.Add(row);
            }
        }
    }
    private string Detail(MediaLanguage language)
    {
        var parts=new List<string>();if(language.NativeName!=language.Name)parts.Add(language.NativeName);parts.Add(language.Id);
        if(Conflicts(language.Id))parts.Add("Excluded languages take priority");
        return string.Join(" · ",parts);
    }
    private void Toggle(MediaLanguage language)
    {
        var selected=Selected;
        var matches=selected.Where(v=>MediaLanguages.FilterCanonicalId(v)==language.Id).ToList();
        Store(matches.Count>0?selected.Except(matches).ToList():ServicesPreferences.SanitizedLanguages([..selected,language.FilterValue]));
    }
    private Button Row(string title,string? detail,bool selected,Action action)
    {
        var grid=new Grid{ColumnSpacing=16};grid.ColumnDefinitions.Add(new());grid.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
        grid.Children.Add(SettingsUI.Text(title,detail));
        var check=new FontIcon{Glyph="",FontSize=14,Visibility=selected?Visibility.Visible:Visibility.Collapsed,Foreground=(Brush)Application.Current.Resources["AccentTextFillColorPrimaryBrush"]};
        Grid.SetColumn(check,1);grid.Children.Add(check);
        var button=new Button{Style=(Style)Application.Current.Resources["SettingsNavigationCardStyle"],Content=grid};
        AutomationProperties.SetName(button,title);AutomationProperties.SetItemStatus(button,selected?"Selected":"Not selected");
        button.Click+=(_,_)=>
        {
            action();RenderResults();
            if(_results.Children.OfType<Button>().FirstOrDefault(b=>AutomationProperties.GetName(b)==title) is {} again)again.Focus(FocusState.Keyboard);
        };
        return button;
    }
}
