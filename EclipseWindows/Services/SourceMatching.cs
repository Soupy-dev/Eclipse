using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Eclipse.Windows.Services;

public static partial class TitleSimilarity
{
    private static readonly object Gate=new();
    private static readonly Dictionary<(string,string,string),double> Cache=[];
    [GeneratedRegex(@"[^a-z0-9\s]")] private static partial Regex Strip();
    public static readonly (string Id,string Name)[] Algorithms=[("hybrid","Hybrid"),("jaro_winkler","Jaro-Winkler Similarity"),("levenshtein","Levenshtein Distance")];
    public static double Score(string original,string result,string algorithm="hybrid")
    {
        if(original.Length==0||result.Length==0)return original.Length==0&&result.Length==0?1:0;
        var a=original.Trim();var b=result.Trim();
        if(a.Length==0||b.Length==0)return a.Length==0&&b.Length==0?1:0;
        lock(Gate)if(Cache.TryGetValue((algorithm,a,b),out var hit))return hit;
        var score=algorithm switch{"jaro_winkler"=>Single(a,b,JaroWinkler),"levenshtein"=>Single(a,b,Levenshtein),_=>Hybrid(a,b)};
        lock(Gate){if(Cache.Count>=4000)Cache.Clear();Cache[(algorithm,a,b)]=score;}
        return score;
    }
    private static double Single(string original,string result,Func<string,string,double> measure)
    {
        var s1=Normalize(original);var s2=Normalize(result);
        return s1.Length==0||s2.Length==0?s1.Length==0&&s2.Length==0?1:0:measure(s1,s2);
    }
    private static string Normalize(string value)=>Strip().Replace(value.ToLowerInvariant(),"");
    private static double Hybrid(string original,string result)
    {
        var s1=Normalize(original);var s2=Normalize(result);
        if(s1.Length==0||s2.Length==0)return s1.Length==0&&s2.Length==0?1:0;
        var jaro=JaroWinkler(s1,s2);var lev=Levenshtein(s1,s2);
        var average=(s1.Length+s2.Length)/2.0;var ratio=Math.Abs(s1.Length-s2.Length)/average;
        var limit=Math.Min(Math.Min(s1.Length,s2.Length),10);var common=0;while(common<limit&&s1[common]==s2[common])common++;
        var prefix=limit>0?(double)common/limit:0;
        var (jw,lw)=average<10||prefix>.7?(.7,.3):average>50?(.3,.7):ratio>.5?(.4,.6):(.5,.5);
        var bonus=1-Math.Abs(jaro-lev)>.8?.05:0;var penalty=(jaro+lev)/2<.3?.05:0;
        return Math.Clamp(jaro*jw+lev*lw+bonus-penalty,0,1);
    }
    private static double JaroWinkler(string s1,string s2)
    {
        var jaro=Jaro(s1,s2);if(jaro<.7)return jaro;
        var prefix=0;while(prefix<Math.Min(4,Math.Min(s1.Length,s2.Length))&&s1[prefix]==s2[prefix])prefix++;
        return jaro+.1*prefix*(1-jaro);
    }
    private static double Jaro(string s1,string s2)
    {
        var window=Math.Max(0,Math.Max(s1.Length,s2.Length)/2-1);var m1=new bool[s1.Length];var m2=new bool[s2.Length];var matches=0;
        for(var i=0;i<s1.Length;i++)for(int j=Math.Max(0,i-window),end=Math.Min(i+window+1,s2.Length);j<end;j++){if(m2[j]||s1[i]!=s2[j])continue;m1[i]=m2[j]=true;matches++;break;}
        if(matches==0)return 0;
        var transpositions=0;var k=0;
        for(var i=0;i<s1.Length;i++){if(!m1[i])continue;while(k<s2.Length&&!m2[k])k++;if(k>=s2.Length)break;if(s1[i]!=s2[k])transpositions++;k++;}
        return ((double)matches/s1.Length+(double)matches/s2.Length+(matches-transpositions/2.0)/matches)/3;
    }
    private static double Levenshtein(string s1,string s2)
    {
        var rows=s1.Length>=s2.Length?s1:s2;var columns=s1.Length>=s2.Length?s2:s1;
        if(columns.Length==0)return 1-(double)rows.Length/Math.Max(1,rows.Length);
        var previous=new int[columns.Length+1];var current=new int[columns.Length+1];for(var i=0;i<previous.Length;i++)previous[i]=i;
        for(var r=0;r<rows.Length;r++)
        {
            current[0]=r+1;
            for(var c=0;c<columns.Length;c++)current[c+1]=Math.Min(Math.Min(current[c]+1,previous[c+1]+1),previous[c]+(rows[r]==columns[c]?0:1));
            (previous,current)=(current,previous);
        }
        return 1-(double)previous[columns.Length]/Math.Max(s1.Length,s2.Length);
    }
}

public sealed record RankedResult(int Index,string Result,double InitialSimilarity,double TitleSimilarity,int AnimeSeasonPreference,int TieBreakScore,double DisplaySimilarity);

public sealed partial class ResultRanking
{
    public required string EffectiveTitle {get;init;}
    public required string MediaTitle {get;init;}
    public required string DisplayTitle {get;init;}
    public string? OriginalTitle {get;init;}
    public string? AnimeSeasonTitle {get;init;}
    public string? NormalizedAnimeSequelTitle {get;init;}
    public string? StrippedAnimeFallbackTitle {get;init;}
    public bool IsAnime {get;init;}
    public (int Season,int Episode)? SelectedEpisode {get;init;}
    public double MinimumSimilarity {get;init;}=.85;
    public string Algorithm {get;init;}="hybrid";
    [GeneratedRegex("[^a-z0-9]+")] private static partial Regex NonAlphanumeric();
    [GeneratedRegex(@"(?i)\s*-\s*S\d{1,3}E\d{1,4}$|(?i)\s*S\d{1,3}E\d{1,4}$|(?i)\s*-\s*E\d{1,4}$|(?i)\s*E\d{1,4}$|(?i)\s*episode\s+\d{1,4}$")] private static partial Regex EpisodeSuffix();
    private static readonly HashSet<string> Ignored=["a","an","and","the","of","to","in","on","tv","series","episode"];
    private bool AnimeContext=>IsAnime||AnimeSeasonTitle is not null;
    private string SheetBase=>StripEpisode(DisplayTitle);

    public IReadOnlyList<RankedResult> Rank(IReadOnlyList<string> results,CancellationToken token)
    {
        var match=Candidates(true,NormalizeTitle);var rank=Candidates(false,RankingKey);var tie=match.Select(NormalizeTitle).Where(t=>t.Length>0).ToArray();
        var markers=AnimeContext&&SelectedEpisode is {Season:>1} episode?SeasonMarkers(StripEpisode(EffectiveTitle),episode.Season):[];
        var ranked=results.Select((result,index)=>
        {
            token.ThrowIfCancellationRequested();
            var initial=match.Select(c=>TitleSimilarity.Score(c,result,Algorithm)).DefaultIfEmpty(0).Max();
            var alternate=OriginalTitle?.Trim();
            var candidates=AnimeContext&&alternate is {Length:>0}&&LooksAlternate(result,alternate)?[alternate]:rank;
            var title=candidates.Count==0?initial:candidates.Max(c=>RankingSimilarity(c,result));
            var season=markers.Count==0?0:markers.All(m=>Matches(StripEpisode(result),m))?1:0;
            return new RankedResult(index,result,initial,title,season,TieBreak(result,tie),Math.Max(TitleSimilarity.Score(EffectiveTitle,result,Algorithm),OriginalTitle is null?0:TitleSimilarity.Score(OriginalTitle,result,Algorithm)));
        }).ToList();
        ranked.Sort((l,r)=>
        {
            bool le=l.InitialSimilarity>=MinimumSimilarity,re=r.InitialSimilarity>=MinimumSimilarity;
            if(le!=re)return le?-1:1;
            if(le&&l.AnimeSeasonPreference!=r.AnimeSeasonPreference)return r.AnimeSeasonPreference.CompareTo(l.AnimeSeasonPreference);
            if(le&&Math.Abs(l.TitleSimilarity-r.TitleSimilarity)>=.0001)return r.TitleSimilarity.CompareTo(l.TitleSimilarity);
            if(Math.Abs(l.InitialSimilarity-r.InitialSimilarity)>=.0001)return r.InitialSimilarity.CompareTo(l.InitialSimilarity);
            if(l.TieBreakScore!=r.TieBreakScore)return r.TieBreakScore.CompareTo(l.TieBreakScore);
            return l.Index.CompareTo(r.Index);
        });
        return ranked;
    }
    private List<string> Candidates(bool matching,Func<string,string> key)
    {
        var seen=new HashSet<string>();
        string?[] values=[SheetBase,EffectiveTitle,MediaTitle,NormalizedAnimeSequelTitle,StrippedAnimeFallbackTitle,matching||!AnimeContext?OriginalTitle:null];
        return values.Select(v=>v?.Trim()).Where(v=>v is {Length:>0}&&seen.Add(key(v))).Select(v=>v!).ToList();
    }
    private static string NormalizeTitle(string title)=>NonAlphanumeric().Replace(title.ToLowerInvariant()," ").Trim();
    private static string RankingKey(string title)
    {
        var folded=new StringBuilder();
        foreach(var c in title.Normalize(NormalizationForm.FormKD))if(CharUnicodeInfo.GetUnicodeCategory(c)!=UnicodeCategory.NonSpacingMark)folded.Append(c);
        return NonAlphanumeric().Replace(folded.ToString().ToLowerInvariant()," ").Trim();
    }
    private static string StripEpisode(string title)=>EpisodeSuffix().Replace(title.Trim(),"",1).Trim();
    private bool LooksAlternate(string result,string alternate)
    {
        var display=RankingSimilarity(SheetBase,result);var other=RankingSimilarity(alternate,result);
        return other>=.82&&other>display+.06;
    }
    private double RankingSimilarity(string expected,string result)
    {
        var e=RankingKey(expected);var r=RankingKey(result);
        var score=Math.Max(TitleSimilarity.Score(expected,result,Algorithm),TitleSimilarity.Score(e,r,Algorithm))*.7+TokenOverlap(e,r)*.3;
        if(e.Length>0)score+=r==e?.15:r.Contains(e)||e.Contains(r)?.08:0;
        return Math.Max(0,score);
    }
    private static double TokenOverlap(string l,string r)
    {
        static HashSet<string> Tokens(string s)=>s.Split(' ',StringSplitOptions.RemoveEmptyEntries).Where(t=>t.Length>1&&!Ignored.Contains(t)).ToHashSet();
        var a=Tokens(l);var b=Tokens(r);if(a.Count==0||b.Count==0)return 0;
        return (double)a.Count(b.Contains)/Math.Max(a.Count,b.Count);
    }
    private static HashSet<(bool Part,int Number)> SeasonMarkers(string title,int? terminal=null)
    {
        var normalized=NormalizeTitle(title);var tokens=normalized.Split(' ',StringSplitOptions.RemoveEmptyEntries);var markers=new HashSet<(bool,int)>();
        static int? After(string prefix,string token)=>token.StartsWith(prefix)&&token.Length>prefix.Length&&int.TryParse(token.AsSpan(prefix.Length),out var n)?n:null;
        static int? Ordinal(string token){foreach(var s in new[]{"st","nd","rd","th"})if(token.EndsWith(s))return int.TryParse(token.AsSpan(0,token.Length-2),out var n)?n:null;return null;}
        for(var i=0;i<tokens.Length;i++)
        {
            var next=i+1<tokens.Length?tokens[i+1]:null;
            if(tokens[i]=="season"&&int.TryParse(next,out var s))markers.Add((false,s));else if(After("season",tokens[i]) is {} s2)markers.Add((false,s2));
            if(tokens[i]=="part"&&int.TryParse(next,out var p))markers.Add((true,p));else if(After("part",tokens[i]) is {} p2)markers.Add((true,p2));
            if(next=="season"&&Ordinal(tokens[i]) is {} o)markers.Add((false,o));
        }
        if(markers.Count==0&&terminal is {} t&&Terminal(normalized,t))markers.Add((false,t));
        return markers;
    }
    private static bool Matches(string title,(bool Part,int Number) marker)
    {
        var explicitMarkers=SeasonMarkers(title);if(explicitMarkers.Contains(marker))return true;
        return explicitMarkers.Count==0&&!marker.Part&&Terminal(title,marker.Number);
    }
    private static bool Terminal(string title,int season)=>Regex.IsMatch(title,$"[a-z]{season}$")||Regex.IsMatch(title,$@"\b{season}$");
    private int TieBreak(string result,string[] expected)
    {
        var normalized=NormalizeTitle(result);var score=0;
        foreach(var c in expected)score+=normalized==c?10:normalized.Contains(c)||c.Contains(normalized)?4:0;
        if(SelectedEpisode is {} e&&(normalized.Contains($"s{e.Season}e{e.Episode}")||normalized.Contains($"e{e.Episode}")))score+=3;
        if(SheetBase.Length>0)score+=(int)(TitleSimilarity.Score(SheetBase,result,Algorithm)*10);
        return score;
    }
}
