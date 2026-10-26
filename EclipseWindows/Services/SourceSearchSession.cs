using System.Threading.Channels;

namespace Eclipse.Windows.Services;

public enum SourceSearchState { Waiting, Searching, Done }

public sealed record RankedServiceResult(ServiceSearchItem Item,double InitialSimilarity,double DisplaySimilarity);

public sealed class SourceSearchResult(SourceEntry source)
{
    public SourceEntry Source {get;}=source;
    public SourceSearchState State {get;internal set;}=SourceSearchState.Waiting;
    public IReadOnlyList<ServiceSearchItem> ServiceItems {get;internal set;}=[];
    public IReadOnlyList<RankedServiceResult> Ranked {get;internal set;}=[];
    public IReadOnlyList<StremioStream> StremioStreams {get;internal set;}=[];
    public StremioOutcome? StremioOutcome {get;internal set;}
    public IReadOnlyList<NuvioStream> NuvioStreams {get;internal set;}=[];
    public NuvioOutcome? NuvioOutcome {get;internal set;}
    public int HiddenCount {get;internal set;}
    public bool Failed {get;internal set;}
}

public sealed class SourceSearchSession
{
    private const int MaxStremioStreamsPerAddon=100;
    private readonly SynchronizationContext? _ui=SynchronizationContext.Current;
    public SourceSearchContext Context {get;}
    public IReadOnlyList<SourceSearchResult> Results {get;}
    public event Action<SourceSearchResult>? Updated;
    public event Action? Completed;
    public bool IsComplete {get;private set;}

    public SourceSearchSession(SourceSearchContext context)
    {
        Context=context;
        Results=SourceRegistry.Unified().Where(e=>e.IsActive&&(e.Kind!=SourceKind.Stremio||e.Addon!.Manifest.SupportsStreams&&context.ShouldSearchStremio)&&(e.Kind!=SourceKind.Nuvio||context.Request.Title.TmdbId>0)).Select(e=>new SourceSearchResult(e)).ToArray();
    }
    public int CompletedCount=>Results.Count(r=>r.State==SourceSearchState.Done);
    private void Post(Action action){if(_ui is null)action();else _ui.Post(_=>action(),null);}
    private void Publish(SourceSearchResult result)=>Post(()=>Updated?.Invoke(result));

    public async Task RunAsync(CancellationToken token)
    {
        var tasks=new List<Task>{ServicesAsync(token),StremioAsync(token),NuvioAsync(token)};
        try{await Task.WhenAll(tasks);}catch(OperationCanceledException){}
        if(token.IsCancellationRequested)return;
        Post(()=>{IsComplete=true;Completed?.Invoke();});
    }
    private async Task ServicesAsync(CancellationToken token)
    {
        var services=Results.Where(r=>r.Source.Kind==SourceKind.Service).ToArray();
        if(services.Length==0)return;
        var r=Context.Request;var effective=Context.EffectiveTitle;
        var primary=!Context.HasEpisode?effective:r.SpecialTitleOnlySearch?effective:r.AnimeSeasonTitle is not null?$"{effective} E{r.EpisodeNumber}":$"{effective} S{r.SeasonNumber}E{r.EpisodeNumber}";
        var baseQuery=Context.NormalizedAnimeSequelSearchQuery??Context.FallbackAnimeSearchQuery??(string.Equals(primary,effective,StringComparison.OrdinalIgnoreCase)?null:effective);
        var candidates=new List<string>{primary};if(baseQuery is not null)candidates.Add(baseQuery);
        if(r.OriginalTitle is {Length:>0} alternate&&!string.Equals(alternate,effective,StringComparison.OrdinalIgnoreCase))candidates.Add(alternate);
        var seen=new HashSet<string>();var queries=candidates.Where(q=>TitleText.Normalized(q) is {Length:>0} n&&seen.Add(n)).ToList();
        foreach(var result in services){result.State=SourceSearchState.Searching;Publish(result);}
        var remaining=services.ToList();
        for(var i=0;i<queries.Count&&remaining.Count>0;i++)
        {
            var query=queries[i];var first=i==0;
            await Task.WhenAll(remaining.Select(async result=>
            {
                IReadOnlyList<ServiceSearchItem>? items;
                try{items=await JsServices.SearchAsync(result.Source.Service!,query,token);}
                catch(OperationCanceledException){throw;}
                catch(Exception){items=null;}
                if(items is null&&first)result.Failed=true;
                var merged=first?(items??[]):result.ServiceItems.Concat((items??[]).Where(n=>result.ServiceItems.All(o=>o.Href!=n.Href))).ToArray();
                result.ServiceItems=merged;
                result.Ranked=await Task.Run(()=>Rank(merged,token),token);
                if(first)result.State=SourceSearchState.Done;
                Publish(result);
            }));
            var threshold=ServicesPreferenceStore.Shared.Value.HighQualityThreshold;
            remaining=remaining.Where(x=>!(x.Ranked.FirstOrDefault() is {} top&&top.InitialSimilarity>=threshold)).ToList();
        }
    }
    public IReadOnlyList<RankedServiceResult> Rank(IReadOnlyList<ServiceSearchItem> items,CancellationToken token)
    {
        var ranking=Context.Ranking;
        return ranking.Rank(items.Select(i=>i.Title).ToArray(),token).Take(300).Select(r=>new RankedServiceResult(items[r.Index],r.InitialSimilarity,r.DisplaySimilarity)).ToArray();
    }
    public void Rerank(CancellationToken token)
    {
        foreach(var result in Results.Where(r=>r.Source.Kind==SourceKind.Service&&r.State==SourceSearchState.Done))
        {
            var items=result.ServiceItems;
            _=Task.Run(()=>Rank(items,token),token).ContinueWith(t=>{if(t.IsCompletedSuccessfully){result.Ranked=t.Result;Publish(result);}},TaskScheduler.Default);
        }
    }
    public (IReadOnlyList<RankedServiceResult> High,IReadOnlyList<RankedServiceResult> Low) Buckets(SourceSearchResult result)
    {
        var p=ServicesPreferenceStore.Shared.Value;
        var visible=result.Ranked.Take(80).Where(r=>!p.DropMismatchedResults||r.InitialSimilarity>=p.MinimumSimilarity).ToArray();
        return (visible.Where(r=>r.InitialSimilarity>=p.HighQualityThreshold).ToArray(),visible.Where(r=>r.InitialSimilarity<p.HighQualityThreshold).ToArray());
    }
    private async Task StremioAsync(CancellationToken token)
    {
        var addons=Results.Where(r=>r.Source.Kind==SourceKind.Stremio).ToDictionary(r=>r.Source.Addon!.Id);
        if(addons.Count==0)return;
        foreach(var result in addons.Values){result.State=SourceSearchState.Searching;Publish(result);}
        try
        {
            await foreach(var found in StremioAddonStore.Shared.StreamsAsync(Context,token))
            {
                if(!addons.TryGetValue(found.Addon.Id,out var result))continue;
                var visible=await Task.Run(()=>found.Streams.Where(s=>!StreamLanguageFilter.ShouldHide(s,found.Addon.SourceId,Context.Request.OriginalLanguage,Context.HasAnimeLookupContext)).Take(MaxStremioStreamsPerAddon).ToArray(),token);
                result.StremioStreams=visible;result.HiddenCount=found.Streams.Count-visible.Length;result.StremioOutcome=found.Outcome;result.State=SourceSearchState.Done;Publish(result);
            }
        }
        catch(OperationCanceledException){throw;}
        finally{foreach(var result in addons.Values.Where(r=>r.State!=SourceSearchState.Done)){result.State=SourceSearchState.Done;result.StremioOutcome??=new StremioOutcome.NoResults();Publish(result);}}
    }
    private async Task NuvioAsync(CancellationToken token)
    {
        var scrapers=Results.Where(r=>r.Source.Kind==SourceKind.Nuvio).ToArray();
        if(scrapers.Length==0)return;
        var type=Context.IsMovie?"movie":"tv";
        await Task.WhenAll(scrapers.Select(async result=>
        {
            result.State=SourceSearchState.Searching;Publish(result);
            NuvioOutcome outcome;
            try{outcome=await NuvioPlugins.Shared.ResolveAsync(result.Source.Scraper!,Context.Request.Title.TmdbId,type,Context.IsMovie?null:Context.StreamSeason,Context.IsMovie?null:Context.StreamEpisode,token);}
            catch(OperationCanceledException){throw;}
            catch(Exception error){outcome=new NuvioOutcome.AppFailure(error.Message);}
            var streams=outcome.ResultStreams;
            var visible=await Task.Run(()=>streams.Where(s=>!StreamLanguageFilter.ShouldHide(s.LanguageHints,[s.DisplayName,s.Url,..s.MetadataHints],result.Source.SourceId,Context.Request.OriginalLanguage,Context.HasAnimeLookupContext)).ToArray(),token);
            result.NuvioStreams=visible;result.HiddenCount=streams.Count-visible.Length;result.NuvioOutcome=outcome;result.State=SourceSearchState.Done;Publish(result);
        }));
    }

    public async Task<(IReadOnlyList<ServiceEpisodeLink> Episodes,string? Href)> EpisodeTargetAsync(JsService service,ServiceSearchItem item,CancellationToken token)
    {
        var episodes=await JsServices.EpisodesAsync(service,item.Href,token);
        if(episodes.Count==0)return (episodes,null);
        if(Context.IsMovie)return (episodes,episodes[0].Href);
        if(!Context.HasEpisode)return (episodes,null);
        var seasons=Seasons(episodes);var index=Context.Request.SeasonNumber!.Value-1;
        if(index>=0&&index<seasons.Count&&seasons[index].FirstOrDefault(e=>e.Number==Context.Request.EpisodeNumber) is {} match)return (episodes,match.Href);
        return (episodes,null);
    }
    public static List<List<ServiceEpisodeLink>> Seasons(IReadOnlyList<ServiceEpisodeLink> episodes)
    {
        var seasons=new List<List<ServiceEpisodeLink>>();var current=new List<ServiceEpisodeLink>();var last=0;
        foreach(var episode in episodes)
        {
            if((episode.Number==1||episode.Number<=last)&&current.Count>0){seasons.Add(current);current=[];}
            current.Add(episode);last=episode.Number;
        }
        if(current.Count>0)seasons.Add(current);
        return seasons;
    }
    public IReadOnlyList<ServiceStreamOption> FilterServiceStreams(IReadOnlyList<ServiceStreamOption> options,JsService service)=>
        options.Where(o=>!StreamLanguageFilter.ShouldHide(o.LanguageHints,[o.Name,o.Url,..o.MetadataHints],service.SourceId,Context.Request.OriginalLanguage,Context.HasAnimeLookupContext)).ToArray();
}
