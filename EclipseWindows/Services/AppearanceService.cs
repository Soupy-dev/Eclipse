using Eclipse.Windows.Models;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace Eclipse.Windows.Services;

public sealed record AtmosphereSpec(string Mode,Color[] Mesh,Color Classic,Color Solid,bool FollowsDominant)
{
    public string Signature=>$"{Mode}:{string.Join(',',Mesh)}:{Classic}:{Solid}:{FollowsDominant}";
    public Color Fallback=>Mode switch{"multi"=>Mesh[4],"solid"=>Solid,_=>AppearanceService.Base};
}

public static class AppearanceService
{
    private static readonly HashSet<string> Overrides=[];
    private static readonly string[] AccentFillKeys=["AccentButtonBackground","AccentFillColorDefaultBrush","SystemControlHighlightAccentBrush","AppBarToggleButtonBackgroundChecked","CalendarViewSelectedBorderBrush","CalendarViewTodayBackground","CheckBoxCheckBackgroundFillChecked","CheckBoxCheckBackgroundFillIndeterminate","CheckBoxCheckBackgroundStrokeChecked","CheckBoxCheckBackgroundStrokeIndeterminate","ComboBoxItemPillFillBrush","GridViewItemCheckBoxSelectedBrush","GridViewItemSelectedBorderBrush","InfoBadgeBackground","ItemContainerSelectionVisualBackground","ItemContainerSelectionVisualPointerOverBackground","ItemContainerSelectionVisualPressedBackground","ListViewItemCheckBoxSelectedBrush","ListViewItemSelectionIndicatorBrush","ListViewItemSelectionIndicatorPointerOverBrush","ListViewItemSelectionIndicatorPressedBrush","NavigationViewSelectionIndicatorForeground","PersonPictureEllipseBadgeFillThemeBrush","PivotHeaderItemSelectedPipeFill","ProgressBarForeground","ProgressRingForegroundThemeBrush","RadioButtonOuterEllipseCheckedFill","RadioButtonOuterEllipseCheckedStroke","RatingControlPointerOverSelectedForeground","RatingControlSelectedForeground","SelectorBarItemPillFill","SliderThumbBackground","SliderTrackValueFill","SplitButtonBackgroundChecked","ToggleButtonBackgroundChecked","ToggleSwitchFillOn","ToggleSwitchStrokeOn"];
    private static readonly string[] AccentHoverKeys=["AccentButtonBackgroundPointerOver","AccentFillColorSecondaryBrush","AppBarToggleButtonBackgroundCheckedPointerOver","CalendarViewFocusBorderBrush","CalendarViewSelectedHoverBorderBrush","CalendarViewTodayHoverBackground","CheckBoxCheckBackgroundFillCheckedPointerOver","CheckBoxCheckBackgroundFillIndeterminatePointerOver","CheckBoxCheckBackgroundStrokeCheckedPointerOver","CheckBoxCheckBackgroundStrokeIndeterminatePointerOver","GridViewItemCheckBoxSelectedPointerOverBrush","GridViewItemSelectedPointerOverBorderBrush","ListViewItemCheckBoxSelectedPointerOverBrush","RadioButtonOuterEllipseCheckedFillPointerOver","RadioButtonOuterEllipseCheckedStrokePointerOver","SliderThumbBackgroundPointerOver","SliderTrackValueFillPointerOver","SplitButtonBackgroundCheckedPointerOver","ToggleButtonBackgroundCheckedPointerOver","ToggleSwitchFillOnPointerOver","ToggleSwitchStrokeOnPointerOver"];
    private static readonly string[] AccentPressedKeys=["AccentButtonBackgroundPressed","AccentFillColorTertiaryBrush","AppBarToggleButtonBackgroundCheckedPressed","CalendarViewTodayBlackoutBackground","CalendarViewTodayPressedBackground","CheckBoxCheckBackgroundFillCheckedPressed","CheckBoxCheckBackgroundFillIndeterminatePressed","CheckBoxCheckBackgroundStrokeCheckedPressed","CheckBoxCheckBackgroundStrokeIndeterminatePressed","GridViewItemCheckBoxSelectedPressedBrush","GridViewItemSelectedPressedBorderBrush","ListViewItemCheckBoxSelectedPressedBrush","RadioButtonOuterEllipseCheckedFillPressed","RadioButtonOuterEllipseCheckedStrokePressed","SliderThumbBackgroundPressed","SliderTrackValueFillPressed","SplitButtonBackgroundCheckedPressed","ToggleButtonBackgroundCheckedPressed","ToggleSwitchFillOnPressed","ToggleSwitchStrokeOnPressed"];
    private static readonly string[] AccentTextKeys=["AccentTextFillColorPrimaryBrush","AccentTextFillColorSecondaryBrush","AccentTextFillColorTertiaryBrush","CalendarViewSelectedForeground","CalendarViewSelectedHoverForeground","CalendarViewSelectedPressedForeground","HyperlinkButtonForeground","HyperlinkButtonForegroundPointerOver","HyperlinkButtonForegroundPressed","HyperlinkForeground","HyperlinkForegroundPointerOver","HyperlinkForegroundPressed","InfoBarHyperlinkButtonForeground"];
    private static readonly string[] OnAccentKeys=["TextOnAccentFillColorPrimaryBrush","AccentButtonForeground","AccentButtonForegroundPointerOver","AccentButtonForegroundPressed","AppBarToggleButtonCheckGlyphForegroundChecked","AppBarToggleButtonForegroundChecked","CalendarViewTodayForeground","CheckBoxCheckGlyphForegroundChecked","CheckBoxCheckGlyphForegroundCheckedPointerOver","CheckBoxCheckGlyphForegroundCheckedPressed","CheckBoxCheckGlyphForegroundIndeterminate","CheckBoxCheckGlyphForegroundIndeterminatePointerOver","CheckBoxCheckGlyphForegroundIndeterminatePressed","GridViewItemCheckBrush","GridViewItemCheckPressedBrush","InfoBadgeForeground","ListViewItemCheckBrush","ListViewItemCheckPressedBrush","PersonPictureEllipseBadgeForegroundThemeBrush","RadioButtonCheckGlyphFill","RadioButtonCheckGlyphFillPointerOver","RadioButtonCheckGlyphFillPressed","SplitButtonForegroundChecked","ToggleButtonForegroundChecked","ToggleButtonForegroundCheckedPointerOver","ToggleButtonForegroundCheckedPressed","ToggleSwitchKnobFillOn","ToggleSwitchKnobFillOnPointerOver","ToggleSwitchKnobFillOnPressed"];
    private static readonly UISettings SystemColors=new();
    private static bool _applying;
    private static string _signature="";
    public static readonly Color Base=Color.FromArgb(255,0x12,0x0F,0x18);
    private static readonly Color ClassicColor=Color.FromArgb(255,0x40,0x1F,0x73);
    public static Color Accent {get;private set;}=Color.FromArgb(255,0xBC,0x8C,0xFF);
    public static Color AmbientSecondary {get;private set;}=Color.FromArgb(255,0xC4,0xA8,0xFF);
    public static AtmosphereSpec Atmosphere {get;private set;}=Spec(new());
    public static double BleedStrength=>PreferenceStore.Shared.Value.AppearanceBleedStrength;

    public static Color AccentFor(string value)
    {
        if(BrowsingPreferences.IsHexColor(value))return Legible(AtmospherePalette.Parse(value));
        if(value=="windows")return Legible(SystemColors.GetColorValue(UIColorType.AccentLight2));
        return AtmospherePalette.Parse(AtmospherePalette.Accents.FirstOrDefault(a=>a.Id==value).Hex??"#BC8CFF");
    }

    public static AtmosphereSpec Spec(BrowsingPreferences settings)
    {
        var intensity=settings.AppearanceBackgroundIntensity;
        var palette=AtmospherePalette.Resolve(settings.AppearancePalette,settings.AppearanceCustomColors.Select(AtmospherePalette.Parse).ToArray());
        var mode=settings.AtmosphereStyle switch{"solid"=>"solid","gradient"=>"classic",_=>"multi"};
        var custom=settings.AtmosphereSolidColorSource=="custom";
        return new(mode,palette.Mesh.Select(c=>AtmospherePalette.Scaled(c,intensity)).ToArray(),AtmospherePalette.Scaled(ClassicColor,intensity),
            custom?AtmospherePalette.Parse(settings.AtmosphereSolidColor):ClassicColor,!custom);
    }

    public static void Apply(FrameworkElement root)
    {
        if(_applying)return;_applying=true;
        try
        {
            var settings=PreferenceStore.Shared.Value;
            MediaTitle.DataSaver=settings.ImageDataSaverEnabled;
            var contrast=new AccessibilitySettings().HighContrast;var accent=AccentFor(settings.AccentColor);
            Atmosphere=Spec(settings);
            var signature=$"{contrast}:{accent}";
            if(signature==_signature){if(!contrast&&root.Resources.TryGetValue("EclipsePageBrush",out var page)&&page is SolidColorBrush brush)brush.Color=Atmosphere.Fallback;return;}
            _signature=signature;
            foreach(var key in Overrides)root.Resources.Remove(key);Overrides.Clear();
            if(contrast){Refresh(root);return;}
            Accent=accent;AmbientSecondary=Blend(HueShift(accent,-12),Colors.White,.18);
            var accentText=.2126*accent.R+.7152*accent.G+.0722*accent.B>115?Color.FromArgb(255,0x21,0x12,0x2F):Colors.White;
            root.Resources["EclipsePageBrush"]=new SolidColorBrush(Atmosphere.Fallback);
            foreach(var key in new[] {"EclipseAccentColor","EclipseAccentHoverColor","EclipseAccentPressedColor","EclipseRailSelectedForegroundColor","SystemAccentColor","SystemAccentColorLight1","SystemAccentColorLight2","SystemAccentColorLight3","SystemAccentColorDark1","SystemAccentColorDark2","SystemAccentColorDark3"})
                root.Resources[key]=accent;
            root.Resources["EclipseAccentTextColor"]=accentText;
            void Brush(string key,Color color){root.Resources[key]=new SolidColorBrush(color);Overrides.Add(key);}
            foreach(var key in AccentFillKeys.Concat(AccentTextKeys))Brush(key,accent);
            foreach(var key in AccentHoverKeys)Brush(key,Color.FromArgb(230,accent.R,accent.G,accent.B));
            foreach(var key in AccentPressedKeys)Brush(key,Color.FromArgb(204,accent.R,accent.G,accent.B));
            foreach(var key in OnAccentKeys)Brush(key,accentText);
            Brush("TextControlSelectionHighlightColor",Blend(accent,Colors.Black,.45));
            foreach(var key in root.Resources.Keys.OfType<string>().Where(k=>k.StartsWith("Eclipse",StringComparison.Ordinal)||k.StartsWith("SystemAccentColor",StringComparison.Ordinal)))Overrides.Add(key);
            Refresh(root);
        }
        finally{_applying=false;}
    }

    // WinUI does not re-resolve existing ThemeResource values when a dictionary entry is replaced.
    private static void Refresh(FrameworkElement root){root.RequestedTheme=ElementTheme.Light;root.RequestedTheme=ElementTheme.Dark;}

    private static Color Legible(Color color)
    {
        var (h,s,l)=ToHsl(color);var result=color;
        while(Contrast(result)<4.5&&l<.97){l=Math.Min(.97,l+.02);result=FromHsl(h,s,l);}
        return result;
    }
    private static double Contrast(Color color)=>(Luminance(color)+.05)/(Luminance(Base)+.05);
    private static double Luminance(Color color)
    {
        static double Channel(byte value){var c=value/255.0;return c<=.03928?c/12.92:Math.Pow((c+.055)/1.055,2.4);}
        return .2126*Channel(color.R)+.7152*Channel(color.G)+.0722*Channel(color.B);
    }
    private static Color HueShift(Color color,double degrees){var (h,s,l)=ToHsl(color);return FromHsl(((h+degrees)%360+360)%360,s,l);}
    private static (double H,double S,double L) ToHsl(Color color)
    {
        double r=color.R/255.0,g=color.G/255.0,b=color.B/255.0,max=Math.Max(r,Math.Max(g,b)),min=Math.Min(r,Math.Min(g,b)),l=(max+min)/2,d=max-min;
        if(d==0)return(0,0,l);
        var h=max==r?60*(((g-b)/d)%6):max==g?60*((b-r)/d+2):60*((r-g)/d+4);
        return((h%360+360)%360,d/(1-Math.Abs(2*l-1)),l);
    }
    private static Color FromHsl(double h,double s,double l)
    {
        var c=(1-Math.Abs(2*l-1))*s;var x=c*(1-Math.Abs(h/60%2-1));var m=l-c/2;
        var (r,g,b)=h<60?(c,x,0.0):h<120?(x,c,0.0):h<180?(0.0,c,x):h<240?(0.0,x,c):h<300?(x,0.0,c):(c,0.0,x);
        return Color.FromArgb(255,(byte)Math.Round((r+m)*255),(byte)Math.Round((g+m)*255),(byte)Math.Round((b+m)*255));
    }
    private static Color Blend(Color a,Color b,double amount)=>Color.FromArgb(255,(byte)(a.R+(b.R-a.R)*amount),(byte)(a.G+(b.G-a.G)*amount),(byte)(a.B+(b.B-a.B)*amount));
}
