using Eclipse.Windows.Models;
using Eclipse.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;

namespace Eclipse.Windows.Views;

public sealed partial class SchedulePoster:UserControl
{
    private static readonly SemaphoreSlim MetadataSlots=new(2);
    private readonly BitmapImage _bitmap=new(){DecodePixelType=DecodePixelType.Logical,DecodePixelWidth=80};
    private CancellationTokenSource? _load;
    private bool _active;
    public static readonly DependencyProperty RowProperty=DependencyProperty.Register(nameof(Row),typeof(ScheduleDisplayRow),typeof(SchedulePoster),new PropertyMetadata(null,(sender,_)=>((SchedulePoster)sender).Reload()));
    public ScheduleDisplayRow? Row{get=>(ScheduleDisplayRow?)GetValue(RowProperty);set=>SetValue(RowProperty,value);}
    public SchedulePoster()
    {
        InitializeComponent();Artwork.Source=_bitmap;Loaded+=(_,_)=>{_active=true;Reload();};Unloaded+=(_,_)=>{_active=false;Cancel();};
    }
    private void Cancel(){_load?.Cancel();_load?.Dispose();_load=null;_bitmap.UriSource=null;}
    private async void Reload()
    {
        Cancel();if(!_active||Row is not{} row)return;
        _load=new();var token=_load.Token;
        if(MediaTitle.ImageUri(row.Entry.Cover,"w185") is{} uri){_bitmap.UriSource=uri;return;}
        if(row.Entry.TmdbId is not >0)return;
        var acquired=false;
        try
        {
            await MetadataSlots.WaitAsync(token);acquired=true;
            var path=await TmdbService.Shared.PosterPathAsync(row.Entry.TmdbId.Value,token);
            if(!token.IsCancellationRequested&&ReferenceEquals(Row,row))_bitmap.UriSource=MediaTitle.ImageUri(path,"w185");
        }
        catch(OperationCanceledException){}catch(TmdbException){}
        finally{if(acquired)MetadataSlots.Release();}
    }
}
