using System.Text.Json;
using Eclipse.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.Web.WebView2.Core;

namespace Eclipse.Windows.Views;

internal static class SourceDialogs
{
    private static readonly SemaphoreSlim Gate=new(1,1);
    private static async Task<ContentDialogResult> ShowAsync(ContentDialog dialog)
    {
        await Gate.WaitAsync();
        try{return await dialog.ShowAsync();}
        catch(System.Runtime.InteropServices.COMException){return ContentDialogResult.None;}
        finally{Gate.Release();}
    }
    public static async Task MessageAsync(XamlRoot root,string title,string message)=>await ShowAsync(new EclipseDialog{XamlRoot=root,Title=title,Content=new TextBlock{Text=message,TextWrapping=TextWrapping.Wrap},CloseButtonText="OK"});
    public static async Task<bool> ConfirmAsync(XamlRoot root,string title,string message,string action)=>
        await ShowAsync(new EclipseDialog{XamlRoot=root,Title=title,Content=new TextBlock{Text=message,TextWrapping=TextWrapping.Wrap},PrimaryButtonText=action,CloseButtonText="Cancel",DefaultButton=ContentDialogButton.Close})==ContentDialogResult.Primary;
    public static async Task<string?> UrlAsync(XamlRoot root,string title,string message,string placeholder,string action="Add",string initial="")
    {
        var box=new TextBox{PlaceholderText=placeholder,Text=initial,IsSpellCheckEnabled=false,IsTextPredictionEnabled=false,MinWidth=420};
        box.InputScope=new Microsoft.UI.Xaml.Input.InputScope{Names={new Microsoft.UI.Xaml.Input.InputScopeName(Microsoft.UI.Xaml.Input.InputScopeNameValue.Url)}};
        AutomationProperties.SetName(box,placeholder);
        var panel=new StackPanel{Spacing=10};panel.Children.Add(new TextBlock{Text=message,TextWrapping=TextWrapping.Wrap});panel.Children.Add(box);
        var dialog=new EclipseDialog{XamlRoot=root,Title=title,Content=panel,PrimaryButtonText=action,CloseButtonText="Cancel",DefaultButton=ContentDialogButton.Primary,IsPrimaryButtonEnabled=initial.Trim().Length>0};
        box.TextChanged+=(_,_)=>dialog.IsPrimaryButtonEnabled=box.Text.Trim().Length>0;
        return await ShowAsync(dialog)==ContentDialogResult.Primary?box.Text.Trim():null;
    }

    public static async Task ServiceSettingsAsync(XamlRoot root,JsService service)
    {
        var settings=JsServices.ParseSettings(service.Script);
        if(settings.Count==0){await MessageAsync(root,service.Metadata.SourceName,"This service doesn't have configurable settings.");return;}
        var values=new Dictionary<string,Func<string?>>();var panel=new StackPanel{Spacing=12,MinWidth=440};
        panel.Children.Add(new TextBlock{Text=$"{service.Metadata.Author.Name} • v{service.Metadata.Version}",Style=(Style)Application.Current.Resources["SettingsDescriptionStyle"]});
        foreach(var setting in settings)
        {
            var label=setting.Key;var description=setting.Comment;FrameworkElement control;
            if(setting.Type=="bool"){var toggle=new ToggleSwitch{IsOn=setting.Value=="true",MinWidth=0};control=toggle;values[setting.Key]=()=>toggle.IsOn?"true":"false";}
            else if(setting.Options is {Count:>0} options){var combo=new ComboBox{ItemsSource=options,SelectedItem=options.Contains(setting.Value)?setting.Value:options[0],MinWidth=200};control=combo;values[setting.Key]=()=>combo.SelectedItem as string;}
            else if(setting.Type is "int" or "float"){var number=new NumberBox{Value=double.TryParse(setting.Value,System.Globalization.NumberStyles.Float,System.Globalization.CultureInfo.InvariantCulture,out var n)?n:0,SpinButtonPlacementMode=NumberBoxSpinButtonPlacementMode.Compact,MinWidth=160,PlaceholderText=setting.Type=="int"?"Enter number":"Enter decimal number"};control=number;values[setting.Key]=()=>double.IsNaN(number.Value)?null:setting.Type=="int"?((long)Math.Round(number.Value)).ToString(System.Globalization.CultureInfo.InvariantCulture):number.Value.ToString(System.Globalization.CultureInfo.InvariantCulture);}
            else if(Sensitive(setting)){var secret=new PasswordBox{Password=setting.Value,PlaceholderText="Enter secure value",MinWidth=240};control=secret;values[setting.Key]=()=>secret.Password;}
            else{var text=new TextBox{Text=setting.Value,PlaceholderText="Enter text",MinWidth=240};control=text;values[setting.Key]=()=>text.Text;}
            AutomationProperties.SetName(control,label);
            var row=new Grid{ColumnSpacing=16};row.ColumnDefinitions.Add(new());row.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
            row.Children.Add(SettingsUI.Text(label,description));Grid.SetColumn(control,1);control.VerticalAlignment=VerticalAlignment.Center;row.Children.Add(control);panel.Children.Add(row);
        }
        var dialog=new EclipseDialog{XamlRoot=root,Title=service.Metadata.SourceName,Content=new ScrollViewer{Content=panel,MaxHeight=520},PrimaryButtonText="Save",CloseButtonText="Cancel",DefaultButton=ContentDialogButton.Primary};
        if(await ShowAsync(dialog)!=ContentDialogResult.Primary)return;
        var updated=settings.Select(s=>values[s.Key]() is {} v?s with{Value=v}:s).ToArray();
        try{JsServices.Shared.UpdateSettings(service,updated);await MessageAsync(root,"Settings Saved","The service settings have been updated successfully.");}
        catch(Exception error) when(error is IOException or UnauthorizedAccessException){await MessageAsync(root,"Settings Not Saved",error.Message);}
    }
    private static bool Sensitive(ServiceSetting setting)
    {
        var key=System.Text.RegularExpressions.Regex.Replace(setting.Key.ToLowerInvariant(),"[^a-z0-9]+","_");
        return new[]{"token","secret","password","passwd","authorization","cookie","api_key","apikey","access_key","private_key"}.Any(key.Contains)||new[]{"api key","access token","refresh token","authorization","password","secret","session cookie","private key","eclipse sensitive"}.Any(m=>setting.Comment?.ToLowerInvariant().Contains(m)==true);
    }

    public static async Task NuvioSettingsAsync(XamlRoot root,NuvioScraper scraper)
    {
        var panel=new StackPanel{Spacing=12,MinWidth=440};
        var enabled=new ToggleSwitch{IsOn=scraper.IsRunnable,MinWidth=0,IsEnabled=scraper.ManifestEnabled};
        enabled.Toggled+=(_,_)=>{try{NuvioPlugins.Shared.SetScraperEnabled(scraper.Id,enabled.IsOn);}catch(Exception error) when(error is IOException or UnauthorizedAccessException){}};
        panel.Children.Add(SettingsUI.Section("Provider"));panel.Children.Add(SettingsUI.Card("Enabled",null,enabled));
        var fieldsHost=new StackPanel{Spacing=8};panel.Children.Add(fieldsHost);
        var dialog=new EclipseDialog{XamlRoot=root,Title=scraper.DisplayName,Content=new ScrollViewer{Content=panel,MaxHeight=540},CloseButtonText="Done"};
        using var lifetime=new CancellationTokenSource();
        async Task Load()
        {
            fieldsHost.Children.Clear();var ring=new ProgressRing{IsActive=true,Width=24,Height=24,HorizontalAlignment=HorizontalAlignment.Left};
            fieldsHost.Children.Add(ring);fieldsHost.Children.Add(SettingsUI.Note("Reading provider settings…"));
            try
            {
                var fields=await NuvioPlugins.Shared.SettingsFieldsAsync(scraper.Id,lifetime.Token);
                fieldsHost.Children.Clear();
                if(fields.Count==0){fieldsHost.Children.Add(SettingsUI.Note("This provider does not expose any configurable options."));return;}
                var values=NuvioPlugins.Shared.SettingsValues(scraper.Id);var group=SettingsUI.Group();
                void Flush(){if(group.Children.Count>0)fieldsHost.Children.Add(group);group=SettingsUI.Group();}
                foreach(var field in fields)
                {
                    if(field.Kind=="header"){Flush();fieldsHost.Children.Add(SettingsUI.Section(field.Label));continue;}
                    var current=values.TryGetValue(field.Key,out var v)?v:field.DefaultValue;
                    FrameworkElement control;
                    switch(field.Kind)
                    {
                        case "toggle":
                            var toggle=new ToggleSwitch{IsOn=current is {} b&&(b.ValueKind==JsonValueKind.True||b.ValueKind==JsonValueKind.String&&b.GetString()?.ToLowerInvariant() is "true" or "yes" or "1"||b.ValueKind==JsonValueKind.Number&&b.GetDouble()!=0),MinWidth=0};
                            toggle.Toggled+=(_,_)=>Save(field.Key,JsonSerializer.SerializeToElement(toggle.IsOn));control=toggle;break;
                        case "select":
                            var items=field.Options.Select(o=>new ComboBoxItem{Content=o.Label,Tag=o.Value}).ToArray();
                            var text=current is {} sv?sv.ValueKind==JsonValueKind.String?sv.GetString():sv.GetRawText():null;
                            var combo=new ComboBox{ItemsSource=items,SelectedItem=items.FirstOrDefault(i=>(string)i.Tag==text),MinWidth=200};
                            combo.SelectionChanged+=(_,_)=>{if(combo.SelectedItem is ComboBoxItem{Tag:string t})Save(field.Key,JsonSerializer.SerializeToElement(t));};control=combo;break;
                        default:
                            var box=new TextBox{Text=current is {} tv?tv.ValueKind==JsonValueKind.String?tv.GetString()??"":tv.GetRawText():"",MinWidth=240};
                            box.LostFocus+=(_,_)=>Save(field.Key,box.Text.Length==0?null:JsonSerializer.SerializeToElement(box.Text));control=box;break;
                    }
                    group.Children.Add(SettingsUI.Card(field.Label,field.Description,control));
                }
                Flush();
            }
            catch(OperationCanceledException){}
            catch(Exception error) when(error is SourceException or JsRunException or IOException or UnauthorizedAccessException)
            {
                fieldsHost.Children.Clear();fieldsHost.Children.Add(SettingsUI.Section("Couldn't Load Settings"));fieldsHost.Children.Add(SettingsUI.Note(error.Message));
                var retry=new Button{Content="Retry",Margin=new(0,8,0,0)};retry.Click+=async(_,_)=>await Load();fieldsHost.Children.Add(retry);
            }
        }
        void Save(string key,JsonElement? value){try{NuvioPlugins.Shared.SetSettingsValue(scraper.Id,key,value);}catch(Exception error) when(error is IOException or UnauthorizedAccessException){}}
        dialog.Opened+=async(_,_)=>await Load();
        await ShowAsync(dialog);lifetime.Cancel();
    }

    public static async Task StremioConfigureAsync(XamlRoot root,StremioAddon addon)
    {
        if(StremioClient.ConfigurationPageUri(addon.ConfiguredUrl) is not {} page){await MessageAsync(root,$"Configure {addon.Manifest.Name}","Unable to determine configure URL for this addon.");return;}
        var web=new WebView2{Height=520,MinWidth=680,HorizontalAlignment=HorizontalAlignment.Stretch};AutomationProperties.SetName(web,$"Configure {addon.Manifest.Name}");
        var loading=new ProgressBar{IsIndeterminate=true,Margin=new(0,0,0,4)};
        var status=new TextBlock{TextWrapping=TextWrapping.Wrap,Style=(Style)Application.Current.Resources["SettingsDescriptionStyle"],Visibility=Visibility.Collapsed};
        var manual=new TextBox{PlaceholderText="https://addon.example/...",IsSpellCheckEnabled=false,MinWidth=420};AutomationProperties.SetName(manual,"Configured addon URL");
        var save=new Button{Content="Save",IsEnabled=false};manual.TextChanged+=(_,_)=>save.IsEnabled=manual.Text.Trim().Length>0;
        var manualRow=new Grid{ColumnSpacing=8};manualRow.ColumnDefinitions.Add(new());manualRow.ColumnDefinitions.Add(new(){Width=GridLength.Auto});manualRow.Children.Add(manual);Grid.SetColumn(save,1);manualRow.Children.Add(save);
        var panel=new StackPanel{Spacing=8};panel.Children.Add(loading);panel.Children.Add(web);panel.Children.Add(status);
        panel.Children.Add(new TextBlock{Text="Configured addon URL",Margin=new(0,8,0,0)});panel.Children.Add(manualRow);
        var dialog=new EclipseDialog{XamlRoot=root,Title=$"Configure {addon.Manifest.Name}",Content=panel,CloseButtonText="Cancel"};
        dialog.Resources["ContentDialogMaxWidth"]=900.0;
        using var lifetime=new CancellationTokenSource();var applying=false;
        async void Apply(string url)
        {
            if(applying||lifetime.IsCancellationRequested)return;applying=true;loading.Visibility=Visibility.Visible;status.Visibility=Visibility.Collapsed;
            try{await StremioAddonStore.Shared.ReconfigureAsync(addon,StremioClient.NormalizedConfiguredUrl(url),lifetime.Token);dialog.Hide();}
            catch(OperationCanceledException){}
            catch(Exception error) when(error is SourceException or IOException or UnauthorizedAccessException){status.Text=error.Message;status.Visibility=Visibility.Visible;}
            finally{applying=false;loading.Visibility=Visibility.Collapsed;}
        }
        save.Click+=(_,_)=>Apply(manual.Text.Trim());
        bool Intercept(string? uri){if(uri is null||!uri.StartsWith("stremio://",StringComparison.OrdinalIgnoreCase))return false;Apply(uri);return true;}
        dialog.Opened+=async(_,_)=>
        {
            try
            {
                await web.EnsureCoreWebView2Async();var core=web.CoreWebView2;
                core.Settings.AreDevToolsEnabled=false;core.Settings.IsStatusBarEnabled=false;
                await core.AddScriptToExecuteOnDocumentCreatedAsync("(function(){function send(u){if(typeof u==='string'&&u.toLowerCase().startsWith('stremio://')){window.chrome.webview.postMessage(u);return true;}return false;}document.addEventListener('click',function(e){var t=e.target;while(t&&t.tagName!=='A'){t=t.parentElement;}if(t&&t.href&&send(t.href)){e.preventDefault();e.stopPropagation();}},true);var a=window.location.assign.bind(window.location);window.location.assign=function(u){if(send(u))return;a(u);};var r=window.location.replace.bind(window.location);window.location.replace=function(u){if(send(u))return;r(u);};var o=window.open;window.open=function(u){if(send(u))return null;return o.apply(window,arguments);};})();");
                core.WebMessageReceived+=(_,args)=>{try{Intercept(args.TryGetWebMessageAsString());}catch(ArgumentException){}};
                core.NavigationStarting+=(_,args)=>{if(Intercept(args.Uri))args.Cancel=true;else loading.Visibility=Visibility.Visible;};
                core.NavigationCompleted+=(_,args)=>{loading.Visibility=Visibility.Collapsed;if(!args.IsSuccess&&args.WebErrorStatus!=CoreWebView2WebErrorStatus.OperationCanceled){status.Text="The configuration page could not be loaded. Enter the configured addon URL below.";status.Visibility=Visibility.Visible;}};
                core.NewWindowRequested+=(_,args)=>{args.Handled=true;if(!Intercept(args.Uri)&&SourceHttp.HttpUri(args.Uri) is not null)core.Navigate(args.Uri);};
                core.Navigate(page.AbsoluteUri);
            }
            catch(Exception error) when(error is System.Runtime.InteropServices.COMException or InvalidOperationException or FileNotFoundException)
            {
                loading.Visibility=Visibility.Collapsed;web.Visibility=Visibility.Collapsed;
                status.Text="The Microsoft Edge WebView2 runtime is unavailable, so the configuration page can't open here. Configure the addon in a browser and enter its configured URL below.";status.Visibility=Visibility.Visible;
            }
        };
        await ShowAsync(dialog);lifetime.Cancel();web.Close();
    }
}
