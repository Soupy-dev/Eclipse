namespace Eclipse.Windows.Models;

// Provider-local episodes, display seasons, and TMDB/TVDB coordinates are different domains.
public sealed record AnimeRelation(string Kind,string Target);
public sealed record AnimeNode(string Id,int? AniListId,int? MalId,string Title,string Format,string Status,
    int? EpisodeCount,string StartDate,string EndDate,IReadOnlyList<AnimeRelation> Relations)
{
    public IReadOnlyList<string> Titles { get; init; } = [];
    public string? Cover { get; init; }
    public int? SeasonYear { get; init; }
    public int SeasonOrdinal { get; init; } = 4;
    public bool RelationsComplete { get; init; } = true;
    public bool Upcoming => Status is "NOT_YET_RELEASED" or "NOT_YET_AIRED";
    public bool Finished => Status is "FINISHED" or "FINISHED_AIRING";
    public bool Releasing => Status is "RELEASING" or "CURRENTLY_AIRING";
    public bool Ordinary => Format is "TV" or "TV_SHORT" or "ONA";
}
public sealed record AnimeCoverage(int? Season,int? Count);
public sealed record AnimeCour(AnimeNode Node,AnimeMapping? Mapping,int DisplaySeason,int? Count,bool Regular,
    int? AbsoluteStart,string Notice)
{
    public string Id => Node.Id;
    public bool RequiresAbsoluteInventory { get; init; }
    public bool HasIdentityConflict { get; init; }
}
public sealed record AnimeStructure(IReadOnlyList<AnimeCour> Cours,bool Complete,string Notice)
{
    public static AnimeStructure Empty(string notice) => new([],false,notice);
}
public sealed record EpisodeRange(int First,int Last)
{
    public bool Contains(int number)=>number>=First&&number<=Last;
    public override string ToString()=>First==Last?First.ToString():$"{First}–{Last}";
}
public sealed record AnimeEpisodeUnit(string Edition,EpisodeRange AniList,EpisodeRange Mal,int? MovieId=null,int? Part=null,int? PartCount=null);
public sealed record SeasonInventory(int Id,int Number,string Name,IReadOnlyList<MediaEpisode> Episodes);
