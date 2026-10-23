using Windows.UI;

namespace Eclipse.Windows.Models;

public sealed record AtmospherePalette(string Id,string Name,Color[] Mesh,(Color Color,float Offset)[] Stops)
{
    public static readonly string[] Ids=["midnightPurple","nocturne","velvet","mutedAurora","custom"];
    public static readonly (string Id,string Name,string? Hex)[] Accents=
        [("windows","Windows",null),("purple","Eclipse","#BC8CFF"),("blue","Blue","#82B8FF"),("teal","Teal","#6CD4CF"),("green","Green","#82D4B1"),
         ("orange","Orange","#EDB077"),("red","Red","#FF8F8F"),("pink","Pink","#F99ACB"),("white","White","#F0EEF6")];

    private static readonly AtmospherePalette MidnightPurple=new("midnightPurple","Midnight Purple",
        [C(.105,.070,.210),C(.165,.085,.235),C(.085,.090,.240),C(.195,.082,.215),C(.180,.110,.300),C(.095,.110,.285),
         C(.150,.080,.215),C(.130,.100,.270),C(.080,.100,.235),C(.065,.052,.110),C(.078,.060,.130),C(.055,.055,.105)],
        [(C(.130,.085,.235),0),(C(.175,.105,.285),.40f),(C(.070,.058,.120),1)]);
    private static readonly AtmospherePalette Nocturne=new("nocturne","Nocturne",
        [C(.060,.095,.205),C(.080,.125,.255),C(.060,.105,.225),C(.072,.150,.270),C(.100,.165,.320),C(.070,.135,.300),
         C(.060,.120,.235),C(.090,.140,.295),C(.070,.105,.260),C(.048,.060,.120),C(.058,.072,.140),C(.044,.058,.110)],
        [(C(.078,.125,.255),0),(C(.095,.155,.305),.40f),(C(.050,.062,.125),1)]);
    private static readonly AtmospherePalette Velvet=new("velvet","Velvet",
        [C(.165,.060,.140),C(.205,.080,.180),C(.140,.070,.165),C(.225,.080,.205),C(.245,.105,.260),C(.165,.085,.225),
         C(.185,.070,.180),C(.165,.095,.245),C(.125,.075,.190),C(.085,.050,.105),C(.095,.062,.125),C(.072,.050,.100)],
        [(C(.205,.080,.180),0),(C(.235,.100,.250),.40f),(C(.082,.052,.105),1)]);
    private static readonly AtmospherePalette MutedAurora=new("mutedAurora","Muted Aurora",
        [C(.050,.130,.140),C(.070,.165,.180),C(.065,.125,.205),C(.072,.185,.200),C(.095,.205,.240),C(.110,.140,.265),
         C(.075,.155,.205),C(.095,.165,.250),C(.110,.120,.265),C(.048,.072,.115),C(.058,.090,.135),C(.052,.072,.120)],
        [(C(.070,.165,.185),0),(C(.100,.185,.245),.40f),(C(.050,.072,.120),1)]);

    public static AtmospherePalette Resolve(string id,IReadOnlyList<Color> custom)=>id switch
    {"nocturne"=>Nocturne,"velvet"=>Velvet,"mutedAurora"=>MutedAurora,"custom"=>Custom(custom),_=>MidnightPurple};

    private static AtmospherePalette Custom(IReadOnlyList<Color> colors)
    {
        var a=colors.Count>0?colors[0]:C(.16,.12,.20);var b=colors.Count>1?colors[1]:C(.26,.16,.34);var c=colors.Count>2?colors[2]:C(.20,.12,.16);
        var deep=C(.058,.050,.080);var aD=Scaled(a,.5);var bD=Scaled(b,.5);var bMid=Scaled(b,.62);var cD=Scaled(c,.46);
        return new("custom","Custom",[aD,Scaled(a,.56),aD,bD,bMid,bD,cD,Scaled(c,.52),cD,deep,deep,deep],[(aD,0),(bMid,.42f),(deep,1)]);
    }

    public static Color Scaled(Color color,double factor)=>factor==1?color:Color.FromArgb(color.A,Channel(color.R*factor),Channel(color.G*factor),Channel(color.B*factor));
    public static Color Parse(string hex)=>Color.FromArgb(255,Convert.ToByte(hex[1..3],16),Convert.ToByte(hex[3..5],16),Convert.ToByte(hex[5..7],16));
    public static string Hex(Color color)=>$"#{color.R:X2}{color.G:X2}{color.B:X2}";
    private static Color C(double r,double g,double b)=>Color.FromArgb(255,Channel(r*255),Channel(g*255),Channel(b*255));
    private static byte Channel(double value)=>(byte)Math.Round(Math.Clamp(value,0,255));
}
