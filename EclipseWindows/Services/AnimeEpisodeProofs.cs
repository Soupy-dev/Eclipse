using System.Text.RegularExpressions;
using Eclipse.Windows.Models;

namespace Eclipse.Windows.Services;

// Independent proofs for catalogs whose cour boundaries do not match TMDB seasons.
public static class AnimeEpisodeProofs
{
    private static bool Link(AnimeCour before,AnimeCour after)=>before.Node.Relations.Any(r=>r.Kind is "SEQUEL" or "SEASON"&&r.Target==after.Id)&&after.Node.Relations.Any(r=>r.Kind=="PREQUEL"&&r.Target==before.Id);
    private static bool ValidRows(SeasonInventory source,int expected)=>AnimeReconciliation.ValidInventory(source,expected)&&source.Episodes.All(e=>AnimeReconciliation.Day(e.AirDate) is not null)&&source.Episodes.OrderBy(e=>e.TmdbEpisodeNumber).Zip(source.Episodes.OrderBy(e=>e.TmdbEpisodeNumber).Skip(1)).All(p=>AnimeReconciliation.Day(p.First.AirDate)<=AnimeReconciliation.Day(p.Second.AirDate));
    private static string Signature(string text)=>AnimeText.Signature(text);
    private static bool Named(AnimeCour cour,SeasonInventory source)=>cour.Node.Titles.Append(cour.Node.Title).Any(t=>Signature(t).Length>=8&&Signature(t)==Signature(source.Name));
    public static IReadOnlyDictionary<string,IReadOnlyList<MediaEpisode>> GroupedCours(IReadOnlyList<AnimeCour> candidates,SeasonInventory source,int expected)
    {
        var name=Signature(source.Name);if(name.Length<8||!ValidRows(source,expected))return new Dictionary<string,IReadOnlyList<MediaEpisode>>();
        var rows=source.Episodes.OrderBy(e=>e.TmdbEpisodeNumber).ToArray();var first=AnimeReconciliation.Day(rows[0].AirDate)!.Value;var last=AnimeReconciliation.Day(rows[^1].AirDate)!.Value;
        var group=candidates.Where(c=>!c.HasIdentityConflict&&c.Regular&&c.Node.Finished&&c.Node.Ordinary&&AnimeReconciliation.Day(c.Node.StartDate) is {} s&&s>=first&&AnimeReconciliation.Day(c.Node.EndDate) is {} e&&e<=last&&c.Node.Titles.Append(c.Node.Title).Any(t=>Signature(t).StartsWith(name,StringComparison.Ordinal))).OrderBy(c=>c.Node.StartDate,StringComparer.Ordinal).ToArray();
        var result=new Dictionary<string,IReadOnlyList<MediaEpisode>>();
        if(group.Length<2||group.Any(c=>!AnimeReconciliation.Count(c.Count))||group.Sum(c=>(long)c.Count!.Value)!=expected||!group.Zip(group.Skip(1)).All(p=>Link(p.First,p.Second)))return result;
        var cursor=0;
        foreach(var cour in group){var own=rows.Skip(cursor).Take(cour.Count!.Value).ToArray();if(own[0].AirDate!=cour.Node.StartDate)return new Dictionary<string,IReadOnlyList<MediaEpisode>>();result[cour.Id]=own;cursor+=own.Length;}
        return AnimeReconciliation.NonConflicting(result);
    }
    public static IReadOnlyList<MediaEpisode>? WholeCourWithSuccessor(AnimeCour cour,AnimeCour next,SeasonInventory source,int expected,SeasonInventory following,int nextExpected,IReadOnlyList<AnimeCour> roster)
    {
        if(cour.HasIdentityConflict||next.HasIdentityConflict||!cour.Node.Finished||!next.Node.Finished||!cour.Node.Ordinary||!next.Node.Ordinary||!Link(cour,next)||source.Number<=0||following.Number<=source.Number||!Named(cour,source)||!Named(next,following)||cour.Count!=expected||next.Count!=nextExpected||!ValidRows(source,expected)||!ValidRows(following,nextExpected)||AnimeReconciliation.Day(cour.Node.StartDate) is not {} start||AnimeReconciliation.Day(next.Node.StartDate) is not {} boundary||start>=boundary)return null;
        if(roster.Any(c=>c.Id!=cour.Id&&c.Node.Ordinary&&AnimeReconciliation.Day(c.Node.StartDate) is {} day&&day>=start&&day<boundary&&(c.Mapping?.TmdbSeason==source.Number||Named(c,source))))return null;
        var rows=source.Episodes.OrderBy(e=>e.TmdbEpisodeNumber).ToArray();var after=following.Episodes.OrderBy(e=>e.TmdbEpisodeNumber).ToArray();
        if(rows[0].AirDate!=cour.Node.StartDate||after[0].AirDate!=next.Node.StartDate||rows.Any(e=>AnimeReconciliation.Day(e.AirDate)>=boundary)||after.Any(e=>AnimeReconciliation.Day(e.AirDate)<boundary)||rows.Concat(after).Select(e=>e.SourceEpisodeId).Distinct().Count()!=rows.Length+after.Length)return null;
        return rows;
    }
    public static IReadOnlyDictionary<string,IReadOnlyList<MediaEpisode>> OngoingPrefix(IReadOnlyList<AnimeCour> cours,SeasonInventory source,int expected,DateOnly today,bool complete)
    {
        var result=new Dictionary<string,IReadOnlyList<MediaEpisode>>();
        if(!complete||cours.Count==0||cours.Any(c=>c.HasIdentityConflict||!c.Regular||!c.Node.Ordinary)||!cours[^1].Node.Releasing||cours.Take(cours.Count-1).Any(c=>!c.Node.Finished||!AnimeReconciliation.Count(c.Count))||!AnimeReconciliation.ValidInventory(source,expected)||cours.Any(c=>c.Mapping?.TmdbSeason is{} s&&s!=source.Number))return result;
        var rows=source.Episodes.OrderBy(e=>e.TmdbEpisodeNumber).ToArray();var prefix=cours.Take(cours.Count-1).Sum(c=>c.Count!.Value);var tail=cours[^1].Node.EpisodeCount??expected-prefix;
        if(!AnimeReconciliation.Count(tail)||prefix>=expected||(cours.Count==1&&tail>expected))return result;
        var total=prefix+tail;var allMappedTV=cours.Count>1&&cours.All(c=>c.Node.Format=="TV"&&c.Mapping?.TmdbShowId is >0)&&cours.Select(c=>c.Mapping!.TmdbShowId).Distinct().Count()==1&&cours.Zip(cours.Skip(1)).All(p=>Link(p.First,p.Second))&&ValidRows(source,expected);
        if(AnimeReconciliation.Day(cours[0].Node.StartDate) is not {} provider||AnimeReconciliation.Day(rows[0].AirDate) is not{} initial)return result;
        var offset=initial.DayNumber-provider.DayNumber;
        if(offset!=0&&!(allMappedTV&&Math.Abs(offset)<=1)&&!(offset==7&&cours.Count>1&&cours.All(c=>c.Node.Format=="ONA")))return result;
        var boundary=0;
        foreach(var cour in cours)
        {
            if(boundary>=rows.Length||AnimeReconciliation.Day(cour.Node.StartDate) is not{} p||AnimeReconciliation.Day(rows[boundary].AirDate) is not{} s)return new Dictionary<string,IReadOnlyList<MediaEpisode>>();
            var shift=s.DayNumber-p.DayNumber;if(shift!=offset&&!(allMappedTV&&Math.Abs(shift)<=1))return new Dictionary<string,IReadOnlyList<MediaEpisode>>();
            var count=cour.Id==cours[^1].Id?tail:cour.Count!.Value;result[cour.Id]=rows.Skip(boundary).Take(count).ToArray();boundary+=count;
        }
        if(rows.Skip(total).Any(e=>AnimeReconciliation.Day(e.AirDate) is not{} date||date<=today))return new Dictionary<string,IReadOnlyList<MediaEpisode>>();
        return AnimeReconciliation.NonConflicting(result);
    }
    public static IReadOnlyList<MediaEpisode>? SpecialContinuation(AnimeCour special,IReadOnlyList<AnimeCour> parents,SeasonInventory source,int showId)
    {
        if(special.HasIdentityConflict||special.Node.Format!="SPECIAL"||!special.Node.Finished||!AnimeReconciliation.Count(special.Count)||special.Node.StartDate!=special.Node.EndDate||AnimeReconciliation.Day(special.Node.StartDate) is not{} release||parents.Count!=1)return null;
        var parent=parents[0];var mapping=parent.Mapping;
        if(parent.HasIdentityConflict||mapping?.TmdbShowId!=showId||mapping.TmdbSeason is not >0||mapping.TmdbSeason!=source.Number||mapping.TvdbEpisodeOffset!=0||!parent.Node.Finished||!parent.Node.Ordinary||!AnimeReconciliation.Count(parent.Count)||!Link(parent,special)||!ValidRows(source,parent.Count!.Value+special.Count!.Value)||AnimeReconciliation.Day(parent.Node.StartDate) is not{} start||AnimeReconciliation.Day(parent.Node.EndDate) is not{} end||start>end)return null;
        var rows=source.Episodes.OrderBy(e=>e.TmdbEpisodeNumber).ToArray();var first=AnimeReconciliation.Day(rows[0].AirDate)!.Value;var last=AnimeReconciliation.Day(rows[parent.Count.Value-1].AirDate)!.Value;
        var shift=first.DayNumber-start.DayNumber;if(Math.Abs(shift)>1||last.DayNumber-end.DayNumber!=shift||last>=release)return null;
        var tail=rows.Skip(parent.Count.Value).ToArray();return tail.All(e=>e.AirDate==special.Node.StartDate)?tail:null;
    }
    public static IReadOnlyList<MediaEpisode>? EpisodeZero(int showId,AnimeCour cour,SeasonInventory source,SeasonInventory specials)
    {
        var n=cour.Node;
        if(showId!=68854||n.AniListId!=9656||n.MalId is not (null or 9656)||n.EpisodeCount!=13||n.Format!="TV"||n.Status!="FINISHED"||n.StartDate!="2011-01-12"||n.EndDate!="2011-03-30"||source.Number!=2||!ValidRows(source,12)||specials.Number!=0||!AnimeReconciliation.ValidInventory(specials,specials.Episodes.Count,false))return null;
        var rows=source.Episodes.OrderBy(e=>e.TmdbEpisodeNumber).ToArray();if(rows[0].SourceEpisodeId!=1344631||rows[^1].SourceEpisodeId!=1344642||rows[0].AirDate!=n.StartDate||rows[^1].AirDate!=n.EndDate||rows.Any(e=>AnimeReconciliation.Day(e.AirDate)<AnimeReconciliation.Day(n.StartDate)||AnimeReconciliation.Day(e.AirDate)>AnimeReconciliation.Day(n.EndDate)))return null;
        var candidates=specials.Episodes.Where(e=>e.TmdbEpisodeNumber==1).ToArray();var all=rows.Concat(specials.Episodes).ToArray();
        if(candidates.Length!=1||candidates[0].SourceEpisodeId!=1699406||candidates[0].AirDate!="2011-01-05"||all.Select(e=>e.SourceEpisodeId).Distinct().Count()!=all.Length)return null;
        return new[]{candidates[0]}.Concat(rows).ToArray();
    }
    public static int? TerminalSeasonNumber(IReadOnlyList<AnimeCour> cours,IReadOnlyDictionary<int,int> counts)
    {
        if(!AnimeReconciliation.ValidCounts(counts)||cours.Count is <2 or >64||cours.Count!=counts.Count||cours.Any(c=>c.HasIdentityConflict)||cours.Select(c=>c.Id).Distinct().Count()!=cours.Count)return null;
        var keys=counts.Keys.Order().ToArray();var last=cours[^1];
        var show=cours[0].Mapping?.TmdbShowId;
        if(show is not >0||cours.Any(c=>c.Mapping is{} m&&m.TmdbShowId!=show))return null;
        if(!last.Node.Releasing||last.Node.EpisodeCount is not null||!last.Node.Ordinary||AnimeReconciliation.Day(last.Node.StartDate) is null||!Link(cours[^2],last)||(last.Mapping is{} mapping&&(mapping.TmdbSeason!=keys[^1]||mapping.TmdbShowId is not >0)))return null;
        for(var i=0;i<cours.Count-1;i++)if(!cours[i].Node.Finished||!cours[i].Node.Ordinary||cours[i].Mapping?.TmdbSeason!=keys[i]||cours[i].Count!=counts[keys[i]])return null;
        return keys[^1];
    }
    public static IReadOnlyList<MediaEpisode>? TerminalUnknown(IReadOnlyList<AnimeCour> cours,IReadOnlyDictionary<int,int> counts,SeasonInventory source,DateOnly today)
    {
        if(TerminalSeasonNumber(cours,counts) is not{} season||source.Number!=season||!ValidRows(source,counts[season])||AnimeReconciliation.Day(cours[^1].Node.StartDate) is not{} start||start>today)return null;
        var rows=source.Episodes.OrderBy(e=>e.TmdbEpisodeNumber).ToArray();return rows[0].AirDate==cours[^1].Node.StartDate&&rows.All(e=>AnimeReconciliation.Day(e.AirDate)>=start)?rows:null;
    }
    private static (string Name,int Part)? Arc(string name)
    {
        var match=Regex.Match(name,@"^(.*?)\s*(?:\(([0-9]{1,2})\)|\bpart\s+([0-9]{1,2}))\s*$",RegexOptions.IgnoreCase|RegexOptions.CultureInvariant,TimeSpan.FromMilliseconds(100));
        if(!match.Success)return null;var title=Signature(match.Groups[1].Value);var number=match.Groups[2].Success?match.Groups[2].Value:match.Groups[3].Value;
        return title.Length>=4&&int.TryParse(number,out var n)&&n>0?(title,n):null;
    }
    public static IReadOnlyList<MediaEpisode>? NumberedArc(AnimeCour cour,SeasonInventory source,int expected,SeasonInventory specials)
    {
        if(cour.HasIdentityConflict||!cour.Node.Ordinary||!cour.Node.Finished||!AnimeReconciliation.Count(cour.Count)||cour.Count<=expected||cour.Count-expected>8||!ValidRows(source,expected)||!AnimeReconciliation.ValidInventory(specials,specials.Episodes.Count,false)||AnimeReconciliation.Day(cour.Node.StartDate) is null||AnimeReconciliation.Day(cour.Node.EndDate) is not{} end)return null;
        var regular=source.Episodes.OrderBy(e=>e.TmdbEpisodeNumber).ToArray();if(regular[0].AirDate!=cour.Node.StartDate||Arc(regular[^1].Title) is not{} arc)return null;
        var last=AnimeReconciliation.Day(regular[^1].AirDate)!.Value;
        var extra=specials.Episodes.Where(e=>AnimeReconciliation.Day(e.AirDate) is{} date&&date>last&&date<=end&&Arc(e.Title) is{} next&&next.Name==arc.Name&&next.Part>arc.Part&&next.Part<=arc.Part+cour.Count-expected).OrderBy(e=>e.AirDate,StringComparer.Ordinal).ToArray();
        if(extra.Length!=cour.Count-expected||extra.Where((e,i)=>Arc(e.Title)!.Value.Part!=arc.Part+i+1).Any()||extra[^1].AirDate!=cour.Node.EndDate)return null;
        var rows=regular.Concat(extra).ToArray();return rows.Select(e=>e.SourceEpisodeId).Distinct().Count()==rows.Length?rows:null;
    }
    private static string EpisodeTitle(string value)
    {
        var tokens=Regex.Split(value.Normalize(System.Text.NormalizationForm.FormKC).ToLowerInvariant(),@"[^\p{L}\p{N}]+").Where(t=>t.Length>0).ToList();
        string[] words=["one","two","three","four","five","six","seven","eight","nine","ten"],roman=["i","ii","iii","iv","v","vi","vii","viii","ix","x"];
        if(tokens.Count>0){var index=Array.IndexOf(words,tokens[^1]);if(index<0)index=Array.IndexOf(roman,tokens[^1]);if(index>=0)tokens[^1]=(index+1).ToString();}
        if(tokens.Count>1&&tokens[^2]=="part"&&int.TryParse(tokens[^1],out _))tokens.RemoveAt(tokens.Count-2);return string.Concat(tokens);
    }
    public static IReadOnlyList<MediaEpisode>? EpisodeList(AnimeCour cour,SeasonInventory source,int expected,SeasonInventory specials,IReadOnlyList<string> streamingTitles)
    {
        if(cour.HasIdentityConflict||!cour.Node.Ordinary||!cour.Node.Finished||!AnimeReconciliation.Count(cour.Count)||cour.Count<=expected||cour.Count-expected>8||streamingTitles.Count!=cour.Count||!ValidRows(source,expected)||!AnimeReconciliation.ValidInventory(specials,specials.Episodes.Count,false)||AnimeReconciliation.Day(cour.Node.StartDate) is not{} start||AnimeReconciliation.Day(cour.Node.EndDate) is not{} end||start>end)return null;
        var titles=new SortedDictionary<int,string>();
        foreach(var title in streamingTitles){var match=Regex.Match(title,@"^Episode\s+([0-9]+)\s*[-–:]\s*(.+)$",RegexOptions.IgnoreCase|RegexOptions.CultureInvariant,TimeSpan.FromMilliseconds(100));if(!match.Success||!int.TryParse(match.Groups[1].Value,out var n)||!titles.TryAdd(n,EpisodeTitle(match.Groups[2].Value)))return null;}
        if(!titles.Keys.SequenceEqual(Enumerable.Range(1,cour.Count!.Value))||titles.Values.Distinct().Count()!=titles.Count)return null;
        var regular=source.Episodes.OrderBy(e=>e.TmdbEpisodeNumber).ToArray();if(regular[0].AirDate!=cour.Node.StartDate||regular[^1].AirDate!=cour.Node.EndDate)return null;
        var rows=regular.Concat(specials.Episodes.Where(e=>AnimeReconciliation.Day(e.AirDate) is{} date&&date>=start&&date<=end)).OrderBy(e=>e.AirDate,StringComparer.Ordinal).ThenByDescending(e=>e.TmdbSeasonNumber).ThenBy(e=>e.TmdbEpisodeNumber).ToArray();
        if(rows.Length!=cour.Count||rows.Select(e=>e.SourceEpisodeId).Distinct().Count()!=rows.Length||!rows.Select(e=>EpisodeTitle(e.Title)).SequenceEqual(titles.Values))return null;
        return rows;
    }
}
