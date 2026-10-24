using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

namespace Eclipse.Windows.Views;

internal static class PosterImages
{
    public static void Update(ContainerContentChangingEventArgs args,Uri? source,double height)
    {
        if(args.ItemContainer.ContentTemplateRoot is not DependencyObject root||Find(root) is not Image image)return;
        if(args.InRecycleQueue||source is null){image.Source=null;return;}
        if(image.Source is BitmapImage{UriSource:{} current}&&current==source)return;
        image.Source=new BitmapImage{DecodePixelType=DecodePixelType.Logical,DecodePixelHeight=(int)Math.Ceiling(height*ContentScale.Factor),UriSource=source};
    }

    public static void Clear(ListViewBase list)
    {
        if(list.ItemsPanelRoot is not Panel panel)return;
        foreach(var child in panel.Children)if(child is SelectorItem{ContentTemplateRoot:DependencyObject root}&&Find(root) is{} image)image.Source=null;
    }

    private static Image? Find(DependencyObject node)
    {
        if(node is Image image)return image;
        for(var i=0;i<VisualTreeHelper.GetChildrenCount(node);i++)if(Find(VisualTreeHelper.GetChild(node,i)) is{} found)return found;
        return null;
    }
}
