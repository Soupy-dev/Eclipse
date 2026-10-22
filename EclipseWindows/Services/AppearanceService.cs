using Eclipse.Windows.Models;
using Microsoft.UI;
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
    public static Color Accent {get;private set;}=Color.FromArgb(255,0xBC,0x8C,0xFF);
    // Second hue for ambient motion: a neighbouring lavender, so arcs vary without leaving Eclipse's palette.
    public static Color AmbientSecondary {get;private set;}=Color.FromArgb(255,0xC4,0xA8,0xFF);
    // The page atmosphere (EclipsePageBrush) as diagonal gradient stops; one stop when solid.
    public static (Color Color,float Offset)[] PageStops {get;private set;}=[(Color.FromArgb(255,0x14,0x12,0x1C),0)];
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
        Accent=Parse(accent);AmbientSecondary=wash==accent?Blend(HueShift(Accent,-12),Colors.White,light?0:.18):Parse(wash);
        var strength=settings.AtmosphereStyle=="gradient"?.045:.12;
        PageStops=settings.AtmosphereStyle=="solid"?[(Parse(color),0)]:[(Parse(color),0),(Blend(Parse(color),Parse(wash),light?strength*.5:strength),.5f),(Blend(Parse(color),Parse(accent),light?.015:.025),1)];
        var stops=new GradientStopCollection();foreach(var (stop,offset) in PageStops)stops.Add(new(){Color=stop,Offset=offset});
        root.Resources["EclipsePageBrush"]=PageStops.Length==1 ? new SolidColorBrush(PageStops[0].Color) : new LinearGradientBrush{StartPoint=new(0,0),EndPoint=new(1,1),GradientStops=stops};
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
    private static Color HueShift(Color color,double degrees)
    {
        double r=color.R/255.0,g=color.G/255.0,b=color.B/255.0,max=Math.Max(r,Math.Max(g,b)),min=Math.Min(r,Math.Min(g,b)),l=(max+min)/2,d=max-min;
        if(d==0)return color;
        var s=d/(1-Math.Abs(2*l-1));var h=max==r?60*(((g-b)/d)%6):max==g?60*((b-r)/d+2):60*((r-g)/d+4);
        h=((h+degrees)%360+360)%360;var c=(1-Math.Abs(2*l-1))*s;var x=c*(1-Math.Abs(h/60%2-1));var m=l-c/2;
        var (r1,g1,b1)=h<60?(c,x,0.0):h<120?(x,c,0.0):h<180?(0.0,c,x):h<240?(0.0,x,c):h<300?(x,0.0,c):(c,0.0,x);
        return Color.FromArgb(255,(byte)Math.Round((r1+m)*255),(byte)Math.Round((g1+m)*255),(byte)Math.Round((b1+m)*255));
    }
    private static Color Blend(Color a,Color b,double amount)=>Color.FromArgb(255,(byte)(a.R+(b.R-a.R)*amount),(byte)(a.G+(b.G-a.G)*amount),(byte)(a.B+(b.B-a.B)*amount));
}
