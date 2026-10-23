using System.Numerics;
using Microsoft.UI;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;
using Windows.UI;

namespace Eclipse.Windows.Views;

// Hero artwork that dissolves into the page, the composition counterpart of Apple's hero blend
// and HeroBannerBleed: the image fades out over its lower half into a wash of its ambient colour,
// which holds behind the banner and trails off Tail px further down. The host element extends Tail
// below the banner; pages size Tail from the banner height as Apple does (TailRatio).
internal sealed class HeroArtwork
{
    public const double TailRatio=.62;
    private static readonly (float Offset,float Alpha)[] BleedCurve=[(.28f,.6f),(.52f,.3f),(.78f,.09f)];
    private readonly FrameworkElement _host;
    private readonly SpriteVisual _art,_bleed;
    private readonly CompositionSurfaceBrush _artSurface;
    private readonly CompositionColorGradientStop[] _bleedStops;
    private LoadedImageSurface? _image;
    private CancellationTokenSource? _tone;
    private Color? _color;
    private bool _light,_artLoaded,_toneLoaded;
    private double _tail;
    public bool IsSettled {get;private set;}
    public event EventHandler? Settled;

    public HeroArtwork(FrameworkElement host)
    {
        _host=host;var compositor=CompositionTarget.GetCompositorForCurrentThread();
        _artSurface=compositor.CreateSurfaceBrush();_artSurface.Stretch=CompositionStretch.UniformToFill;_artSurface.VerticalAlignmentRatio=.25f;
        _art=compositor.CreateSpriteVisual();_art.Brush=Masked(compositor,_artSurface,VerticalFade(compositor,.55f));
        var bleed=compositor.CreateLinearGradientBrush();bleed.StartPoint=new(0,0);bleed.EndPoint=new(0,1);
        _bleedStops=[..Enumerable.Range(0,BleedCurve.Length+3).Select(_=>compositor.CreateColorGradientStop())];
        _bleedStops[^1].Offset=1;foreach(var stop in _bleedStops)bleed.ColorStops.Add(stop);
        _bleed=compositor.CreateSpriteVisual();_bleed.Brush=bleed;_bleed.Opacity=0;
        var fade=compositor.CreateScalarKeyFrameAnimation();fade.Target="Opacity";fade.InsertExpressionKeyFrame(1,"this.FinalValue");fade.Duration=TimeSpan.FromMilliseconds(320);
        _bleed.ImplicitAnimations=compositor.CreateImplicitAnimationCollection();_bleed.ImplicitAnimations["Opacity"]=fade;
        var root=compositor.CreateContainerVisual();root.Children.InsertAtTop(_bleed);root.Children.InsertAtTop(_art);
        ElementCompositionPreview.SetElementChildVisual(host,root);
        host.SizeChanged+=(_,_)=>Layout();
    }

    public double Tail{get=>_tail;set{if(_tail==value)return;_tail=value;Layout();}}

    public void SetTheme(bool light){_light=light;ApplyBleed();}

    public void Load(Uri? artwork,Uri? tone,double decodeWidth)
    {
        Release();
        _toneLoaded=tone is null;
        if(tone is not null){_tone=new();LoadTone(tone,_tone.Token);}
        if(artwork is null){_artLoaded=true;Settle();return;}
        _image=LoadedImageSurface.StartLoadFromUri(artwork,new Size(decodeWidth,decodeWidth*9/16));
        _image.LoadCompleted+=Image_LoadCompleted;_artSurface.Surface=_image;
    }

    public void Release()
    {
        IsSettled=_artLoaded=_toneLoaded=false;_artSurface.Surface=null;
        _tone?.Cancel();_tone?.Dispose();_tone=null;_color=null;ApplyBleed();
        if(_image is not null){_image.LoadCompleted-=Image_LoadCompleted;_image.Dispose();_image=null;}
    }

    private void Image_LoadCompleted(LoadedImageSurface sender,LoadedImageSourceLoadCompletedEventArgs args)
    {if(ReferenceEquals(sender,_image)){_artLoaded=true;Settle();}}

    private void Settle()
    {if(_artLoaded&&_toneLoaded&&!IsSettled){IsSettled=true;Settled?.Invoke(this,EventArgs.Empty);}}

    private async void LoadTone(Uri uri,CancellationToken token)
    {
        Color? color=null;
        try
        {
            using var stream=await RandomAccessStreamReference.CreateFromUri(uri).OpenReadAsync().AsTask(token);
            if(stream.Size is >0 and <=4*1024*1024)color=await AmbientColorAsync(await BitmapDecoder.CreateAsync(stream).AsTask(token),token);
        }
        catch(OperationCanceledException) when(token.IsCancellationRequested){return;}
        catch(Exception){}
        if(token.IsCancellationRequested)return;
        _color=color;_toneLoaded=true;ApplyBleed();Settle();
    }

    private static async Task<Color?> AmbientColorAsync(BitmapDecoder decoder,CancellationToken token)
    {
        var scale=64.0/Math.Max(1,Math.Min(decoder.PixelWidth,decoder.PixelHeight));
        var width=(int)Math.Max(1,Math.Round(decoder.PixelWidth*scale));var height=(int)Math.Max(1,Math.Round(decoder.PixelHeight*scale));
        var transform=new BitmapTransform{InterpolationMode=BitmapInterpolationMode.Fant,ScaledWidth=(uint)width,ScaledHeight=(uint)height};
        var pixels=(await decoder.GetPixelDataAsync(BitmapPixelFormat.Rgba8,BitmapAlphaMode.Straight,transform,ExifOrientationMode.IgnoreExifOrientation,ColorManagementMode.DoNotColorManage).AsTask(token)).DetachPixelData();
        double red=0,green=0,blue=0,total=0;double centerX=width/2.0,centerY=height/2.0;var reach=Math.Sqrt(centerX*centerX+centerY*centerY);
        for(var y=0;y<height;y++)for(var x=0;x<width;x++)
        {
            var i=(y*width+x)*4;double r=pixels[i]/255.0,g=pixels[i+1]/255.0,b=pixels[i+2]/255.0,a=pixels[i+3]/255.0;
            if(a<=.1||r+g+b<=.15)continue;
            var high=Math.Max(r,Math.Max(g,b));var saturation=high>0?(high-Math.Min(r,Math.Min(g,b)))/high:0;
            var row=(double)y/height;var weight=(1-Math.Sqrt((x-centerX)*(x-centerX)+(y-centerY)*(y-centerY))/reach*.3)*(1-Math.Abs(r*.2126+g*.7152+b*.0722-.5)*.4)*(.5+saturation*.5)*a*(.3+.7*row*row);
            red+=r*weight;green+=g*weight;blue+=b*weight;total+=weight;
        }
        if(total<=0)return null;
        red/=total;green/=total;blue/=total;
        var max=Math.Max(red,Math.Max(green,blue));var min=Math.Min(red,Math.Min(green,blue));var s=max>0?(max-min)/max:0;
        var stretch=s>0?Math.Min(s*1.2,1)/s:1;
        byte Channel(double value)=>(byte)Math.Round(Math.Clamp((max-(max-value)*stretch)*.7,0,1)*255);
        return max*.7<.06?null:Color.FromArgb(255,Channel(red),Channel(green),Channel(blue));
    }

    private void ApplyBleed()
    {
        if(_color is not {} color){_bleed.Opacity=0;return;}
        var strength=_light?.35f:.55f;
        _bleedStops[0].Color=_bleedStops[1].Color=Tint(color,strength);_bleedStops[^1].Color=Tint(color,0);
        for(var i=0;i<BleedCurve.Length;i++)_bleedStops[i+2].Color=Tint(color,BleedCurve[i].Alpha*strength);
        _bleed.Opacity=1;
    }

    private void Layout()
    {
        var width=(float)_host.ActualWidth;var total=Math.Max(1,(float)_host.ActualHeight);var height=Math.Max(1,total-(float)_tail);
        _art.Size=new(width,height);_bleed.Size=new(width,total);
        var hold=Math.Min(height/total,.98f);_bleedStops[1].Offset=hold;
        for(var i=0;i<BleedCurve.Length;i++)_bleedStops[i+2].Offset=hold+(1-hold)*BleedCurve[i].Offset;
    }

    internal static CompositionLinearGradientBrush VerticalFade(Compositor compositor,float solidUntil)
    {
        var brush=compositor.CreateLinearGradientBrush();brush.StartPoint=new(0,0);brush.EndPoint=new(0,1);
        brush.ColorStops.Add(Stop(compositor,0,1));brush.ColorStops.Add(Stop(compositor,solidUntil,1));
        brush.ColorStops.Add(Stop(compositor,solidUntil+(1-solidUntil)*.55f,.45f));brush.ColorStops.Add(Stop(compositor,1,0));
        return brush;
    }
    internal static CompositionMaskBrush Masked(Compositor compositor,CompositionBrush source,CompositionBrush mask)
    {var brush=compositor.CreateMaskBrush();brush.Source=source;brush.Mask=mask;return brush;}
    private static CompositionColorGradientStop Stop(Compositor compositor,float offset,float alpha)=>compositor.CreateColorGradientStop(offset,Tint(Colors.White,alpha));
    private static Color Tint(Color color,float alpha)=>Color.FromArgb((byte)Math.Round(alpha*255),color.R,color.G,color.B);
}

// The left-to-right legibility shade behind hero copy, faded out with the artwork so it never
// leaves a hard edge where the banner meets the page.
internal sealed class HeroShade
{
    private readonly SpriteVisual _shade;
    private bool? _light;

    public HeroShade(FrameworkElement host)
    {
        _shade=CompositionTarget.GetCompositorForCurrentThread().CreateSpriteVisual();
        ElementCompositionPreview.SetElementChildVisual(host,_shade);
        host.SizeChanged+=(_,_)=>_shade.Size=new((float)host.ActualWidth,(float)host.ActualHeight);
        SetTheme(false);
    }

    // Light pages keep the shade under the copy longer, because the hero text stays white.
    public void SetTheme(bool light)
    {
        if(_light==light)return;_light=light;
        var compositor=_shade.Compositor;var source=compositor.CreateLinearGradientBrush();source.StartPoint=new(0,.5f);source.EndPoint=new(1,.5f);
        foreach(var (offset,alpha) in new[]{(0f,0xF0),(.42f,0xC0),(1f,0x10)})source.ColorStops.Add(compositor.CreateColorGradientStop(offset,Color.FromArgb((byte)alpha,0x11,0x10,0x1A)));
        _shade.Brush=HeroArtwork.Masked(compositor,source,HeroArtwork.VerticalFade(compositor,light?.86f:.55f));
    }
}
