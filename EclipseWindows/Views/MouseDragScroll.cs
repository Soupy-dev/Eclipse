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
    private const double Threshold=8;
    private readonly UIElement _root;
    private ScrollViewer? _target;
    private uint? _pointer;
    private Point _start;
    private double _offset,_velocity,_lastY;
    private ulong _lastTime;
    private bool _dragging;

    public MouseDragScroll(UIElement root)
    {
        _root=root;
        root.AddHandler(UIElement.PointerPressedEvent,new PointerEventHandler(Pressed),true);
        root.AddHandler(UIElement.PointerMovedEvent,new PointerEventHandler(Moved),true);
        root.AddHandler(UIElement.PointerReleasedEvent,new PointerEventHandler(Released),true);
        root.AddHandler(UIElement.PointerCanceledEvent,new PointerEventHandler((_,args)=>{if(_pointer==args.Pointer.PointerId)Reset();}),true);
        root.AddHandler(UIElement.PointerCaptureLostEvent,new PointerEventHandler((_,args)=>{if(_dragging&&ReferenceEquals(args.OriginalSource,_target))Reset();}),true);
    }

    private void Pressed(object sender,PointerRoutedEventArgs args)
    {
        Reset();
        var point=args.GetCurrentPoint(_root);
        if(args.Pointer.PointerDeviceType!=PointerDeviceType.Mouse||!point.Properties.IsLeftButtonPressed||Target(args.OriginalSource as DependencyObject) is not{} target)return;
        _target=target;_pointer=args.Pointer.PointerId;_start=point.Position;_offset=target.VerticalOffset;
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
            _dragging=true;_velocity=0;_lastY=point.Position.Y;_lastTime=point.Timestamp;
        }
        var elapsed=(point.Timestamp-_lastTime)/1000.0;
        if(elapsed>0)
        {
            var instant=(point.Position.Y-_lastY)/elapsed;
            _velocity=elapsed>80?instant:_velocity*.6+instant*.4;_lastY=point.Position.Y;_lastTime=point.Timestamp;
        }
        target.ChangeView(null,Math.Clamp(_offset-dy,0,target.ScrollableHeight),null,true);
        args.Handled=true;
    }

    private void Released(object sender,PointerRoutedEventArgs args)
    {
        if(_pointer!=args.Pointer.PointerId)return;
        if(_dragging&&_target is{} target)
        {
            args.Handled=true;
            var idle=(args.GetCurrentPoint(_root).Timestamp-_lastTime)/1000.0;
            if(idle<60&&Math.Abs(_velocity)>.3)target.ChangeView(null,Math.Clamp(target.VerticalOffset-Math.Clamp(_velocity*320,-target.ViewportHeight,target.ViewportHeight),0,target.ScrollableHeight),null,false);
        }
        Reset();
    }

    private void Reset()
    {
        var target=_target;var release=_dragging;
        _pointer=null;_target=null;_dragging=false;
        if(release)target?.ReleasePointerCaptures();
    }
}
