using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Eclipse.Windows.Views;

// Windows counterpart of Apple's low-quality EclipseAmbientMotionBackground: counter-rotating
// eclipse rings, orbiting glints and drifting particles. Like Apple's TimelineView with a minimum
// interval, shapes are posed only at the chosen frame rate rather than at display refresh. Poses
// land on rendering ticks so their spacing stays even; pausing unhooks the tick and holds the pose.
internal sealed class AmbientBackdrop
{
    private static readonly (float X,float Y,float Size,float Drift,float Opacity)[] Particles=
    [(.25f,.24f,2.8f,15,.34f),(.75f,.25f,3.2f,-15,.38f),(.39f,.42f,2.4f,12,.30f),(.63f,.50f,2.7f,-12,.30f),(.25f,.70f,3.0f,14,.32f),
     (.76f,.70f,2.8f,-14,.32f),(.47f,.18f,2.2f,11,.28f),(.53f,.84f,3.0f,-11,.28f),(.36f,.60f,1.9f,10,.24f),(.66f,.34f,2.1f,-10,.24f)];
    private readonly FrameworkElement _host;
    private readonly Compositor _compositor;
    private readonly System.Diagnostics.Stopwatch _clock=new();
    private readonly List<IDisposable> _owned=[];
    private readonly List<Action<double>> _motion=[];
    private readonly List<(CompositionEllipseGeometry Geometry,bool Large,float Factor)> _rings=[];
    private readonly List<(CompositionShape Shape,float Angle)> _glints=[];
    private readonly List<(CompositionShape Shape,float X,float Y)> _particles=[];
    private ContainerVisual? _root;
    private ShapeVisual? _visual;
    private SpriteVisual? _cover;
    private CompositionLinearGradientBrush? _coverMask;
    private CompositionContainerShape? _center;
    private string _signature="";
    private bool _requested,_ticking;
    private double _fps=30,_clearance;
    private long _frame=-1;

    public AmbientBackdrop(FrameworkElement host)
    {
        _host=host;_compositor=CompositionTarget.GetCompositorForCurrentThread();
        host.SizeChanged+=(_,_)=>Layout();
    }

    public void Update(bool enabled,Color accent,Color secondary,bool light,(Color Color,float Offset)[] page)
    {
        var signature=enabled?$"{accent}:{secondary}:{light}:{string.Join(',',page)}":"";
        if(signature==_signature)return;
        _signature=signature;Clear();
        if(enabled){Build(accent,secondary,light);BuildCover(page);Layout();Pose(_clock.Elapsed.TotalSeconds);}
        Refresh();
    }

    public void SetRunning(bool running){_requested=running;Refresh();}
    public void SetFrameRate(int framesPerSecond)=>_fps=Math.Clamp(framesPerSecond,1,240);

    // Home keeps the motion out from behind its hero and bleed: everything above y is covered by the
    // page atmosphere, fading in just below. Fully covered motion stops posing.
    public void SetClearance(double y){_clearance=Math.Max(0,y);ApplyClearance();Refresh();}

    private bool Covered=>_clearance-40>=_host.ActualHeight;
    private void Refresh()
    {
        var tick=_requested&&_visual is not null&&!Covered;
        if(tick==_ticking)return;_ticking=tick;
        if(tick){_clock.Start();_frame=-1;CompositionTarget.Rendering+=Rendering;}else{CompositionTarget.Rendering-=Rendering;_clock.Stop();}
    }

    private void Rendering(object? sender,object args)
    {
        if(args is not RenderingEventArgs rendering)return;
        var frame=(long)(rendering.RenderingTime.TotalSeconds*_fps);
        if(frame==_frame)return;_frame=frame;
        Pose(_clock.Elapsed.TotalSeconds);
    }

    private void Pose(double seconds){foreach(var step in _motion)step(seconds);}

    private void BuildCover((Color Color,float Offset)[] page)
    {
        CompositionBrush atmosphere;
        if(page.Length==1)atmosphere=Own(_compositor.CreateColorBrush(page[0].Color));
        else
        {
            var gradient=Own(_compositor.CreateLinearGradientBrush());gradient.StartPoint=new(0,0);gradient.EndPoint=new(1,1);
            foreach(var (color,offset) in page)gradient.ColorStops.Add(Own(_compositor.CreateColorGradientStop(offset,color)));
            atmosphere=gradient;
        }
        _coverMask=Own(_compositor.CreateLinearGradientBrush());_coverMask.MappingMode=CompositionMappingMode.Absolute;
        _coverMask.ColorStops.Add(Own(_compositor.CreateColorGradientStop(0,Color.FromArgb(255,255,255,255))));
        _coverMask.ColorStops.Add(Own(_compositor.CreateColorGradientStop(1,Color.FromArgb(0,255,255,255))));
        var mask=Own(_compositor.CreateMaskBrush());mask.Source=atmosphere;mask.Mask=_coverMask;
        _cover=Own(_compositor.CreateSpriteVisual());_cover.Brush=mask;_root!.Children.InsertAtTop(_cover);
    }

    private void ApplyClearance()
    {
        if(_cover is null||_coverMask is null)return;
        var start=(float)_clearance-40;var end=start+140;
        _cover.IsVisible=end>0;_coverMask.StartPoint=new(0,start);_coverMask.EndPoint=new(0,end);
    }

    private void Build(Color accent,Color secondary,Color ink,float alpha,float dx,float dy)
    {
        _root=Own(_compositor.CreateContainerVisual());
        _visual=Own(_compositor.CreateShapeVisual());_root.Children.InsertAtTop(_visual);
        _center=Own(_compositor.CreateContainerShape());_visual.Shapes.Add(_center);

        // Apple blurs this breathing stroke; two soft strokes approximate it without an effect pass.
        var halo=Group(_center);Breathe(halo,new(.94f),new(1.06f),9.6);
        Ring(halo,true,.39f,0,360,Brush(accent,.03f*alpha),12);
        Ring(halo,true,.39f,0,360,Pulse(accent,.06f*alpha,.13f*alpha,9.6),5);

        var large=Group(_center);
        Sway(large,new(-dx,dy),new(dx,-dy),19);Spin(large,-18,360,28);Breathe(large,new(.992f),new(1.018f),9.6);
        Ring(large,true,.5f,18,128,Brush(accent,.30f*alpha),1.45f);
        Ring(large,true,.5f,128,228,Brush(secondary,.22f*alpha),1.45f);
        Ring(large,true,.5f,228,292,Brush(ink,.16f*alpha),1.45f);
        var glow=Pulse(accent,.18f*alpha,.26f*alpha,9.6);var core=Pulse(ink,.30f*alpha,.46f*alpha,9.6);
        foreach(var angle in new[]{18f,146f,274f})
        {
            var glint=Group(large);_glints.Add((glint,angle));Breathe(glint,new(1),new(1.35f),9.6);
            Dot(glint,10.3f,glow);Dot(glint,4.7f,core);
        }

        var small=Group(_center);
        Sway(small,new(dx,-dy),new(-dx,dy),19);Spin(small,14,-360,36);Breathe(small,new(1.02f),new(.98f),9.6);
        Ring(small,false,.5f,29,259,Brush(secondary,.28f*alpha),1.6f);
        Ring(small,false,.5f,132,224,Brush(accent,.20f*alpha),1.6f);

        var accentLarge=Group(_center);
        Sway(accentLarge,new(-dx*.6f,dy*.6f),new(dx*.6f,-dy*.6f),19);Spin(accentLarge,-18,360,28);
        Ring(accentLarge,true,.45f,79,130,Pulse(secondary,.58f*alpha,.86f*alpha,9.6),2.4f);
        var accentSmall=Group(_center);
        Sway(accentSmall,new(dx*.8f,-dy*.8f),new(-dx*.8f,dy*.8f),19);Spin(accentSmall,14,-360,36);
        Ring(accentSmall,false,.58f,160,210,Pulse(accent,.48f*alpha,.74f*alpha,9.6),2.1f);

        var particle=Blend(accent,ink,.42f);
        foreach(var p in Particles)
        {
            var holder=Own(_compositor.CreateContainerShape());_visual.Shapes.Add(holder);_particles.Add((holder,p.X,p.Y));
            var dot=Dot(holder,p.Size,Brush(particle,Math.Min(1,p.Opacity*1.3f)*alpha));
            Sway(dot,new(-p.Drift,12),new(p.Drift,-12),19);Breathe(dot,new(1),new(1.25f),9.6);
        }
        ElementCompositionPreview.SetElementChildVisual(_host,_root);
    }

    private void Build(Color accent,Color secondary,bool light)
    {
        // Apple screen-blends this layer over a dark atmosphere; on light surfaces it is drawn
        // in a deep ink instead so the rings stay visible without washing the page out.
        var ink=light?Color.FromArgb(255,58,40,92):Color.FromArgb(255,255,255,255);
        var width=(float)Math.Max(_host.ActualWidth,1);var height=(float)Math.Max(_host.ActualHeight,1);
        // Slightly below Apple's strengths: Windows pages put more text directly over this layer.
        Build(accent,secondary,ink,light?.6f:.85f,Math.Clamp(width*.018f,8,28),Math.Clamp(height*.012f,6,16));
    }

    private void Layout()
    {
        if(_visual is null||_center is null)return;
        var width=(float)Math.Max(_host.ActualWidth,1);var height=(float)Math.Max(_host.ActualHeight,1);
        var shortSide=Math.Min(width,height);var longSide=Math.Max(width,height);
        var large=Math.Min(Math.Max(shortSide*1.05f,340),Math.Min(longSide*.96f,760));
        var small=Math.Min(Math.Max(shortSide*.78f,260),Math.Min(longSide*.74f,560));
        _visual.Size=new(width,height);_center.Offset=new(width/2,height/2);
        if(_cover is not null)_cover.Size=new(width,height);
        ApplyClearance();Refresh();
        foreach(var (geometry,isLarge,factor) in _rings)geometry.Radius=new((isLarge?large:small)*factor);
        foreach(var (shape,angle) in _glints)
        {var radians=angle*MathF.PI/180;shape.Offset=new(MathF.Cos(radians)*large*.42f,MathF.Sin(radians)*large*.42f);}
        foreach(var (shape,x,y) in _particles)shape.Offset=new(width*x,height*y);
    }

    private void Clear()
    {
        CompositionTarget.Rendering-=Rendering;_ticking=false;_clock.Stop();
        if(_root is not null)ElementCompositionPreview.SetElementChildVisual(_host,null);
        foreach(var item in _owned)item.Dispose();
        _owned.Clear();_motion.Clear();_rings.Clear();_glints.Clear();_particles.Clear();_root=null;_visual=null;_cover=null;_coverMask=null;_center=null;
    }

    private void Ring(CompositionContainerShape parent,bool large,float factor,float start,float end,CompositionBrush brush,float thickness)
    {
        var geometry=Own(_compositor.CreateEllipseGeometry());geometry.TrimStart=start/360;geometry.TrimEnd=end/360;
        var shape=Own(_compositor.CreateSpriteShape(geometry));shape.StrokeBrush=brush;shape.StrokeThickness=thickness;
        shape.StrokeStartCap=shape.StrokeEndCap=CompositionStrokeCap.Round;
        parent.Shapes.Add(shape);_rings.Add((geometry,large,factor));
    }

    private CompositionSpriteShape Dot(CompositionContainerShape parent,float diameter,CompositionBrush brush)
    {
        var geometry=Own(_compositor.CreateEllipseGeometry());geometry.Radius=new(diameter/2);
        var shape=Own(_compositor.CreateSpriteShape(geometry));shape.FillBrush=brush;parent.Shapes.Add(shape);
        return shape;
    }

    private CompositionContainerShape Group(CompositionContainerShape parent)
    {var group=Own(_compositor.CreateContainerShape());parent.Shapes.Add(group);return group;}

    private CompositionColorBrush Brush(Color color,float opacity)=>Own(_compositor.CreateColorBrush(WithAlpha(color,opacity)));

    private CompositionColorBrush Pulse(Color color,float low,float high,double seconds)
    {
        var brush=Brush(color,low);
        _motion.Add(t=>brush.Color=WithAlpha(color,low+(high-low)*Wave(t,seconds)));return brush;
    }

    // Apple's wave(seconds:period:): a sine eased between two poses.
    private static float Wave(double seconds,double period)=>(float)((Math.Sin(seconds/period%1*2*Math.PI)+1)/2);
    private void Sway(CompositionShape target,Vector2 from,Vector2 to,double period)=>_motion.Add(t=>target.Offset=Vector2.Lerp(from,to,Wave(t,period)));
    private void Breathe(CompositionShape target,Vector2 from,Vector2 to,double period)=>_motion.Add(t=>target.Scale=Vector2.Lerp(from,to,Wave(t,period)));
    private void Spin(CompositionShape target,float start,float degrees,double period)=>_motion.Add(t=>target.RotationAngleInDegrees=start+degrees*(float)(t/period%1));

    private T Own<T>(T value) where T:IDisposable {_owned.Add(value);return value;}
    private static Color WithAlpha(Color color,float opacity)=>Color.FromArgb((byte)Math.Clamp(opacity*255,0,255),color.R,color.G,color.B);
    private static Color Blend(Color a,Color b,float amount)=>Color.FromArgb(255,(byte)(a.R+(b.R-a.R)*amount),(byte)(a.G+(b.G-a.G)*amount),(byte)(a.B+(b.B-a.B)*amount));
}
