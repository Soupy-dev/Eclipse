using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using Eclipse.Windows.Models;

namespace Eclipse.Windows.Services;

public static partial class StremioCatalogs
{
    private const int Limit=15;
    private static readonly object Gate=new();
    private static readonly Dictionary<string,MediaTitle?> Resolved=[];
    private static bool _hooked;
    [GeneratedRegex(@"^tt\d+")] private static partial Regex ImdbPrefix();

    public static string CatalogId(StremioAddon addon,StremioCatalog catalog)=>$"stremio:{addon.Id.ToString().ToUpperInvariant()}:{catalog.Type}:{catalog.Id}";
    public static string DisplayName(StremioCatalog catalog)=>catalog.Name?.Trim() is {Length:>0} name?name:CultureInfo.InvariantCulture.TextInfo.ToTitleCase(catalog.Type.ToLowerInvariant());
    private static string? Config(HomeCatalog catalog,string key)=>catalog.ProviderConfiguration?.TryGetValue(key,out var value)==true&&value.ValueKind==JsonValueKind.String?value.GetString():null;
    private static (StremioAddon Addon,StremioCatalog Catalog)? Find(HomeCatalog catalog,bool activeOnly)
    {
        if(!Guid.TryParse(Config(catalog,"stremioAddonId"),out var addonId)||Config(catalog,"stremioCatalogId") is not {} catalogId||Config(catalog,"stremioCatalogType") is not {} type)return null;
        var addons=activeOnly?StremioAddonStore.Shared.ActiveCatalogAddons:StremioAddonStore.Shared.Addons;
        return addons.FirstOrDefault(a=>a.Id==addonId) is {} addon&&addon.Manifest.HomeCatalogs.FirstOrDefault(c=>c.Id==catalogId&&c.Type==type) is {} match?(addon,match):null;
    }
    public static bool IsAvailable(HomeCatalog catalog)=>Find(catalog,true) is not null;

    public static void Hook()
    {
        if(_hooked)return;_hooked=true;
        StremioAddonStore.Shared.Changed+=(_,_)=>Sync();
        Sync();
    }
    public static void Sync()
    {
        var store=PreferenceStore.Shared;if(store.ReadError is not null)return;
        var addonCatalogs=StremioAddonStore.Shared.Addons.SelectMany(addon=>addon.Manifest.HomeCatalogs.Where(c=>c.Id.Trim().Length>0&&c.EclipseMediaType is not null).Select(c=>(Addon:addon,Catalog:c))).ToList();
        var valid=addonCatalogs.Select(a=>CatalogId(a.Addon,a.Catalog)).ToHashSet();
        var current=store.Value.EnabledCatalogs;var copy=store.Copy();
        var merged=copy.EnabledCatalogs.Where(c=>c.Source!="Stremio"||valid.Contains(c.Id)).ToList();
        var next=(merged.Count==0?-1:merged.Max(c=>c.Order))+1;
        foreach(var (addon,catalog) in addonCatalogs)
        {
            var id=CatalogId(addon,catalog);
            var configuration=new Dictionary<string,JsonElement>
            {
                ["stremioAddonId"]=JsonSerializer.SerializeToElement(addon.Id.ToString().ToUpperInvariant()),["stremioAddonName"]=JsonSerializer.SerializeToElement(addon.Manifest.Name),
                ["stremioCatalogId"]=JsonSerializer.SerializeToElement(catalog.Id),["stremioCatalogType"]=JsonSerializer.SerializeToElement(catalog.Type),["stremioMediaType"]=JsonSerializer.SerializeToElement(catalog.EclipseMediaType!)
            };
            if(merged.FirstOrDefault(c=>c.Id==id) is {} existing){existing.Name=DisplayName(catalog);existing.ProviderConfiguration=configuration;continue;}
            merged.Add(new HomeCatalog{Id=id,Name=DisplayName(catalog),Source="Stremio",IsEnabled=true,Order=next++,ProviderConfiguration=configuration});
        }
        merged=merged.OrderBy(c=>c.Order).Select((c,i)=>{c.Order=i;return c;}).ToList();
        string Signature(IEnumerable<HomeCatalog> list)=>string.Join("|",list.Select(c=>$"{c.Id}:{c.Name}:{c.IsEnabled}:{c.Order}:{(c.ProviderConfiguration is null?"":string.Join(",",c.ProviderConfiguration.OrderBy(p=>p.Key).Select(p=>p.Key+"="+p.Value.GetRawText())))}"));
        if(Signature(merged)==Signature(current))return;
        copy.EnabledCatalogs=merged.Take(80).ToList();
        try{store.Save(copy);}catch(IOException){}
    }

    public static async Task<CatalogPage> LoadAsync(string catalogId,CancellationToken token)
    {
        var catalog=PreferenceStore.Shared.Value.EnabledCatalogs.FirstOrDefault(c=>c.Id==catalogId)??throw new ProviderException("This Stremio catalog is no longer installed.");
        if(Find(catalog,true) is not var (addon,stremioCatalog))throw new ProviderException("Requires a configured Stremio addon");
        IReadOnlyList<StremioMeta> metas;
        try{metas=await StremioClient.FetchCatalogAsync(addon.ConfiguredUrl,stremioCatalog,null,stremioCatalog.ShouldSendInitialSkip?0:null,token);}
        catch(StremioException error){throw new ProviderException($"{addon.Manifest.Name} could not load this catalog. {error.Message}");}
        var results=new List<MediaTitle>();var seen=new HashSet<string>();
        foreach(var meta in metas.Take(Limit*2))
        {
            token.ThrowIfCancellationRequested();
            if(await ResolveAsync(meta,stremioCatalog,addon,token) is {} title&&seen.Add(title.Id))results.Add(title);
            if(results.Count>=Limit)break;
        }
        return new(results,1,1);
    }
    private static string? MediaType(string? type)=>type?.ToLowerInvariant() switch{"movie"=>"movie","series" or "tv" or "anime"=>"tv",_=>null};
    private static int? TmdbIdFrom(string stremioId)
    {
        foreach(var prefix in new[]{"tmdb:","tmdb_id:"})
            if(stremioId.StartsWith(prefix,StringComparison.OrdinalIgnoreCase))
                foreach(var part in stremioId[prefix.Length..].Split(':'))if(int.TryParse(part,out var id))return id;
        return null;
    }
    private static async Task<MediaTitle?> ResolveAsync(StremioMeta meta,StremioCatalog catalog,StremioAddon addon,CancellationToken token)
    {
        if((MediaType(meta.Type)??catalog.EclipseMediaType) is not {} type)return null;
        var key=$"{addon.Id}|{catalog.Id}|{type}|{meta.Id}";
        lock(Gate)if(Resolved.TryGetValue(key,out var cached))return cached;
        MediaTitle? title=null;
        try
        {
            if((meta.TmdbId??TmdbIdFrom(meta.Id)) is {} tmdbId&&tmdbId>0)
            {
                var anime=type=="tv"&&(meta.Genres??[]).Concat([catalog.Id,catalog.Name??""]).Any(l=>l.ToLowerInvariant().Split(c=>!char.IsLetterOrDigit(c)).Contains("anime"));
                var released=meta.Released?.Trim() is {Length:>=10} r?r[..10]:meta.Released?.Trim() is {Length:>0} p?p:meta.ReleaseInfo;
                title=new MediaTitle
                {
                    TmdbId=tmdbId,MediaType=type,Title=meta.Name,Synopsis=meta.Description??"",ReleaseDate=released??"",PosterPath=meta.Poster,BackdropPath=meta.Background,
                    Score=double.TryParse(meta.ImdbRating,NumberStyles.Float,CultureInfo.InvariantCulture,out var rating)?rating:0,GenreIds=anime?[16]:[]
                };
                if(title.PosterUri is null)
                {
                    var details=await TmdbService.Shared.DetailsAsync($"{type}:{tmdbId}",token);
                    title=title with{PosterPath=details.PosterPath,BackdropPath=title.ArtworkUri is null?details.BackdropPath:title.BackdropPath};
                }
            }
            else if(StremioClient.NormalizedImdbId(meta.ImdbId??(ImdbPrefix().Match(meta.Id) is {Success:true} m?m.Value:null)) is {} imdb)
                title=await TmdbService.Shared.FindByImdbAsync(imdb,type,token);
        }
        catch(OperationCanceledException){throw;}
        catch(Exception error) when(error is TmdbException or ProviderException){return null;}
        lock(Gate){if(Resolved.Count>=2000)Resolved.Clear();Resolved[key]=title;}
        return title;
    }
}
