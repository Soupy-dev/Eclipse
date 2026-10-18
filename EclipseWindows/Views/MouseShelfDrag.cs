using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Devices.Input;
using Windows.Foundation;

namespace Eclipse.Windows.Views;

// Mouse counterpart of Apple's horizontally pannable catalog shelves. Touch/pen stay native.
internal sealed class MouseShelfDrag
{
    private readonly ListView _host;
    private readonly Func<ScrollViewer?> _scroll;
    private uint? _pointer;
    private Point _start;
    private double _offset;
    private bool _dragging;
    public bool SuppressClick {get;private set;}
    public MouseShelfDrag(ListView host,Func<ScrollViewer?> scroll)
    {
        _host=host;_scroll=scroll;
        host.AddHandler(UIElement.PointerPressedEvent,new PointerEventHandler(Pressed),true);
        host.AddHandler(UIElement.PointerMovedEvent,new PointerEventHandler(Moved),true);
        host.AddHandler(UIElement.PointerReleasedEvent,new PointerEventHandler(Released),true);
        host.AddHandler(UIElement.PointerCanceledEvent,new PointerEventHandler(Canceled),true);
        host.AddHandler(UIElement.PointerCaptureLostEvent,new PointerEventHandler((sender,args)=>{if(ReferenceEquals(args.OriginalSource,_host))Canceled(sender,args);}),true);
        host.AddHandler(UIElement.KeyDownEvent,new KeyEventHandler((_,_)=>{if(!_dragging&&_pointer is null)SuppressClick=false;}),true);
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
        var point=args.GetCurrentPoint(_host);if(!point.Properties.IsLeftButtonPressed){Reset();return;}
        var dx=point.Position.X-_start.X;var dy=point.Position.Y-_start.Y;
        if(!_dragging)
        {
            if(Math.Abs(dy)>8&&Math.Abs(dy)>Math.Abs(dx)){Reset();return;}
            if(Math.Abs(dx)<8||Math.Abs(dx)<Math.Abs(dy)*1.2)return;
            _dragging=true;SuppressClick=true;
            // Capture only after horizontal intent, so an ordinary press still clicks its title.
            if(!_host.CapturePointer(args.Pointer)){Reset();return;}
        }
        if(_scroll() is{} scroll)scroll.ChangeView(Math.Clamp(_offset-dx,0,scroll.ScrollableWidth),null,null,true);
        args.Handled=true;
    }
    private void Released(object sender,PointerRoutedEventArgs args)
    {if(_pointer!=args.Pointer.PointerId)return;if(_dragging)args.Handled=true;Reset();}
    private void Canceled(object sender,PointerRoutedEventArgs args)
    {if(_pointer==args.Pointer.PointerId)Reset();}
    public void Reset()
    {
        var release=_dragging;_pointer=null;_dragging=false;
        if(release)_host.ReleasePointerCaptures();
        // Kept through PointerReleased/ItemClick ordering; next press or keyboard input clears it.
    }
}
