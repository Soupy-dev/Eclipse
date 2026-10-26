using System.Net.Http;
using System.Text;
using System.Text.Json;

namespace Eclipse.Windows.Services;

public enum StremioFailure { InvalidUrl, Http, Network, Timeout, TooLarge, Unreadable }

public sealed class StremioException(StremioFailure failure,string message,int status=0) : SourceException(message,status)
{
    public StremioFailure Failure {get;}=failure;
    public bool Transient=>Failure is StremioFailure.Network or StremioFailure.Timeout or StremioFailure.Unreadable||Failure==StremioFailure.Http&&Status is 408 or 425 or 429 or 500 or 502 or 503 or 504;
    public string? EclipseRefusal=>Failure==StremioFailure.TooLarge?"the response was larger than Eclipse's own limit":null;
    public string AddonReason=>Failure switch{StremioFailure.InvalidUrl=>"Invalid Stremio addon URL",StremioFailure.Http=>$"HTTP error {Status}",_=>""};
}

public sealed record StremioStreamFetch(IReadOnlyList<StremioStream> Streams,int TorrentOnlyCount,int ExternalOnlyCount);

public static class StremioClient
{
    private const int ManifestBytes=1_000_000,StreamBytes=10_000_000,CatalogBytes=10_000_000,MetaBytes=5_000_000,MaximumPlayable=300;

    private static (string Head,string Path,string Tail)? Split(string value)
    {
        var scheme=value.IndexOf("://",StringComparison.Ordinal);if(scheme<=0)return null;
        var authorityEnd=value.IndexOfAny(['/','?','#'],scheme+3);if(authorityEnd<0)return (value,"","");
        var pathEnd=value.IndexOfAny(['?','#'],authorityEnd);if(pathEnd<0)pathEnd=value.Length;
        return (value[..authorityEnd],value[authorityEnd..pathEnd],value[pathEnd..]);
    }
    private static string TrimSlashes(string path){while(path.Length>1&&path.EndsWith('/'))path=path[..^1];return path=="/"?"":path;}
    public static string NormalizedConfiguredUrl(string url)
    {
        var cleaned=url.Trim();
        if(cleaned.StartsWith("stremio://",StringComparison.OrdinalIgnoreCase))cleaned="https://"+cleaned["stremio://".Length..];
        if(Split(cleaned) is not {} parts)return cleaned;
        var (head,path,tail)=parts;path=TrimSlashes(path);
        if(path.EndsWith("/manifest.json",StringComparison.OrdinalIgnoreCase))path=path[..^"/manifest.json".Length];
        path=TrimSlashes(path);
        if(path.EndsWith("/configure",StringComparison.OrdinalIgnoreCase))path=path[..^"/configure".Length];
        if(path=="/")path="";
        return head+path+tail;
    }
    private static Uri? Build(string configured,Func<string,string> path,bool dropFragment=true)
    {
        var normalized=NormalizedConfiguredUrl(configured);
        if(Split(normalized) is not {} parts||SourceHttp.HttpUri(parts.Head) is null)return null;
        var (head,current,tail)=parts;
        var fragment=tail.IndexOf('#');if(dropFragment&&fragment>=0)tail=tail[..fragment];
        return Uri.TryCreate(head+path(TrimSlashes(current))+tail,UriKind.Absolute,out var uri)&&SourceHttp.HttpUri(uri.AbsoluteUri) is not null?uri:null;
    }
    public static Uri? ConfigurationPageUri(string configured)=>Build(configured,p=>p.EndsWith("/configure",StringComparison.OrdinalIgnoreCase)?p:p+"/configure");
    public static Uri? EndpointUri(string configured,string suffix)=>Build(configured,p=>p+(suffix.StartsWith('/')?suffix:"/"+suffix));
    public static string EncodePathSegment(string value,bool preservingColon){var encoded=Uri.EscapeDataString(value);return preservingColon?encoded.Replace("%3A",":").Replace("%3a",":"):encoded;}
    public static string EncodeExtraValue(string value)
    {
        var builder=new StringBuilder();
        foreach(var b in Encoding.UTF8.GetBytes(value))
        {
            var c=(char)b;
            if(b<128&&(char.IsAsciiLetterOrDigit(c)||"-._~!$'()*,;:@".Contains(c)))builder.Append(c);else builder.Append('%').Append(b.ToString("X2"));
        }
        return builder.ToString();
    }
    public static string? NormalizedImdbId(string? raw)
    {
        var value=raw?.Trim().ToLowerInvariant();if(string.IsNullOrEmpty(value))return null;
        if(value.StartsWith("imdb:"))value=value[5..];
        if(value.StartsWith("tt"))value=value[2..];
        if(value.Length==0||!value.All(char.IsAsciiDigit))return null;
        return "tt"+value.PadLeft(7,'0');
    }

    private static async Task<JsonElement> GetAsync(Uri uri,int limit,CancellationToken token,bool noCache=false)
    {
        using var deadline=CancellationTokenSource.CreateLinkedTokenSource(token);deadline.CancelAfter(TimeSpan.FromSeconds(30));
        try
        {
            using var request=new HttpRequestMessage(HttpMethod.Get,uri);request.Headers.Accept.ParseAdd("application/json");request.Headers.UserAgent.ParseAdd("EclipseWindows/0.1");
            if(noCache)request.Headers.CacheControl=new(){NoCache=true};
            using var response=await SourceHttp.Addons.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,deadline.Token).ConfigureAwait(false);
            if(!response.IsSuccessStatusCode)throw new StremioException(StremioFailure.Http,$"HTTP error {(int)response.StatusCode}",(int)response.StatusCode);
            byte[] bytes;
            try{bytes=await SourceHttp.ReadAsync(response,limit,deadline.Token).ConfigureAwait(false);}
            catch(SourceException){throw new StremioException(StremioFailure.TooLarge,"The response was larger than Eclipse's own limit.");}
            using var document=JsonDocument.Parse(bytes,new JsonDocumentOptions{MaxDepth=16});
            return document.RootElement.Clone();
        }
        catch(OperationCanceledException) when(!token.IsCancellationRequested){throw new StremioException(StremioFailure.Timeout,$"{uri.Host} took too long to respond.");}
        catch(HttpRequestException){throw new StremioException(StremioFailure.Network,$"Could not connect to {uri.Host}.");}
        catch(IOException){throw new StremioException(StremioFailure.Network,$"The connection to {uri.Host} was interrupted.");}
        catch(JsonException){throw new StremioException(StremioFailure.Unreadable,$"{uri.Host} returned an unreadable response.");}
    }

    public static async Task<(StremioManifest Manifest,JsonElement Raw)> FetchManifestAsync(string url,CancellationToken token)
    {
        var uri=EndpointUri(url,"/manifest.json")??throw new StremioException(StremioFailure.InvalidUrl,"Invalid Stremio addon URL");
        var raw=await GetAsync(uri,ManifestBytes,token).ConfigureAwait(false);
        return (StremioManifest.Parse(raw)??throw new StremioException(StremioFailure.Unreadable,"This is not a valid Stremio addon manifest."),raw);
    }
    public static async Task<StremioStreamFetch> FetchStreamsAsync(string baseUrl,string type,string id,bool retryEmpty,CancellationToken token)
    {
        var uri=EndpointUri(baseUrl,$"/stream/{type}/{EncodePathSegment(id,true)}.json")??throw new StremioException(StremioFailure.InvalidUrl,"Invalid Stremio addon URL");
        for(var attempt=1;;attempt++)
        {
            token.ThrowIfCancellationRequested();
            try
            {
                var all=StremioStream.ParseList(JsonValue.Child(await GetAsync(uri,StreamBytes,token,true).ConfigureAwait(false),"streams"),2000);
                var playable=all.Where(s=>s.IsDirectHttp).Take(MaximumPlayable).ToArray();
                var torrent=all.Count(s=>!s.IsDirectHttp&&s.UsesTorrentTransport);var external=all.Count(s=>!s.IsDirectHttp&&!s.UsesTorrentTransport&&s.HasExternalDestination);
                if(retryEmpty&&attempt<2&&playable.Length==0&&all.All(s=>string.IsNullOrWhiteSpace(s.Url)&&string.IsNullOrWhiteSpace(s.InfoHash)&&!s.HasExternalDestination)){await Task.Delay(400,token).ConfigureAwait(false);continue;}
                return new(playable,torrent,external);
            }
            catch(StremioException error) when(attempt<2&&error.Transient){await Task.Delay(400,token).ConfigureAwait(false);}
        }
    }
    public static async Task<IReadOnlyList<StremioMeta>> FetchCatalogAsync(string baseUrl,StremioCatalog catalog,string? search,int? skip,CancellationToken token)
    {
        var extras=new List<string>();if(skip is {} s)extras.Add($"skip={Math.Max(s,0)}");if(search is not null)extras.Add($"search={EncodeExtraValue(search)}");
        var uri=EndpointUri(baseUrl,$"/catalog/{EncodePathSegment(catalog.Type,false)}/{EncodePathSegment(catalog.Id,true)}{(extras.Count==0?"":"/"+string.Join('&',extras))}.json")??throw new StremioException(StremioFailure.InvalidUrl,"Invalid Stremio addon URL");
        var json=await GetAsync(uri,CatalogBytes,token).ConfigureAwait(false);
        return JsonValue.Array(json,"metas").Take(300).Select(StremioMeta.Parse).Where(m=>m is not null).Select(m=>m!).ToArray();
    }
    public static async Task<StremioMeta?> FetchMetaAsync(string baseUrl,string type,string id,CancellationToken token)
    {
        var uri=EndpointUri(baseUrl,$"/meta/{EncodePathSegment(type,false)}/{EncodePathSegment(id,true)}.json")??throw new StremioException(StremioFailure.InvalidUrl,"Invalid Stremio addon URL");
        var meta=JsonValue.Child(await GetAsync(uri,MetaBytes,token).ConfigureAwait(false),"meta");
        return meta.ValueKind==JsonValueKind.Array?JsonValue.Items(meta).Select(StremioMeta.Parse).FirstOrDefault():StremioMeta.Parse(meta);
    }

    public static List<string> BuildContentIds(int tmdbId,string? imdbId,string type,int? season,int? episode,IReadOnlyList<string>? idPrefixes,int? anilistId=null,int? anilistSeason=null,int? anilistEpisode=null,int? kitsuId=null,int? kitsuEpisode=null,int? alternateSeason=null,int? alternateEpisode=null,bool allowParentSeriesIds=true)
    {
        var prefixes=(idPrefixes??[]).Select(p=>p.ToLowerInvariant()).ToArray();
        var tmdb=prefixes.Length==0||prefixes.Any(p=>p=="tmdb"||p.StartsWith("tmdb:"));
        var imdb=prefixes.Length==0||prefixes.Any(p=>p=="tt"||p.StartsWith("tt")||p=="imdb"||p=="imdb:");
        var imdbNamespace=prefixes.Contains("imdb:");
        var anilist=prefixes.Length==0||prefixes.Any(p=>p is "anilist" or "anilist:");
        var kitsu=prefixes.Length==0||prefixes.Any(p=>p is "kitsu" or "kitsu:");
        var tt=NormalizedImdbId(imdbId);var series=type=="series";
        var tuples=new List<(int Season,int Episode)>();
        if(series)
        {
            if(season is >=0 and var s&&episode is >0 and var e)tuples.Add((s,e));
            if(alternateSeason is {} a&&alternateEpisode is {} b)tuples.Add((a,b));
            tuples=tuples.Where(t=>t.Season>=0&&t.Episode>0).Distinct().ToList();
        }
        var candidates=new List<string>();
        if(allowParentSeriesIds&&imdb&&tt is not null)
        {
            if(series)candidates.AddRange(tuples.Select(t=>$"{tt}:{t.Season}:{t.Episode}"));else candidates.Add(tt);
            if(imdbNamespace){if(series)candidates.AddRange(tuples.Select(t=>$"imdb:{tt}:{t.Season}:{t.Episode}"));else candidates.Add($"imdb:{tt}");}
        }
        if(allowParentSeriesIds&&tmdb){if(series)candidates.AddRange(tuples.Select(t=>$"tmdb:{tmdbId}:{t.Season}:{t.Episode}"));else candidates.Add($"tmdb:{tmdbId}");}
        if(anilist&&anilistId is >0)
        {
            if(!series)candidates.Add($"anilist:{anilistId}");
            else if(anilistEpisode is >0)candidates.Add(anilistSeason is >0?$"anilist:{anilistId}:{anilistSeason}:{anilistEpisode}":$"anilist:{anilistId}:{anilistEpisode}");
        }
        if(kitsu&&kitsuId is >0)
        {
            if(!series)candidates.Add($"kitsu:{kitsuId}");else if(kitsuEpisode is >0)candidates.Add($"kitsu:{kitsuId}:{kitsuEpisode}");
        }
        return candidates.Distinct().ToList();
    }
}
