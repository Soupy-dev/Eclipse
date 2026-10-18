using Eclipse.Windows.Models;
using static Eclipse.Windows.Services.JsonValue;

namespace Eclipse.Windows.Services;

// Verified non-1:1 editions from AnimeVerifiedEpisodeUnitPolicy in the Apple app.
// These are source-inventory proofs, not a generic count ratio or runtime heuristic.
public static class AnimeEpisodeUnits
{
    private static readonly int[] SaikiIds=[1219718,1243370,1243374,1243376,1243377,1243378,1243379,1243380,1243381,1243382,1243383,1243384,1243385,1243386,1243387,1243388,1243389,1243390,1243391,1243392,1370413,1370415,1370416,1370417];
    private static readonly int[] RazbliutoIds=[5167933,5167934,5167935,5167936];
    public static bool RequiresVerifiedInventory(int showId,AnimeNode node)=>(showId==67676&&(node.AniListId==21804||node.MalId==33255))||(showId==93816&&(node.AniListId==170935||node.MalId==57184));
    private static bool UniqueOwner(MediaTitle title,AnimeCour cour,int season,IReadOnlyList<AnimeCour> cours)
    {
        if(cours.Any(c=>c.Id!=cour.Id&&c.Mapping?.TmdbSeason==season))return false;
        return title.AnimeMappings.Where(m=>m.TmdbShowId==title.TmdbId).All(m=>
        {
            var same=(cour.Node.AniListId is {} a&&m.AniListId==a)||(cour.Node.MalId is {} mal&&m.MalId==mal);
            if(same&&m.TmdbSeason is >0&&m.TmdbSeason!=season)return false;
            return m.TmdbSeason!=season||same&&(m.AniListId is null||m.AniListId==cour.Node.AniListId)&&(m.MalId is null||m.MalId==cour.Node.MalId);
        });
    }
    public static IReadOnlyList<MediaEpisode>? Saiki(int showId,AnimeCour cour,SeasonInventory source,bool uniqueOwner)
    {
        var n=cour.Node;
        if(showId!=67676||!(n.AniListId==21804||n.AniListId is null&&n.MalId==33255)||(n.MalId is not null&&n.MalId!=33255)||n.EpisodeCount!=120||!uniqueOwner||n.Format is not ("TV" or "TV_SHORT")||!n.Finished||n.StartDate!="2016-07-04"||n.EndDate!="2016-12-26"||source.Id!=79808||source.Number!=1||!AnimeReconciliation.ValidInventory(source,24))return null;
        var rows=source.Episodes.OrderBy(e=>e.TmdbEpisodeNumber).ToArray();
        if(!rows.Select(e=>e.SourceEpisodeId!.Value).SequenceEqual(SaikiIds)||rows[0].AirDate!="2016-07-11"||rows[^1].AirDate!="2016-12-26"||!VerifiedRows(rows,20,30))return null;
        return rows.Select((e,i)=>e with{Number=i+1,AnimeId=cour.Id,Unit=new("Compilation",new(i*5+1,(i+1)*5),new(i*5+1,(i+1)*5))}).ToArray();
    }
    public static IReadOnlyList<MediaEpisode>? RazbliutoParts(int showId,AnimeCour cour,SeasonInventory source,bool uniqueOwner)
    {
        var n=cour.Node;
        if(showId!=93816||n.MalId!=57184||n.AniListId is not (null or 170935)||n.EpisodeCount!=4||n.Format!="ONA"||!n.Finished||n.StartDate!="2024-02-23"||!uniqueOwner||source.Id!=380779||source.Number!=2||!AnimeReconciliation.ValidInventory(source,4))return null;
        var rows=source.Episodes.OrderBy(e=>e.TmdbEpisodeNumber).ToArray();
        if(!rows.Select(e=>e.SourceEpisodeId!.Value).SequenceEqual(RazbliutoIds)||rows.Any(e=>e.AirDate!="2024-02-23")||!VerifiedRows(rows,20,30))return null;
        return rows.Select((e,i)=>e with{Number=i+1,AnimeId=cour.Id,Unit=new("Feature part",new(1,1),new(i+1,i+1),Part:i+1,PartCount:4)}).ToArray();
    }
    public static IReadOnlyList<MediaEpisode>? RazbliutoFeature(int showId,AnimeCour cour,MediaTitle movie,string imdb)
    {
        var n=cour.Node;
        if(showId!=93816||n.AniListId!=170935||n.MalId is not (null or 57184)||n.EpisodeCount!=1||n.Format!="ONA"||n.Status!="FINISHED"||n.StartDate!="2024-02-23"||movie.TmdbId!=1220441||movie.MediaType!="movie"||imdb!="tt30827040"||!movie.OriginalTitle.Equals("great pretender razbliuto",StringComparison.OrdinalIgnoreCase)||movie.ReleaseDate!="2024-01-09"||movie.RuntimeMinutes is not (>=88 and <=90)||!movie.GenreIds.Contains(16))return null;
        return [new(1,movie.Title,movie.Duration,movie.Synopsis,movie.ReleaseDate,movie.BackdropPath){AnimeId=cour.Id,RuntimeMinutes=movie.RuntimeMinutes,Unit=new("Feature",new(1,1),new(1,4),MovieId:1220441)}];
    }
    private static bool VerifiedRows(IReadOnlyList<MediaEpisode> rows,int minRuntime,int maxRuntime)=>rows.All(e=>!string.IsNullOrWhiteSpace(e.Title)&&AnimeReconciliation.Day(e.AirDate) is not null&&e.RuntimeMinutes>=minRuntime&&e.RuntimeMinutes<=maxRuntime)&&rows.Zip(rows.Skip(1)).All(p=>AnimeReconciliation.Day(p.First.AirDate)<=AnimeReconciliation.Day(p.Second.AirDate));
    public static async Task<(bool Handled,IReadOnlyList<MediaEpisode> Episodes)> TryHydrateAsync(MediaTitle title,AnimeCour cour,IReadOnlyList<AnimeCour> cours,Func<int,Task<SeasonInventory?>> fetch,TmdbService tmdb,CancellationToken token)
    {
        if(!RequiresVerifiedInventory(title.TmdbId,cour.Node))return(false,[]);
        IReadOnlyList<MediaEpisode>? proof=null;
        if(title.TmdbId==67676)
        {
            if(await fetch(1) is {} source)proof=Saiki(title.TmdbId,cour,source,UniqueOwner(title,cour,1,cours));
        }
        else if(cour.Node.EpisodeCount==1&&cour.Node.AniListId==170935)
        {
            var movie=await tmdb.DetailsAsync("movie:1220441",token);var external=await tmdb.ExtraAsync(movie,"external_ids",token);
            proof=RazbliutoFeature(title.TmdbId,cour,movie,Text(external,"imdb_id"));
        }
        else if(await fetch(2) is {} source)proof=RazbliutoParts(title.TmdbId,cour,source,UniqueOwner(title,cour,2,cours));
        return(true,proof??AnimeReconciliation.Project(cour,null));
    }
}
