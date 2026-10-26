using System.Globalization;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading.Channels;
using Eclipse.Windows.Models;

namespace Eclipse.Windows.Services;

public sealed class StremioAddon
{
    public required Guid Id {get;init;}
    public required string ConfiguredUrl {get;init;}
    public required StremioManifest Manifest {get;init;}
    public required JsonElement ManifestJson {get;init;}
    public bool IsActive {get;init;}
    public int SortIndex {get;init;}
    public string SourceId=>"stremio:"+Id.ToString().ToUpperInvariant();
}

public sealed record StremioAddonResult(StremioAddon Addon,IReadOnlyList<StremioStream> Streams,StremioOutcome Outcome);

public sealed partial class StremioAddonStore
{
    private sealed record Entry(Guid Id,string ConfiguredUrl,JsonElement Manifest,bool IsActive,int SortIndex);
    private static readonly JsonSerializerOptions Options=new(){PropertyNamingPolicy=JsonNamingPolicy.CamelCase};
    public static StremioAddonStore Shared {get;}=new();
    private readonly string _path=LocalProtection.LocalPath("stremio-addons.protected");
    private readonly object _gate=new();
    private readonly Dictionary<Guid,long> _generations=[];
    private readonly Dictionary<string,string> _imdbCache=[];
    public IReadOnlyList<StremioAddon> Addons {get;private set;}=[];
    public string? ReadError {get;private set;}
    public bool IsBusy {get;private set;}
    public event EventHandler? Changed;

    private StremioAddonStore()
    {
        try
        {
            if(!File.Exists(_path))return;
            if(new FileInfo(_path).Length>32*1024*1024)throw new IOException();
            var json=LocalProtection.Transform(File.ReadAllBytes(_path),false,"","");
            var entries=JsonSerializer.Deserialize<List<Entry>>(json,Options)??[];
            Addons=entries.Select(Model).Where(a=>a is not null).Select(a=>a!).OrderBy(a=>a.SortIndex).ThenBy(a=>a.Manifest.Name,StringComparer.CurrentCultureIgnoreCase).ToArray();
        }
        catch{ReadError="Saved Stremio addons could not be read. The original file has been preserved.";}
    }
    private static StremioAddon? Model(Entry e)=>StremioManifest.Parse(e.Manifest) is {} manifest?new(){Id=e.Id,ConfiguredUrl=e.ConfiguredUrl,Manifest=manifest,ManifestJson=e.Manifest.Clone(),IsActive=e.IsActive,SortIndex=e.SortIndex}:null;
    private void Persist(IReadOnlyList<StremioAddon> addons)
    {
        if(ReadError is not null)throw new IOException(ReadError);
        var ordered=addons.Select((a,i)=>new Entry(a.Id,a.ConfiguredUrl,a.ManifestJson,a.IsActive,i)).ToList();
        var bytes=LocalProtection.Transform(JsonSerializer.SerializeToUtf8Bytes(ordered,Options),true,"Eclipse Stremio addons","Windows could not protect the Stremio addon list.");
        LocalProtection.WriteAtomically(_path,bytes);
        lock(_gate)Addons=addons.Select((a,i)=>new StremioAddon{Id=a.Id,ConfiguredUrl=a.ConfiguredUrl,Manifest=a.Manifest,ManifestJson=a.ManifestJson,IsActive=a.IsActive,SortIndex=i}).ToArray();
        Changed?.Invoke(this,EventArgs.Empty);
    }
    public static Guid AddonId(string manifestId,string configuredUrl)=>new(SHA256.HashData(Encoding.UTF8.GetBytes($"{manifestId}|{configuredUrl}")).AsSpan(0,16),true);
    public IEnumerable<StremioAddon> Active=>Addons.Where(a=>a.IsActive);
    public IEnumerable<StremioAddon> ActiveStreamAddons=>Active.Where(a=>a.Manifest.SupportsStreams);
    public IEnumerable<StremioAddon> ActiveCatalogAddons=>ServicesPreferenceStore.Shared.Value.BlockAddonCatalogs?[]:Active.Where(a=>a.Manifest.SupportsCatalogs&&ServicesPreferenceStore.Shared.Value.StremioComponent("catalogs",a.SourceId));

    public async Task<StremioAddon> AddAsync(string url,CancellationToken token)
    {
        IsBusy=true;
        try
        {
            var (manifest,raw)=await StremioClient.FetchManifestAsync(url,token);
            if(!manifest.SupportsInstallableResources)throw new SourceException("This addon does not support streams, subtitles, or catalogs");
            var configured=StremioClient.NormalizedConfiguredUrl(url);var id=AddonId(manifest.Id,configured);
            if(Addons.Any(a=>a.Id==id||a.Manifest.Id==manifest.Id&&StremioClient.NormalizedConfiguredUrl(a.ConfiguredUrl)==configured))throw new SourceException("This addon is already installed");
            var addon=new StremioAddon{Id=id,ConfiguredUrl=configured,Manifest=manifest,ManifestJson=raw,IsActive=true,SortIndex=Addons.Count};
            Persist([..Addons,addon]);
            if(manifest.SupportsStreams)SourceOrder.Append(addon.SourceId);
            return Addons.First(a=>a.Id==id);
        }
        finally{IsBusy=false;}
    }
    public void Remove(StremioAddon addon)
    {
        lock(_gate)_generations[addon.Id]=_generations.GetValueOrDefault(addon.Id)+1;
        Persist(Addons.Where(a=>a.Id!=addon.Id).ToArray());
        SourceOrder.Forget(addon.SourceId);
    }
    public void SetActive(StremioAddon addon,bool active)=>Persist(Addons.Select(a=>a.Id==addon.Id?Copy(a,a.ConfiguredUrl,a.Manifest,a.ManifestJson,active):a).ToArray());
    public void Reorder(IReadOnlyList<Guid> order)=>Persist(Addons.OrderBy(a=>order.Contains(a.Id)?order.ToList().IndexOf(a.Id):int.MaxValue).ThenBy(a=>a.SortIndex).ToArray());
    private static StremioAddon Copy(StremioAddon a,string url,StremioManifest manifest,JsonElement raw,bool active)=>new(){Id=a.Id,ConfiguredUrl=url,Manifest=manifest,ManifestJson=raw,IsActive=active,SortIndex=a.SortIndex};
    public async Task ReconfigureAsync(StremioAddon addon,string newUrl,CancellationToken token)
    {
        long generation;lock(_gate)generation=_generations[addon.Id]=_generations.GetValueOrDefault(addon.Id)+1;
        var (manifest,raw)=await StremioClient.FetchManifestAsync(newUrl,token);
        if(!manifest.SupportsInstallableResources)throw new SourceException("This addon does not support streams, subtitles, or catalogs");
        token.ThrowIfCancellationRequested();
        lock(_gate)if(_generations.GetValueOrDefault(addon.Id)!=generation)throw new SourceException("This addon changed while it was being reconfigured. Try again.");
        if(Addons.FirstOrDefault(a=>a.Id==addon.Id) is not {} current||current.ConfiguredUrl!=addon.ConfiguredUrl)throw new SourceException("This addon changed while it was being reconfigured. Try again.");
        Persist(Addons.Select(a=>a.Id==addon.Id?Copy(a,StremioClient.NormalizedConfiguredUrl(newUrl),manifest,raw,current.IsActive):a).ToArray());
        if(manifest.SupportsStreams)SourceOrder.Append(addon.SourceId);else SourceOrder.Remove(addon.SourceId);
    }
    public async Task RefreshAsync(CancellationToken token)
    {
        foreach(var addon in Addons.ToArray())
        {
            long generation;lock(_gate)generation=_generations.GetValueOrDefault(addon.Id);
            try
            {
                var (manifest,raw)=await StremioClient.FetchManifestAsync(addon.ConfiguredUrl,token);
                lock(_gate)if(_generations.GetValueOrDefault(addon.Id)!=generation)continue;
                if(Addons.FirstOrDefault(a=>a.Id==addon.Id) is not {} current||current.ConfiguredUrl!=addon.ConfiguredUrl)continue;
                lock(_gate)_generations[addon.Id]=generation+1;
                Persist(Addons.Select(a=>a.Id==addon.Id?Copy(a,a.ConfiguredUrl,manifest,raw,current.IsActive):a).ToArray());
            }
            catch(OperationCanceledException){throw;}
            catch(Exception error) when(error is SourceException or IOException){}
        }
    }

    public async IAsyncEnumerable<StremioAddonResult> StreamsAsync(SourceSearchContext context,[System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken token)
    {
        var active=ActiveStreamAddons.ToArray();
        if(active.Length==0)yield break;
        var type=context.IsMovie?"movie":"series";
        var animeContext=context.PlaybackContext;
        var season=context.StreamSeason;var episode=context.StreamEpisode;
        if(type=="series"&&animeContext is {HasAnimeMediaId:true}){season=animeContext.TmdbSeason??season;episode=animeContext.TmdbEpisode??episode;}
        var imdbTask=ResolveImdbAsync(context.Request.Title,token);
        var kitsuTask=EnrichKitsuAsync(animeContext,active,type,context.CatalogTitleCandidates,context.Request.Year,"stream",token);
        var imdb=await imdbTask;animeContext=await kitsuTask;
        var channel=Channel.CreateUnbounded<StremioAddonResult>();var next=0;var running=0;
        void Start()
        {
            var addon=active[next++];Interlocked.Increment(ref running);
            _=Task.Run(async()=>
            {
                StremioAddonResult result;
                try{result=await ResolveAsync(addon,context,type,imdb,season,episode,animeContext,token);}
                catch(OperationCanceledException){result=new(addon,[],new StremioOutcome.NoResults());}
                catch(Exception error){result=new(addon,[],new StremioOutcome.AddonError(error is SourceException?error.Message:""));}
                channel.Writer.TryWrite(result);
            },CancellationToken.None);
        }
        while(next<active.Length&&next<2)Start();
        await foreach(var result in channel.Reader.ReadAllAsync(token))
        {
            yield return result;
            if(next<active.Length)Start();
            if(Interlocked.Decrement(ref running)==0&&next>=active.Length)break;
        }
    }
    private async Task<string?> ResolveImdbAsync(MediaTitle title,CancellationToken token)
    {
        var key=$"{(title.MediaType=="movie"?"movie":"series")}|{title.TmdbId}";
        lock(_gate)if(_imdbCache.TryGetValue(key,out var cached))return cached;
        if(title.TmdbId<=0)return null;
        try
        {
            var ids=await TmdbService.Shared.ExtraAsync(new MediaTitle{TmdbId=title.TmdbId,MediaType=title.MediaType,Title=title.Title},"external_ids",token);
            if(StremioClient.NormalizedImdbId(JsonValue.Text(ids,"imdb_id")) is not {} normalized)return null;
            lock(_gate){if(_imdbCache.Count>512)_imdbCache.Clear();_imdbCache[key]=normalized;}
            return normalized;
        }
        catch(Exception error) when(error is TmdbException or ProviderException or HttpRequestException){return null;}
    }
    internal static async Task<SourceEpisodeContext?> EnrichKitsuAsync(SourceEpisodeContext? context,IReadOnlyList<StremioAddon> addons,string type,IReadOnlyList<string> titles,int? year,string resource,CancellationToken token)
    {
        if(type!="series"||context is null||context.KitsuId is not null||context.PositiveAniListId is null||context.IsSpecial||context.TitleOnlySearch||titles.Count==0)return context;
        if(!addons.Any(a=>ExplicitlyKitsu(resource=="subtitles"?a.Manifest.SubtitleIdPrefixes:a.Manifest.StreamIdPrefixes)))return context;
        var kitsu=await KitsuLookup.ResolveAsync(titles,context.SeasonEpisodeCount,year,context.PositiveAniListId,token);
        return kitsu is null?context:context with{KitsuId=kitsu};
    }
    private static bool ExplicitlyKitsu(IReadOnlyList<string>? prefixes)=>prefixes is null||prefixes.Count==0||prefixes.Any(p=>p.Trim().ToLowerInvariant() is "kitsu" or "kitsu:");
    private static int? LocalStremioSeason(SourceEpisodeContext? c)=>c is {IsSpecial:false,TitleOnlySearch:false,PositiveAniListId:not null,LocalEpisode:>0}?1:null;
    private static int? LocalStremioEpisode(SourceEpisodeContext? c)=>c is {PositiveAniListId:not null,LocalEpisode:>0}&&(c.IsSpecial||!c.TitleOnlySearch)?c.LocalEpisode:null;
    private static int? LocalKitsuEpisode(SourceEpisodeContext? c)=>c is {KitsuId:not null,LocalEpisode:>0}&&(c.IsSpecial||!c.TitleOnlySearch)?c.LocalEpisode:null;
    private static int? LocalSeriesSeason(SourceEpisodeContext? c)=>c is {IsSpecial:false,TitleOnlySearch:false,PositiveAniListId:not null,LocalSeason:>0}?c.LocalSeason:null;
    private static int? LocalSeriesEpisode(SourceEpisodeContext? c)=>c is {IsSpecial:false,TitleOnlySearch:false,PositiveAniListId:not null,LocalEpisode:>0}?c.LocalEpisode:null;

    private static async Task<StremioAddonResult> ResolveAsync(StremioAddon addon,SourceSearchContext context,string type,string? imdb,int? season,int? episode,SourceEpisodeContext? anime,CancellationToken token)
    {
        var ids=StremioClient.BuildContentIds(context.Request.Title.TmdbId,imdb,type,season,episode,addon.Manifest.StreamIdPrefixes,anime?.PositiveAniListId??context.Request.Anime?.PositiveAniListId,LocalStremioSeason(anime),LocalStremioEpisode(anime),anime?.KitsuId,LocalKitsuEpisode(anime),LocalSeriesSeason(anime),LocalSeriesEpisode(anime));
        var streams=new List<StremioStream>();var torrent=0;var external=0;StremioException? last=null;
        for(var i=0;i<ids.Count;i++)
        {
            if(token.IsCancellationRequested)break;
            try
            {
                var fetched=await StremioClient.FetchStreamsAsync(addon.ConfiguredUrl,type,ids[i],i==0,token);
                torrent=Math.Max(torrent,fetched.TorrentOnlyCount);external=Math.Max(external,fetched.ExternalOnlyCount);streams.AddRange(fetched.Streams);
            }
            catch(OperationCanceledException){break;}
            catch(StremioException error){last=error;}
        }
        var deduped=Dedupe(streams);
        if(deduped.Count>0||token.IsCancellationRequested)return Outcome(addon,deduped,torrent,external,last);
        var fallback=await CatalogSearchAsync(addon,type,season,episode,anime,context.CatalogTitleCandidates,context.Request.Year,token);
        return Outcome(addon,fallback,torrent,external,last);
    }
    private static StremioAddonResult Outcome(StremioAddon addon,IReadOnlyList<StremioStream> streams,int torrent,int external,StremioException? last)=>
        new(addon,streams,streams.Count>0?new StremioOutcome.Results(streams.Count):torrent>0?new StremioOutcome.UnplayableOnly(torrent):external>0?new StremioOutcome.ExternalOnly(external):
            last?.EclipseRefusal is {} refusal?new StremioOutcome.AppFailure(refusal):last is not null?new StremioOutcome.AddonError(last.AddonReason):new StremioOutcome.NoResults());
    private static List<StremioStream> Dedupe(IEnumerable<StremioStream> streams){var seen=new HashSet<string>();return streams.Where(s=>seen.Add(s.Url??s.InfoHash??s.Key)).ToList();}

    private static async Task<IReadOnlyList<StremioStream>> CatalogSearchAsync(StremioAddon addon,string type,int? season,int? episode,SourceEpisodeContext? anime,IReadOnlyList<string> titles,int? year,CancellationToken token)
    {
        var queries=TitleText.SearchQueries(titles);if(queries.Count==0)return [];
        var catalogs=addon.Manifest.SearchableCatalogs.Where(c=>c.SupportsType(type)).Take(3).ToArray();if(catalogs.Length==0)return [];
        var ranked=new List<(StremioCatalog Catalog,StremioMeta Meta,double Score)>();
        foreach(var catalog in catalogs)foreach(var query in queries.Take(4))
        {
            try
            {
                foreach(var meta in (await StremioClient.FetchCatalogAsync(addon.ConfiguredUrl,catalog,query,null,token)).Take(12))
                {
                    var metaType=meta.Type??catalog.Type;
                    if(!(metaType==type||type=="series"&&metaType is "tv" or "anime"))continue;
                    var score=CatalogScore(meta,titles,year);if(score>=.78)ranked.Add((catalog,meta,score));
                }
            }
            catch(OperationCanceledException){throw;}
            catch(StremioException){}
        }
        foreach(var candidate in ranked.OrderByDescending(r=>Math.Round(r.Score,4)).ThenBy(r=>r.Meta.Name.Length).Take(5))
        {
            var streams=await StreamsForMetaAsync(candidate.Meta,candidate.Catalog,addon,type,season,episode,anime,token);
            if(streams.Count>0)return streams;
        }
        return [];
    }
    private static double CatalogScore(StremioMeta meta,IReadOnlyList<string> titles,int? year)
    {
        var score=titles.Select(t=>TitleText.Similarity(t,meta.Name)).DefaultIfEmpty(0).Max();
        if(year is {} expected&&Regex.Match(meta.ReleaseInfo??meta.Released??"",@"\b(19|20)\d{2}\b") is {Success:true} m)
        {var distance=Math.Abs(expected-int.Parse(m.Value,CultureInfo.InvariantCulture));score+=distance==0?.08:distance==1?.03:distance>3?-.12:0;}
        return Math.Clamp(score,0,1);
    }
    private static async Task<IReadOnlyList<StremioStream>> StreamsForMetaAsync(StremioMeta preview,StremioCatalog catalog,StremioAddon addon,string type,int? season,int? episode,SourceEpisodeContext? anime,CancellationToken token)
    {
        var streamType=preview.Type??catalog.Type;
        var direct=StreamsFromMeta(preview,season,episode,anime);if(direct.Count>0)return direct;
        var meta=preview;
        if(addon.Manifest.SupportsMeta)
        {
            try{if(await StremioClient.FetchMetaAsync(addon.ConfiguredUrl,streamType,preview.Id,token) is {} fetched){meta=fetched;var fromMeta=StreamsFromMeta(fetched,season,episode,anime);if(fromMeta.Count>0)return fromMeta;}}
            catch(StremioException){}
        }
        foreach(var id in StreamIdsFromMeta(meta,type,season,episode,anime))
        {
            try{var fetched=await StremioClient.FetchStreamsAsync(addon.ConfiguredUrl,streamType,id,false,token);if(fetched.Streams.Count>0)return fetched.Streams;}
            catch(StremioException){}
        }
        return [];
    }
    private static List<StremioStream> StreamsFromMeta(StremioMeta meta,int? season,int? episode,SourceEpisodeContext? anime)
    {
        if(meta.Videos is not {} videos)return [];
        IEnumerable<StremioVideo> matching;
        if(season is {} s&&episode is {} e){var exact=videos.Where(v=>v.Season==s&&v.Episode==e).ToArray();matching=exact.Length>0?exact:AutoEpisodeMatches(videos,anime);}
        else if(meta.DefaultVideoId is {} d&&videos.FirstOrDefault(v=>v.Id==d) is {} video)matching=[video];
        else matching=videos;
        return Dedupe(matching.SelectMany(v=>v.Streams??[]).Where(s=>s.IsDirectHttp));
    }
    private static List<string> StreamIdsFromMeta(StremioMeta meta,string type,int? season,int? episode,SourceEpisodeContext? anime)
    {
        var candidates=new List<string>();
        if(season is {} s&&episode is {} e)
        {
            if(meta.Videos?.FirstOrDefault(v=>v.Season==s&&v.Episode==e) is {} video)candidates.Add(video.Id);
            candidates.AddRange(AutoEpisodeMatches(meta.Videos??[],anime).Select(v=>v.Id));
            if(meta.Id.StartsWith("kitsu:",StringComparison.OrdinalIgnoreCase))
            {
                if(LocalKitsuEpisode(anime) is {} local)candidates.Add(KitsuStreamId(meta.Id,local));else if(e>0)candidates.Add(KitsuStreamId(meta.Id,e));
            }
            else
            {
                candidates.Add($"{meta.Id}:{s}:{e}");
                if(LocalSeriesSeason(anime) is {} ls&&LocalSeriesEpisode(anime) is {} le)candidates.Add($"{meta.Id}:{ls}:{le}");
                var lower=meta.Id.ToLowerInvariant();
                if(anime?.PositiveAniListId is not null&&!lower.StartsWith("tt")&&!lower.StartsWith("imdb:")&&!lower.StartsWith("tmdb:")&&!lower.StartsWith("kitsu:")&&LocalStremioSeason(anime) is {} ss&&LocalStremioEpisode(anime) is {} se)candidates.Add($"{meta.Id}:{ss}:{se}");
            }
        }
        else if(type=="movie")candidates.Add(meta.Id);
        else if(meta.DefaultVideoId is {} d)candidates.Add(d);
        if(candidates.Count==0)candidates.Add(meta.Id);
        return candidates.Where(c=>c.Length>0).Distinct().ToList();
    }
    private static string KitsuStreamId(string metaId,int episode){var parts=metaId.Split(':');return parts.Length>=3&&int.TryParse(parts[^1],out _)?metaId:$"{metaId}:{episode}";}
    private static IEnumerable<StremioVideo> AutoEpisodeMatches(IReadOnlyList<StremioVideo> videos,SourceEpisodeContext? c)
    {
        if(c is not {IsSpecial:false,TitleOnlySearch:false,SeasonEpisodeCount:>0,LocalEpisode:>0})return [];
        var numbers=videos.Where(v=>v.Episode is not null).Select(v=>v.Episode!.Value).ToArray();if(numbers.Length==0)return [];
        var max=numbers.Max();
        if(c.AbsoluteEpisode is >0 and var absolute&&max>c.SeasonEpisodeCount)return videos.Where(v=>v.Episode==absolute);
        return max<=c.SeasonEpisodeCount?videos.Where(v=>v.Episode==c.LocalEpisode):[];
    }
}

public static partial class TitleText
{
    [GeneratedRegex("[^a-z0-9]+")] private static partial Regex NonAlphanumeric();
    [GeneratedRegex(@"(?i)\s*-\s*S\d{1,3}E\d{1,4}$|(?i)\s*S\d{1,3}E\d{1,4}$|(?i)\s*-\s*E\d{1,4}$|(?i)\s*E\d{1,4}$|(?i)\s*episode\s+\d{1,4}$")] private static partial Regex EpisodeSuffix();
    private static readonly HashSet<string> Ignored=["a","an","and","the","of","to","in","on","tv","series","episode"];
    public static string Normalized(string title)=>NonAlphanumeric().Replace(MediaLanguages.SearchKey(title)," ").Trim();
    public static string StripEpisodeSuffix(string title)=>EpisodeSuffix().Replace(title,"",1);
    public static List<string> SearchQueries(IEnumerable<string> values){var seen=new HashSet<string>();return values.Select(v=>StripEpisodeSuffix(v).Trim()).Where(v=>v.Length>0&&seen.Add(Normalized(v))).ToList();}
    public static double TokenOverlap(string l,string r)
    {
        static HashSet<string> Tokens(string s)=>s.Split(' ',StringSplitOptions.RemoveEmptyEntries).Where(t=>t.Length>1&&!Ignored.Contains(t)).ToHashSet();
        var a=Tokens(l);var b=Tokens(r);return a.Count==0||b.Count==0?0:(double)a.Count(b.Contains)/Math.Max(a.Count,b.Count);
    }
    public static double Similarity(string expected,string result)
    {
        var e=Normalized(expected);var r=Normalized(result);if(e.Length==0||r.Length==0)return 0;
        var score=Math.Max(TitleSimilarity.Score(expected,result),TitleSimilarity.Score(e,r))*.68+TokenOverlap(e,r)*.32;
        score+=e==r?.12:e.Contains(r)||r.Contains(e)?.05:0;
        return Math.Clamp(score,0,1);
    }
}

public static class KitsuLookup
{
    private static readonly SemaphoreSlim Gate=new(1,1);
    private static readonly Dictionary<int,int> ByHint=[];
    private static readonly Dictionary<string,int?> Queries=[];
    private static readonly Queue<string> Order=new();
    private static DateTime _nextAvailable=DateTime.MinValue,_rateLimitedUntil=DateTime.MinValue;
    public static async Task<int?> ResolveAsync(IReadOnlyList<string> titles,int? expectedEpisodes,int? expectedYear,int? hint,CancellationToken token)
    {
        await Gate.WaitAsync(token);
        try
        {
            if(hint is {} h&&ByHint.TryGetValue(h,out var cached))return cached;
            if(_rateLimitedUntil>DateTime.UtcNow)return null;
            foreach(var query in TitleText.SearchQueries(titles).Take(5))
            {
                var key=$"{TitleText.Normalized(query)}|{expectedEpisodes?.ToString()??"-"}|{expectedYear?.ToString()??"-"}";
                if(Queries.TryGetValue(key,out var known)){if(known is {} id){if(hint is {} hh)ByHint[hh]=id;return id;}continue;}
                var wait=_nextAvailable-DateTime.UtcNow;if(wait>TimeSpan.Zero)await Task.Delay(wait,token);
                _nextAvailable=DateTime.UtcNow.AddSeconds(.4);
                JsonElement json;
                try
                {
                    var uri=new Uri($"https://kitsu.io/api/edge/anime?filter%5Btext%5D={Uri.EscapeDataString(query)}&page%5Blimit%5D=5&fields%5Banime%5D=slug,canonicalTitle,titles,startDate,episodeCount");
                    using var request=new HttpRequestMessage(HttpMethod.Get,uri);request.Headers.Accept.ParseAdd("application/vnd.api+json");
                    using var deadline=CancellationTokenSource.CreateLinkedTokenSource(token);deadline.CancelAfter(TimeSpan.FromSeconds(5));
                    using var response=await SourceHttp.Sandboxed.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,deadline.Token);
                    if((int)response.StatusCode==429){var seconds=response.Headers.RetryAfter?.Delta?.TotalSeconds??5;_rateLimitedUntil=DateTime.UtcNow.AddSeconds(Math.Clamp(seconds,1,120));return null;}
                    if(response.StatusCode!=System.Net.HttpStatusCode.OK)continue;
                    using var document=JsonDocument.Parse(await SourceHttp.ReadAsync(response,512*1024,deadline.Token),new JsonDocumentOptions{MaxDepth=12});
                    json=document.RootElement.Clone();
                }
                catch(OperationCanceledException) when(token.IsCancellationRequested){return null;}
                catch(Exception error) when(error is HttpRequestException or OperationCanceledException or JsonException or SourceException or IOException){continue;}
                var match=Best(json,titles,expectedEpisodes,expectedYear);
                Queries[key]=match;Order.Enqueue(key);while(Order.Count>512)Queries.Remove(Order.Dequeue());
                if(match is {} found){if(hint is {} hh)ByHint[hh]=found;return found;}
            }
            return null;
        }
        finally{Gate.Release();}
    }
    private static int? Best(JsonElement json,IReadOnlyList<string> titles,int? expectedEpisodes,int? expectedYear)
    {
        var best=(Id:0,Title:"",Score:0.0);
        foreach(var item in JsonValue.Array(json,"data"))
        {
            if(!int.TryParse(JsonValue.Text(item,"id"),out var id)||id<=0)continue;
            var a=JsonValue.Child(item,"attributes");
            var names=new[]{JsonValue.Text(a,"canonicalTitle"),JsonValue.Text(a,"slug")}.Concat(JsonValue.Child(a,"titles") is {ValueKind:JsonValueKind.Object} t?t.EnumerateObject().Select(p=>p.Value.ValueKind==JsonValueKind.String?p.Value.GetString()??"":""):[])
                .Select(n=>n.Trim()).Where(n=>n.Length>0).DistinctBy(n=>n.ToLowerInvariant()).ToArray();
            if(names.Length==0)continue;
            var score=titles.SelectMany(c=>names.Select(n=>TitleText.Similarity(c,n))).DefaultIfEmpty(0).Max();if(score<.82)continue;
            if(expectedEpisodes is >0 and var expected&&JsonValue.Int(a,"episodeCount") is >0 and var actual){var d=Math.Abs(actual-expected);score+=d==0?.08:d==1?.03:d>Math.Max(2,expected/4)?-.12:0;}
            if(expectedYear is {} year&&JsonValue.Text(a,"startDate") is {Length:>=4} start&&int.TryParse(start[..4],out var actualYear)){var d=Math.Abs(actualYear-year);score+=d==0?.05:d>2?-.08:0;}
            if(score<.84)continue;score=Math.Min(score,1);
            var display=names[0];
            if(score>best.Score+.0001||Math.Abs(score-best.Score)<=.0001&&best.Id!=0&&display.Length<best.Title.Length)best=(id,display,score);
        }
        return best.Id==0?null:best.Id;
    }
}
