using Eclipse.Windows.Models;

namespace Eclipse.Windows.Services;

public sealed record CatalogRequest(string CatalogId,int FacetId=0)
{
    public int LoadedPages {get;set;}=1;
    public double Offset {get;set;}
    public string? FocusTitleId {get;set;}
}
public sealed record CatalogFacet(int Id,string Name) { public override string ToString()=>Name; }
public static class CatalogService
{
    public static IReadOnlyList<CatalogFacet> Facets(string id) => id switch
    {
        "networks" => [new(213,"Netflix"),new(2739,"Disney+"),new(49,"HBO"),new(1024,"Amazon"),new(2552,"Apple TV+"),new(453,"Hulu"),new(4330,"Paramount+"),new(1112,"Crunchyroll")],
        "companies" => [new(33,"Universal"),new(4,"Paramount"),new(174,"Warner Bros."),new(25,"20th Century"),new(2,"Walt Disney"),new(41077,"A24"),new(1632,"Lionsgate"),new(5,"Columbia")],
        "genres" => [new(28,"Action"),new(35,"Comedy"),new(18,"Drama"),new(878,"Sci-Fi"),new(10749,"Romance"),new(16,"Animation"),new(10751,"Family"),new(53,"Thriller"),new(27,"Horror"),new(99,"Documentary")],
        _ => []
    };
    public static async Task<CatalogPage> LoadAsync(CatalogRequest request,int page,CancellationToken token)
    {
        var id=request.CatalogId; var tmdb=TmdbService.Shared;
        if(!HomeCatalog.SupportedIds.Contains(id))throw new ProviderException("This catalog requires a provider integration that is not available on Windows yet.");
        if(id=="trending") return await tmdb.BrowseAsync("all","trending",0,page,token);
        var type=id.Contains("Movie",StringComparison.Ordinal) || id=="companies" || id=="genres" ? "movie" : "tv";
        var order=id.StartsWith("topRated") || id.StartsWith("best") ? "top_rated" : id switch
        { "nowPlayingMovies"=>"now_playing","upcomingMovies"=>"upcoming","onTheAirTV"=>"on_the_air","airingTodayTV"=>"airing_today",_=>"popular" };
        if(id.EndsWith("Anime",StringComparison.Ordinal))
        {
            // The Apple performance path uses TMDB anime discovery rather than N title matches per shelf.
            var combined=new List<MediaTitle>();
            if(id=="trendingAnime")
            {
                var trending=await tmdb.BrowseAsync("tv","trending",0,page,token);
                combined.AddRange(trending.Titles.Where(t=>t.GenreIds.Contains(16)&&t.OriginalLanguage is "ja" or "zh" or "ko"));
                if(combined.Count>=10)return new(combined.Take(20).ToArray(),page,5);
            }
            foreach(var pair in new[] {("JP","ja"),("CN","zh"),("KR","ko"),("TW","zh")})
            {
                var filters=new Dictionary<string,string> { ["with_genres"]="16",["with_origin_country"]=pair.Item1,["with_original_language"]=pair.Item2,
                    ["sort_by"]=order=="top_rated" ? "vote_average.desc" : "popularity.desc" };
                if(order=="top_rated") filters["vote_count.gte"]="100";
                if(id=="airingAnime") { filters["air_date.gte"]=DateTime.Today.AddDays(-7).ToString("yyyy-MM-dd"); filters["air_date.lte"]=DateTime.Today.AddDays(7).ToString("yyyy-MM-dd"); filters["with_status"]="0"; }
                combined.AddRange((await tmdb.DiscoverAsync("tv",filters,page,token)).Titles);
            }
            return new(combined.DistinctBy(t=>t.Id).Take(20).ToArray(),page,5);
        }
        if(id is "networks" or "companies" or "genres")
        {
            var facet=request.FacetId>0 ? request.FacetId : Facets(id)[0].Id;
            return await tmdb.DiscoverAsync(type,new() { [id=="networks" ? "with_networks" : id=="companies" ? "with_companies" : "with_genres"]=facet.ToString(),["sort_by"]="popularity.desc" },page,token);
        }
        if(id=="upcomingTV") return await tmdb.DiscoverAsync("tv",new() { ["first_air_date.gte"]=DateTime.Today.AddDays(1).ToString("yyyy-MM-dd"),["sort_by"]="popularity.desc" },page,token);
        if(id=="featured") return await tmdb.DiscoverAsync("tv",new() { ["with_genres"]="10765",["sort_by"]="popularity.desc" },page,token);
        return await tmdb.BrowseAsync(type,order,0,page,token);
    }
}
