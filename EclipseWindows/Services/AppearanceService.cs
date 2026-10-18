using Eclipse.Windows.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace Eclipse.Windows.Services;

public static class AppearanceService
{
    private static readonly HashSet<string> Overrides=[];
    private static bool _applying;
    private static string _signature="";
    public static ElementTheme Theme
    {
        get
        {
            var preference=PreferenceStore.Shared.Value.Appearance;
            if(preference=="light")return ElementTheme.Light;if(preference!="system")return ElementTheme.Dark;
            var foreground=new UISettings().GetColorValue(UIColorType.Foreground);
            return 5*foreground.G+2*foreground.R+foreground.B>8*128?ElementTheme.Dark:ElementTheme.Light;
        }
    }
    public static void Apply(FrameworkElement root)
    {
        if(_applying)return;_applying=true;
        try
        {
        var settings=PreferenceStore.Shared.Value;
        MediaTitle.DataSaver=settings.ImageDataSaverEnabled;
        var theme=Theme;var contrast=new AccessibilitySettings().HighContrast;
        var signature=$"{theme}:{contrast}:{settings.AppearancePalette}:{settings.AtmosphereStyle}:{settings.AccentColor}";
        if(signature==_signature)return;_signature=signature;
        foreach(var key in Overrides)root.Resources.Remove(key);Overrides.Clear();
        if(contrast){root.RequestedTheme=theme==ElementTheme.Light?ElementTheme.Dark:ElementTheme.Light;root.RequestedTheme=theme;return;}
        var light=theme==ElementTheme.Light;
        var color=settings.AppearancePalette switch
        { "nocturne"=>light ? "#F1F5FB" : "#0D1422","velvet"=>light ? "#FAF2F8" : "#1D1220","mutedAurora"=>light ? "#F0F8F7" : "#101D20",_=>light ? "#F7F4FC" : "#14121C" };
        var accent=settings.AccentColor switch{"blue"=>light?"#1E64B2":"#82B8FF","pink"=>light?"#A92C72":"#F99ACB","green"=>light?"#166B4A":"#82D4B1","orange"=>light?"#965315":"#EDB077",_=>light?"#7442B8":"#BC8CFF"};
        var accentText=light?"#FFFFFF":"#21122F";
        var wash=settings.AtmosphereStyle switch{"aurora"=>"#73B4AE","ember"=>"#BB7059",_=>accent};
        var strength=settings.AtmosphereStyle=="gradient"?.045:.12;
        root.Resources["EclipsePageBrush"]=settings.AtmosphereStyle=="solid" ? new SolidColorBrush(Parse(color)) : new LinearGradientBrush
        { StartPoint=new(0,0),EndPoint=new(1,1),GradientStops=new GradientStopCollection { new() { Color=Parse(color),Offset=0 },new() {Color=Blend(Parse(color),Parse(wash),light?strength*.5:strength),Offset=.5},new(){Color=Blend(Parse(color),Parse(accent),light?.015:.025),Offset=1} } };
        root.Resources["EclipseRailColor"]=Parse(light ? "#F1EDF6" : "#100E1B");
        root.Resources["EclipseRailBrush"]=new SolidColorBrush(Parse(light ? "#F1EDF6" : "#100E1B"));
        root.Resources["EclipseRailIconColor"]=Parse(light ? "#625A71" : "#9A95A7");
        foreach(var key in new[] {"EclipseAccentColor","EclipseAccentHoverColor","EclipseAccentPressedColor","EclipseRailSelectedForegroundColor","SystemAccentColor","SystemAccentColorLight1","SystemAccentColorLight2","SystemAccentColorLight3","SystemAccentColorDark1","SystemAccentColorDark2","SystemAccentColorDark3"})
            root.Resources[key]=Parse(accent);
        root.Resources["EclipseAccentTextColor"]=Parse(accentText);
        foreach(var key in new[]{"AccentButtonBackground","AccentButtonBackgroundPointerOver","AccentButtonBackgroundPressed","AccentFillColorDefaultBrush","AccentFillColorSecondaryBrush","AccentFillColorTertiaryBrush","SystemControlHighlightAccentBrush","HyperlinkButtonForeground","HyperlinkButtonForegroundPointerOver"})
        {root.Resources[key]=new SolidColorBrush(Parse(accent));Overrides.Add(key);}
        foreach(var key in new[]{"AccentButtonForeground","AccentButtonForegroundPointerOver","AccentButtonForegroundPressed","TextOnAccentFillColorPrimaryBrush"})
        {root.Resources[key]=new SolidColorBrush(Parse(accentText));Overrides.Add(key);}
        foreach(var key in root.Resources.Keys.OfType<string>().Where(k=>k.StartsWith("Eclipse",StringComparison.Ordinal)||k.StartsWith("SystemAccentColor",StringComparison.Ordinal)))Overrides.Add(key);
        // WinUI does not re-resolve existing ThemeResource values when a dictionary entry
        // is replaced. Refresh the element theme only on an actual appearance change.
        root.RequestedTheme=theme==ElementTheme.Light?ElementTheme.Dark:ElementTheme.Light;root.RequestedTheme=theme;
        }
        finally{_applying=false;}
    }
    private static Color Parse(string value)=>Color.FromArgb(255,Convert.ToByte(value.Substring(1,2),16),Convert.ToByte(value.Substring(3,2),16),Convert.ToByte(value.Substring(5,2),16));
    private static Color Blend(Color a,Color b,double amount)=>Color.FromArgb(255,(byte)(a.R+(b.R-a.R)*amount),(byte)(a.G+(b.G-a.G)*amount),(byte)(a.B+(b.B-a.B)*amount));
}
