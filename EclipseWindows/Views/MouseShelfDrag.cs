using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace Eclipse.Windows.Views;

// Mouse counterpart of Apple's horizontally pannable catalog shelves. Touch/pen stay native.
internal sealed class MouseShelfDrag
{
    private const double Threshold=8,Friction=.9975,MinimumFling=.2,StopSpeed=.02;
    private readonly ListView _host;
    private readonly Func<ScrollViewer?> _scroll;
    private readonly Queue<(ulong Time,double X)> _samples=new();
    private ScrollViewer? _glide;
    private uint? _pointer;
    private Point _start;
    private double _offset,_velocity,_glideOffset;
    private TimeSpan? _lastFrame;
    private bool _dragging;
    public bool SuppressClick {get;private set;}
    public MouseShelfDrag(ListView host,Func<ScrollViewer?>? scroll=null)
    {
        _host=host;_scroll=scroll??(()=>Find(host));
        host.AddHandler(UIElement.PointerPressedEvent,new PointerEventHandler(Pressed),true);
        host.AddHandler(UIElement.PointerMovedEvent,new PointerEventHandler(Moved),true);
        host.AddHandler(UIElement.PointerReleasedEvent,new PointerEventHandler(Released),true);
        host.AddHandler(UIElement.PointerCanceledEvent,new PointerEventHandler(Canceled),true);
        host.AddHandler(UIElement.PointerWheelChangedEvent,new PointerEventHandler((_,_)=>StopGlide()),true);
        host.AddHandler(UIElement.PointerCaptureLostEvent,new PointerEventHandler((sender,args)=>{if(ReferenceEquals(args.OriginalSource,_host))Canceled(sender,args);}),true);
        host.AddHandler(UIElement.KeyDownEvent,new KeyEventHandler((_,_)=>{StopGlide();if(!_dragging&&_pointer is null)SuppressClick=false;}),true);
        host.Unloaded+=(_,_)=>Reset();
    }
    private void Pressed(object sender,PointerRoutedEventArgs args)
    {
        Reset();SuppressClick=false;
        var point=args.GetCurrentPoint(_host);
        if(args.Pointer.PointerDeviceType!=Microsoft.UI.Input.PointerDeviceType.Mouse||!point.Properties.IsLeftButtonPressed||Interactive(args.OriginalSource as DependencyObject)||_scroll() is not{ScrollableWidth:>0} scroll)return;
        _pointer=args.Pointer.PointerId;_start=point.Position;_offset=scroll.HorizontalOffset;
    }
    private bool Interactive(DependencyObject? node)
    {
        for(;node is not null&&!ReferenceEquals(node,_host);node=VisualTreeHelper.GetParent(node))
            if(node is ScrollBar or Thumb or ButtonBase or TextBox or ComboBox)return true;
        return false;
    }
    private void Moved(object sender,PointerRoutedEventArgs args)
    {
        if(_pointer!=args.Pointer.PointerId)return;
        var point=args.GetCurrentPoint(_host);if(!point.Properties.IsLeftButtonPressed){EndDrag();return;}
        var dx=point.Position.X-_start.X;var dy=point.Position.Y-_start.Y;
        if(!_dragging)
        {
            if(Math.Abs(dy)>Threshold&&Math.Abs(dy)>Math.Abs(dx)){EndDrag();return;}
            if(Math.Abs(dx)<Threshold||Math.Abs(dx)<Math.Abs(dy)*1.2)return;
            _dragging=true;SuppressClick=true;_samples.Clear();
            // Capture only after horizontal intent, so an ordinary press still clicks its title.
            if(!_host.CapturePointer(args.Pointer)){EndDrag();return;}
        }
        _samples.Enqueue((point.Timestamp,point.Position.X));
        while(_samples.Count>2&&point.Timestamp-_samples.Peek().Time>100_000)_samples.Dequeue();
        if(_scroll() is{} scroll)scroll.ChangeView(Math.Clamp(_offset-dx,0,scroll.ScrollableWidth),null,null,true);
        args.Handled=true;
    }
    private void Released(object sender,PointerRoutedEventArgs args)
    {
        if(_pointer!=args.Pointer.PointerId)return;
        if(_dragging)
        {
            args.Handled=true;
            var now=args.GetCurrentPoint(_host).Timestamp;
            if(_samples.Count>=2&&now-_samples.Last().Time<60_000&&_scroll() is{} scroll)
            {
                var (firstTime,firstX)=_samples.Peek();var (lastTime,lastX)=_samples.Last();
                var elapsed=(lastTime-firstTime)/1000.0;
                if(elapsed>0)StartGlide(scroll,(lastX-firstX)/elapsed);
            }
        }
        EndDrag();
    }
    private void Canceled(object sender,PointerRoutedEventArgs args)
    {if(_pointer==args.Pointer.PointerId)EndDrag();}
    private void StartGlide(ScrollViewer target,double velocity)
    {
        if(Math.Abs(velocity)<MinimumFling)return;
        _glide=target;_velocity=velocity;_glideOffset=target.HorizontalOffset;_lastFrame=null;
        CompositionTarget.Rendering+=Glide_Rendering;
    }
    private void Glide_Rendering(object? sender,object args)
    {
        if(_glide is not{} target||!target.IsLoaded){StopGlide();return;}
        var time=((RenderingEventArgs)args).RenderingTime;
        var elapsed=_lastFrame is{} last?Math.Clamp((time-last).TotalMilliseconds,0,50):0;_lastFrame=time;
        if(elapsed==0)return;
        var decay=Math.Pow(Friction,elapsed);
        _glideOffset-=_velocity*(1-decay)/-Math.Log(Friction);_velocity*=decay;
        var offset=Math.Clamp(_glideOffset,0,target.ScrollableWidth);
        target.ChangeView(offset,null,null,true);
        if(Math.Abs(_velocity)<StopSpeed||offset!=_glideOffset)StopGlide();
    }
    private void StopGlide()
    {
        if(_glide is null)return;
        CompositionTarget.Rendering-=Glide_Rendering;_glide=null;
    }
    public void Reset(){EndDrag();StopGlide();}
    private void EndDrag()
    {
        var release=_dragging;_pointer=null;_dragging=false;_samples.Clear();
        if(release)_host.ReleasePointerCaptures();
        // Kept through PointerReleased/ItemClick ordering; next press or keyboard input clears it.
    }
    private static ScrollViewer? Find(DependencyObject root)
    {for(var i=0;i<VisualTreeHelper.GetChildrenCount(root);i++){var child=VisualTreeHelper.GetChild(root,i);if(child is ScrollViewer scroll)return scroll;if(Find(child) is{} found)return found;}return null;}
}
