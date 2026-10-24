using Eclipse.Windows.Services;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;
using Windows.UI;

namespace Eclipse.Windows.Views;

internal sealed class AtmosphereBackdrop
{
    private const int MeshSize=64;
    private static readonly float[] MeshRows=[0,.323f,.677f,1];
    private static readonly (float Offset,float Amount)[] ClassicStops=[(0,0),(.08f,.70f),(.22f,.35f),(.55f,0),(1,0)];
    private static readonly Dictionary<string,LoadedImageSurface> Surfaces=[];
    private readonly Compositor _compositor;
    private readonly ContainerVisual _root;
    private readonly SpriteVisual _sprite;
    private readonly CompositionSurfaceBrush _surface;
    private AtmosphereSpec? _spec;
    private CompositionColorBrush? _solid;
    private Color? _dominant;
    private string _signature="";
    private int _generation;
    public CompositionBrush? Brush {get;private set;}

    public AtmosphereBackdrop(FrameworkElement host)
    {
        _compositor=CompositionTarget.GetCompositorForCurrentThread();
        _surface=_compositor.CreateSurfaceBrush();_surface.Stretch=CompositionStretch.Fill;
        _root=_compositor.CreateContainerVisual();_sprite=_compositor.CreateSpriteVisual();_root.Children.InsertAtTop(_sprite);
        ElementCompositionPreview.SetElementChildVisual(host,_root);
        host.SizeChanged+=(_,_)=>_root.Size=_sprite.Size=new((float)host.ActualWidth,(float)host.ActualHeight);
    }

    public void Update(AtmosphereSpec spec)
    {
        if(spec.Signature==_signature)return;
        _signature=spec.Signature;_spec=spec;var generation=++_generation;
        if(spec.Mode=="solid")
        {
            if(_solid is null)
            {
                _solid=_compositor.CreateColorBrush(SolidColor());
                var fade=_compositor.CreateColorKeyFrameAnimation();fade.Target="Color";fade.InsertExpressionKeyFrame(1,"this.FinalValue");fade.Duration=TimeSpan.FromMilliseconds(450);
                _solid.ImplicitAnimations=_compositor.CreateImplicitAnimationCollection();_solid.ImplicitAnimations["Color"]=fade;
            }
            else _solid.Color=SolidColor();
            Brush=_solid;
        }
        else
        {
            _solid=null;Brush=_surface;
            if(spec.Mode=="classic")_=LoadSurfaceAsync($"classic:{spec.Classic}",4,256,()=>ClassicPixels(spec.Classic),generation);
            else _=LoadSurfaceAsync($"mesh:{string.Join(',',spec.Mesh)}",MeshSize,MeshSize,()=>MeshPixels(spec.Mesh),generation);
        }
        _sprite.Brush=Brush;
    }

    public void SetDominant(Color? color)
    {
        _dominant=color;
        if(_solid is not null)_solid.Color=SolidColor();
    }

    private Color SolidColor()=>_spec is{FollowsDominant:true}&&_dominant is{} dominant?dominant:_spec?.Solid??AppearanceService.Base;

    private async Task LoadSurfaceAsync(string key,int width,int height,Func<byte[]> pixels,int generation)
    {
        if(!Surfaces.TryGetValue(key,out var surface))
        {
            var stream=new InMemoryRandomAccessStream();
            var encoder=await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId,stream);
            encoder.SetPixelData(BitmapPixelFormat.Bgra8,BitmapAlphaMode.Ignore,(uint)width,(uint)height,96,96,pixels());
            await encoder.FlushAsync();stream.Seek(0);
            if(Surfaces.TryGetValue(key,out var raced)){stream.Dispose();surface=raced;}
            else
            {
                if(Surfaces.Count>=4)Surfaces.Clear();
                surface=LoadedImageSurface.StartLoadFromStream(stream);surface.LoadCompleted+=(_,_)=>stream.Dispose();Surfaces[key]=surface;
            }
        }
        if(generation==_generation)_surface.Surface=surface;
    }

    private static byte[] ClassicPixels(Color classic)
    {
        var pixels=new byte[4*256*4];
        for(var y=0;y<256;y++)
        {
            var v=y/255f;var segment=0;while(segment<ClassicStops.Length-2&&v>ClassicStops[segment+1].Offset)segment++;
            var (from,to)=(ClassicStops[segment],ClassicStops[segment+1]);var t=(v-from.Offset)/(to.Offset-from.Offset);
            var color=Blend(AppearanceService.Base,classic,from.Amount+(to.Amount-from.Amount)*t);
            for(var x=0;x<4;x++){var index=(y*4+x)*4;pixels[index]=color.B;pixels[index+1]=color.G;pixels[index+2]=color.R;pixels[index+3]=255;}
        }
        return pixels;
    }

    private static byte[] MeshPixels(Color[] mesh)
    {
        var pixels=new byte[MeshSize*MeshSize*4];
        for(var y=0;y<MeshSize;y++)
        {
            var v=y/(MeshSize-1f);var row=0;while(row<2&&v>MeshRows[row+1])row++;
            var ty=(v-MeshRows[row])/(MeshRows[row+1]-MeshRows[row]);
            for(var x=0;x<MeshSize;x++)
            {
                var u=x/(MeshSize-1f)*2;var column=Math.Min(1,(int)u);var tx=u-column;var index=(y*MeshSize+x)*4;
                for(var channel=0;channel<3;channel++)
                {
                    double Sample(int c,int r){var color=mesh[Math.Clamp(r,0,3)*3+Math.Clamp(c,0,2)];return channel==0?color.B:channel==1?color.G:color.R;}
                    double Across(int r)=>CatmullRom(Sample(column-1,r),Sample(column,r),Sample(column+1,r),Sample(column+2,r),tx);
                    pixels[index+channel]=(byte)Math.Clamp(Math.Round(CatmullRom(Across(row-1),Across(row),Across(row+1),Across(row+2),ty)),0,255);
                }
                pixels[index+3]=255;
            }
        }
        return pixels;
    }

    private static double CatmullRom(double p0,double p1,double p2,double p3,double t)=>.5*(2*p1+(p2-p0)*t+(2*p0-5*p1+4*p2-p3)*t*t+(3*p1-p0-3*p2+p3)*t*t*t);
    private static Color Blend(Color a,Color b,float amount)=>Color.FromArgb(255,(byte)Math.Round(a.R+(b.R-a.R)*amount),(byte)Math.Round(a.G+(b.G-a.G)*amount),(byte)Math.Round(a.B+(b.B-a.B)*amount));
}
