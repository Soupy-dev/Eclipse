using Eclipse.Windows.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
namespace Eclipse.Windows.Views;

// Artwork belongs to the realized card, never to the persisted collection or its cache.
public sealed class LibraryCollectionCard : UserControl
{
    public static readonly DependencyProperty CollectionProperty=DependencyProperty.Register(nameof(Collection),typeof(LibraryCollection),typeof(LibraryCollectionCard),new PropertyMetadata(null,(owner,_)=>{if(owner is LibraryCollectionCard{IsLoaded:true} card)card.Render();}));
    public LibraryCollection? Collection{get=>(LibraryCollection?)GetValue(CollectionProperty);set=>SetValue(CollectionProperty,value);}
    private readonly List<BitmapImage> _images=[];
    public LibraryCollectionCard(){Width=192;Loaded+=(_,_)=>Render();Unloaded+=(_,_)=>Release();}
    private void Release(){foreach(var image in _images)image.UriSource=null;_images.Clear();Content=null;}
    private void Render()
    {
        Release();if(Collection is not {} collection)return;
        var stack=new StackPanel{Spacing=7,Padding=new(8)};var cover=new Grid{Width=176,Height=176};var recent=collection.Items.OrderByDescending(i=>i.DateAdded).Take(4).Reverse().ToArray();
        if(recent.Length==0){var placeholder=new StackPanel{Spacing=8,HorizontalAlignment=HorizontalAlignment.Center,VerticalAlignment=VerticalAlignment.Center};placeholder.Children.Add(new FontIcon{Glyph="\uE8B7",FontSize=36});placeholder.Children.Add(new TextBlock{Text="Empty",HorizontalAlignment=HorizontalAlignment.Center,Opacity=.65});cover.Children.Add(placeholder);}
        else
        {
            if(recent.Length>1){for(var i=0;i<2;i++){cover.RowDefinitions.Add(new(){Height=new(1,GridUnitType.Star)});cover.ColumnDefinitions.Add(new(){Width=new(1,GridUnitType.Star)});}cover.RowSpacing=cover.ColumnSpacing=2;}
            for(var i=0;i<recent.Length;i++)if(MediaTitle.ImageUri(recent[i].SearchResult.PosterPath,"w185")is {} uri){var bitmap=new BitmapImage{DecodePixelType=DecodePixelType.Logical,DecodePixelWidth=recent.Length==1?176:88,UriSource=uri};_images.Add(bitmap);var image=new Image{Source=bitmap,Stretch=Stretch.UniformToFill};if(recent.Length>1){Grid.SetRow(image,i/2);Grid.SetColumn(image,i%2);}cover.Children.Add(image);}
        }
        stack.Children.Add(new Border{Child=cover,CornerRadius=new(12),Background=(Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"]});stack.Children.Add(new TextBlock{Text=collection.Name,FontWeight=Microsoft.UI.Text.FontWeights.SemiBold,MaxLines=1,TextTrimming=TextTrimming.CharacterEllipsis});stack.Children.Add(new TextBlock{Text=collection.Summary,FontSize=12,MaxLines=2,TextWrapping=TextWrapping.Wrap,TextTrimming=TextTrimming.WordEllipsis,Opacity=.7});Content=stack;
    }
}
