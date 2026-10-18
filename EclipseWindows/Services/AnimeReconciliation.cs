using System.Globalization;
using Eclipse.Windows.Models;

namespace Eclipse.Windows.Services;

// Ports the proof boundaries in AniListService.swift. Approximate preview coverage is
// deliberately never used to assign metadata or coordinates.
public static class AnimeReconciliation
{
    public const int MaximumNodes=128,MaximumEpisodes=10000,MaximumTotalEpisodes=20000;
    public static bool Count(int? n)=>n is >0 and <=MaximumEpisodes;
    public static DateOnly? Day(string? text)=>text?.Length==10&&DateOnly.TryParseExact(text,"yyyy-MM-dd",CultureInfo.InvariantCulture,DateTimeStyles.None,out var day)&&day.Year is >=1800 and <=3000?day:null;
    public static bool ValidCounts(IReadOnlyDictionary<int,int> counts)=>counts.Count is >0 and <=64&&counts.All(p=>p.Key is >=0 and <=10000&&Count(p.Value))&&counts.Values.Sum(n=>(long)n)<=MaximumTotalEpisodes;
    public static bool MatchingTotals(IReadOnlyDictionary<int,int> counts,IReadOnlyList<AnimeCoverage> segments)=>ValidCounts(counts)&&segments.Count is >0 and <=MaximumNodes&&segments.All(s=>Count(s.Count))&&segments.Sum(s=>(long)s.Count!.Value)==counts.Where(p=>p.Key>0).Sum(p=>(long)p.Value);
    public static bool ExactCoverage(IReadOnlyDictionary<int,int> counts,IReadOnlyList<AnimeCoverage> segments)
    {
        if(!MatchingTotals(counts,segments))return false;
        var ordinary=counts.Where(p=>p.Key>0).ToDictionary();if(ordinary.Count==0)return false;
        if(ordinary.Count==1)return segments.All(s=>s.Season is null||ordinary.ContainsKey(s.Season.Value));
        if(segments.Any(s=>s.Season is null||!ordinary.ContainsKey(s.Season.Value)))return false;
        var totals=segments.GroupBy(s=>s.Season!.Value).ToDictionary(g=>g.Key,g=>g.Sum(s=>s.Count!.Value));
        return totals.Count==ordinary.Count&&ordinary.All(p=>totals.GetValueOrDefault(p.Key)==p.Value);
    }
    public static IReadOnlyList<AnimeCoverage> ResolveSingleUnknown(IReadOnlyDictionary<int,int> counts,IReadOnlyList<AnimeCoverage> segments)
    {
        if(!ValidCounts(counts)||segments.Count>MaximumNodes||segments.Any(s=>s.Season is not >0||!counts.ContainsKey(s.Season.Value)||(s.Count is not null&&!Count(s.Count))))return segments;
        var result=segments.ToArray();
        foreach(var (season,target) in counts.Where(p=>p.Key>0))
        {
            var group=Enumerable.Range(0,result.Length).Where(i=>result[i].Season==season).ToArray();
            var unknown=group.Where(i=>result[i].Count is null).ToArray();
            var remainder=target-group.Sum(i=>(long)(result[i].Count??0));
            if(unknown.Length==1&&remainder is >0 and <=MaximumEpisodes)result[unknown[0]]=result[unknown[0]] with{Count=(int)remainder};
        }
        return result;
    }
    public static IReadOnlyList<AnimeCoverage> ReconcileReleasingTail(IReadOnlyDictionary<int,int> counts,IReadOnlyList<AnimeCoverage> segments,string status)
    {
        if(status is not ("RELEASING" or "NOT_YET_RELEASED" or "CURRENTLY_AIRING" or "NOT_YET_AIRED")||!ValidCounts(counts)||segments.Count is <2 or >MaximumNodes||!Count(segments[^1].Count))return segments;
        var expected=counts.Where(p=>p.Key>0).OrderBy(p=>p.Key).ToArray();if(expected.Length<2)return segments;
        var last=expected[^1];if(segments[^1].Count<=last.Value||(segments[^1].Season is {} s&&s!=last.Key))return segments;
        var prefix=segments.Take(segments.Count-1).ToArray();
        if(prefix.Any(s=>s.Season is null||!Count(s.Count)))return segments;
        var actual=prefix.GroupBy(s=>s.Season!.Value).ToDictionary(g=>g.Key,g=>g.Sum(s=>(long)s.Count!.Value));
        if(actual.Count!=expected.Length-1||expected.Take(expected.Length-1).Any(p=>actual.GetValueOrDefault(p.Key)!=p.Value))return segments;
        var result=segments.ToArray();result[^1]=result[^1] with{Count=last.Value};return result;
    }
    public static bool CompatibleMappedOrder(IReadOnlyList<AnimeCour> cours,int tmdbSeasonCount)
    {
        if(cours.Count>MaximumNodes||tmdbSeasonCount is <0 or >64)return false;
        if(cours.Count<=1)return true;
        if(tmdbSeasonCount>1)
        {
            var seasons=cours.Select(c=>c.Mapping?.TmdbSeason).ToArray();
            if(seasons.Any(s=>s is not >0)||seasons.Zip(seasons.Skip(1)).Any(p=>p.First>p.Second))return false;
        }
        foreach(var group in cours.GroupBy(c=>tmdbSeasonCount>1?c.Mapping?.TmdbSeason:1).Where(g=>g.Count()>1))
        {
            var list=group.ToArray();if(list[0].Mapping?.TvdbEpisodeOffset is not <=0||list.Any(c=>c.Mapping?.TvdbSeason is not >0))return false;
            for(var i=1;i<list.Length;i++)
            {
                var previous=list[i-1];var current=list[i];
                if(current.Mapping!.TvdbSeason<previous.Mapping!.TvdbSeason)return false;
                if(current.Mapping.TvdbSeason==previous.Mapping.TvdbSeason&&(!Count(previous.Count)||previous.Mapping.TvdbEpisodeOffset is null||current.Mapping.TvdbEpisodeOffset!=(long)previous.Mapping.TvdbEpisodeOffset+previous.Count))return false;
            }
        }
        return true;
    }
    public static IReadOnlyList<AnimeNode> Order(IEnumerable<AnimeNode> values)
    {
        var nodes=values.DistinctBy(n=>n.Id).Take(MaximumNodes).OrderBy(n=>Year(n)).ThenBy(n=>Month(n)).ThenBy(n=>Day(n.StartDate)?.Day??32).ThenBy(n=>NumericId(n.Id)).ThenBy(n=>n.Id,StringComparer.Ordinal).ToArray();
        var ranks=nodes.Select((n,i)=>(n.Id,i)).ToDictionary(p=>p.Id,p=>p.i);var outgoing=nodes.ToDictionary(n=>n.Id,_=>new HashSet<string>());var indegree=nodes.ToDictionary(n=>n.Id,_=>0);
        foreach(var node in nodes)foreach(var relation in node.StoryRelations)
        {
            var before=relation.Kind=="PREQUEL"?relation.Target:node.Id;var after=relation.Kind=="PREQUEL"?node.Id:relation.Target;
            if(relation.Kind is not ("PREQUEL" or "SEQUEL" or "SEASON")||before==after||!ranks.ContainsKey(before)||!ranks.ContainsKey(after))continue;
            if(outgoing[before].Add(after))indegree[after]++;
        }
        var result=new List<AnimeNode>();var ready=nodes.Where(n=>indegree[n.Id]==0).Select(n=>n.Id).ToList();
        while(ready.Count>0){ready.Sort((a,b)=>ranks[a].CompareTo(ranks[b]));var id=ready[0];ready.RemoveAt(0);result.Add(nodes[ranks[id]]);foreach(var target in outgoing[id])if(--indegree[target]==0)ready.Add(target);}
        result.AddRange(nodes.Where(n=>result.All(r=>r.Id!=n.Id)));return result;
    }
    private static int NumericId(string id)=>int.TryParse(id.Split(':').Last(),out var n)?n:int.MaxValue;
    private static int Year(AnimeNode n)=>n.StartDate.Length>=4&&int.TryParse(n.StartDate[..4],out var year)&&year is >=1800 and <=3000?year:n.SeasonYear??int.MaxValue;
    private static int Month(AnimeNode n)=>n.StartDate.Length>=7&&int.TryParse(n.StartDate.Substring(5,2),out var month)&&month is >=1 and <=12?month:n.SeasonOrdinal is >=0 and <=3?n.SeasonOrdinal*3+1:13;
    public static AnimeStructure Reconcile(IReadOnlyList<AnimeNode> nodes,IReadOnlyList<AnimeMapping> mappings,IReadOnlyDictionary<int,int> counts,int showId,bool complete)
    {
        if(nodes.Count>MaximumNodes||mappings.Count>512||!ValidCounts(counts))return AnimeStructure.Empty("Anime structure exceeds the verified inventory limits.");
        bool Conflict(AnimeNode node)
        {
            var rows=mappings.Where(m=>(node.AniListId is {} a&&m.AniListId==a)||(node.MalId is {} mal&&m.MalId==mal)).ToArray();
            return rows.Any(m=>(m.AniListId is {} a&&node.AniListId is {} na&&a!=na)||(m.MalId is {} x&&node.MalId is {} nx&&x!=nx)||m.Target is {} target&&target!=$"tv:{showId}")||rows.Where(m=>m.Target is not null).Select(m=>(m.Target,m.TmdbSeason,m.TvdbSeason,m.TvdbEpisodeOffset)).Distinct().Count()>1;
        }
        complete&=!nodes.Any(Conflict);
        AnimeMapping? Mapping(AnimeNode node)
        {
            var rows=mappings.Where(m=>m.TmdbShowId==showId&&((node.AniListId is {} a&&m.AniListId==a)||(node.MalId is {} mal&&m.MalId==mal))).ToArray();
            if(rows.Any(m=>(m.AniListId is {} a&&node.AniListId is {} na&&a!=na)||(m.MalId is {} x&&node.MalId is {} nx&&x!=nx))||rows.Select(m=>(m.Target,m.TmdbSeason,m.TvdbSeason,m.TvdbEpisodeOffset)).Distinct().Count()>1)return null;
            return rows.FirstOrDefault();
        }
        var ordered=Order(nodes);var ordinary=new List<AnimeNode>();var specials=new List<AnimeNode>();
        foreach(var n in ordered)
        {
            var m=Mapping(n);var mapped=m?.TmdbSeason is >0;
            var explicitlySpecial=m is not null&&(m.TmdbSeason==0||m.TmdbSeason is null&&m.TvdbSeason==0);
            var regular=!explicitlySpecial&&(n.Format is "TV" or "TV_SHORT"||(n.Format=="ONA"&&(mapped||m?.TvdbSeason is >0||n.Relations.Any(r=>r.Kind is "PREQUEL" or "SEQUEL" or "SEASON"&&nodes.Any(other=>other.Id==r.Target&&other.Ordinary)))));
            if(!regular&&mapped&&n.Format is "ONA" or "SPECIAL" or "OVA" or "OAD" or "MOVIE")
            {
                var occupied=ordered.Where(o=>o.Id!=n.Id&&o.Ordinary&&Mapping(o)?.TmdbSeason==m!.TmdbSeason).Sum(o=>(long)(o.EpisodeCount??0));
                regular=counts.TryGetValue(m!.TmdbSeason!.Value,out var available)&&occupied<available&&(!Count(n.EpisodeCount)||n.EpisodeCount<=available-occupied);
            }
            (regular?ordinary:specials).Add(n);
        }
        var coverage=ordinary.Select(n=>new AnimeCoverage(Mapping(n)?.TmdbSeason,n.EpisodeCount)).ToArray();
        var resolved=complete?ResolveSingleUnknown(counts,coverage):coverage;
        if(complete&&ordinary.Count>0)resolved=ReconcileReleasingTail(counts,resolved,ordinary[^1].Status);
        var cours=ordinary.Select((n,i)=>new AnimeCour(n,Mapping(n),i+1,resolved[i].Count,true,null,""){HasIdentityConflict=Conflict(n)}).ToArray();
        var openEnded=complete&&cours.Length==1&&cours[0].Node.Format=="TV"&&cours[0].Node.Releasing&&cours[0].Node.EpisodeCount is null&&cours[0].Mapping?.TmdbSeason is null;
        if(openEnded)cours[0]=cours[0] with{Count=counts.Where(p=>p.Key>0).Sum(p=>p.Value),AbsoluteStart=1,RequiresAbsoluteInventory=true};
        // Complete future identities can close a roster, but never manufacture unaired rows.
        var firstUpcoming=Array.FindIndex(cours,c=>c.Node.Upcoming);if(firstUpcoming<0)firstUpcoming=cours.Length;
        var active=cours.Take(firstUpcoming).ToArray();var activeCoverage=resolved.Take(firstUpcoming).ToArray();
        var totals=complete&&((ExactCoverage(counts,resolved)||MatchingTotals(counts,resolved))||(firstUpcoming>0&&cours.Skip(firstUpcoming).All(c=>c.Node.Upcoming)&&(ExactCoverage(counts,activeCoverage)||MatchingTotals(counts,activeCoverage))));
        var compatible=CompatibleMappedOrder(cours,counts.Count(p=>p.Key>0));
        var linear=totals&&(compatible||(NoMappedContradictions(active)&&HasReciprocalChain(active)));
        var absolute=1;
        for(var i=0;i<cours.Length;i++)
        {
            int? start=openEnded?1:linear?absolute:complete?ExactMappedStart(i,cours,counts):null;
            var absoluteInventory=openEnded||ordinary.Any(n=>n.VerifiedBridgeRelations.Count>0)||cours.Any(c=>c.Mapping?.TvdbSeason==-1)&&counts.Count(p=>p.Key>0)>1;
            cours[i]=cours[i] with{AbsoluteStart=start,RequiresAbsoluteInventory=absoluteInventory,Notice=start is not null?"Exact episode coverage":"Episode coordinates require an independent inventory proof."};
            absolute+=cours[i].Count??0;
        }
        var all=cours.Concat(specials.Select((n,i)=>new AnimeCour(n,Mapping(n),cours.Length+i+1,n.EpisodeCount,false,null,"Special episode identity; source dates must match uniquely."){HasIdentityConflict=Conflict(n)})).ToArray();
        return new(all,complete,complete?"Provider identities reconciled. Episode coordinates are assigned only after coverage and source inventory checks.":"Partial provider roster. Unproved episode coordinates are withheld.");
    }
    public static bool HasReciprocalChain(IReadOnlyList<AnimeCour> cours)=>cours.Count>0&&cours.Zip(cours.Skip(1)).All(p=>p.First.Node.StoryRelations.Any(r=>r.Kind is "SEQUEL" or "SEASON"&&r.Target==p.Second.Id)&&p.Second.Node.StoryRelations.Any(r=>r.Kind=="PREQUEL"&&r.Target==p.First.Id));
    private static bool NoMappedContradictions(IReadOnlyList<AnimeCour> cours)
    {
        var seasons=cours.Select(c=>c.Mapping?.TmdbSeason).Where(s=>s is >0).ToArray();
        if(seasons.Zip(seasons.Skip(1)).Any(p=>p.First>p.Second))return false;
        foreach(var group in cours.GroupBy(c=>c.Mapping?.TmdbSeason).Where(g=>g.Count()>1))
        {
            var rows=group.ToArray();if(rows[0].Mapping?.TvdbEpisodeOffset is >0)return false;
            foreach(var (before,after) in rows.Zip(rows.Skip(1)))
            {
                if(before.Mapping?.TvdbSeason is {} bs&&after.Mapping?.TvdbSeason is {} next&&bs>0&&next>0&&next<bs)return false;
                if(before.Mapping?.TvdbSeason is {} s&&s>0&&after.Mapping?.TvdbSeason==s&&before.Mapping.TvdbEpisodeOffset is {} offset&&after.Mapping.TvdbEpisodeOffset is {} nextOffset&&Count(before.Count)&&nextOffset!=(long)offset+before.Count)return false;
            }
        }
        return true;
    }
    public static int? ExactMappedStart(int index,IReadOnlyList<AnimeCour> cours,IReadOnlyDictionary<int,int> counts)
    {
        if(index<0||index>=cours.Count||cours[index].Mapping?.TmdbSeason is not >0)return null;
        var season=cours[index].Mapping!.TmdbSeason!.Value;if(!counts.TryGetValue(season,out var target))return null;
        var group=Enumerable.Range(0,cours.Count).Where(i=>cours[i].Mapping?.TmdbSeason==season).ToArray();
        if(group.Length==0||group.Length!=group[^1]-group[0]+1||group.Any(i=>!Count(cours[i].Count))||group.Sum(i=>(long)cours[i].Count!.Value)!=target)return null;
        var groupCours=group.Select(i=>cours[i]).ToArray();
        if(group.Length>1&&!CompatibleMappedOrder(groupCours,1)&&!(NoMappedContradictions(groupCours)&&HasReciprocalChain(groupCours)))return null;
        return 1+counts.Where(p=>p.Key>0&&p.Key<season).Sum(p=>p.Value)+group.Where(i=>i<index).Sum(i=>cours[i].Count!.Value);
    }
    public static bool ValidInventory(SeasonInventory inventory,int expected,bool contiguous=true)
    {
        var rows=inventory.Episodes.OrderBy(e=>e.TmdbEpisodeNumber).ToArray();
        return inventory.Number is >=0 and <=10000&&Count(expected)&&rows.Length==expected&&rows.All(e=>e.SourceEpisodeId is >0&&e.TmdbSeasonNumber==inventory.Number&&Count(e.TmdbEpisodeNumber))&&rows.Select(e=>e.SourceEpisodeId).Distinct().Count()==expected&&rows.Select(e=>e.TmdbEpisodeNumber).Distinct().Count()==expected&&(!contiguous||rows.Select((e,i)=>e.TmdbEpisodeNumber==i+1).All(v=>v));
    }
    public static IReadOnlyList<MediaEpisode>? SpecialWindow(AnimeCour cour,SeasonInventory inventory)
    {
        if(cour.HasIdentityConflict||cour.Node.Upcoming||!Count(cour.Count)||!ValidInventory(inventory,inventory.Episodes.Count,false)||Day(cour.Node.StartDate) is not {} start||(cour.Node.EndDate.Length>0&&Day(cour.Node.EndDate) is null))return null;
        var ordered=inventory.Episodes.OrderBy(e=>e.TmdbEpisodeNumber).ToArray();var matches=new List<MediaEpisode[]>();
        for(var i=0;i+cour.Count<=ordered.Length;i++)
        {
            var rows=ordered.Skip(i).Take(cour.Count!.Value).ToArray();if(Day(rows[0].AirDate)!=start)continue;
            var end=Day(cour.Node.EndDate);if(end is not null&&Day(rows[^1].AirDate)!=end)continue;
            if(rows.Select((e,j)=>e.TmdbEpisodeNumber==rows[0].TmdbEpisodeNumber+j&&Day(e.AirDate) is {} date&&date>=start&&(end is null||date<=end)).All(v=>v)&&rows.Zip(rows.Skip(1)).All(p=>Day(p.First.AirDate)<=Day(p.Second.AirDate)))matches.Add(rows);
        }
        return matches.Count==1?matches[0]:null;
    }
    public static IReadOnlyList<MediaEpisode>? ContainedCour(AnimeCour cour,SeasonInventory inventory,int expected,bool permitsMeasuredOneDayOffset=false,bool hasExplicitSpecialContinuation=false)
    {
        if(cour.HasIdentityConflict||!cour.Regular||!cour.Node.Ordinary||!cour.Node.Finished||!Count(cour.Count)||!ValidInventory(inventory,expected)||Day(cour.Node.StartDate) is not {} start||Day(cour.Node.EndDate) is not {} end||start>end||(cour.Node.Format=="ONA"&&cour.Count==1&&expected>1))return null;
        var source=inventory.Episodes.OrderBy(e=>e.TmdbEpisodeNumber).ToArray();var windows=new List<MediaEpisode[]>();
        for(var i=0;i+cour.Count<=source.Length;i++)
        {
            var rows=source.Skip(i).Take(cour.Count!.Value).ToArray();
            if(Day(rows[0].AirDate) is not{} first||Day(rows[^1].AirDate) is not{} last)continue;
            var offset=first.DayNumber-start.DayNumber;
            if((offset!=0&&!(permitsMeasuredOneDayOffset&&Math.Abs(offset)<=1))||last.DayNumber-end.DayNumber!=offset||rows.Any(e=>Day(e.AirDate) is null)||!rows.Zip(rows.Skip(1)).All(p=>Day(p.First.AirDate)<=Day(p.Second.AirDate)))continue;
            if(source.Take(i).Any(e=>Day(e.AirDate) is not {} date||date>=first)||source.Skip(i+rows.Length).Any(e=>Day(e.AirDate) is{} date?date<=last:e.AirDate.Length>0||hasExplicitSpecialContinuation))continue;
            var tail=source.Skip(i+rows.Length).ToArray();var mappedPrefix=cour.Mapping?.TmdbSeason==inventory.Number&&cour.Node.Format=="TV"&&cour.Count>=2&&i==0&&offset==0&&tail.All(e=>Day(e.AirDate)>end);
            if(rows.Length<expected&&!hasExplicitSpecialContinuation&&!mappedPrefix&&tail.Any(e=>Day(e.AirDate) is not null))continue;
            windows.Add(rows);
        }
        return windows.Count==1?windows[0]:null;
    }
    public static IReadOnlyDictionary<string,IReadOnlyList<MediaEpisode>> NonConflicting(IReadOnlyDictionary<string,IReadOnlyList<MediaEpisode>> placements)
    {
        var invalid=new HashSet<string>();var ids=new Dictionary<int,HashSet<string>>();var coordinates=new Dictionary<(int,int),HashSet<string>>();
        foreach(var (owner,rows) in placements)
        {
            var ownIds=new HashSet<int>();var ownCoordinates=new HashSet<(int,int)>();
            foreach(var row in rows)
            {
                if(row.SourceEpisodeId is not >0||row.TmdbSeasonNumber is not >=0||!Count(row.TmdbEpisodeNumber)){invalid.Add(owner);continue;}
                var id=row.SourceEpisodeId.Value;var coordinate=(row.TmdbSeasonNumber.Value,row.TmdbEpisodeNumber!.Value);
                if(!ownIds.Add(id)||!ownCoordinates.Add(coordinate))invalid.Add(owner);
                if(!ids.TryGetValue(id,out var a))ids[id]=a=[];a.Add(owner);if(!coordinates.TryGetValue(coordinate,out var b))coordinates[coordinate]=b=[];b.Add(owner);
            }
        }
        foreach(var owners in ids.Values.Concat(coordinates.Values).Where(s=>s.Count>1))invalid.UnionWith(owners);
        return placements.Where(p=>!invalid.Contains(p.Key)).ToDictionary();
    }
    public static IReadOnlyList<MediaEpisode> Project(AnimeCour cour,IReadOnlyList<MediaEpisode>? proof)
    {
        if(cour.Node.Upcoming)return [];
        if(proof is not null)return proof.Select((e,i)=>e with{Number=i+1,AnimeId=cour.Id}).ToArray();
        if(!Count(cour.Count))return [];
        return Enumerable.Range(1,cour.Count!.Value).Select(n=>new MediaEpisode(n,$"Episode {n}","Runtime TBA","","",null){AnimeId=cour.Id}).ToArray();
    }
}
