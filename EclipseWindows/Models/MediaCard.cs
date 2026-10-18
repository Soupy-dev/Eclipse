using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml;
namespace Eclipse.Windows.Models;
public sealed record MediaCard(MediaTitle Media,double Width,double ImageHeight,double Radius,bool IsLandscape,int Rank=0)
{
    public BitmapImage? Image => IsLandscape ? Media.Landscape : Media.Poster;
    public string Title=>Media.Title;
    public string Subtitle=>(Rank>0 ? $"{Rank:00} · " : "")+Media.Subtitle;
    public CornerRadius Corners=>new(Radius);
}
