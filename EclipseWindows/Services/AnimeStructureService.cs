using System.Text.Json;
using Eclipse.Windows.Models;
using static Eclipse.Windows.Services.JsonValue;

namespace Eclipse.Windows.Services;

// No global mapping index, background work, or cache of hydrated image-bearing graphs.
// A details page owns one bounded graph; the shared byte-bounded HTTP caches handle reuse.
public sealed class AnimeStructureService(IProviderJson? transport=null,TmdbService? tmdb=null)
{
    public static AnimeStructureService Shared { get; }=new();
    private readonly IProviderJson _json=transport??ProviderJson.Shared;
    private readonly AnimeMetadataService _metadata=new(transport);
    private readonly TmdbService _tmdb=tmdb??TmdbService.Shared;
    private const string Fields="id idMal isAdult title{english romaji native} format status episodes season seasonYear startDate{year month day} endDate{year month day} coverImage{medium} relations{edges{relationType node{id type format isAdult}}}";

    public async Task<MediaTitle> LoadAsync(MediaTitle title,CancellationToken token,bool refresh=false)
    {
        if(title.MediaType!="tv"||(title.AniListId is null&&title.MalId is null&&title.AnimeMappings.Count==0))return title;
        using var deadline=CancellationTokenSource.CreateLinkedTokenSource(token);deadline.CancelAfter(TimeSpan.FromSeconds(75));var work=deadline.Token;
        var mappings=title.AnimeMappings;var complete=true;var mappingRosterComplete=true;var integrityFailure=false;var nodes=new Dictionary<string,AnimeNode>();var excluded=new HashSet<string>();var notice="";
        var capacityReached=false;var aniListFailed=false;
        void Admit(AnimeNode node)
        {
            if(!nodes.ContainsKey(node.Id)&&nodes.Count>=AnimeReconciliation.MaximumNodes)
            {
                capacityReached=true;
                var selected=title.Provider=="MAL"?node.MalId==title.ProviderId:title.Provider=="AniList"&&node.AniListId==title.ProviderId;
                if(!selected)return;
                var displaced=nodes.LastOrDefault(p=>title.Provider=="MAL"?p.Value.MalId!=title.ProviderId:p.Value.AniListId!=title.ProviderId);
                if(displaced.Value is null)return;
                nodes.Remove(displaced.Key);
            }
            nodes[node.Id]=node;
        }
        try
        {
            if(title.TmdbId>0)
            {
                // The provider-seed lookup is not a complete show roster.
                try
                {
                    mappings=await _metadata.MappingsAsync("tmdb_show",title.TmdbId,work,refresh);
                    mappings=mappings.Where(m=>m.TmdbShowId==title.TmdbId).Concat(title.AnimeMappings.Where(m=>m.TmdbShowId==title.TmdbId)).Distinct().ToArray();
                    if(mappings.Count==0)complete=false;
                }
                catch(ProviderException){mappingRosterComplete=false;complete=false;notice="The anime mapping roster is unavailable. Original provider identities are retained.";}
            }
            var relocated=title.TmdbId>0&&mappingRosterComplete?await RelocatedCandidatesAsync(title,mappings,work,refresh):[];
            var wanted=new[]{title.AniListId??0}.Concat(relocated.Select(r=>r.AniListId!.Value)).Concat(mappings.Where(m=>m.MalId==title.MalId&&title.MalId is not null).Select(m=>m.AniListId??0)).Concat(mappings.Where(m=>m.AniListId is not null).Select(m=>m.AniListId!.Value)).Where(id=>id>0).Distinct().ToArray();
            if(wanted.Length>AnimeReconciliation.MaximumNodes)complete=false;
            var pending=wanted.Take(AnimeReconciliation.MaximumNodes).ToArray();var attempted=new HashSet<int>();
            // Four bounded batches cover mapped identities and direct ordinary continuations.
            for(var batch=0;batch<4&&pending.Length>0;batch++)
            {
                var ids=pending.Where(id=>attempted.Add(id)).Take(40).ToArray();if(ids.Length==0)break;
                try
                {
                    var data=await _metadata.GraphAsync("query($ids:[Int]){Page(page:1,perPage:50){media(id_in:$ids,type:ANIME,isAdult:false){"+Fields+"}}}",new{ids},work,refresh);
                    var raw=Array(Child(data,"Page"),"media").ToArray();
                    if(raw.Length>50||raw.Any(r=>Positive(r,"id") is not{} id||!ids.Contains(id))||raw.Select(r=>Int(r,"id")).Distinct().Count()!=raw.Length){integrityFailure=true;throw new ProviderException("AniList returned an invalid structure inventory.");}
                    foreach(var row in raw)
                    {
                        var node=ParseAniList(row);if(node is null||!ids.Contains(node.AniListId!.Value))continue;
                        Admit(node);
                    }
                    if(ids.Any(id=>!nodes.ContainsKey($"anilist:{id}")))complete=false;
                }
                catch(ProviderException){complete=false;aniListFailed=true;notice="AniList structure is unavailable; using verified MAL identities where possible.";break;}
                var remaining=wanted.Where(id=>!attempted.Contains(id));
                var related=nodes.Values.Where(n=>!n.Upcoming).SelectMany(n=>n.Relations).Where(r=>r.Kind is "PREQUEL" or "SEQUEL" or "SEASON").Select(r=>ParseId(r.Target)).Where(id=>id>0&&!attempted.Contains(id));
                pending=remaining.Concat(related).Distinct().Take(AnimeReconciliation.MaximumNodes-attempted.Count).ToArray();
                if(batch==3&&pending.Length>0)complete=false;
            }
            foreach(var row in relocated)
            {
                if(!nodes.TryGetValue($"anilist:{row.AniListId}",out var node))continue;
                var claimed=mappings.Where(m=>m.TmdbShowId==title.TmdbId).Select(m=>m.TmdbSeason).OfType<int>().ToHashSet();
                int? season=null;
                try{season=await AnimeMetadataService.ProvenSeasonAsync(_tmdb,title,node.StartDate,node.EpisodeCount,node.Titles.Append(node.Title).ToArray(),row.TvdbSeason,claimed,work,refresh);}catch(TmdbException){}
                if(season is not null)mappings=mappings.Append(row with{TmdbShowId=title.TmdbId,TmdbMovieId=null,TmdbSeason=season}).ToArray();
                else{nodes.Remove(node.Id);excluded.Add(node.Id);}
            }
            // A mapped foreign show/film must not be pulled in through a franchise relation.
            var mappedIds=wanted.ToHashSet();var outsiders=nodes.Values.Where(n=>n.AniListId is {} a&&!mappedIds.Contains(a)).ToArray();
            if(outsiders.Length>16){complete=false;foreach(var n in outsiders.Skip(16))nodes.Remove(n.Id);}
            foreach(var node in outsiders.Take(16))
            {
                try
                {
                    var rows=await _metadata.MappingsAsync("anilist",node.AniListId!.Value,work,refresh);
                    if(rows.Any(m=>m.Target is {} target&&target!=$"tv:{title.TmdbId}")){nodes.Remove(node.Id);excluded.Add(node.Id);continue;}
                    mappings=mappings.Concat(rows.Where(m=>m.TmdbShowId==title.TmdbId)).Distinct().ToArray();
                }
                catch(ProviderException){complete=false;mappingRosterComplete=false;}
            }
            var missing=(title.MalId is {} seed&&!nodes.Values.Any(n=>n.MalId==seed)?new[]{seed}:[]).Concat(mappings.Where(m=>m.MalId is not null&&(aniListFailed||m.AniListId is not null)&&!nodes.Values.Any(n=>n.MalId==m.MalId||n.AniListId is not null&&n.AniListId==m.AniListId)).Select(m=>m.MalId!.Value)).Distinct().ToArray();
            if(missing.Length>32)complete=false;
            foreach(var malId in missing.Take(32))
            {
                try
                {
                    var node=await MalNodeAsync(malId,work,refresh);var row=mappings.Where(m=>m.MalId==malId).ToArray();
                    var ani=row.Select(m=>m.AniListId).OfType<int>().Distinct().ToArray();
                    if(ani.Length==1)node=node with{Id=$"anilist:{ani[0]}",AniListId=ani[0]};
                    Admit(node);
                }
                catch(ProviderException){complete=false;}
            }
            var malAttempted=missing.Take(32).ToHashSet();
            var bridges=new Dictionary<int,AnimeNode>();var bridgePending=new Queue<int>();
            while(malAttempted.Count<32)
            {
                var relation=nodes.Values.Where(n=>n.Ordinary&&!n.Upcoming).SelectMany(n=>n.Relations).FirstOrDefault(r=>r.Kind is "PREQUEL" or "SEQUEL" or "SEASON"&&r.Target.StartsWith("mal:",StringComparison.Ordinal)&&!malAttempted.Contains(ParseId(r.Target))&&!nodes.Values.Any(n=>n.MalId==ParseId(r.Target))&&!excluded.Contains(r.Target));
                if(relation is null&&bridgePending.Count==0)break;
                var bridgeOnly=bridgePending.Count>0;var mal=bridgeOnly?bridgePending.Dequeue():ParseId(relation!.Target);if(!malAttempted.Add(mal))continue;
                try
                {
                    var node=await MalNodeAsync(mal,work,refresh);IReadOnlyList<AnimeMapping> rows=[];var mappingAvailable=true;
                    try{rows=await _metadata.MappingsAsync("mal",mal,work,refresh);}
                    catch(ProviderException){mappingAvailable=false;mappingRosterComplete=false;}
                    if(rows.Any(m=>m.Target is{} target&&target!=$"tv:{title.TmdbId}")){excluded.Add(node.Id);continue;}
                    if(!node.Ordinary&&!rows.Any(m=>m.TmdbShowId==title.TmdbId&&m.TmdbSeason is >0))
                    {
                        if(!mappingAvailable){integrityFailure=true;continue;}
                        var opposites=nodes.Values.Select(current=>BridgeOpposite(node,current)).OfType<int>().Distinct().ToArray();
                        if(opposites.Length==1){bridges[mal]=node;if(!malAttempted.Contains(opposites[0]))bridgePending.Enqueue(opposites[0]);}
                        else excluded.Add(node.Id);
                        continue;
                    }
                    mappings=mappings.Concat(rows.Where(m=>m.TmdbShowId==title.TmdbId)).Distinct().ToArray();
                    var ani=rows.Select(m=>m.AniListId).OfType<int>().Distinct().ToArray();if(ani.Length==1)node=node with{Id=$"anilist:{ani[0]}",AniListId=ani[0]};
                    if(nodes.TryGetValue(node.Id,out var existing)&&existing.MalId!=mal){integrityFailure=true;node=node with{Id=$"mal:{mal}"};}
                    if(bridgeOnly)
                    {
                        if(!mappingAvailable){integrityFailure=true;continue;}
                        var verified=false;
                        foreach(var bridge in bridges.Values)
                        {
                            var prequel=nodes.Values.Append(node).Where(n=>n.MalId==BridgeEndpoint(bridge,"PREQUEL")).DistinctBy(n=>n.Id).ToArray();
                            var sequel=nodes.Values.Append(node).Where(n=>n.MalId==BridgeEndpoint(bridge,"SEQUEL")).DistinctBy(n=>n.Id).ToArray();
                            if(prequel.Length!=1||sequel.Length!=1||!VerifiedBridge(bridge,prequel[0],sequel[0]))continue;
                            var before=prequel[0] with{VerifiedBridgeRelations=prequel[0].VerifiedBridgeRelations.Append(new("SEQUEL",sequel[0].Id)).Distinct().ToArray()};
                            var after=sequel[0] with{VerifiedBridgeRelations=sequel[0].VerifiedBridgeRelations.Append(new("PREQUEL",prequel[0].Id)).Distinct().ToArray()};
                            Admit(before);Admit(after);Admit(bridge);verified=true;
                        }
                        if(!verified){integrityFailure=true;excluded.Add(node.Id);}
                        continue;
                    }
                    Admit(node);
                }
                catch(ProviderException){complete=false;}
            }
            // Translate MAL fallback edges into canonical AniList identities only through exact IDs.
            foreach(var key in nodes.Keys.ToArray())nodes[key]=nodes[key] with{Relations=nodes[key].Relations.Select(r=>
            {
                var matches=r.Target.StartsWith("mal:",StringComparison.Ordinal)?nodes.Values.Where(n=>n.MalId==ParseId(r.Target)).Take(2).ToArray():[];
                return matches.Length==1?r with{Target=matches[0].Id}:r;
            }).ToArray()};
            complete=mappingRosterComplete&&!capacityReached&&!integrityFailure&&nodes.Count>0&&mappings.Count>0&&mappings.Where(m=>m.TmdbShowId==title.TmdbId&&(m.AniListId is not null||m.MalId is not null)).All(m=>nodes.Values.Any(n=>(m.AniListId is {} a&&n.AniListId==a)||(m.MalId is {} mal&&n.MalId==mal)))&&
                nodes.Values.All(n=>n.RelationsComplete&&n.Relations.Where(r=>r.Kind is "PREQUEL" or "SEQUEL" or "SEASON").All(r=>nodes.ContainsKey(r.Target)||excluded.Contains(r.Target)||!n.Ordinary));
        }
        catch(OperationCanceledException)when(!token.IsCancellationRequested){complete=false;notice="Anime reconciliation reached its request budget. Unproved coordinates are withheld.";}
        catch(ProviderException){complete=false;notice="The anime mapping roster is unavailable. Original identities are preserved.";}
        token.ThrowIfCancellationRequested();
        var reliable=mappingRosterComplete&&!capacityReached&&!integrityFailure&&nodes.Count>0&&nodes.Values.All(n=>n.RelationsComplete);
        if(nodes.Count==0)return title with{AnimeStructure=AnimeStructure.Empty(notice.Length>0?notice:"No verified anime structure is available."),Seasons=title.Provider is "AniList" or "MAL"?[]:title.Seasons.Select(s=>s with{Name="TMDB · "+s.Name}).ToArray()};
        AnimeStructure structure;
        var counts=SeasonCounts(title);
        if(counts is null)structure=new(AnimeReconciliation.Order(nodes.Values).Select((n,i)=>new AnimeCour(n,null,i+1,n.EpisodeCount,n.Ordinary,null,"Provider episodes; TMDB coordinates unresolved.")).ToArray(),false,"TMDB season inventory is unavailable. Provider episode identities are retained.");
        else structure=AnimeReconciliation.Reconcile(nodes.Values.ToArray(),mappings,counts,title.TmdbId,complete,reliable,RootIdentities(title,nodes.Values));
        if(notice.Length>0)structure=structure with{Notice=notice+" "+structure.Notice};
        return title with{AnimeMappings=mappings,AnimeStructure=structure,TmdbSeasonCounts=counts??new(),TmdbSeasons=title.Seasons,Seasons=structure.Cours.Select(c=>new MediaSeason(c.DisplaySeason,c.Node.Title,c.Count??0){Cour=c}).ToArray()};
    }
    private async Task<IReadOnlyList<AnimeMapping>> RelocatedCandidatesAsync(MediaTitle title,IReadOnlyList<AnimeMapping> mappings,CancellationToken token,bool refresh)
    {
        var claimed=mappings.Select(m=>m.TmdbSeason).OfType<int>().ToHashSet();
        if(!title.Seasons.Any(s=>s.Number>0&&s.Cour is null&&!claimed.Contains(s.Number)))return [];
        var result=new List<AnimeMapping>();
        foreach(var tvdb in mappings.Select(m=>m.TvdbId).OfType<int>().Distinct().Take(2))
        {
            IReadOnlyList<AnimeMapping> siblings;
            try{siblings=await _metadata.MappingsAsync("tvdb",tvdb,token,refresh);}catch(ProviderException){continue;}
            foreach(var row in siblings.Where(m=>m.AniListId is not null&&m.TmdbMovieId is null&&m.TvdbSeason is >0&&m.TmdbShowId!=title.TmdbId&&!mappings.Any(x=>x.AniListId==m.AniListId)).DistinctBy(m=>m.AniListId).Take(4))
            {
                if(row.TmdbShowId is not {} show){result.Add(row);continue;}
                try{await _tmdb.DetailsAsync($"tv:{show}",token,refresh);}
                catch(TmdbException error)when(error.Missing){result.Add(row);}
                catch(TmdbException){}
            }
        }
        return result;
    }
    private static HashSet<string> RootIdentities(MediaTitle title,IEnumerable<AnimeNode> nodes)
    {
        var targets=new[]{title.TmdbRootTitle.Length>0?title.TmdbRootTitle:title.Title,title.OriginalTitle}.Select(AnimeText.Signature).Where(s=>s.Length>0).ToHashSet();
        if(targets.Count==0||title.ReleaseDate.Length<4)return [];
        return nodes.Where(n=>n.Ordinary&&n.StartDate.Length>=4&&n.StartDate[..4]==title.ReleaseDate[..4]&&n.Titles.Append(n.Title).Select(AnimeText.Signature).Any(targets.Contains)).Select(n=>n.Id).ToHashSet();
    }
    private static Dictionary<int,int>? SeasonCounts(MediaTitle title)
    {
        var seasons=title.Seasons.Where(s=>s.Number>0&&s.Cour is null).ToArray();
        if(seasons.Select(s=>s.Number).Distinct().Count()!=seasons.Length)return null;
        var counts=seasons.ToDictionary(s=>s.Number,s=>s.EpisodeCount);
        return AnimeReconciliation.ValidCounts(counts)?counts:null;
    }
    private static int ParseId(string id)=>int.TryParse(id.Split(':').Last(),out var n)&&n is >0 and <=1_000_000_000?n:0;
    private static int? BridgeEndpoint(AnimeNode node,string kind)
    {var edges=node.Relations.Where(r=>r.Kind==kind&&r.Target.StartsWith("mal:",StringComparison.Ordinal)).ToArray();return edges.Length==1&&ParseId(edges[0].Target)>0?ParseId(edges[0].Target):null;}
    private static bool EligibleBridge(AnimeNode node)=>node.MalId is >0&&node.RelationsComplete&&node.Format is "SPECIAL" or "OVA" or "OAD"&&node.Finished&&node.EpisodeCount==1&&
        AnimeReconciliation.Day(node.StartDate) is{} start&&AnimeReconciliation.Day(node.EndDate) is{} end&&start<=end&&BridgeEndpoint(node,"PREQUEL") is{} prior&&BridgeEndpoint(node,"SEQUEL") is{} next&&prior!=next&&prior!=node.MalId&&next!=node.MalId;
    private static int? BridgeOpposite(AnimeNode bridge,AnimeNode current)
    {
        if(!EligibleBridge(bridge)||!current.Ordinary||!AnimeReconciliation.Count(current.EpisodeCount)||current.MalId is not{} id)return null;
        if(BridgeEndpoint(bridge,"PREQUEL")==id&&current.Relations.Any(r=>r.Kind=="SEQUEL"&&r.Target==$"mal:{bridge.MalId}"))return BridgeEndpoint(bridge,"SEQUEL");
        if(BridgeEndpoint(bridge,"SEQUEL")==id&&current.Relations.Any(r=>r.Kind=="PREQUEL"&&r.Target==$"mal:{bridge.MalId}"))return BridgeEndpoint(bridge,"PREQUEL");return null;
    }
    private static bool VerifiedBridge(AnimeNode bridge,AnimeNode prior,AnimeNode next)=>EligibleBridge(bridge)&&prior.Ordinary&&next.Ordinary&&AnimeReconciliation.Count(prior.EpisodeCount)&&AnimeReconciliation.Count(next.EpisodeCount)&&
        BridgeOpposite(bridge,prior)==next.MalId&&BridgeOpposite(bridge,next)==prior.MalId&&prior.Relations.Count(r=>r.Kind=="SEQUEL"&&r.Target==$"mal:{bridge.MalId}")==1&&next.Relations.Count(r=>r.Kind=="PREQUEL"&&r.Target==$"mal:{bridge.MalId}")==1&&
        AnimeReconciliation.Day(prior.EndDate) is{} end&&AnimeReconciliation.Day(next.StartDate) is{} start&&end<=AnimeReconciliation.Day(bridge.StartDate)&&AnimeReconciliation.Day(bridge.EndDate)<=start;
    public static AnimeNode? ParseAniList(JsonElement row)
    {
        if(Positive(row,"id") is not {} id||Bool(row,"isAdult"))return null;
        var names=Child(row,"title");var aliases=new[]{Text(names,"english"),Text(names,"romaji"),Text(names,"native")}.Where(s=>s.Length>0).ToArray();if(aliases.Length==0)return null;
        var count=Int(row,"episodes");if(Child(row,"episodes").ValueKind is not (JsonValueKind.Null or JsonValueKind.Undefined)&&!AnimeReconciliation.Count(count))return null;
        var edges=Array(Child(row,"relations"),"edges").ToArray();if(edges.Length>512)return null;
        var relationIntegrity=edges.All(e=>Text(e,"relationType") is not ("PREQUEL" or "SEQUEL" or "SEASON")||
            Text(Child(e,"node"),"type")=="MANGA"||Bool(Child(e,"node"),"isAdult")||
            Positive(Child(e,"node"),"id") is not null&&Text(Child(e,"node"),"type")=="ANIME");
        var relations=edges.Where(e=>Text(Child(e,"node"),"type")=="ANIME"&&!Bool(Child(e,"node"),"isAdult")&&Positive(Child(e,"node"),"id") is not null)
            .Where(e=>Text(e,"relationType") is not ("PREQUEL" or "SEQUEL" or "SEASON")||Text(Child(e,"node"),"format") is "" or "TV" or "TV_SHORT" or "ONA" or "SPECIAL" or "OVA" or "OAD")
            .Select(e=>new AnimeRelation(Text(e,"relationType"),$"anilist:{Int(Child(e,"node"),"id")}")).Distinct().ToArray();
        var season=Text(row,"season");var year=Int(row,"seasonYear");
        return new($"anilist:{id}",id,Positive(row,"idMal"),aliases[0],Text(row,"format"),Text(row,"status"),count>0?count:null,Date(Child(row,"startDate")),Date(Child(row,"endDate")),relations)
            {Titles=aliases,Cover=Text(Child(row,"coverImage"),"medium"),RelationsComplete=relationIntegrity&&Child(Child(row,"relations"),"edges").ValueKind==JsonValueKind.Array,SeasonYear=year is >=1800 and <=3000?year:null,SeasonOrdinal=season switch{"WINTER"=>0,"SPRING"=>1,"SUMMER"=>2,"FALL"=>3,_=>4}};
    }
    private static string Date(JsonElement date)
    {
        var year=Int(date,"year");var month=Int(date,"month");var day=Int(date,"day");if(year is <1800 or >3000)return "";
        var text=$"{year:D4}";if(month is >=1 and <=12){text+=$"-{month:D2}";if(day>=1&&day<=DateTime.DaysInMonth(year,month))text+=$"-{day:D2}";}return text;
    }
    private async Task<AnimeNode> MalNodeAsync(int id,CancellationToken token,bool refresh)
    {
        var key=LocalCredentials.Read("MalClientId");if(key.Length==0)throw new ProviderException("MyAnimeList is not configured on this device.");
        var row=await _json.FetchAsync($"https://api.myanimelist.net/v2/anime/{id}?fields=id,title,alternative_titles,media_type,status,num_episodes,start_date,end_date,start_season,related_anime,nsfw,genres",token,headers:new(){["X-MAL-CLIENT-ID"]=key},refresh:refresh);
        if(Int(row,"id")!=id||Text(row,"nsfw")=="black"||Array(row,"genres").Any(g=>Int(g,"id") is 12 or 49))throw new ProviderException("MAL returned an invalid anime identity.");
        var count=Int(row,"num_episodes");var rawCount=Child(row,"num_episodes");
        if(rawCount.ValueKind is not (JsonValueKind.Undefined or JsonValueKind.Null)&&(rawCount.ValueKind!=JsonValueKind.Number||!rawCount.TryGetInt32(out count)||count<0||count>AnimeReconciliation.MaximumEpisodes))throw new ProviderException("MAL returned an invalid episode count.");
        var rawRelations=Array(row,"related_anime").ToArray();if(rawRelations.Length>512)throw new ProviderException("MAL returned too many relation identities.");
        var relationIntegrity=rawRelations.All(r=>Text(r,"relation_type").ToUpperInvariant() is not ("PREQUEL" or "SEQUEL" or "SEASON")||Positive(Child(r,"node"),"id") is not null);
        var relations=rawRelations.Where(r=>Positive(Child(r,"node"),"id") is not null).Select(r=>new AnimeRelation(Text(r,"relation_type").ToUpperInvariant(),$"mal:{Int(Child(r,"node"),"id")}")).ToArray();
        return new($"mal:{id}",null,id,Text(row,"title"),Text(row,"media_type").ToUpperInvariant(),Text(row,"status").ToUpperInvariant(),count>0?count:null,Text(row,"start_date"),Text(row,"end_date"),relations)
            {RelationsComplete=relationIntegrity&&Child(row,"related_anime").ValueKind==JsonValueKind.Array,Titles=new[]{Text(row,"title"),Text(Child(row,"alternative_titles"),"en"),Text(Child(row,"alternative_titles"),"ja")}.Where(s=>s.Length>0).ToArray()};
    }
    public async Task<IReadOnlyList<MediaEpisode>> EpisodesAsync(MediaTitle title,MediaSeason season,CancellationToken token,bool refresh=false)
    {
        if(season.Cour is not {} cour)return await _metadata.EpisodesAsync(title,season.Number,token,refresh);
        if(cour.Node.Upcoming)return [];
        if(cour.HasIdentityConflict)return AnimeReconciliation.Project(cour,null);
        var structure=title.AnimeStructure!;var counts=title.TmdbSeasonCounts;
        if(title.TmdbId<=0||counts.Count==0)return AnimeReconciliation.Project(cour,null);
        using var deadline=CancellationTokenSource.CreateLinkedTokenSource(token);deadline.CancelAfter(TimeSpan.FromSeconds(45));var work=deadline.Token;
        var inventories=new Dictionary<int,SeasonInventory>();
        async Task<SeasonInventory?> Fetch(int number)
        {
            if(inventories.TryGetValue(number,out var cached))return cached;
            var result=await _tmdb.SeasonInventoryAsync(title.TmdbId,number,work,refresh);inventories[number]=result;return result;
        }
        try
        {
            var unit=await AnimeEpisodeUnits.TryHydrateAsync(title,cour,structure.Cours,Fetch,_tmdb,work);
            if(unit.Handled)return HasUniqueOwnership(cour,unit.Episodes,structure,inventories,counts)?unit.Episodes:AnimeReconciliation.Project(cour,null);
            if(cour.AbsoluteStart is {} absolute&&AnimeReconciliation.Count(cour.Count))
            {
                var target=new List<MediaEpisode>();var cursor=1;var all=new List<MediaEpisode>();var verified=true;
                foreach(var (number,count) in counts.OrderBy(p=>p.Key))
                {
                    var needed=cour.RequiresAbsoluteInventory||(absolute<cursor+count&&absolute+cour.Count>cursor);
                    if(needed)
                    {
                        var inventory=(await Fetch(number))!;
                        if(!AnimeReconciliation.ValidInventory(inventory,count,!cour.RequiresAbsoluteInventory)){verified=false;break;}
                        var rows=inventory.Episodes.OrderBy(e=>e.TmdbEpisodeNumber).ToArray();all.AddRange(rows);
                        target.AddRange(rows.Where((_,index)=>cursor+index>=absolute&&cursor+index<absolute+cour.Count));
                    }
                    cursor+=count;
                }
                if(cour.RequiresAbsoluteInventory)
                {
                    var root=structure.Cours.FirstOrDefault(c=>c.Regular);var ordered=all.OrderBy(e=>e.TmdbSeasonNumber).ThenBy(e=>e.TmdbEpisodeNumber).ToArray();
                    verified&=ordered.Length==counts.Values.Sum()&&ordered.Select(e=>e.SourceEpisodeId).Distinct().Count()==ordered.Length&&ordered.Length>0&&AnimeReconciliation.Day(root?.Node.StartDate) is {} start&&AnimeReconciliation.Day(ordered[0].AirDate)==start&&ordered.All(e=>AnimeReconciliation.Day(e.AirDate) is not null)&&ordered.Zip(ordered.Skip(1)).All(p=>AnimeReconciliation.Day(p.First.AirDate)<=AnimeReconciliation.Day(p.Second.AirDate));
                    if(structure.Cours.Any(c=>c.Node.VerifiedBridgeRelations.Count>0))
                    {
                        // AnimeMALFallbackRelationPolicy.allowsVerifiedBridgeLinearInventory.
                        var regular=structure.Cours.Where(c=>c.Regular).ToArray();var active=regular.TakeWhile(c=>!c.Node.Upcoming).ToArray();
                        var starts=active.Select(c=>AnimeReconciliation.Day(c.Node.StartDate)).ToArray();
                        var targets=new[]{title.TmdbRootTitle.Length>0?title.TmdbRootTitle:title.Title,title.OriginalTitle}.Select(AnimeText.Signature).Where(s=>s.Length>0).ToHashSet();
                        var exactRoot=starts.FirstOrDefault() is{} rootStart&&title.ReleaseDate.Length>=4&&int.TryParse(title.ReleaseDate[..4],out var rootYear)&&rootStart.Year==rootYear&&active[0].Node.Titles.Append(active[0].Node.Title).Select(AnimeText.Signature).Any(targets.Contains);
                        verified&=structure.Complete&&exactRoot&&regular.All(c=>c.Node.Format=="TV")&&AnimeReconciliation.HasReciprocalChain(regular)&&active.Length>0&&regular.Skip(active.Length).All(c=>c.Node.Upcoming)&&
                            active.All(c=>c.Node.Finished&&AnimeReconciliation.Count(c.Count))&&active.Sum(c=>(long)(c.Count??0))==ordered.Length&&starts.All(d=>d is not null)&&starts.Zip(starts.Skip(1)).All(p=>p.First<=p.Second)&&
                            counts.All(p=>inventories.TryGetValue(p.Key,out var inventory)&&AnimeReconciliation.ValidInventory(inventory,p.Value));
                    }
                }
                if(verified&&target.Count==cour.Count&&target.Select(e=>e.SourceEpisodeId).Distinct().Count()==target.Count&&HasUniqueOwnership(cour,target,structure,inventories,counts))return AnimeReconciliation.Project(cour,target);
            }
            var ordinary=structure.Cours.Where(c=>c.Regular).ToArray();
            if(structure.Complete&&ordinary.LastOrDefault()?.Id==cour.Id&&AnimeEpisodeProofs.TerminalSeasonNumber(ordinary,counts) is{} terminal&&await Fetch(terminal) is{} terminalSource&&AnimeEpisodeProofs.TerminalUnknown(ordinary,counts,terminalSource,DateOnly.FromDateTime(DateTime.Now)) is{} terminalRows&&HasUniqueOwnership(cour,terminalRows,structure,inventories,counts))return AnimeReconciliation.Project(cour,terminalRows);
            var candidateSeason=cour.Mapping?.TmdbSeason??(cour.Regular&&counts.Count==1?counts.Keys.Single():cour.Regular?-1:0);
            if(candidateSeason<0)
            {
                var named=title.TmdbSeasons.Where(s=>s.Number>0&&AnimeText.Signature(s.Name).Length>=8&&cour.Node.Titles.Append(cour.Node.Title).Any(t=>AnimeText.Signature(t).StartsWith(AnimeText.Signature(s.Name),StringComparison.Ordinal))).ToArray();
                if(named.Length==1)candidateSeason=named[0].Number;
            }
            var parents=structure.Cours.Where(c=>c.Regular&&c.Node.Relations.Any(r=>r.Kind=="SEQUEL"&&r.Target==cour.Id)).ToArray();
            if(!cour.Regular&&parents.Length==1&&parents[0].Mapping?.TmdbSeason is >0)candidateSeason=parents[0].Mapping!.TmdbSeason!.Value;
            if(candidateSeason>=0)
            {
                var inventory=(await Fetch(candidateSeason))!;var placements=new Dictionary<string,IReadOnlyList<MediaEpisode>>();
                foreach(var candidate in structure.Cours.Where(c=>c.Mapping?.TmdbSeason==candidateSeason||c.Mapping?.TmdbSeason is null&&(!c.Regular&&candidateSeason==0||c.Regular&&counts.Count==1)))
                {
                    var proof=candidate.Regular?ContainedPlacement(candidate,inventory,counts.GetValueOrDefault(candidateSeason),structure,title.TmdbId):AnimeReconciliation.SpecialWindow(candidate,inventory);
                    if(proof is not null)placements[candidate.Id]=proof;
                }
                foreach(var (owner,proof) in AnimeEpisodeProofs.GroupedCours(structure.Cours,inventory,counts.GetValueOrDefault(candidateSeason)))placements[owner]=proof;
                if(counts.Count==1&&counts.TryGetValue(candidateSeason,out var single))foreach(var (owner,proof) in AnimeEpisodeProofs.OngoingPrefix(structure.Cours.Where(c=>c.Regular).ToArray(),inventory,single,DateOnly.FromDateTime(DateTime.Now),structure.Complete))placements[owner]=proof;
                if(!cour.Regular&&AnimeEpisodeProofs.SpecialContinuation(cour,parents,inventory,title.TmdbId) is{} continuation)placements[cour.Id]=continuation;
                var nextSeason=counts.Keys.Where(s=>s>candidateSeason).Order().FirstOrDefault();
                if(cour.Regular&&nextSeason>0&&counts.ContainsKey(candidateSeason)&&cour.Node.Finished&&cour.Node.Titles.Append(cour.Node.Title).Any(t=>AnimeText.Signature(t)==AnimeText.Signature(inventory.Name)))
                {
                    var successors=structure.Cours.Where(c=>cour.Node.Relations.Any(r=>r.Kind is "SEQUEL" or "SEASON"&&r.Target==c.Id)&&c.Node.Relations.Any(r=>r.Kind=="PREQUEL"&&r.Target==cour.Id)).ToArray();
                    if(successors.Length==1&&await Fetch(nextSeason) is{} following&&AnimeEpisodeProofs.WholeCourWithSuccessor(cour,successors[0],inventory,counts[candidateSeason],following,counts[nextSeason],structure.Cours) is{} whole)placements[cour.Id]=whole;
                }
                if(cour.Regular&&cour.Count is{} declared&&counts.TryGetValue(candidateSeason,out var expected)&&declared>expected&&declared-expected<=8&&await Fetch(0) is{} special)
                {
                    var proof=AnimeEpisodeProofs.EpisodeZero(title.TmdbId,cour,inventory,special)??AnimeEpisodeProofs.NumberedArc(cour,inventory,expected,special);
                    if(proof is null&&cour.Node.AniListId is{} id&&cour.Node.Finished)
                    {
                        var data=await _metadata.GraphAsync("query($id:Int!){Media(id:$id,type:ANIME){id streamingEpisodes{title}}}",new{id},work,refresh);var media=Child(data,"Media");
                        if(Int(media,"id")==id){var titles=Array(media,"streamingEpisodes").Take(AnimeReconciliation.MaximumEpisodes+1).Select(e=>Text(e,"title")).ToArray();proof=AnimeEpisodeProofs.EpisodeList(cour,inventory,expected,special,titles);}
                    }
                    if(proof is not null)placements[cour.Id]=proof;
                }
                var safe=AnimeReconciliation.NonConflicting(placements);if(safe.TryGetValue(cour.Id,out var own)&&HasUniqueOwnership(cour,own,structure,inventories,counts))return AnimeReconciliation.Project(cour,own);
                var prologue=await PrologueAsync(cour,structure,inventory,counts,Fetch);if(prologue is not null&&HasUniqueOwnership(cour,prologue,structure,inventories,counts))return AnimeReconciliation.Project(cour,prologue);
            }
        }
        catch(OperationCanceledException)when(!token.IsCancellationRequested){}
        catch(Exception error)when(error is TmdbException or ProviderException){}
        token.ThrowIfCancellationRequested();return AnimeReconciliation.Project(cour,null);
    }
    private static IReadOnlyList<MediaEpisode>? ContainedPlacement(AnimeCour cour,SeasonInventory source,int expected,AnimeStructure structure,int showId)
    {
        var continuation=structure.Cours.Where(c=>c.Node.Format=="SPECIAL"&&cour.Node.Relations.Any(r=>r.Kind=="SEQUEL"&&r.Target==c.Id)).Any(special=>
        {
            var parents=structure.Cours.Where(c=>c.Regular&&c.Node.Relations.Any(r=>r.Kind=="SEQUEL"&&r.Target==special.Id)).ToArray();
            return AnimeEpisodeProofs.SpecialContinuation(special,parents,source,showId) is not null;
        });
        var namedWhole=cour.Count==expected&&AnimeText.Signature(source.Name).Length>=8&&cour.Node.Titles.Append(cour.Node.Title).Any(t=>AnimeText.Signature(t)==AnimeText.Signature(source.Name));
        return AnimeReconciliation.ContainedCour(cour,source,expected,continuation||namedWhole,continuation);
    }
    private static bool HasUniqueOwnership(AnimeCour selected,IReadOnlyList<MediaEpisode> proof,AnimeStructure structure,IReadOnlyDictionary<int,SeasonInventory> inventories,IReadOnlyDictionary<int,int> counts)
    {
        if(proof.Count==0||proof.All(e=>e.TmdbEpisodeNumber is null))return true;
        var placements=new Dictionary<string,IReadOnlyList<MediaEpisode>>{{selected.Id,proof}};
        foreach(var other in structure.Cours.Where(c=>c.Id!=selected.Id&&!c.Node.Upcoming&&!c.HasIdentityConflict))
        {
            var rows=new List<MediaEpisode>();var cursor=1;
            foreach(var (season,count) in counts.OrderBy(p=>p.Key))
            {
                if(inventories.TryGetValue(season,out var source)&&other.AbsoluteStart is {} start&&AnimeReconciliation.Count(other.Count)&&AnimeReconciliation.ValidInventory(source,count))
                    rows.AddRange(source.Episodes.OrderBy(e=>e.TmdbEpisodeNumber).Where((_,index)=>cursor+index>=start&&cursor+index<start+other.Count));
                cursor+=count;
            }
            if(rows.Count==other.Count&&rows.Count>0)placements[other.Id]=rows;
            else foreach(var source in inventories.Values)
            {
                if(other.Mapping?.TmdbSeason is {} mapped&&mapped!=source.Number||!other.Regular&&source.Number!=(other.Mapping?.TmdbSeason??0))continue;
                var candidate=other.Regular?ContainedPlacement(other,source,counts.GetValueOrDefault(source.Number),structure,other.Mapping?.TmdbShowId??selected.Mapping?.TmdbShowId??0):AnimeReconciliation.SpecialWindow(other,source);
                if(other.Regular&&inventories.TryGetValue(0,out var specials)&&counts.TryGetValue(source.Number,out var expected))
                    candidate??=AnimeEpisodeProofs.EpisodeZero(other.Mapping?.TmdbShowId??0,other,source,specials)??AnimeEpisodeProofs.NumberedArc(other,source,expected,specials);
                if(!other.Regular)
                {
                    var parents=structure.Cours.Where(c=>c.Regular&&c.Node.Relations.Any(r=>r.Kind=="SEQUEL"&&r.Target==other.Id)).ToArray();
                    candidate??=AnimeEpisodeProofs.SpecialContinuation(other,parents,source,other.Mapping?.TmdbShowId??parents.FirstOrDefault()?.Mapping?.TmdbShowId??0);
                }
                if(candidate is null&&other.Regular&&selected.Regular&&other.Node.Finished&&other.Count==selected.Count&&other.Node.StartDate.Length>0&&other.Node.EndDate.Length>0&&other.Node.StartDate==selected.Node.StartDate&&other.Node.EndDate==selected.Node.EndDate&&other.Mapping?.TmdbSeason==selected.Mapping?.TmdbSeason)
                    return false; // Two equally eligible owners cannot gain authority from a single catalog's episode list.
                if(candidate is not null)placements[other.Id]=candidate;
            }
        }
        return AnimeReconciliation.NonConflicting(placements).ContainsKey(selected.Id);
    }
    private static async Task<IReadOnlyList<MediaEpisode>?> PrologueAsync(AnimeCour selected,AnimeStructure structure,SeasonInventory source,IReadOnlyDictionary<int,int> counts,Func<int,Task<SeasonInventory?>> fetch)
    {
        if(!structure.Complete||!counts.TryGetValue(source.Number,out var expected)||!AnimeReconciliation.ValidInventory(source,expected))return null;
        var group=structure.Cours.Where(c=>c.Regular&&c.Mapping?.TmdbSeason==source.Number).ToArray();
        if(group.Length==0||group.Any(c=>!c.Node.Finished||!AnimeReconciliation.Count(c.Count))||group.Sum(c=>c.Count)!=expected+1)return null;
        var rows=source.Episodes.OrderBy(e=>e.TmdbEpisodeNumber).ToArray();var first=AnimeReconciliation.Day(group[0].Node.StartDate);var actual=AnimeReconciliation.Day(rows[0].AirDate);
        if(first is null||actual is null||actual.Value.DayNumber-first.Value.DayNumber is <1 or >14)return null;
        var position=group[0].Count!.Value;
        foreach(var next in group.Skip(1)){if(position-1>=rows.Length||AnimeReconciliation.Day(next.Node.StartDate) is not {} date||AnimeReconciliation.Day(rows[position-1].AirDate)!=date)return null;position+=next.Count!.Value;}
        var specials=await fetch(0);if(specials is null||!AnimeReconciliation.ValidInventory(specials,specials.Episodes.Count,false))return null;
        var matches=specials.Episodes.Where(e=>AnimeReconciliation.Day(e.AirDate)==first).ToArray();if(matches.Length!=1||rows.Any(e=>e.SourceEpisodeId==matches[0].SourceEpisodeId))return null;
        var inventory=new[]{matches[0]}.Concat(rows).ToArray();var offset=0;
        foreach(var c in group){if(c.Id==selected.Id)return inventory.Skip(offset).Take(c.Count!.Value).ToArray();offset+=c.Count!.Value;}return null;
    }
}
