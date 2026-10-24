using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace Eclipse.Windows.Views;

internal sealed class MouseDragScroll
{
    private const double Threshold=8,Friction=.9975,MinimumFling=.2,StopSpeed=.02;
    private readonly UIElement _root;
    private readonly Queue<(ulong Time,double Y)> _samples=new();
    private ScrollViewer? _target,_glide;
    private uint? _pointer;
    private Point _start;
    private double _startY,_offset,_velocity,_glideOffset;
    private TimeSpan? _lastFrame;
    private bool _dragging;

    public MouseDragScroll(UIElement root)
    {
        _root=root;
        root.AddHandler(UIElement.PointerPressedEvent,new PointerEventHandler(Pressed),true);
        root.AddHandler(UIElement.PointerMovedEvent,new PointerEventHandler(Moved),true);
        root.AddHandler(UIElement.PointerReleasedEvent,new PointerEventHandler(Released),true);
        root.AddHandler(UIElement.PointerWheelChangedEvent,new PointerEventHandler((_,_)=>StopGlide()),true);
        root.AddHandler(UIElement.PointerCanceledEvent,new PointerEventHandler((_,args)=>{if(_pointer==args.Pointer.PointerId)Reset();}),true);
        root.AddHandler(UIElement.PointerCaptureLostEvent,new PointerEventHandler((_,args)=>{if(_dragging&&ReferenceEquals(args.OriginalSource,_target))Reset();}),true);
    }

    private void Pressed(object sender,PointerRoutedEventArgs args)
    {
        StopGlide();Reset();
        var point=args.GetCurrentPoint(_root);
        if(args.Pointer.PointerDeviceType!=PointerDeviceType.Mouse||!point.Properties.IsLeftButtonPressed||Target(args.OriginalSource as DependencyObject) is not{} target)return;
        _target=target;_pointer=args.Pointer.PointerId;_start=point.Position;_startY=args.GetCurrentPoint(target).Position.Y;_offset=target.VerticalOffset;
    }

    private static ScrollViewer? Target(DependencyObject? node)
    {
        for(;node is not null;node=VisualTreeHelper.GetParent(node))
            switch(node)
            {
                case RangeBase or Thumb or TextBox or PasswordBox or RichEditBox or AutoSuggestBox or ComboBox or ToggleSwitch or ColorPicker or ColorSpectrum:
                case TextBlock{IsTextSelectionEnabled:true} or RichTextBlock{IsTextSelectionEnabled:true}:
                case ListViewBase{CanReorderItems:true} or ListViewBase{CanDragItems:true} or UIElement{CanDrag:true}:
                case SelectorItem item when ItemsControl.ItemsControlFromItemContainer(item) is ListViewBase{CanReorderItems:true} or ListViewBase{CanDragItems:true}:
                    return null;
                case ScrollViewer scroll when scroll.VerticalScrollMode!=ScrollMode.Disabled&&scroll.VerticalScrollBarVisibility!=ScrollBarVisibility.Disabled&&scroll.ScrollableHeight>0:
                    return scroll;
            }
        return null;
    }

    private void Moved(object sender,PointerRoutedEventArgs args)
    {
        if(_pointer!=args.Pointer.PointerId||_target is not{} target)return;
        var point=args.GetCurrentPoint(_root);if(!point.Properties.IsLeftButtonPressed){Reset();return;}
        var dx=point.Position.X-_start.X;var dy=point.Position.Y-_start.Y;
        if(!_dragging)
        {
            if(Math.Abs(dx)>Threshold&&Math.Abs(dx)>=Math.Abs(dy)){Reset();return;}
            if(Math.Abs(dy)<=Threshold||Math.Abs(dy)<=Math.Abs(dx))return;
            for(var node=args.OriginalSource as DependencyObject;node is not null&&!ReferenceEquals(node,target);node=VisualTreeHelper.GetParent(node))
                if(node is UIElement holder&&holder.PointerCaptures?.Any(p=>p.PointerId==args.Pointer.PointerId)==true){holder.ReleasePointerCapture(args.Pointer);break;}
            target.CapturePointer(args.Pointer);
            _dragging=true;_samples.Clear();
        }
        var y=args.GetCurrentPoint(target).Position.Y;
        _samples.Enqueue((point.Timestamp,y));
        while(_samples.Count>2&&point.Timestamp-_samples.Peek().Time>100_000)_samples.Dequeue();
        target.ChangeView(null,Math.Clamp(_offset-(y-_startY),0,target.ScrollableHeight),null,true);
        args.Handled=true;
    }

    private void Released(object sender,PointerRoutedEventArgs args)
    {
        if(_pointer!=args.Pointer.PointerId)return;
        if(_dragging&&_target is{} target)
        {
            args.Handled=true;
            var now=args.GetCurrentPoint(_root).Timestamp;
            if(_samples.Count>=2&&now-_samples.Last().Time<60_000)
            {
                var (firstTime,firstY)=_samples.Peek();var (lastTime,lastY)=_samples.Last();
                var elapsed=(lastTime-firstTime)/1000.0;
                if(elapsed>0)StartGlide(target,(lastY-firstY)/elapsed);
            }
        }
        Reset();
    }

    private void StartGlide(ScrollViewer target,double velocity)
    {
        if(Math.Abs(velocity)<MinimumFling)return;
        _glide=target;_velocity=velocity;_glideOffset=target.VerticalOffset;_lastFrame=null;
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
        var offset=Math.Clamp(_glideOffset,0,target.ScrollableHeight);
        target.ChangeView(null,offset,null,true);
        if(Math.Abs(_velocity)<StopSpeed||offset!=_glideOffset)StopGlide();
    }

    private void StopGlide()
    {
        if(_glide is null)return;
        CompositionTarget.Rendering-=Glide_Rendering;_glide=null;
    }

    private void Reset()
    {
        var target=_target;var release=_dragging;
        _pointer=null;_target=null;_dragging=false;_samples.Clear();
        if(release)target?.ReleasePointerCaptures();
    }
}
