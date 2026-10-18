using System.Globalization;
using System.Text.Json;
using Eclipse.Windows.Models;
using static Eclipse.Windows.Services.JsonValue;

namespace Eclipse.Windows.Services;

public sealed class ScheduleService(IProviderJson? transport=null)
{
    public static ScheduleService Shared { get; }=new();
    private readonly IProviderJson _json=transport ?? ProviderJson.Shared;
    private readonly Dictionary<string,(DateTime fetched,ScheduleResult result)> _cache=[];
    private readonly object _cacheGate=new();
    public async Task<ScheduleResult> LoadAsync(string mode,int days,CancellationToken token,bool refresh=false)
    {
        if(mode is not ("anime" or "western" or "combined") || !new[] {7,14,21,30}.Contains(days)) throw new ArgumentException("Invalid schedule range");
        var window=ScheduleDates.Envelope(DateTimeOffset.UtcNow,days,TimeZoneInfo.Local);
        var key=$"{mode}:{days}:{window.Start:O}:{window.End:O}:{TimeZoneInfo.Local.Id}";
        lock(_cacheGate)if(!refresh && _cache.TryGetValue(key,out var hit) && hit.fetched>DateTime.UtcNow.AddMinutes(-10)) return hit.result;
        var all=new List<ScheduleEntry>(); var notices=new List<string>(); var successful=0;
        // Each source is independent. A failed provider must not discard a successful half.
        foreach(var source in mode=="combined" ? new[] {"anime","western"} : new[] {mode})
        {
            token.ThrowIfCancellationRequested();
            try
            {
                var result=source=="anime" ? await AnimeAsync(window,token,refresh) : await WesternAsync(window,token,refresh);
                all.AddRange(result.Entries); if(result.Notice.Length>0) notices.Add(result.Notice); ++successful;
            }
            catch(ProviderException error) { notices.Add($"{(source=="anime" ? "Anime" : "Western")}: {error.Message}"); }
        }
        token.ThrowIfCancellationRequested();
        if(successful==0) throw new ProviderException(string.Join(" ",notices));
        var filtered=all.Where(e=>e.AiringAt>=window.Start && e.AiringAt<window.End).DistinctBy(e=>e.Id).OrderBy(e=>e.AiringAt).ToArray();
        if(filtered.Length>2000) notices.Add("Showing the first 2,000 airing entries. Use a shorter date range to see a complete calendar.");
        var final=new ScheduleResult(filtered.Take(2000).ToArray(),string.Join(" ",notices));
        // Only complete success is reusable as a calendar result; a partial failure can be retried.
        if(successful==(mode=="combined" ? 2 : 1) && notices.Count==0)
        {lock(_cacheGate){if(_cache.Count>=4&&!_cache.ContainsKey(key)) _cache.Remove(_cache.MinBy(x=>x.Value.fetched).Key); _cache[key]=(DateTime.UtcNow,final);}}
        return final;
    }
    private async Task<ScheduleResult> AnimeAsync((DateTimeOffset Start,DateTimeOffset End) window,CancellationToken token,bool refresh)
    {
        try
        {
            var entries=new List<ScheduleEntry>(); var hasNext=false;
            for(var page=1;page<=20;page++)
            {
                const string query="query($page:Int!,$start:Int!,$end:Int!){Page(page:$page,perPage:50){pageInfo{hasNextPage} airingSchedules(airingAt_greater:$start,airingAt_lesser:$end,sort:TIME){id airingAt episode media{id idMal isAdult format title{english romaji native} coverImage{medium}}}}}";
                var raw=await _json.FetchAsync("https://graphql.anilist.co",token,JsonSerializer.Serialize(new {query,variables=new {page,start=window.Start.ToUnixTimeSeconds()-1,end=window.End.ToUnixTimeSeconds()}}),refresh:refresh);
                if(Array(raw,"errors").Any()) throw new ProviderException("AniList could not load the airing calendar.");
                var data=Child(Child(raw,"data"),"Page");
                if(data.ValueKind!=JsonValueKind.Object || Child(data,"airingSchedules").ValueKind!=JsonValueKind.Array) throw new ProviderException("AniList returned an invalid calendar.");
                foreach(var item in Array(data,"airingSchedules"))
                {
                    var media=Child(item,"media"); if(Bool(media,"isAdult") || Positive(media,"id") is not { } id || Int(item,"episode")<=0) continue;
                    var timestamp=Double(item,"airingAt"); if(timestamp<0 || timestamp>7258118400) continue;
                    var names=Child(media,"title"); var title=Text(names,"english"); if(title.Length==0) title=Text(names,"romaji");
                    if(title.Length==0) continue;
                    entries.Add(new($"anime:{id}:{Int(item,"episode")}","Anime","AniList",id,title,DateTimeOffset.FromUnixTimeSeconds((long)timestamp),Int(item,"episode"),Cover:Text(Child(media,"coverImage"),"medium"),MalId:Positive(media,"idMal")));
                }
                hasNext=Bool(Child(data,"pageInfo"),"hasNextPage"); if(!hasNext) break;
                await Task.Delay(450,token);
            }
            return new(entries,hasNext ? "AniList's page limit was reached; this calendar may be incomplete." : "");
        }
        catch(ProviderException)
        {
            token.ThrowIfCancellationRequested();
            try { return await AnimeScheduleAsync(window,token,refresh); }
            catch(ProviderException) { token.ThrowIfCancellationRequested(); return await MalEstimatesAsync(window,token,refresh); }
        }
    }
    private async Task<ScheduleResult> AnimeScheduleAsync((DateTimeOffset Start,DateTimeOffset End) window,CancellationToken token,bool refresh)
    {
        var credential=LocalCredentials.Read("AnimeScheduleApiToken");if(credential.Length==0)throw new ProviderException("AnimeSchedule is not configured.");
        var headers=new Dictionary<string,string>{["Authorization"]="Bearer "+credential};
        using var budget=CancellationTokenSource.CreateLinkedTokenSource(token);budget.CancelAfter(TimeSpan.FromSeconds(45));
        var rows=new List<JsonElement>();var weeks=new HashSet<string>();var metadata=new Dictionary<string,JsonElement>();var complete=true;
        async Task<JsonElement> Request(string path)
        {await Task.Delay(550,budget.Token);return await _json.FetchAsync("https://animeschedule.net/api/v3/"+path,budget.Token,headers:headers,refresh:refresh);}
        try
        {
            for(var date=window.Start.UtcDateTime.Date;date<window.End.UtcDateTime;date=date.AddDays(1))
            {
                var week=$"{ISOWeek.GetYear(date)}:{ISOWeek.GetWeekOfYear(date)}";if(!weeks.Add(week))continue;
                try
                {
                    var raw=await Request($"timetables/raw?year={ISOWeek.GetYear(date)}&week={ISOWeek.GetWeekOfYear(date)}&tz=UTC");
                    if(raw.ValueKind!=JsonValueKind.Array||raw.GetArrayLength()>2000)throw new ProviderException("AnimeSchedule returned an invalid timetable.");
                    rows.AddRange(Items(raw).Where(row=>Text(row,"airType")=="raw"&&ValidRoute(Text(row,"route"))&&DateTimeOffset.TryParse(Text(row,"episodeDate"),out var air)&&air>=window.Start&&air<window.End));
                }
                catch(ProviderException){complete=false;}
            }
            var wanted=rows.Select(r=>Text(r,"route")).Distinct().ToHashSet();
            // Reuse one ongoing metadata page for many timetable entries before point lookups.
            if(wanted.Count>0)
            {
                try
                {
                    for(var page=1;page<=32;page++)
                    {
                        var data=await Request($"anime?airing-statuses=ongoing&page={page}");var anime=Array(data,"anime").ToArray();
                        if(Int(data,"page")!=page||anime.Length>18||Int(data,"totalAmount") is <0 or >10000)throw new ProviderException("AnimeSchedule returned invalid catalog metadata.");
                        foreach(var item in anime){var route=Text(item,"route");if(wanted.Contains(route))metadata[route]=item;}
                        if(metadata.Count==wanted.Count||page*18>=Int(data,"totalAmount")||anime.Length==0)break;
                    }
                }
                catch(ProviderException){complete=false;}
                foreach(var route in wanted.Where(r=>!metadata.ContainsKey(r)).Take(80))
                {
                    try{var data=await Request("anime/"+route);if(Text(data,"route")!=route)throw new ProviderException("AnimeSchedule returned a different identity.");metadata[route]=data;}
                    catch(ProviderException){complete=false;}
                }
                if(wanted.Any(r=>!metadata.ContainsKey(r)))complete=false;
            }
        }
        catch(OperationCanceledException)when(!token.IsCancellationRequested){complete=false;}
        token.ThrowIfCancellationRequested();
        var result=new List<ScheduleEntry>();
        foreach(var row in rows)
        {
            var route=Text(row,"route");if(!metadata.TryGetValue(route,out var anime)||IsAdultSchedule(anime))continue;
            var ids=ScheduleIds(anime);if(ids.AniList is null&&ids.Mal is null){complete=false;continue;}
            var title=Text(row,"english");if(title.Length==0)title=Text(row,"title");if(title.Length==0)continue;
            if(!DateTimeOffset.TryParse(Text(row,"episodeDate"),out var airing))continue;
            var last=Int(row,"episodeNumber");var first=Int(row,"subtractedEpisodeNumber");if(first==0)first=last;
            if(first<=0||last<first||last-first>=200||last>100000){complete=false;continue;}
            var delayed=Text(row,"airingStatus").StartsWith("delayed",StringComparison.OrdinalIgnoreCase)||DateTimeOffset.TryParse(Text(row,"delayedFrom"),out var delayedFrom)&&airing>=delayedFrom&&(!DateTimeOffset.TryParse(Text(row,"delayedUntil"),out var delayedUntil)||airing<delayedUntil);
            for(var ep=first;ep<=last;ep++)result.Add(new($"animeschedule:{route}:{ep}","Anime",ids.AniList is not null?"AniList":"MAL",ids.AniList??ids.Mal!.Value,title,airing,ep,MalId:ids.Mal,KnownTime:!delayed,Route:route,TimetableProvider:"AnimeSchedule"));
        }
        if(result.Count==0&&!complete)throw new ProviderException("AnimeSchedule could not provide verified calendar identities.");
        return new(result,"AniList is unavailable. Schedule provided by AnimeSchedule.net."+(complete?"":" Some dates or shows are unavailable."));
    }
    public static bool ValidRoute(string route)=>route.Length is >0 and <=200&&route.All(c=>char.IsAsciiLetterLower(c)||char.IsAsciiDigit(c)||c=='-');
    private static bool IsAdultSchedule(JsonElement anime)=>Array(anime,"genres").Any(g=>Text(g,"route").ToLowerInvariant() is "hentai" or "adult" or "erotica");
    private static (int? AniList,int? Mal) ScheduleIds(JsonElement anime)
    {
        var sites=Child(anime,"websites");
        static int? Read(string value,string host)
        {
            if(!Uri.TryCreate(value,UriKind.Absolute,out var uri)||uri.Scheme is not ("https" or "http")||uri.UserInfo.Length>0||uri.Host!=host&&uri.Host!="www."+host)return null;
            var p=uri.AbsolutePath.Split('/',StringSplitOptions.RemoveEmptyEntries);return p.Length>=2&&p[0]=="anime"&&int.TryParse(p[1],out var id)&&id is >0 and <=1_000_000_000?id:null;
        }
        return(Read(Text(sites,"aniList"),"anilist.co"),Read(Text(sites,"mal"),"myanimelist.net"));
    }
    public Task<string?> ResolveAsync(ScheduleEntry entry,CancellationToken token)
    {token.ThrowIfCancellationRequested();return Task.FromResult<string?>(entry.TitleId.Length>0?entry.TitleId:null);}
    private async Task<ScheduleResult> MalEstimatesAsync((DateTimeOffset Start,DateTimeOffset End) window,CancellationToken token,bool refresh)
    {
        var credential=LocalCredentials.Read("MalClientId"); if(credential.Length==0) throw new ProviderException("Anime calendar providers are unavailable. MyAnimeList fallback is not configured.");
        var now=DateTime.UtcNow; var quarter=(now.Month-1)/3; var seasonNames=new[] {"winter","spring","summer","fall"};
        var result=new List<ScheduleEntry>(); var tokyo=TimeZoneInfo.FindSystemTimeZoneById("Tokyo Standard Time");
        for(var q=0;q<2;q++)
        {
            var year=now.Year+(quarter+q)/4; var season=seasonNames[(quarter+q)%4];
            var raw=await _json.FetchAsync($"https://api.myanimelist.net/v2/anime/season/{year}/{season}?limit=100&fields=id,title,main_picture,alternative_titles,start_date,end_date,status,genres,broadcast,num_episodes,nsfw",token,headers:new() { ["X-MAL-CLIENT-ID"]=credential },refresh:refresh);
            foreach(var node in Array(raw,"data").Select(row=>Child(row,"node")))
            {
                var anime=AnimeMetadataService.MapMal(node); if(anime is null || Text(node,"status")!="currently_airing") continue;
                var broadcast=Child(node,"broadcast"); var weekday=Text(broadcast,"day_of_the_week");
                if(!Enum.TryParse<DayOfWeek>(weekday,true,out var targetDay)) continue;
                var time=TimeOnly.TryParse(Text(broadcast,"start_time"),out var parsed) ? parsed : new TimeOnly(12,0);
                for(var date=DateOnly.FromDateTime(window.Start.UtcDateTime).AddDays(-1); date<=DateOnly.FromDateTime(window.End.UtcDateTime).AddDays(1);date=date.AddDays(1))
                {
                    if(date.DayOfWeek!=targetDay || DateOnly.TryParse(Text(node,"start_date"),out var startDate)&&date<startDate || DateOnly.TryParse(Text(node,"end_date"),out var endDate)&&date>endDate) continue;
                    var local=date.ToDateTime(time,DateTimeKind.Unspecified); var airing=new DateTimeOffset(local,tokyo.GetUtcOffset(local));
                    if(airing<window.Start || airing>=window.End) continue;
                    result.Add(new($"mal:{anime.ProviderId}:{date:yyyy-MM-dd}","Anime","MAL",anime.ProviderId,anime.Title,airing,0,Cover:anime.PosterPath,MalId:anime.ProviderId,KnownTime:false,Estimated:true));
                }
            }
        }
        return new(result,"AniList and AnimeSchedule are unavailable. MyAnimeList dates are broadcast estimates; exact times and episode numbers are unavailable.");
    }
    private async Task<ScheduleResult> WesternAsync((DateTimeOffset Start,DateTimeOffset End) window,CancellationToken token,bool refresh)
    {
        try
        {
            var key=LocalCredentials.Read("TraktClientId"); if(key.Length==0) throw new ProviderException("Trakt is not configured.");
            var items=new List<JsonElement>();
            var cursor=window.Start.UtcDateTime.Date;
            while(cursor<window.End.UtcDateTime)
            {
                var count=Math.Min(30,(int)Math.Ceiling((window.End.UtcDateTime-cursor).TotalDays));
                var raw=await _json.FetchAsync($"https://api.trakt.tv/calendars/all/shows/{cursor:yyyy-MM-dd}/{count}?extended=full&languages=en",token,headers:new(){["trakt-api-key"]=key,["trakt-api-version"]="2"},refresh:refresh);
                if(raw.ValueKind!=JsonValueKind.Array)throw new ProviderException("Trakt returned an invalid calendar.");
                items.AddRange(Items(raw));cursor=cursor.AddDays(count);
            }
            var excluded=new[] {"anime","documentary","food","game-show","home-and-garden","news","reality","soap","special-interest","sport","talk-show"};
            var entries=new List<ScheduleEntry>();
            foreach(var item in items)
            {
                var show=Child(item,"show"); var ep=Child(item,"episode"); var ids=Child(show,"ids");
                if(Text(show,"language")!="en" || Array(show,"genres").Any(g=>g.ValueKind==JsonValueKind.String&&excluded.Contains(g.GetString())) || Positive(ids,"tmdb") is not { } tmdb || !DateTimeOffset.TryParse(Text(item,"first_aired"),out var airing)) continue;
                var number=Int(ep,"number"); var season=Int(ep,"season"); if(number<=0 || season<0) continue;
                entries.Add(new($"western:{tmdb}:{season}:{number}","Western","Trakt",Positive(ids,"trakt") ?? tmdb,Text(show,"title"),airing,number,season,TmdbId:tmdb));
            }
            return new(RemoveDaily(entries),"");
        }
        catch(ProviderException)
        {
            token.ThrowIfCancellationRequested();
            return new(await TVMazeAsync(window,token,refresh),"Trakt is unavailable. Showing TVMaze broadcast and streaming data.");
        }
    }
    private async Task<IReadOnlyList<ScheduleEntry>> TVMazeAsync((DateTimeOffset Start,DateTimeOffset End) window,CancellationToken token,bool refresh)
    {
        var region=RegionInfo.CurrentRegion.TwoLetterISORegionName;
        var result=new List<ScheduleEntry>();
        // Per-day endpoints bound each response; avoid downloading the multi-megabyte full schedule.
        for(var day=DateOnly.FromDateTime(window.Start.UtcDateTime).AddDays(-1);day<=DateOnly.FromDateTime(window.End.UtcDateTime);day=day.AddDays(1))
        {
            foreach(var web in new[] {false,true})
            {
                JsonElement rows;
                try { rows=await _json.FetchAsync($"https://api.tvmaze.com/schedule{(web ? "/web" : "")}?country={(web ? "" : Uri.EscapeDataString(region))}&date={day:yyyy-MM-dd}",token,refresh:refresh); }
                catch(ProviderException) when(web) { continue; }
                foreach(var row in Items(rows))
                {
                    var show=Child(row,"show"); if(show.ValueKind!=JsonValueKind.Object) show=Child(Child(row,"_embedded"),"show");
                    var language=Text(show,"language"); var type=Text(show,"type");
                    if(type is not ("Scripted" or "Animation") || web && language!="English" || language=="Japanese" && Array(show,"genres").Any(g=>g.ValueKind==JsonValueKind.String&&g.GetString() is "Anime" or "Animation") || Array(Child(show,"schedule"),"days").Count()>=4) continue;
                    if(Positive(show,"id") is not { } id || !DateTimeOffset.TryParse(Text(row,"airstamp"),out var airing)) continue;
                    var number=Int(row,"number"); if(number<=0) continue;
                    result.Add(new($"tvmaze:{Int(row,"id")}","Western","TVMaze",id,Text(show,"name"),airing,number,Int(row,"season"),Cover:Text(Child(show,"image"),"medium"),KnownTime:Text(row,"airtime").Length>0));
                }
                await Task.Delay(250,token);
            }
        }
        return RemoveDaily(result.DistinctBy(e=>e.Id).ToArray());
    }
    private static IReadOnlyList<ScheduleEntry> RemoveDaily(IReadOnlyList<ScheduleEntry> entries)
    {
        var daily=entries.GroupBy(e=>$"{e.Provider}:{e.MediaId}").Where(g=>ScheduleDates.IsDaily(g.Select(e=>e.AiringAt))).Select(g=>g.Key).ToHashSet();
        return entries.Where(e=>!daily.Contains($"{e.Provider}:{e.MediaId}")).ToArray();
    }
}
