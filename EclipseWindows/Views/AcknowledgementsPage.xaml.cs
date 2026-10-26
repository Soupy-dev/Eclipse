using System.Reflection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Eclipse.Windows.Views;

public sealed partial class AcknowledgementsPage : Page
{
    private sealed record Notice(string Title,string Detail,string Project,params (string Label,string Resource)[] Documents);
    public AcknowledgementsPage()
    {
        InitializeComponent();SettingsUI.Fit(Scroll,Form);
        Add("Project lineage & compatibility",
            new Notice("SoraCore","cranci1's service runtime. Eclipse's service runtime and network layer are adapted from it. Licensed under GPLv3.","https://github.com/cranci1/SoraCore"),
            new Notice("Nuvio","Defined the plugin format and behavior supported by Eclipse's Nuvio compatibility layer. Nuvio plugins are independent projects and are not bundled with Eclipse.","https://github.com/NuvioMedia/NuvioMobile"));
        Add("App libraries",
            new Notice("Acornima","JavaScript parser used by Jint. Copyright © Adam Simon.","https://github.com/adams85/acornima",("BSD 3-Clause License","Acornima.txt")),
            new Notice("AngleSharp","HTML parsing for plugin scraping. Copyright © 2013 - 2026 AngleSharp.","https://github.com/AngleSharp/AngleSharp",("MIT License","AngleSharp.txt")),
            new Notice("Jint","JavaScript interpreter that runs source scripts in a sandbox. Copyright © 2013, Sebastien Ros.","https://github.com/sebastienros/jint",("BSD 2-Clause License","Jint.txt")));
        Add("Application framework",
            new Notice(".NET","Runtime bundled with Eclipse. Copyright © .NET Foundation and Contributors.","https://github.com/dotnet/runtime",("MIT License","DotNet.txt"),("Third-party notices","DotNetThirdPartyNotices.txt")),
            new Notice("Windows App SDK and WinUI","Application platform and user interface framework.","https://github.com/microsoft/WindowsAppSDK",("Microsoft Software License Terms","WindowsAppSDK.txt"),("WinUI notices","WinUINotice.txt")),
            new Notice("Microsoft Edge WebView2","Embedded browser used for addon configuration pages.","https://developer.microsoft.com/microsoft-edge/webview2",("License","WebView2.txt"),("Notices","WebView2Notice.txt")));
    }
    private void Add(string section,params Notice[] notices)
    {
        Form.Children.Add(SettingsUI.Section(section));
        var group=SettingsUI.Group();
        foreach(var notice in notices)
        {
            var panel=new StackPanel{Spacing=8};
            panel.Children.Add(new TextBlock{Text=notice.Title,FontWeight=Microsoft.UI.Text.FontWeights.SemiBold});
            panel.Children.Add(new TextBlock{Text=notice.Detail,TextWrapping=TextWrapping.Wrap,Style=(Style)Application.Current.Resources["SettingsDescriptionStyle"]});
            panel.Children.Add(new HyperlinkButton{Content="Project",NavigateUri=new Uri(notice.Project),Padding=new(0,4,0,4)});
            foreach(var (label,resource) in notice.Documents)
            {
                var text=new TextBlock{TextWrapping=TextWrapping.Wrap,IsTextSelectionEnabled=true,FontFamily=new Microsoft.UI.Xaml.Media.FontFamily("Consolas"),FontSize=12};
                var expander=new Expander{Header=label,Content=text,HorizontalAlignment=HorizontalAlignment.Stretch,HorizontalContentAlignment=HorizontalAlignment.Stretch};
                expander.Expanding+=(_,_)=>{if(text.Text.Length==0)text.Text=Document(resource);};
                panel.Children.Add(expander);
            }
            group.Children.Add(SettingsUI.Panel(panel));
        }
        Form.Children.Add(group);
    }
    private static string Document(string name)
    {
        using var stream=Assembly.GetExecutingAssembly().GetManifestResourceStream("Eclipse.Licenses."+name);
        if(stream is null)return "This license document is missing from the app package.";
        using var reader=new StreamReader(stream);return reader.ReadToEnd();
    }
}
