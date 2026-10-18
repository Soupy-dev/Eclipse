using System.Text.Json;
using Eclipse.Windows.Models;
using static Eclipse.Windows.Services.JsonValue;

namespace Eclipse.Windows.Services;

public sealed class AnimeMetadataService(IProviderJson? transport=null)
{
    public static AnimeMetadataService Shared { get; }=new();
    private readonly IProviderJson _json=transport ?? ProviderJson.Shared;
    public async Task<JsonElement> GraphAsync(string query,object variables,CancellationToken token,bool refresh=false)
    {
        var result=await _json.FetchAsync("https://graphql.anilist.co",token,JsonSerializer.Serialize(new { query,variables }),refresh:refresh);
        if(Array(result,"errors").Any()) throw new ProviderException("AniList could not return this metadata.");
        return Child(result,"data");
    }
    public async Task<IReadOnlyList<AnimeMapping>> MappingsAsync(string key,int id,CancellationToken token,bool refresh=false)
    {
        if(id is <=0 or >1_000_000_000 || key is not ("anilist" or "mal" or "tmdb_show" or "tmdb_movie")) return [];
        var result=await _json.FetchAsync($"https://animap.s0n1c.ca/mappings/{id}?mapping_key={key}",token,refresh:refresh);
        if(result.ValueKind!=JsonValueKind.Array && Child(result,"mappings").ValueKind!=JsonValueKind.Array)throw new ProviderException("AniMap returned an invalid mapping response.");
        var rows=(result.ValueKind==JsonValueKind.Array ? Items(result) : Array(result,"mappings")).ToArray();
        if(rows.Length>512)throw new ProviderException("AniMap returned too many mappings to resolve safely.");
        if(rows.Any(row=>row.ValueKind!=JsonValueKind.Object || AnimeMapping.Parse(row) is null))throw new ProviderException("AniMap returned invalid mapping fields.");
        return rows.Select(AnimeMapping.Parse).OfType<AnimeMapping>().Where(row=>key switch
        {
            "anilist"=>row.AniListId is null || row.AniListId==id,"mal"=>row.MalId is null || row.MalId==id,
            "tmdb_show"=>row.TmdbShowId==id,_=>row.TmdbMovieId==id
        }).ToArray();
    }
    public async Task<MediaTitle> AniListAsync(int id,CancellationToken token,bool refresh=false)
    {
        var data=await GraphAsync("query($id:Int!){Media(id:$id,type:ANIME){id idMal isAdult title{english romaji native} description(asHtml:false) format status episodes duration averageScore startDate{year month day} genres coverImage{large medium} bannerImage}}",new {id},token,refresh);
        var title=MapAniList(Child(data,"Media")) ?? throw new ProviderException("AniList did not return this anime.");
        if(title.ProviderId!=id)throw new ProviderException("AniList returned a different anime identity.");
        return title;
    }
    public static MediaTitle? MapAniList(JsonElement item)
    {
        if(Positive(item,"id") is not { } id || Bool(item,"isAdult")) return null;
        var names=Child(item,"title"); var name=Text(names,"english"); if(name.Length==0) name=Text(names,"romaji");
        if(string.IsNullOrWhiteSpace(name)) return null;
        var date=Child(item,"startDate"); var year=Int(date,"year"); var month=Int(date,"month"); var day=Int(date,"day");
        var release=year is >=1900 and <2200 ? year.ToString("D4") : "";
        if(release.Length>0 && month is >=1 and <=12) {release+=$"-{month:D2}";if(day>=1 && day<=DateTime.DaysInMonth(year,month))release+=$"-{day:D2}";}
        return new MediaTitle { Provider="AniList",ProviderId=id,AniListId=id,MalId=Positive(item,"idMal"),TmdbId=0,MediaType=Text(item,"format")=="MOVIE" ? "movie" : "tv",
            Title=name,OriginalTitle=Text(names,"romaji"),Format=Text(item,"format"),Status=Text(item,"status"),Synopsis=AnimeText.Plain(Text(item,"description")),
            ReleaseDate=release,Score=Double(item,"averageScore")/10,ScoreProvider="AniList",
            Genre=string.Join(" · ",Array(item,"genres").Where(e=>e.ValueKind==JsonValueKind.String).Take(4).Select(e=>e.GetString())),Duration=Int(item,"episodes")>0 ? $"{Int(item,"episodes")} episodes" : "",
            PosterPath=Text(Child(item,"coverImage"),"large"),BackdropPath=Text(item,"bannerImage") };
    }
    public async Task<MediaTitle> MalAsync(int id,CancellationToken token,bool refresh=false)
    {
        var key=LocalCredentials.Read("MalClientId"); if(key.Length==0) throw new ProviderException("MyAnimeList is not configured on this device.");
        var item=await _json.FetchAsync($"https://api.myanimelist.net/v2/anime/{id}?fields=id,title,main_picture,alternative_titles,start_date,synopsis,mean,media_type,status,genres,num_episodes,nsfw",token,headers:new() { ["X-MAL-CLIENT-ID"]=key },refresh:refresh);
        var result=MapMal(item) ?? throw new ProviderException("MyAnimeList did not return this anime.");
        if(result.ProviderId!=id) throw new ProviderException("MyAnimeList returned a different anime identity.");
        return result;
    }
    public static MediaTitle? MapMal(JsonElement item)
    {
        if(Positive(item,"id") is not { } id || Text(item,"nsfw")=="black" || Array(item,"genres").Any(g=>Int(g,"id") is 12 or 49)) return null;
        var name=Text(Child(item,"alternative_titles"),"en"); if(name.Length==0) name=Text(item,"title"); if(name.Length==0) return null;
        return new MediaTitle { Provider="MAL",ProviderId=id,MalId=id,TmdbId=0,MediaType=Text(item,"media_type")=="movie" ? "movie" : "tv",Title=name,
            OriginalTitle=Text(item,"title"),Format=Text(item,"media_type").ToUpperInvariant(),Status=Text(item,"status"),ReleaseDate=Text(item,"start_date"),
            Synopsis=AnimeText.Plain(Text(item,"synopsis")),Score=Double(item,"mean"),ScoreProvider="MAL",PosterPath=Text(Child(item,"main_picture"),"large"),
            Duration=Int(item,"num_episodes")>0 ? $"{Int(item,"num_episodes")} episodes" : "",Genre=string.Join(" · ",Array(item,"genres").Take(4).Select(g=>Text(g,"name"))) };
    }
    public async Task<MediaTitle> DetailsAsync(string reference,CancellationToken token,bool refresh=false,int? knownMalId=null)
    {
        if(reference.StartsWith("tvmaze:",StringComparison.Ordinal)) return await TVMazeDetailsAsync(reference,token,refresh);
        if(MediaTitle.TryParseId(reference,out _,out _))
        {
            var tmdb=await TmdbService.Shared.DetailsAsync(reference,token,refresh);
            if(!tmdb.GenreIds.Contains(16) || tmdb.OriginalLanguage is not ("ja" or "zh" or "ko")) return tmdb;
            try
            {
                var rows=await MappingsAsync(tmdb.MediaType=="movie" ? "tmdb_movie" : "tmdb_show",tmdb.TmdbId,token,refresh);
                var valid=rows.Where(r=>r.Target==reference).OrderBy(r=>r.TmdbSeason ?? int.MaxValue).ToArray();
                var root=valid.FirstOrDefault(r=>r.AniListId is not null) ?? valid.FirstOrDefault(r=>r.MalId is not null);
                if(root is null) return await MatchAniListByTitleAsync(tmdb,token,"No AniMap mapping is available.",refresh);
                // TMDB shows can contain many cours. The primary IDs are only a root seed;
                // every season mapping is retained separately by the matching section.
                return tmdb with { AniListId=root.AniListId,MalId=root.MalId,AnimeMappings=valid,IdentityNotice=$"{valid.Length} AniMap mapping(s). Season identities remain separate." };
            }
            catch(ProviderException) { return await MatchAniListByTitleAsync(tmdb,token,"AniMap is temporarily unavailable.",refresh); }
        }
        var parts=reference.Split(':');
        if(parts.Length!=2 || !int.TryParse(parts[1],out var id) || id is <=0 or >1_000_000_000 || parts[0] is not ("anilist" or "mal")) throw new ProviderException("This media identity is invalid.");
        var provider=parts[0]=="mal" ? "MAL" : "AniList";
        IReadOnlyList<AnimeMapping> mappings=[]; var mappingUnavailable=false;
        try { mappings=await MappingsAsync(parts[0],id,token,refresh); } catch(ProviderException) { mappingUnavailable=true; }
        var mappedMal=mappings.Where(r=>r.MalId is not null).Select(r=>r.MalId!.Value).Distinct().ToArray();
        var malFallback=knownMalId is >0 and <=1_000_000_000 ? knownMalId : mappedMal is [int singleMal] ? singleMal : (int?)null;
        if(knownMalId is not null && mappedMal.Any(m=>m!=knownMalId))malFallback=null;
        MediaTitle native;
        try { native=provider=="AniList" ? await AniListAsync(id,token,refresh) : await MalAsync(id,token,refresh); }
        catch(ProviderException) when(provider=="AniList" && malFallback is int mal)
        { native=await MalAsync(mal,token,refresh); native=native with { Provider="AniList",ProviderId=id,AniListId=id,IdentityNotice="AniList is unavailable. Showing MyAnimeList metadata." }; }
        if(native.MalId is null&&provider=="AniList"&&malFallback is not null)native=native with{MalId=malFallback};
        var match=AnimeMapping.UniqueTarget(mappings,provider,id,native.Format);
        if(match?.Target is null)
        {
            // An ambiguous authoritative mapping must never be overridden by title guessing.
            if(mappings.Any(m=>m.Target is not null))return native with {AnimeMappings=mappings,IdentityNotice="Multiple TMDB matches. Original provider metadata is preserved."};
            var exact=await MatchTmdbByTitleAsync(native,token,refresh);
            if(exact is null)return native with {IdentityNotice=(mappingUnavailable ? "Cross-provider matching is temporarily unavailable. " : "No unique TMDB match. ")+native.IdentityNotice};
            return exact with {Provider=provider,ProviderId=id,AniListId=native.AniListId,MalId=native.MalId,Format=native.Format,Title=native.Title,IdentityNotice="Exact title, format and year match. No verified season mapping is available."};
        }
        try
        {
            var tmdb=await TmdbService.Shared.DetailsAsync(match.Target,token,refresh);
            if(tmdb.TmdbId<=0 || (native.Format=="MOVIE" && tmdb.MediaType!="movie")) return native;
            return tmdb with { Provider=provider,ProviderId=id,AniListId=native.AniListId ?? match.AniListId,MalId=native.MalId ?? match.MalId,MappedSeason=match.TmdbSeason,
                Title=native.Title,Format=native.Format,AnimeMappings=mappings,IdentityNotice=$"AniMap match{(match.TmdbSeason is { } season ? $" · Season {season}" : "")}. {native.IdentityNotice}" };
        }
        catch(TmdbException) { return native with { IdentityNotice="TMDB is unavailable. Original provider metadata is preserved." }; }
    }
    private async Task<MediaTitle> MatchAniListByTitleAsync(MediaTitle title,CancellationToken token,string notice,bool refresh)
    {
        try
        {
            var candidates=new Dictionary<int,MediaTitle>();
            foreach(var name in new[]{title.Title,title.OriginalTitle}.Where(s=>s.Length>0).Distinct().Take(2))
            {
                var data=await GraphAsync("query($search:String!){Page(page:1,perPage:10){media(search:$search,type:ANIME,isAdult:false){id idMal isAdult title{english romaji native} format startDate{year month day}}}}",new{search=name},token,refresh);
                foreach(var row in Array(Child(data,"Page"),"media"))if(MapAniList(row) is {} candidate && ExactTitle(title,candidate))candidates[candidate.ProviderId]=candidate;
            }
            if(candidates.Count==1)
            {var anime=candidates.Values.Single();return title with{AniListId=anime.ProviderId,MalId=anime.MalId,IdentityNotice=notice+" Exact AniList title, format and year match; season identities are unresolved."};}
        }
        catch(ProviderException){}
        return title with{IdentityNotice=notice+" No unique anime match is available."};
    }
    private async Task<MediaTitle?> MatchTmdbByTitleAsync(MediaTitle anime,CancellationToken token,bool refresh)
    {
        if(!int.TryParse(anime.Year,out _)||new[]{anime.Title,anime.OriginalTitle}.All(name=>AnimeText.Signature(name).Length==0))return null;
        try
        {
            var matches=new Dictionary<string,MediaTitle>();
            foreach(var name in new[]{anime.Title,anime.OriginalTitle}.Where(s=>s.Length>0).Distinct().Take(2))
            {
                var page=await TmdbService.Shared.SearchAsync(anime.MediaType,name,1,token,refresh);
                foreach(var candidate in page.Titles)if(ExactTitle(anime,candidate))matches[candidate.Id]=candidate;
            }
            return matches.Count==1 ? await TmdbService.Shared.DetailsAsync(matches.Keys.Single(),token,refresh) : null;
        }
        catch(TmdbException){return null;}
    }
    public static bool ExactTitle(MediaTitle a,MediaTitle b) => a.MediaType==b.MediaType && int.TryParse(a.Year,out _) && a.Year==b.Year &&
        new[]{a.Title,a.OriginalTitle}.Where(s=>s.Length>0).Select(AnimeText.Signature).Where(s=>s.Length>0).Intersect(new[]{b.Title,b.OriginalTitle}.Where(s=>s.Length>0).Select(AnimeText.Signature).Where(s=>s.Length>0)).Any();
    private async Task<MediaTitle> TVMazeDetailsAsync(string reference,CancellationToken token,bool refresh)
    {
        if(!int.TryParse(reference[7..],out var id) || id is <=0 or >1_000_000_000)throw new ProviderException("This television identity is invalid.");
        var data=await _json.FetchAsync($"https://api.tvmaze.com/shows/{id}?embed=seasons",token,refresh:refresh);
        if(Int(data,"id")!=id)throw new ProviderException("TVMaze returned a different television identity.");
        try
        {
            var exact=await TmdbService.Shared.FindImdbAsync(Text(Child(data,"externals"),"imdb"),token);
            if(exact is not null)return await TmdbService.Shared.DetailsAsync(exact.Id,token);
        }
        catch(TmdbException){}
        return new MediaTitle{TmdbId=0,Provider="TVMaze",ProviderId=id,Title=Text(data,"name"),MediaType="tv",Synopsis=AnimeText.Plain(Text(data,"summary")),
            ReleaseDate=Text(data,"premiered"),Score=Double(Child(data,"rating"),"average"),ScoreProvider="TVMaze",Status=Text(data,"status"),
            PosterPath=Text(Child(data,"image"),"medium"),BackdropPath=Text(Child(data,"image"),"original"),Genre=string.Join(" · ",Array(data,"genres").Where(x=>x.ValueKind==JsonValueKind.String).Take(4).Select(x=>x.GetString())),
            Seasons=Array(Child(data,"_embedded"),"seasons").Where(s=>Int(s,"number")>=0).Take(100).Select(s=>new MediaSeason(Int(s,"number"),$"Season {Int(s,"number")}",Int(s,"episodeOrder"))).ToArray(),
            IdentityNotice="TVMaze metadata. No unique TMDB identity is available."};
    }
    public async Task<IReadOnlyList<MediaEpisode>> EpisodesAsync(MediaTitle title,int season,CancellationToken token,bool refresh=false)
    {
        if(title.TmdbId>0)return await TmdbService.Shared.EpisodesAsync(title.TmdbId,season,token,refresh);
        if(title.Provider!="TVMaze")return [];
        var data=await _json.FetchAsync($"https://api.tvmaze.com/shows/{title.ProviderId}/episodes?specials=1",token,refresh:refresh);
        return Items(data).Where(e=>Int(e,"season")==season).Take(250).Select(e=>new MediaEpisode(Int(e,"number"),Text(e,"name"),Int(e,"runtime")>0?$"{Int(e,"runtime")} min":"Runtime TBA",AnimeText.Plain(Text(e,"summary")),Text(e,"airdate"),Text(Child(e,"image"),"medium"))).ToArray();
    }
}
