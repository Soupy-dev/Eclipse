using System.Text.Json;
using System.Text.RegularExpressions;
using System.Net;
using static Eclipse.Windows.Services.JsonValue;

namespace Eclipse.Windows.Models;

public sealed record AnimeMapping(int? AniListId,int? MalId,int? TmdbShowId,int? TmdbMovieId,int? TmdbSeason,int? TvdbSeason,int? TvdbEpisodeOffset,string Format)
{
    public int? TvdbId { get; init; }
    public string? Target => Format=="MOVIE" && TmdbMovieId is { } movie ? $"movie:{movie}" : TmdbShowId is { } show ? $"tv:{show}" : TmdbMovieId is { } film ? $"movie:{film}" : null;
    public static AnimeMapping? Parse(JsonElement row)
    {
        var ids=new[] {"anilist_id","mal_id","tmdb_show_id","tmdb_movie_id"};
        if(ids.Any(key=>Child(row,key).ValueKind is not (JsonValueKind.Undefined or JsonValueKind.Null) && Positive(row,key) is null)) return null;
        int? Season(string key,bool sentinel=false)
        { var e=Child(row,key); if(e.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined) return null; return e.ValueKind==JsonValueKind.Number && e.TryGetInt32(out var n) && n>= (sentinel ? -1 : 0) && n<=10000 ? n : null; }
        var season=Season("tmdb_season");
        if(Child(row,"tmdb_season").ValueKind is not (JsonValueKind.Undefined or JsonValueKind.Null) && season is null) return null;
        if(Child(row,"tvdb_season").ValueKind is not (JsonValueKind.Undefined or JsonValueKind.Null) && Season("tvdb_season",true) is null) return null;
        if(Child(row,"media_type").ValueKind is not (JsonValueKind.Undefined or JsonValueKind.Null or JsonValueKind.String))return null;
        var offset=Child(row,"tvdb_epoffset");
        if(offset.ValueKind is not (JsonValueKind.Undefined or JsonValueKind.Null) && (offset.ValueKind!=JsonValueKind.Number || !offset.TryGetInt32(out var n) || Math.Abs((long)n)>100000)) return null;
        return new(Positive(row,"anilist_id"),Positive(row,"mal_id"),Positive(row,"tmdb_show_id"),Positive(row,"tmdb_movie_id"),season,Season("tvdb_season",true),offset.ValueKind==JsonValueKind.Number ? offset.GetInt32() : null,Text(row,"media_type").ToUpperInvariant()){TvdbId=Positive(row,"tvdb_id")};
    }
    // Never collapse two typed targets or guess which cour/season a provider identity means.
    public static AnimeMapping? UniqueTarget(IEnumerable<AnimeMapping> rows,string provider,int id,string format)
    {
        var eligible=rows.Where(row=>(provider=="AniList" ? row.AniListId is null || row.AniListId==id : row.MalId is null || row.MalId==id)
            && row.Target is not null).ToArray();
        if(eligible.Select(row=>row.Target).Distinct().Count()!=1) return null;
        if(format=="MOVIE" && !eligible[0].Target!.StartsWith("movie:",StringComparison.Ordinal))return null;
        var seasons=eligible.Where(row=>row.TmdbSeason is not null).Select(row=>row.TmdbSeason).Distinct().ToArray();
        if(seasons.Length>1) return null;
        return eligible.FirstOrDefault(row=>row.TmdbSeason is not null) ?? eligible.FirstOrDefault();
    }
}
public static class AnimeText
{
    public static string Plain(string text) => WebUtility.HtmlDecode(Regex.Replace(text.Length>20000 ? text[..20000] : text,"<[^>]*>"," ")).Trim();
    public static string Signature(string title) => Regex.Replace(title.Normalize(System.Text.NormalizationForm.FormKC).ToLowerInvariant(),@"[^\p{L}\p{N}]","");
}
