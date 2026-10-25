using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;
using Windows.UI.ViewManagement;

namespace Eclipse.Windows.Views;

internal static class ShelfWheel
{
    private const double Stiffness=26,Frame60=1d/60;
    private static readonly UISettings Motion=new();
    private sealed class Glide(ScrollViewer scroll)
    {
        private double _target,_position,_velocity,_pixel,_written;
        private TimeSpan? _last;
        private bool _running;

        public void Push(double distance)
        {
            _target=Math.Clamp((_running?_target:scroll.VerticalOffset)+distance,0,scroll.ScrollableHeight);
            if(_running)return;
            _position=_written=scroll.VerticalOffset;_velocity=0;_pixel=1/(scroll.XamlRoot?.RasterizationScale??1);_last=null;_running=true;
            CompositionTarget.Rendering+=Frame;
        }

        private void Frame(object? sender,object args)
        {
            if(!scroll.IsLoaded){Stop();return;}
            var drift=scroll.VerticalOffset-_written;
            if(Math.Abs(drift)>_pixel)
            {
                if(Math.Abs(drift)>scroll.ViewportHeight/4){Stop();return;}
                _position+=drift;_target=Math.Clamp(_target+drift,0,scroll.ScrollableHeight);
            }
            var time=((RenderingEventArgs)args).RenderingTime;
            var seconds=_last is{} last?Math.Clamp((time-last).TotalSeconds,0,Frame60):.008;_last=time;
            _target=Math.Min(_target,scroll.ScrollableHeight);
            var offset=_position-_target;var decay=Math.Exp(-Stiffness*seconds);var push=_velocity+Stiffness*offset;
            _position=_target+(offset+push*seconds)*decay;_velocity=(_velocity-Stiffness*push*seconds)*decay;
            if(Math.Abs(_target-_position)<_pixel&&Math.Abs(_velocity)<_pixel*8){_position=_target;_velocity=0;}
            _written=Math.Round(_position/_pixel)*_pixel;
            scroll.ChangeView(null,_written,null,true);
            if(_position==_target)Stop();
        }

        public void Cancel(){if(_running)Stop();}

        private void Stop(){CompositionTarget.Rendering-=Frame;_running=false;}
    }

    private static readonly ConditionalWeakTable<ScrollViewer,Glide> Glides=new();
    private static readonly ConditionalWeakTable<UIElement,object> Pages=new();

    public static void Attach(UIElement shelf,Func<bool>? enabled=null,Func<ScrollViewer?>? page=null)=>
        shelf.AddHandler(UIElement.PointerWheelChangedEvent,new PointerEventHandler((sender,args)=>{if(enabled?.Invoke()!=false&&(page?.Invoke()??Parent((UIElement)sender)) is{} scroll)Forward((UIElement)sender,args,scroll);}),true);

    public static void AttachPage(ScrollViewer page)
    {
        if(Presenter(page) is not{} presenter||VisualTreeHelper.GetParent(presenter) is not UIElement root||Pages.TryGetValue(root,out _))return;
        Pages.Add(root,page);
        root.AddHandler(UIElement.PointerWheelChangedEvent,new PointerEventHandler((sender,args)=>Forward((UIElement)sender,args,page)),false);
        root.AddHandler(UIElement.PointerPressedEvent,new PointerEventHandler((_,_)=>{if(Glides.TryGetValue(page,out var glide))glide.Cancel();}),true);
        root.AddHandler(UIElement.KeyDownEvent,new KeyEventHandler((_,_)=>{if(Glides.TryGetValue(page,out var glide))glide.Cancel();}),true);
    }

    private static void Forward(UIElement source,PointerRoutedEventArgs args,ScrollViewer scroll)
    {
        var pointer=args.GetCurrentPoint(source).Properties;
        if(pointer.IsHorizontalMouseWheel||(args.KeyModifiers&(VirtualKeyModifiers.Control|VirtualKeyModifiers.Shift))!=0)return;
        if(!SystemParametersInfo(0x0068,0,out var lines,0))lines=3;
        var distance=-pointer.MouseWheelDelta/120d*scroll.ViewportHeight*(lines==uint.MaxValue?1:.05*lines);
        if(scroll.ScrollableHeight>0)
        {
            if(Motion.AnimationsEnabled)Glides.GetValue(scroll,s=>new Glide(s)).Push(distance);
            else scroll.ChangeView(null,Math.Clamp(scroll.VerticalOffset+distance,0,scroll.ScrollableHeight),null,true);
        }
        args.Handled=true;
    }

    private static ScrollContentPresenter? Presenter(DependencyObject node)
    {
        for(var i=0;i<VisualTreeHelper.GetChildrenCount(node);i++)
        {
            var child=VisualTreeHelper.GetChild(node,i);
            if(child is ScrollContentPresenter presenter)return presenter;
            if(Presenter(child) is{} found)return found;
        }
        return null;
    }

    private static ScrollViewer? Parent(DependencyObject node)
    {
        DependencyObject? current=node;
        while((current=VisualTreeHelper.GetParent(current)) is not null)if(current is ScrollViewer scroll)return scroll;
        return null;
    }

    [DllImport("user32.dll",EntryPoint="SystemParametersInfoW",ExactSpelling=true)] [return:MarshalAs(UnmanagedType.Bool)] private static extern bool SystemParametersInfo(uint action,uint parameter,out uint value,uint flags);
}
