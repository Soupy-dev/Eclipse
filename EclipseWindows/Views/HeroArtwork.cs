using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.UI;

namespace Eclipse.Windows.Views;

// Hero artwork that dissolves into the page, the composition counterpart of Apple's hero blend
// and AtmosphereBleedLayer: the image fades out over its lower half while its bottom-edge colours
// bleed a short distance further down. The host element extends Tail below the banner.
internal sealed class HeroArtwork
{
    public const double Tail=200;
    private readonly FrameworkElement _host;
    private readonly SpriteVisual _art,_bleed;
    private readonly CompositionSurfaceBrush _artSurface,_edgeSurface;
    private readonly CompositionColorGradientStop[] _bleedStops;
    private LoadedImageSurface? _image,_edge;
    private int _edgeRows=1;
    public bool IsSettled {get;private set;}
    public event EventHandler? Settled;

    public HeroArtwork(FrameworkElement host)
    {
        _host=host;var compositor=CompositionTarget.GetCompositorForCurrentThread();
        _artSurface=compositor.CreateSurfaceBrush();_artSurface.Stretch=CompositionStretch.UniformToFill;
        _art=compositor.CreateSpriteVisual();_art.Brush=Masked(compositor,_artSurface,VerticalFade(compositor,.55f));
        // An 8-pixel-wide decode of the backdrop, upscaled with linear filtering, is a soft colour field; showing
        // only its last rows stretched downward continues the image's bottom edge without a blur pass.
        _edgeSurface=compositor.CreateSurfaceBrush();_edgeSurface.Stretch=CompositionStretch.Fill;_edgeSurface.BitmapInterpolationMode=CompositionBitmapInterpolationMode.Linear;
        var bleedMask=compositor.CreateLinearGradientBrush();bleedMask.StartPoint=new(0,0);bleedMask.EndPoint=new(0,1);
        _bleedStops=[Stop(compositor,0,0),Stop(compositor,.4f,1),Stop(compositor,.7f,.45f),Stop(compositor,1,0)];
        foreach(var stop in _bleedStops)bleedMask.ColorStops.Add(stop);
        _bleed=compositor.CreateSpriteVisual();_bleed.Brush=Masked(compositor,_edgeSurface,bleedMask);
        var root=compositor.CreateContainerVisual();root.Children.InsertAtTop(_bleed);root.Children.InsertAtTop(_art);
        ElementCompositionPreview.SetElementChildVisual(host,root);
        SetTheme(false);host.SizeChanged+=(_,_)=>Layout();
    }

    public void SetTheme(bool light)=>_bleed.Opacity=light?.3f:.5f;

    public void Load(Uri? artwork,Uri? edge,double decodeWidth)
    {
        Release();
        if(artwork is null){IsSettled=true;Settled?.Invoke(this,EventArgs.Empty);return;}
        _image=LoadedImageSurface.StartLoadFromUri(artwork,new Size(decodeWidth,decodeWidth*9/16));
        _image.LoadCompleted+=Image_LoadCompleted;_artSurface.Surface=_image;
        if(edge is null)return;
        _edge=LoadedImageSurface.StartLoadFromUri(edge,new Size(8,5));
        _edge.LoadCompleted+=Edge_LoadCompleted;_edgeSurface.Surface=_edge;
    }

    public void Release()
    {
        IsSettled=false;_artSurface.Surface=_edgeSurface.Surface=null;
        if(_image is not null){_image.LoadCompleted-=Image_LoadCompleted;_image.Dispose();_image=null;}
        if(_edge is not null){_edge.LoadCompleted-=Edge_LoadCompleted;_edge.Dispose();_edge=null;}
    }

    private void Image_LoadCompleted(LoadedImageSurface sender,LoadedImageSourceLoadCompletedEventArgs args)
    {if(ReferenceEquals(sender,_image)){IsSettled=true;Settled?.Invoke(this,EventArgs.Empty);}}

    private void Edge_LoadCompleted(LoadedImageSurface sender,LoadedImageSourceLoadCompletedEventArgs args)
    {if(ReferenceEquals(sender,_edge)&&args.Status==LoadedImageSourceLoadStatus.Success){_edgeRows=Math.Max(1,(int)sender.DecodedPhysicalSize.Height);Layout();}}

    private void Layout()
    {
        var width=(float)_host.ActualWidth;var total=(float)_host.ActualHeight;var height=Math.Max(1,total-(float)Tail);
        _art.Size=new(width,height);
        var top=height*.5f;var bleedHeight=Math.Max(1,total-top);var edge=(height-top)/bleedHeight;
        _bleed.Offset=new(0,top,0);_bleed.Size=new(width,bleedHeight);
        _bleedStops[1].Offset=edge;_bleedStops[2].Offset=edge+(1-edge)*.4f;
        // Stretch the bottom one and a half source rows over the whole bleed.
        _edgeSurface.CenterPoint=new(0,bleedHeight);_edgeSurface.Scale=new(1,_edgeRows/1.5f);
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
    private static CompositionColorGradientStop Stop(Compositor compositor,float offset,float alpha)=>compositor.CreateColorGradientStop(offset,Color.FromArgb((byte)(alpha*255),255,255,255));
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
