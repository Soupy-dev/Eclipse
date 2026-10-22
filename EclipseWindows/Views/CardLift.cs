using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace Eclipse.Windows.Views;

// Apple's media cards respond to pointer hover by lifting the artwork and brightening its rim.
// Set on a card's artwork element; the hosting list item drives it and keeps its own backplate
// transparent. Scale and rim fades are compositor transitions, so resting cards cost nothing.
public static class CardLift
{
    public static readonly DependencyProperty IsEnabledProperty=DependencyProperty.RegisterAttached("IsEnabled",typeof(bool),typeof(CardLift),new PropertyMetadata(false,Enabled_Changed));
    private static readonly DependencyProperty StateProperty=DependencyProperty.RegisterAttached("State",typeof(object),typeof(CardLift),new PropertyMetadata(null));
    private static readonly PointerEventHandler PressedHandler=Host_Pressed,ReleasedHandler=Host_Released;
    private static readonly UISettings Settings=new();
    public static bool GetIsEnabled(DependencyObject element)=>(bool)element.GetValue(IsEnabledProperty);
    public static void SetIsEnabled(DependencyObject element,bool value)=>element.SetValue(IsEnabledProperty,value);

    private sealed class LiftState(FrameworkElement art,UIElement host)
    {
        public readonly FrameworkElement Art=art;
        public readonly UIElement Host=host;
        public bool Hovered,Pressed,Focused;
        public ShapeVisual? Rim;
        public CompositionRoundedRectangleGeometry? RimShape;
        public CompositionColorBrush? RimBrush;
    }

    private static void Enabled_Changed(DependencyObject element,DependencyPropertyChangedEventArgs args)
    {
        if(element is not FrameworkElement art)return;
        art.Loaded-=Art_Loaded;art.Unloaded-=Art_Unloaded;art.SizeChanged-=Art_SizeChanged;
        if(args.NewValue is not true){Detach(art);return;}
        art.Loaded+=Art_Loaded;art.Unloaded+=Art_Unloaded;art.SizeChanged+=Art_SizeChanged;
        if(art.IsLoaded)Attach(art);
    }

    private static void Art_Loaded(object sender,RoutedEventArgs args)=>Attach((FrameworkElement)sender);
    private static void Art_Unloaded(object sender,RoutedEventArgs args)=>Detach((FrameworkElement)sender);
    private static void Art_SizeChanged(object sender,SizeChangedEventArgs args)
    {if(((FrameworkElement)sender).GetValue(StateProperty) is LiftState state)Measure(state);}

    private static void Attach(FrameworkElement art)
    {
        if(art.GetValue(StateProperty) is LiftState)return;
        UIElement host=art;
        for(var parent=VisualTreeHelper.GetParent(art);parent is not null;parent=VisualTreeHelper.GetParent(parent))
            if(parent is SelectorItem item){host=item;break;}
        var state=new LiftState(art,host);
        art.SetValue(StateProperty,state);host.SetValue(StateProperty,state);
        host.PointerEntered+=Host_Entered;host.PointerExited+=Host_Exited;host.PointerCanceled+=Host_Exited;host.PointerCaptureLost+=Host_CaptureLost;
        host.AddHandler(UIElement.PointerPressedEvent,PressedHandler,true);host.AddHandler(UIElement.PointerReleasedEvent,ReleasedHandler,true);
        host.GotFocus+=Host_FocusChanged;host.LostFocus+=Host_FocusChanged;
        art.ScaleTransition=new Vector3Transition{Duration=TimeSpan.FromMilliseconds(180)};
        Measure(state);
    }

    private static void Detach(FrameworkElement art)
    {
        if(art.GetValue(StateProperty) is not LiftState state)return;
        var host=state.Host;
        host.PointerEntered-=Host_Entered;host.PointerExited-=Host_Exited;host.PointerCanceled-=Host_Exited;host.PointerCaptureLost-=Host_CaptureLost;
        host.RemoveHandler(UIElement.PointerPressedEvent,PressedHandler);host.RemoveHandler(UIElement.PointerReleasedEvent,ReleasedHandler);
        host.GotFocus-=Host_FocusChanged;host.LostFocus-=Host_FocusChanged;
        host.ClearValue(StateProperty);art.ClearValue(StateProperty);
        art.ScaleTransition=null;art.Scale=Vector3.One;
        if(state.Rim is not null){ElementCompositionPreview.SetElementChildVisual(art,null);state.Rim.Dispose();state.RimShape?.Dispose();state.RimBrush?.Dispose();}
    }

    private static LiftState? StateOf(object sender)=>(sender as UIElement)?.GetValue(StateProperty) as LiftState;
    private static void Host_Entered(object sender,PointerRoutedEventArgs args){if(StateOf(sender) is { } state){state.Hovered=args.Pointer.PointerDeviceType!=Microsoft.UI.Input.PointerDeviceType.Touch;Apply(state);}}
    private static void Host_Exited(object sender,PointerRoutedEventArgs args){if(StateOf(sender) is { } state){state.Hovered=state.Pressed=false;Apply(state);}}
    private static void Host_Pressed(object sender,PointerRoutedEventArgs args){if(StateOf(sender) is { } state){state.Pressed=true;Apply(state);}}
    private static void Host_Released(object sender,PointerRoutedEventArgs args){if(StateOf(sender) is { } state){state.Pressed=false;Apply(state);}}
    private static void Host_CaptureLost(object sender,PointerRoutedEventArgs args){if(StateOf(sender) is { } state){state.Pressed=false;Apply(state);}}
    private static void Host_FocusChanged(object sender,RoutedEventArgs args)
    {if(StateOf(sender) is { } state){state.Focused=state.Host is Control{FocusState:FocusState.Keyboard};Apply(state);}}

    private static void Apply(LiftState state)
    {
        var lifted=state.Hovered||state.Focused;
        var scale=!Settings.AnimationsEnabled?1f:state.Pressed?.975f:lifted?1.035f:1f;
        state.Art.Scale=new(scale,scale,1);
        if(lifted&&state.Rim is null)CreateRim(state);
        if(state.Rim is null)return;
        state.RimBrush!.Color=state.Art.ActualTheme==ElementTheme.Light?Color.FromArgb(72,20,12,36):Color.FromArgb(150,255,255,255);
        state.Rim.Opacity=lifted?1:0;
    }

    private static void CreateRim(LiftState state)
    {
        // High contrast keeps the system focus visual as the only state cue.
        if(new AccessibilitySettings().HighContrast)return;
        // Never take the artwork's hand-off visual: that disables the Scale facade used for the lift.
        var compositor=CompositionTarget.GetCompositorForCurrentThread();
        state.RimShape=compositor.CreateRoundedRectangleGeometry();
        state.RimBrush=compositor.CreateColorBrush();
        var shape=compositor.CreateSpriteShape(state.RimShape);shape.StrokeBrush=state.RimBrush;shape.StrokeThickness=1.5f;
        var fade=compositor.CreateScalarKeyFrameAnimation();fade.Target="Opacity";fade.InsertExpressionKeyFrame(1,"this.FinalValue");fade.Duration=TimeSpan.FromMilliseconds(160);
        var implicitAnimations=compositor.CreateImplicitAnimationCollection();implicitAnimations["Opacity"]=fade;
        state.Rim=compositor.CreateShapeVisual();state.Rim.Shapes.Add(shape);state.Rim.Opacity=0;state.Rim.ImplicitAnimations=implicitAnimations;
        ElementCompositionPreview.SetElementChildVisual(state.Art,state.Rim);
        Measure(state);
    }

    private static void Measure(LiftState state)
    {
        var art=state.Art;var width=(float)art.ActualWidth;var height=(float)art.ActualHeight;
        art.CenterPoint=new(width/2,height/2,0);
        if(state.Rim is null||state.RimShape is null)return;
        var radius=art is Border border?(float)border.CornerRadius.TopLeft:12f;
        state.Rim.Size=new(width,height);state.RimShape.Offset=new(.75f);
        state.RimShape.Size=new(Math.Max(0,width-1.5f),Math.Max(0,height-1.5f));state.RimShape.CornerRadius=new(Math.Max(0,radius-.75f));
    }
}
