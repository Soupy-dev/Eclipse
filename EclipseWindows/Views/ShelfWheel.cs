using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace Eclipse.Windows.Views;

internal static class ShelfWheel
{
    private sealed class Pending{public double Target;public bool Moving;}
    private static readonly ConditionalWeakTable<ScrollViewer,Pending> Targets=new();

    public static void Attach(UIElement shelf,Func<bool>? enabled=null,Func<ScrollViewer?>? page=null)=>
        shelf.AddHandler(UIElement.PointerWheelChangedEvent,new PointerEventHandler((sender,args)=>{if(enabled?.Invoke()!=false)Forward((UIElement)sender,args,page);}),true);

    private static void Forward(UIElement shelf,PointerRoutedEventArgs args,Func<ScrollViewer?>? page)
    {
        var pointer=args.GetCurrentPoint(shelf).Properties;
        if(pointer.IsHorizontalMouseWheel||(args.KeyModifiers&(VirtualKeyModifiers.Control|VirtualKeyModifiers.Shift))!=0)return;
        if((page?.Invoke()??Parent(shelf)) is not{} scroll)return;
        if(!SystemParametersInfo(0x0068,0,out var lines,0))lines=3;
        var distance=pointer.MouseWheelDelta/120d*scroll.ViewportHeight*(lines==uint.MaxValue?1:.05*lines);
        var pending=Targets.GetValue(scroll,Track);
        var target=Math.Clamp((pending.Moving?pending.Target:scroll.VerticalOffset)-distance,0,scroll.ScrollableHeight);
        pending.Target=target;pending.Moving=true;
        scroll.ChangeView(null,target,null,false);
        args.Handled=true;
    }

    private static Pending Track(ScrollViewer scroll)
    {
        var pending=new Pending();
        scroll.ViewChanging+=(_,args)=>{pending.Target=args.FinalView.VerticalOffset;pending.Moving=true;};
        scroll.ViewChanged+=(_,args)=>{if(!args.IsIntermediate)pending.Moving=false;};
        return pending;
    }

    private static ScrollViewer? Parent(DependencyObject node)
    {
        DependencyObject? current=node;
        while((current=VisualTreeHelper.GetParent(current)) is not null)if(current is ScrollViewer scroll)return scroll;
        return null;
    }

    [DllImport("user32.dll",EntryPoint="SystemParametersInfoW",ExactSpelling=true)] [return:MarshalAs(UnmanagedType.Bool)] private static extern bool SystemParametersInfo(uint action,uint parameter,out uint value,uint flags);
}
