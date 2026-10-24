using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace Eclipse.Windows.Views;

public sealed partial class ContentScale : Panel
{
    private const double BaseWidth=1440,BaseHeight=900,Maximum=1.25,Step=.05;
    private readonly ScaleTransform _transform=new();
    public static double Factor {get;private set;}=1;

    protected override Size MeasureOverride(Size available)
    {
        var factor=1.0;
        if(double.IsFinite(available.Width)&&double.IsFinite(available.Height))
            factor=Math.Round(Math.Clamp(Math.Min(available.Width/BaseWidth,available.Height/BaseHeight),1,Maximum)/Step)*Step;
        if(factor!=Factor){Factor=Models.MediaTitle.ImageScale=factor;_transform.ScaleX=_transform.ScaleY=factor;}
        var inner=new Size(available.Width/Factor,available.Height/Factor);
        foreach(var child in Children)child.Measure(inner);
        return double.IsFinite(available.Width)&&double.IsFinite(available.Height)?available:new(0,0);
    }

    protected override Size ArrangeOverride(Size final)
    {
        var inner=new Rect(0,0,final.Width/Factor,final.Height/Factor);
        foreach(var child in Children)
        {
            Transform? desired=Factor==1?null:_transform;
            if(!ReferenceEquals(child.RenderTransform,desired))child.RenderTransform=desired;
            child.Arrange(inner);
        }
        return final;
    }
}
