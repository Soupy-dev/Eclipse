using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Eclipse.Windows.Services;

public interface IStreamText
{
    string? Name {get;}
    string? Title {get;}
    string? Description {get;}
    string? Filename {get;}
    IReadOnlyList<string> LanguageHints {get;}
    string? FormattedVideoSize {get;}
}

internal static class TextSplitting
{
    public static string[] Split(this string value,Func<char,bool> separator,StringSplitOptions options=StringSplitOptions.None)
    {
        var parts=new List<string>();var start=0;
        for(var i=0;i<=value.Length;i++)if(i==value.Length||separator(value[i])){if(options!=StringSplitOptions.RemoveEmptyEntries||i>start)parts.Add(value[start..i]);start=i+1;}
        return parts.ToArray();
    }
}

public sealed record StreamQuality(int? Height,double? SizeMb,double SourceScore,double FeatureScore);

internal sealed record LanguageSearchText(string Value,HashSet<string> ShortCodeTokens,HashSet<string> LanguageIds);

public static partial class StreamDetection
{
    private const int MaxHint=512,MaxSearch=8192,MaxTokenScalars=24;
    private static readonly char[] Newlines=['\n','\r','\u000B','\u000C','\u0085',(char)0x2028,(char)0x2029];
    private static readonly (string Name,HashSet<string> Markers)[] Markers=
    [
        ("English",["english","eng","en"]),("Japanese",["japanese","jpn","ja","jp"]),("Hindi",["hindi","hin","hi"]),("Korean",["korean","kor","ko"]),
        ("Chinese",["chinese","mandarin","cantonese","zho","chi","zh"]),("Spanish",["spanish","spa","es"]),("Bulgarian",["bulgarian","bul","bg"]),
        ("Latino",["latino","latin","lat","latam","latinoamericano"]),("French",["french","fra","fre","fr"]),("German",["german","deu","ger","de"]),
        ("Italian",["italian","ita","it"]),("Portuguese",["portuguese","por","pt"]),("Russian",["russian","rus","ru"]),("Arabic",["arabic","ara","ar"]),
        ("Tamil",["tamil","tam","ta"]),("Telugu",["telugu","tel","te"]),("Bengali",["bengali","ben","bn"]),("Malayalam",["malayalam","mal","ml"]),
        ("Kannada",["kannada","kan","kn"]),("Marathi",["marathi","mar","mr"]),("Turkish",["turkish","tur","tr"]),("Polish",["polish","pol","pl"]),
        ("Dutch",["dutch","nld","dut","nl"]),("Indonesian",["indonesian","ind","id"]),("Thai",["thai","tha","th"]),("Vietnamese",["vietnamese","vie","vi"]),
        ("Ukrainian",["ukrainian","ukr","uk"]),("Swedish",["swedish","swe","sv"]),("Norwegian",["norwegian","nor","nob","nno","nb","nn","no"]),
        ("Danish",["danish","dan","da"]),("Finnish",["finnish","fin","fi"]),("Icelandic",["icelandic","isl","ice","is"]),("Greek",["greek","ell","gre","el"]),
        ("Czech",["czech","ces","cze","cs"]),("Slovak",["slovak","slk","slo","sk"]),("Hungarian",["hungarian","hun","hu"]),("Romanian",["romanian","ron","rum","ro"]),
        ("Croatian",["croatian","hrv","hr"]),("Serbian",["serbian","srp","sr"]),("Bosnian",["bosnian","bos","bs"]),("Slovenian",["slovenian","slv","sl"]),
        ("Estonian",["estonian","est","et"]),("Latvian",["latvian","lav","lv"]),("Lithuanian",["lithuanian","lit","lt"]),("Hebrew",["hebrew","heb","he","iw"]),
        ("Persian",["persian","farsi","fas","per","fa"]),("Urdu",["urdu","urd","ur"]),("Punjabi",["punjabi","panjabi","pan","pa"]),("Gujarati",["gujarati","guj","gu"]),
        ("Filipino",["filipino","tagalog","fil","tgl","tl"]),("Malay",["malay","msa","may","ms"])
    ];
    private static readonly (string Flag,string Name)[] Flags=[("🇬🇧","English"),("🇺🇸","English"),("🇯🇵","Japanese"),("🇫🇷","French"),("🇩🇪","German"),("🇮🇹","Italian"),("🇪🇸","Spanish"),("🇰🇷","Korean"),("🇵🇹","Portuguese"),("🇷🇺","Russian"),("🇺🇦","Ukrainian"),("🇹🇷","Turkish"),("🇵🇱","Polish"),("🇧🇬","Bulgarian")];
    private static readonly HashSet<string> Ambiguous3=["may","per","est","lit","rum","dan","pan","fin"];
    private static readonly HashSet<string> AmbiguousShort=["de","es","id","it","mr","ms","la","is","in","no","me","so","to","may","per","est","lit","rum","dan","pan","fin"];
    private static readonly HashSet<string> ContextWords=["audio","audios","dub","dubs","dubbed","dublado","sub","subs","subbed","subtitle","subtitles","subtitulos","lang","langs","language","languages","dual","multi","multiaudio","multilang","multilanguage","track","tracks"];
    private static readonly HashSet<string> StructureTokens=["4k","8k","uhd","fhd","qhd","hd","sd","hdr","hdr10","hdr10plus","dv","dovi","hlg","sdr","10bit","8bit","hi10p","bluray","blu","ray","bdrip","bdremux","brrip","bd","remux","web","webrip","webdl","dl","hdtv","hdrip","dvdrip","dvd","dvdscr","cam","hdcam","ts","hdts","telesync","telecine","pdtv","tvrip","sdtv","vodrip","x264","x265","h264","h265","hevc","avc","av1","xvid","divx","vp9","aac","ac3","eac3","dd","ddp","dd5","ddp5","dts","dtshd","truehd","atmos","opus","flac","mp3","amzn","nf","dsnp","hmax","atvp","pcok","hulu","itunes","hbo","sho","proper","repack","extended","uncut","unrated","imax","limited","internal","complete","season","seasons","episode","remastered","theatrical","directors","mkv","mp4","avi","m4v","mov","esub","esubs","msub","msubs"];
    private static readonly HashSet<string> ResolutionHeights=["240","360","480","540","576","720","1080","1440","2160","4320"];
    private static readonly HashSet<string> UnambiguousMarkers=Markers.SelectMany(m=>m.Markers).Where(m=>!AmbiguousShort.Contains(m)).ToHashSet();
    private static readonly HashSet<string> AnimeAudioTokens=Markers.SelectMany(m=>m.Markers).SelectMany(m=>Tokens(m.ToLowerInvariant())).Concat(["audio","dual","multi","dub","dubbed","sub","subbed","subs","subtitles","and"]).ToHashSet();
    private static readonly (int Height,Regex Regex)[] Resolutions=new[]{2160,1440,1080,720,480,360}.Select(h=>(h,new Regex(h==2160?@"(?<![a-wyz0-9])(?:2160(?:p|i)?|4k|uhd)(?![a-z0-9])(?!\s*(?:mb|mib|gb|gib)\b)":$@"(?<![a-wyz0-9]){h}(?:p|i)?(?![a-z0-9])(?!\s*(?:mb|mib|gb|gib)\b)",RegexOptions.IgnoreCase|RegexOptions.CultureInvariant|RegexOptions.Compiled))).ToArray();
    private static readonly (int Height,Regex Regex)[] Dimensions=new[]{(2160,@"(?<![0-9])(?:3840|4096)\s*[x×]\s*2160(?![0-9])"),(1440,@"(?<![0-9])2560\s*[x×]\s*1440(?![0-9])"),(1080,@"(?<![0-9])1920\s*[x×]\s*1080(?![0-9])"),(720,@"(?<![0-9])1280\s*[x×]\s*720(?![0-9])"),(480,@"(?<![0-9])(?:854|720|640)\s*[x×]\s*480(?![0-9])")}.Select(d=>(d.Item1,new Regex(d.Item2,RegexOptions.IgnoreCase|RegexOptions.CultureInvariant|RegexOptions.Compiled))).ToArray();
    [GeneratedRegex(@"(\d+(?:\.\d+)?)\s*(gb|gib|mb|mib)",RegexOptions.IgnoreCase|RegexOptions.CultureInvariant)] private static partial Regex FileSize();
    [GeneratedRegex(@"[\[(]([^\[\]()]{1,128})[\])]")] private static partial Regex Bracket();
    [GeneratedRegex(@"\baudio\s*[:：-]\s*[^|;\n]+$",RegexOptions.IgnoreCase|RegexOptions.CultureInvariant)] private static partial Regex AnimeAudioLabel();
    [GeneratedRegex(@"(?<![\p{L}\p{N}])(?:es|spa|spanish)(?:[-_.\s]+|\s*\(\s*)(?:latinoamerican|latinamerican|latino|latin|latam|lat|419)(?:\s*\))?(?![\p{L}\p{N}])",RegexOptions.IgnoreCase|RegexOptions.CultureInvariant)] private static partial Regex LatinoSpanish();
    [GeneratedRegex(@"^[^\p{L}\p{N}]*(?:(?:subtitles?|subs?|captions?)\s*[:：]|(?:no|without)\s+(?:(?:included|available|external|embedded)\s+)?(?:subtitles?|subs?|captions?)\b)",RegexOptions.IgnoreCase|RegexOptions.CultureInvariant)] private static partial Regex SubtitleLine();
    [GeneratedRegex(@"^[^\p{L}\p{N}]*(?:audio(?:\s+(?:languages?|tracks?))?|languages?|langs?)\s*[:：]\s*(.+)$",RegexOptions.IgnoreCase|RegexOptions.CultureInvariant)] private static partial Regex AudioLine();
    [GeneratedRegex(@"(?<![\p{L}\p{N}])(?:subtitles?|subs?|captions?)\s*[:：]",RegexOptions.IgnoreCase|RegexOptions.CultureInvariant)] private static partial Regex InlineSubtitle();
    [GeneratedRegex(@"(?<![\p{L}\p{N}])(?:audio(?:\s+(?:languages?|tracks?))?|languages?|langs?)\s*[:：]",RegexOptions.IgnoreCase|RegexOptions.CultureInvariant)] private static partial Regex InlineAudio();
    [GeneratedRegex(@"(\d+(?:\.\d+)?\s*(?:GB|MB|gb|mb))")] private static partial Regex DisplaySize();
    [GeneratedRegex(@"\d+(?:\.\d+)?\s*(?:KB|MB|GB|TB)",RegexOptions.IgnoreCase|RegexOptions.CultureInvariant)] private static partial Regex DisplayedSize();
    private static readonly Lazy<Regex> AnimeAudioSuffix=new(()=>new Regex($@"\b(?:(?:{string.Join('|',Markers.Where(m=>m.Name is not ("Dual Audio" or "Multi Audio")).SelectMany(m=>m.Markers).Distinct().OrderByDescending(m=>m.Length).Select(Regex.Escape))})\s+)?dub(?:bed)?\s*$",RegexOptions.IgnoreCase|RegexOptions.CultureInvariant));
    private static readonly Lazy<Regex> SubtitleSuffix=new(()=>
    {
        var markers=string.Join('|',Markers.SelectMany(m=>m.Markers).Concat(MediaLanguages.All.SelectMany(l=>new[]{l.Id,l.Name,l.NativeName}.Concat(l.Aliases))).Concat(Flags.Select(f=>f.Flag)).Distinct().OrderByDescending(m=>m.Length).Select(Regex.Escape));
        const string region="(?!(?:audio|dubbed|dubs?|tracks?|subtitles?|subs?|captions?)(?![a-z0-9]))(?:[a-z0-9]{2,4}|latam|latino|latin|latinoamerican|latinamerican)";
        var language=$@"(?:{markers})(?:(?:[-_]{region})|(?:\s*\((?:{region}|latin\s+america)\)))?";
        return new Regex($@"(?<![\p{{L}}\p{{N}}])({language})((?:(?:[\s./,+&_-]+|\s+(?:and|or)\s+){language})*)[\s._-]+(?:subtitles?|subs?|captions?)(?![\p{{L}}\p{{N}}])",RegexOptions.IgnoreCase|RegexOptions.CultureInvariant|RegexOptions.Compiled);
    });

    private static string Prefix(string value,int count)=>value.Length<=count?value:count<=0?"":char.IsHighSurrogate(value[count-1])?value[..(count-1)]:value[..count];
    private static string[] Lines(string value)=>value.Split(Newlines);
    private static IEnumerable<string> Tokens(string value)=>value.Split(c=>!char.IsLetterOrDigit(c),StringSplitOptions.RemoveEmptyEntries);

    public static StreamQuality Quality(string label)
    {
        var bounded=TaggableText([label]);var lower=bounded.ToLowerInvariant();
        double source=lower.Contains("remux")?9:lower.Contains("bluray")||lower.Contains("blu-ray")||lower.Contains("bdrip")||lower.Contains("brrip")?8:lower.Contains("web-dl")||lower.Contains("webdl")?7:
            lower.Contains("webrip")||lower.Contains(" web ")||lower.Contains(".web.")?6:lower.Contains("hdtv")||lower.Contains("hdrip")?5:lower.Contains("dvdrip")||lower.Contains("dvd")?4:
            lower.Contains("cam")||lower.Contains("hdcam")||lower.Contains(" telesync")||lower.Contains(" ts ")?1:3;
        var feature=0.0;
        if(lower.Contains("cached")||lower.Contains("cache"))feature+=.4;
        if(lower.Contains("hdr")||lower.Contains("dolby vision")||lower.Contains(" dv "))feature+=.2;
        if(lower.Contains("hevc")||lower.Contains("x265")||lower.Contains("h265")||lower.Contains("h.265"))feature+=.1;
        return new(Resolution(bounded),LargestSizeMb(bounded),source,feature);
    }
    public static int? Resolution(string label)
    {
        foreach(var d in Dimensions)if(d.Regex.IsMatch(label))return d.Height;
        foreach(var r in Resolutions)if(r.Regex.IsMatch(label))return r.Height;
        return null;
    }
    public static double? LargestSizeMb(string label)
    {
        double? best=null;
        foreach(Match m in FileSize().Matches(label))if(double.TryParse(m.Groups[1].Value,NumberStyles.Float,CultureInfo.InvariantCulture,out var value)){var mb=m.Groups[2].Value.StartsWith('g')||m.Groups[2].Value.StartsWith('G')?value*1024:value;if(best is null||mb>best)best=mb;}
        return best;
    }

    public static List<string> QualityMetadata(IStreamText stream)
    {
        var fields=new[]{stream.Name,stream.Description,stream.Title,stream.Filename}.Where(f=>f is not null).Select(f=>TaggableFragment(f!.Trim())).Where(f=>f.Length>0).ToList();
        var declared=fields.Select(Resolution).FirstOrDefault(h=>h is not null);
        if(declared is null)return fields;
        return fields.SelectMany(Lines).Where(f=>Resolution(f) is not {} h||h==declared).ToList();
    }
    public static string StremioLabel(IStreamText stream)
    {
        var parts=new List<string>();if(stream.Name is {Length:>0} name)parts.Add(name);
        if(new[]{stream.Title,stream.Description}.FirstOrDefault(d=>d is not null&&d.Trim().Length>0) is {} detail)
        {
            var lines=detail.Split('\n').Select(l=>l.Trim()).Where(l=>l.Length>0).ToArray();
            var tags=QualityTags(QualityMetadata(stream));
            if(tags.Length>0)parts.Add(tags);else if(lines.FirstOrDefault() is {} first&&first!=stream.Name)parts.Add(first);
        }
        if(LanguageLabel(stream) is {} language&&!LanguageAlreadyShown(language,parts))parts.Add(language);
        if(!DisplayedSize().IsMatch(string.Join(' ',parts))&&stream.FormattedVideoSize is {} size)parts.Add(size);
        return parts.Count==0?"Stream":string.Join(" · ",parts);
    }
    public static string? LanguageLabel(IStreamText stream)
    {
        var metadata=Metadata(stream);
        var languages=stream.LanguageHints.Concat(LanguageHintsFromMetadata(metadata)).SelectMany(SplitHint).Select(NormalizedLanguageName).Where(n=>n is not null).Select(n=>n!).ToList();
        var search=SearchText(metadata);languages.AddRange(DetectedLanguageNames(search));
        var unique=languages.Distinct().ToList();
        if(unique.Contains("Multi Audio")||unique.Count>3)return "Multi Audio";
        var named=unique.Where(l=>l!="Dual Audio").ToList();if(named.Count>0)return string.Join('/',named);
        if(ContainsMarker("multi audio",search)||ContainsMarker("multi-language",search)||ContainsMarker("multilang",search))return "Multi Audio";
        if(unique.Contains("Dual Audio")||ContainsMarker("dual audio",search))return "Dual Audio";
        return null;
    }
    internal static List<string> Metadata(IStreamText stream)=>new[]{stream.Name,stream.Title,stream.Description,stream.Filename}.Where(v=>v is not null).Select(v=>v!.Trim()).Where(v=>v.Length>0).ToList();
    public static IEnumerable<string> SplitHint(string value)=>Prefix(value,MaxHint).Split(c=>c is ',' or '/' or '|' or ';' or '+').Select(v=>v.Trim()).Where(v=>v.Length>0);

    public static string? NormalizedLanguageName(string value)
    {
        var normalized=value.Trim().ToLowerInvariant().Replace('_','-').Trim('[',']','(',')','{','}');
        foreach(var flag in Flags)if(flag.Flag==normalized)return flag.Name;
        if(IsLatinoSpanish(normalized))return "Latino";
        if(MediaLanguages.Find(normalized) is {} language)return language.Id=="es-419"?"Latino":language.Name;
        var dash=normalized.IndexOf('-');var code=dash<0?normalized:normalized[..dash];
        return code switch
        {
            "dual" or "dual audio" or "dual-audio"=>"Dual Audio",
            "multi" or "multi audio" or "multi-audio" or "multilang" or "multi-language"=>"Multi Audio",
            "eng" or "en" or "english"=>"English","jpn" or "ja" or "jp" or "japanese"=>"Japanese","hin" or "hi" or "hindi"=>"Hindi","kor" or "ko" or "korean"=>"Korean",
            "chi" or "zho" or "zh" or "chinese" or "mandarin" or "cantonese"=>"Chinese","spa" or "es" or "esp" or "spanish"=>"Spanish","bul" or "bg" or "bulgarian"=>"Bulgarian",
            "lat" or "latin" or "latino"=>"Latino","fre" or "fra" or "fr" or "french"=>"French","ger" or "deu" or "de" or "german"=>"German","ita" or "it" or "italian"=>"Italian",
            "por" or "pt" or "portuguese"=>"Portuguese","rus" or "ru" or "russian"=>"Russian","ara" or "ar" or "arabic"=>"Arabic","tam" or "ta" or "tamil"=>"Tamil",
            "tel" or "te" or "telugu"=>"Telugu","ben" or "bn" or "bengali"=>"Bengali","mal" or "ml" or "malayalam"=>"Malayalam","kan" or "kn" or "kannada"=>"Kannada",
            "mar" or "mr" or "marathi"=>"Marathi","tur" or "tr" or "turkish"=>"Turkish","pol" or "pl" or "polish"=>"Polish","dut" or "nld" or "nl" or "dutch"=>"Dutch",
            "ind" or "id" or "indonesian"=>"Indonesian","tha" or "th" or "thai"=>"Thai","vie" or "vi" or "vietnamese"=>"Vietnamese","ukr" or "uk" or "ukrainian"=>"Ukrainian",
            _=>dash<0&&normalized.Length==0?null:Markers.FirstOrDefault(m=>m.Markers.Contains(code)).Name
        };
    }
    private static bool IsLatinoSpanish(string value)
    {
        var tokens=Tokens(value).ToHashSet();
        string[] latino=["lat","latin","latino","latam","419","latinoamerican","latinamerican"];string[] spanish=["es","spa","spanish"];
        if(tokens.Overlaps(latino)&&(tokens.Overlaps(spanish)||tokens.Overlaps(["lat","latin","latino","latam"])))return true;
        var parts=value.Split('-',StringSplitOptions.RemoveEmptyEntries);
        return parts.Length>1&&spanish.Contains(parts[0])&&parts.Skip(1).Any(latino.Contains);
    }

    internal static LanguageSearchText SearchText(IEnumerable<string> values)=>FreeTextSearch(TaggableText(values));
    internal static LanguageSearchText SearchText(string value)=>SearchText([value]);
    internal static LanguageSearchText HintSearchText(IEnumerable<string> values)
    {
        var hints=values.SelectMany(SplitHint).ToList();var ids=new HashSet<string>();var remaining=new List<string>();
        foreach(var hint in hints){if(CatalogHint(hint) is {} language)ids.Add(language.Id);else remaining.Add(hint);}
        var combined=Combined(remaining).ToLowerInvariant();
        return new(combined,AsciiTokens(combined).Where(IsShortCode).ToHashSet(),ids);
    }
    internal static string TaggableText(IEnumerable<string> values)=>Combined(values.Select(TaggableFragment));
    private static LanguageSearchText FreeTextSearch(string source)
    {
        var canonical=LatinoSpanish().Replace(source,"Latino");
        return new(canonical.ToLowerInvariant(),TagLikeShortCodes(canonical),ExplicitLanguageIds(canonical));
    }
    internal static MediaLanguage? CatalogHint(string value)
    {
        if(IsLatinoSpanish(value.ToLowerInvariant().Replace('_','-')))return MediaLanguages.Find("es-419");
        return MediaLanguages.Find(value)??(NormalizedLanguageName(value) is {} name?MediaLanguages.Find(name):null);
    }
    private static HashSet<string> ExplicitLanguageIds(string source)
    {
        var ids=LanguageHintsFromMetadata([source]).Select(MediaLanguages.CanonicalId).Where(i=>i is not null).Select(i=>i!).ToHashSet();
        foreach(Match match in Bracket().Matches(source))foreach(var value in SplitHint(match.Groups[1].Value))if(CatalogHint(value) is {} language)ids.Add(language.Id);
        return ids;
    }
    private static string Combined(IEnumerable<string> values)
    {
        var combined=new StringBuilder();var remaining=MaxSearch;
        foreach(var value in values)
        {
            if(remaining<=0)break;
            var fragment=Prefix(value,remaining).Trim();if(fragment.Length==0)continue;
            if(combined.Length>0){combined.Append('\n');if(--remaining<=0)break;}
            var bounded=Prefix(fragment,remaining);combined.Append(bounded);remaining-=bounded.Length;
        }
        return combined.ToString();
    }
    private static string AudioFragment(string line)
    {
        var subtitles=InlineSubtitle().Matches(line);var audio=InlineAudio().Matches(line);
        var withoutTail=new StringBuilder();var cursor=0;
        foreach(Match label in subtitles)
        {
            if(label.Index<cursor)continue;
            withoutTail.Append(line,cursor,label.Index-cursor);
            cursor=audio.Select(a=>a.Index).Where(i=>i>=label.Index+label.Length).DefaultIfEmpty(line.Length).First();
        }
        withoutTail.Append(line,cursor,line.Length-cursor);
        var text=withoutTail.ToString();var result=new StringBuilder();cursor=0;
        foreach(Match suffix in SubtitleSuffix.Value.Matches(text))
        {
            result.Append(text,cursor,suffix.Index-cursor);
            var prefix=text[..suffix.Index];
            if(InlineAudio().Matches(prefix).LastOrDefault() is {} audioLabel&&prefix[(audioLabel.Index+audioLabel.Length)..].Trim().Length==0&&suffix.Groups[2].Length>0)result.Append(suffix.Groups[1].Value);
            cursor=suffix.Index+suffix.Length;
        }
        result.Append(text,cursor,text.Length-cursor);
        return result.ToString();
    }
    internal static List<string> LanguageHintsFromMetadata(IEnumerable<string> metadata)
    {
        var bounded=new StringBuilder();
        foreach(var value in metadata)
        {
            var remaining=MaxSearch-bounded.Length;if(remaining<=1)break;
            if(bounded.Length>0)bounded.Append('\n');bounded.Append(Prefix(value,remaining-1));
        }
        var result=new List<string>();
        foreach(var raw in Lines(bounded.ToString()))
        {
            var match=AudioLine().Match(AudioFragment(raw));if(!match.Success)continue;
            var search=HintSearchText([match.Groups[1].Value]);
            var identifiers=search.LanguageIds.ToList();identifiers.Sort((l,r)=>DisplayOrder(NormalizedLanguageName(l)??l,NormalizedLanguageName(r)??r));
            result.AddRange(identifiers);result.AddRange(DetectedLanguageNames(search with {LanguageIds=[]}));
            if(result.Count>=40)break;
        }
        return result.Take(40).ToList();
    }
    internal static string TaggableFragment(string value)
    {
        var bounded=string.Join('\n',Lines(Prefix(value,MaxSearch)).Select(AudioFragment).Where(l=>!SubtitleLine().IsMatch(l)));
        if(!bounded.Contains("://"))return bounded;
        var result=new StringBuilder(bounded.Length);var remainder=bounded;
        int separator;
        while((separator=remainder.IndexOf("://",StringComparison.Ordinal))>=0)
        {
            var schemeStart=separator;while(schemeStart>0&&remainder[schemeStart-1] is var c&&char.IsAscii(c)&&(char.IsAsciiLetterOrDigit(c)||c is '+' or '-' or '.'))schemeStart--;
            result.Append(remainder,0,schemeStart);
            var after=remainder[(separator+3)..];
            var authorityEnd=0;while(authorityEnd<after.Length&&after[authorityEnd] is not ('/' or '?' or '#')&&!char.IsWhiteSpace(after[authorityEnd]))authorityEnd++;
            var tokenEnd=0;while(tokenEnd<after.Length&&!char.IsWhiteSpace(after[tokenEnd]))tokenEnd++;
            var pathAndQuery=after[Math.Min(authorityEnd,tokenEnd)..tokenEnd];
            var cut=pathAndQuery.IndexOfAny(['?','#']);var path=cut<0?pathAndQuery:pathAndQuery[..cut];
            result.Append(' ');
            if(path.StartsWith('/')){try{result.Append(Uri.UnescapeDataString(path));}catch(UriFormatException){result.Append(path);}}
            remainder=after[tokenEnd..];
        }
        result.Append(remainder);
        return result.ToString();
    }
    private static bool IsShortCode(string value)=>(value.Length<=2||Ambiguous3.Contains(value))&&value.All(char.IsAsciiLetter);

    private sealed record ReleaseToken(string Text,bool IsShortLetterCode,bool IsBracketWrapped,bool OpensWhitespaceGroup);
    private static HashSet<string> TagLikeShortCodes(string source)
    {
        var codes=new HashSet<string>();
        foreach(var line in Lines(source))
        {
            var tokens=ReleaseTokens(line);
            for(var i=0;i<tokens.Count;i++)if(tokens[i].IsShortLetterCode&&tokens[i].Text.Length>0&&ReadsAsTag(i,tokens))codes.Add(tokens[i].Text);
        }
        return codes;
    }
    private static bool ReadsAsTag(int index,List<ReleaseToken> tokens)
    {
        var token=tokens[index];
        if(StructureTokens.Contains(token.Text)||ContextWords.Contains(token.Text))return false;
        if(token.IsBracketWrapped||!AmbiguousShort.Contains(token.Text))return true;
        var neighbours=new[]{index>0?tokens[index-1]:null,index+1<tokens.Count?tokens[index+1]:null}.Where(t=>t is not null).Select(t=>t!.Text);
        return token.OpensWhitespaceGroup?neighbours.Any(NamesLanguageContext):neighbours.Any(AnchorsLanguageTag);
    }
    private static bool NamesLanguageContext(string text)=>text.Length>0&&(ContextWords.Contains(text)||UnambiguousMarkers.Contains(text));
    private static bool AnchorsLanguageTag(string text)=>text.Length>0&&(NamesLanguageContext(text)||StructureTokens.Contains(text)||IsResolutionToken(text)||IsYearToken(text)||IsSeasonEpisodeToken(text));
    private static bool IsResolutionToken(string text)=>ResolutionHeights.Contains(text)||text.Length>1&&text[^1] is 'p' or 'i'&&ResolutionHeights.Contains(text[..^1]);
    private static bool IsYearToken(string text)=>text.Length==4&&text.All(char.IsAsciiDigit)&&int.Parse(text) is >=1900 and <=2099;
    private static bool IsSeasonEpisodeToken(string text)
    {
        var i=0;var matched=false;
        while(i<text.Length&&text[i] is 's' or 'e')
        {
            i++;var start=i;while(i<text.Length&&char.IsAsciiDigit(text[i]))i++;
            if(i==start||i-start>4)return false;matched=true;
        }
        return matched&&i==text.Length;
    }
    private static List<ReleaseToken> ReleaseTokens(string source)
    {
        var tokens=new List<ReleaseToken>();var current=new StringBuilder();var count=0;var asciiLetters=true;var followsOpening=false;Rune? previous=null;var awaitingGroup=true;
        void Append(Rune? next)
        {
            if(count>0)
            {
                var lower=current.ToString().ToLowerInvariant();
                tokens.Add(new(count<=MaxTokenScalars?lower:"",asciiLetters&&(count<=2||Ambiguous3.Contains(lower)),followsOpening&&next is {} n&&n.Value is ']' or ')' or '}',awaitingGroup));
                awaitingGroup=false;
            }
            current.Clear();count=0;asciiLetters=true;followsOpening=false;
        }
        foreach(var rune in source.EnumerateRunes())
        {
            if(Rune.IsLetter(rune)||Rune.IsNumber(rune))
            {
                if(count==0)followsOpening=previous is {} p&&p.Value is '[' or '(' or '{';
                if(!(rune.Value is >=65 and <=90 or >=97 and <=122))asciiLetters=false;
                if(count<MaxTokenScalars)current.Append(rune.ToString());
                count++;
            }
            else{Append(rune);if(Rune.IsWhiteSpace(rune))awaitingGroup=true;}
            previous=rune;
        }
        Append(null);
        return tokens;
    }
    internal static List<string> DetectedLanguageNames(LanguageSearchText search)
    {
        var tokens=AsciiTokens(search.Value).Where(t=>!IsShortCode(t)).ToHashSet();tokens.UnionWith(search.ShortCodeTokens);
        var flagged=Flags.Where(f=>search.Value.Contains(f.Flag)).Select(f=>f.Name).ToHashSet();
        var detected=Markers.Where(m=>flagged.Contains(m.Name)||m.Markers.Overlaps(tokens)).Select(m=>m.Name);
        var declared=search.LanguageIds.Order(StringComparer.Ordinal).Select(id=>id=="es-419"?"Latino":MediaLanguages.Find(id)?.Name).Where(n=>n is not null).Select(n=>n!);
        var result=declared.Concat(detected).Distinct().ToList();result.Sort(DisplayOrder);
        return result;
    }
    public static List<string> DetectedLanguageNames(string value)=>DetectedLanguageNames(SearchText(value));
    private static int DisplayOrder(string l,string r)
    {
        int Priority(string name){var i=Array.FindIndex(Markers,m=>m.Name==name);return i<0?Markers.Length:i;}
        var p=Priority(l).CompareTo(Priority(r));if(p!=0)return p;
        var c=string.Compare(l,r,CultureInfo.CurrentCulture,CompareOptions.IgnoreCase);
        return c!=0?c:string.CompareOrdinal(l,r);
    }
    internal static bool ContainsMarker(string marker,LanguageSearchText search)
    {
        var normalized=Prefix(marker,MaxHint).ToLowerInvariant();
        if(normalized.Length==0||search.Value.Length==0)return false;
        if(IsShortCode(normalized))return search.ShortCodeTokens.Contains(normalized);
        var value=search.Value;var start=0;int found;
        while(start<value.Length&&(found=value.IndexOf(normalized,start,StringComparison.Ordinal))>=0)
        {
            var end=found+normalized.Length;
            if((found==0||!char.IsAsciiLetter(value[found-1]))&&(end==value.Length||!char.IsAsciiLetter(value[end])))return true;
            start=found+1;
        }
        return false;
    }
    public static bool ContainsMarker(string marker,string value)=>ContainsMarker(marker,SearchText(value));
    private static HashSet<string> AsciiTokens(string value)
    {
        var tokens=new HashSet<string>();var start=-1;
        for(var i=0;i<=value.Length;i++)
        {
            var letter=i<value.Length&&value[i] is >='a' and <='z';
            if(letter){if(start<0)start=i;}else if(start>=0){tokens.Add(value[start..i]);start=-1;}
        }
        return tokens;
    }
    public static bool LanguageAlreadyShown(string label,IEnumerable<string> parts)
    {
        var displayed=string.Join(' ',parts);
        if(displayed.Contains(label,StringComparison.OrdinalIgnoreCase))return true;
        var languages=DetectedLanguageNames(displayed).ToHashSet();var expected=label.Split('/');
        return expected.Length>0&&expected.All(languages.Contains);
    }
    public static string QualityTags(IReadOnlyList<string> lines)
    {
        var tags=new List<string>();var joined=string.Join(' ',lines);var all=joined.ToLowerInvariant();
        if(Resolution(joined) is {} height)tags.Add(height==2160?"4K":$"{height}P");
        void First(string[] patterns,Func<string,string> display){foreach(var p in patterns)if(ContainsTag(p,all)){tags.Add(display(p));return;}}
        First(["bluray","blu-ray","bdrip","brrip","dvdrip","dvd","webrip","web-dl","webdl","web","hdtv","hdrip","cam","ts","hdcam","remux"],p=>p switch{"bluray" or "blu-ray"=>"BluRay","bdrip"=>"BDRip","brrip"=>"BRRip","dvdrip"=>"DVDRip","dvd"=>"DVD","webrip"=>"WEBRip","web-dl" or "webdl"=>"WEB-DL","web"=>"WEB","hdtv"=>"HDTV","hdrip"=>"HDRip","cam"=>"CAM","ts"=>"TS","hdcam"=>"HDCAM","remux"=>"Remux",_=>p.ToUpperInvariant()});
        First(["hevc","h265","h.265","x265","h264","h.264","x264","av1","vp9","xvid"],p=>p switch{"hevc" or "h265" or "h.265" or "x265"=>"HEVC","h264" or "h.264" or "x264"=>"H.264","av1"=>"AV1",_=>p.ToUpperInvariant()});
        First(["hdr10+","hdr10","hdr","dolby vision","dv","sdr"],p=>p switch{"hdr10+"=>"HDR10+","hdr10"=>"HDR10","hdr"=>"HDR","dolby vision" or "dv"=>"DV",_=>p.ToUpperInvariant()});
        First(["atmos","truehd","dts-hd","dts","dd5.1","dd+","aac","5.1","7.1"],p=>p switch{"atmos"=>"Atmos","truehd"=>"TrueHD","dts-hd"=>"DTS-HD","dts"=>"DTS","dd5.1"=>"DD5.1","dd+"=>"DD+",_=>p});
        if(DisplaySize().Match(joined) is {Success:true} size)tags.Add(size.Groups[1].Value);
        return string.Join(" · ",tags);
    }
    private static bool ContainsTag(string tag,string text)
    {
        var start=0;int found;
        while((found=text.IndexOf(tag,start,StringComparison.Ordinal))>=0)
        {
            var end=found+tag.Length;
            if((found==0||!char.IsLetter(text[found-1]))&&(end==text.Length||!char.IsLetter(text[end])))return true;
            start=end;
        }
        return false;
    }
}

public sealed record LanguageMatcher(HashSet<string> Keys,List<string> Markers,HashSet<string> LanguageIds);

public sealed class StreamFilterConfiguration
{
    public bool HideUnknownLanguage {get;init;}
    public bool AssumeOriginalAudio {get;init;}
    public bool TreatDubbedAnimeAsEnglish {get;init;}
    public required List<LanguageMatcher> Included {get;init;}
    public required List<LanguageMatcher> Hidden {get;init;}
    public required HashSet<int> HiddenQualities {get;init;}
    public bool HideUnknownQuality {get;init;}
    public bool HasLanguageRules=>HideUnknownLanguage||AssumeOriginalAudio||TreatDubbedAnimeAsEnglish||Included.Count>0||Hidden.Count>0;
    public bool HasQualityRules=>HideUnknownQuality||HiddenQualities.Count>0;
}

public static class StreamLanguageFilter
{
    private static readonly object Gate=new();
    private static readonly Dictionary<string,StreamFilterConfiguration?> Cache=[];
    private static readonly HashSet<string> AudioDescriptionTokens=["aac","ac3","eac3","dd","ddp","dts","dtshd","truehd","atmos","flac","opus","mp3","stereo","mono","surround","dolby","digital","plus","hd","ma","pcm","lpcm","audio","channels","channel","ch"];
    private static readonly HashSet<string> Placeholders=["unknown","unknown language","unk","und","undefined","undetermined","none","null","n a","na","not available","no language"];
    private static readonly string[] DubMarkers=["dub","dubbed","dubbed audio","foreign dub"];
    public static void Invalidate(){lock(Gate)Cache.Clear();}
    public static StreamFilterConfiguration? Configuration(string? sourceId)
    {
        var key=sourceId??"";
        lock(Gate)if(Cache.TryGetValue(key,out var cached))return cached;
        var p=ServicesPreferenceStore.Shared.Value;StreamFilterConfiguration? resolved=null;
        if(p.ExtraRulesApply(sourceId)&&(p.HideUnknownLanguage||p.AssumeOriginalAudio||p.TreatDubbedAnimeAsEnglish||p.HideUnknownQuality||p.IncludedLanguages.Count>0||p.HiddenLanguages.Count>0||p.HiddenQualities.Count>0))
            resolved=new(){HideUnknownLanguage=p.HideUnknownLanguage,AssumeOriginalAudio=p.AssumeOriginalAudio,TreatDubbedAnimeAsEnglish=p.TreatDubbedAnimeAsEnglish,Included=p.IncludedLanguages.Select(Matcher).ToList(),Hidden=p.HiddenLanguages.Select(Matcher).ToList(),HiddenQualities=p.HiddenQualities.ToHashSet(),HideUnknownQuality=p.HideUnknownQuality};
        lock(Gate)Cache[key]=resolved;
        return resolved;
    }
    public static bool ShouldHide(IStreamText stream,string? sourceId,string? originalAudioLanguage=null,bool isAnime=false)=>
        Configuration(sourceId) is {} configuration&&ShouldHide(stream.LanguageHints,StreamDetection.Metadata(stream),configuration,originalAudioLanguage,isAnime,StreamDetection.QualityMetadata(stream));
    public static bool ShouldHide(IReadOnlyList<string> languageHints,IReadOnlyList<string> metadata,string? sourceId,string? originalAudioLanguage=null,bool isAnime=false,IReadOnlyList<string>? qualityMetadata=null)=>
        Configuration(sourceId) is {} configuration&&ShouldHide(languageHints,metadata,configuration,originalAudioLanguage,isAnime,qualityMetadata);
    public static bool ShouldHide(IReadOnlyList<string> languageHints,IReadOnlyList<string> metadata,StreamFilterConfiguration configuration,string? originalAudioLanguage,bool isAnime,IReadOnlyList<string>? qualityMetadata)
    {
        var text=StreamDetection.TaggableText(metadata);
        if(configuration.HasQualityRules)
        {
            var quality=StreamDetection.Quality(qualityMetadata is null?text:StreamDetection.TaggableText(qualityMetadata)).Height;
            if(configuration.HideUnknownQuality&&quality is null)return true;
            if(quality is {} height&&configuration.HiddenQualities.Contains(height))return true;
        }
        if(!configuration.HasLanguageRules)return false;
        return HideForLanguage(languageHints.Concat(StreamDetection.LanguageHintsFromMetadata(metadata)).ToList(),text,configuration,originalAudioLanguage,isAnime);
    }
    private static bool HideForLanguage(List<string> hints,string metadataText,StreamFilterConfiguration configuration,string? originalAudio,bool isAnime)
    {
        var search=StreamDetection.SearchText(metadataText);var detectedMetadata=StreamDetection.DetectedLanguageNames(search);
        var hintSearch=StreamDetection.HintSearchText(hints);
        var dubbed=IndicatesDubbed(search)||IndicatesDubbed(hintSearch);
        var detectedHints=StreamDetection.DetectedLanguageNames(hintSearch);
        var split=hints.SelectMany(StreamDetection.SplitHint).ToList();
        var explicitHints=split.Where(h=>IsMeaningful(h)&&!IsMultiplicity(h)&&!IsDub(h)).ToList();
        var dubbedAnimeEnglish=isAnime&&configuration.TreatDubbedAnimeAsEnglish&&dubbed&&explicitHints.Count==0&&detectedHints.Count==0&&detectedMetadata.Count==0;
        var hasData=split.Select(h=>h.Trim()).Any(IsMeaningful)||search.Value.Length>0&&(detectedMetadata.Count>0||isAnime&&configuration.TreatDubbedAnimeAsEnglish&&dubbed||new[]{"multi audio","multi-audio","multi-language","multilang","dual audio","dual-audio"}.Any(m=>StreamDetection.ContainsMarker(m,search)));
        var hintKeys=split.Select(h=>StreamDetection.CatalogHint(h)?.Id??StreamDetection.NormalizedLanguageName(h)??h).SelectMany(LanguageKeys).Concat(detectedHints.SelectMany(LanguageKeys)).ToHashSet();
        if(dubbedAnimeEnglish)hintKeys.UnionWith(LanguageKeys("English"));
        var metadataKeys=detectedMetadata.SelectMany(LanguageKeys).ToHashSet();metadataKeys.UnionWith(search.LanguageIds);
        var assumed=!hasData&&!dubbed&&configuration.AssumeOriginalAudio&&originalAudio is {} original&&IsMeaningful(original)&&!IsMultiplicity(original)&&!IsDub(original)?LanguageKeys(original).ToHashSet():[];
        metadataKeys.UnionWith(assumed);
        if(configuration.HideUnknownLanguage&&!hasData&&assumed.Count==0)return true;
        if(configuration.Included.Count==0&&configuration.Hidden.Count==0)return false;
        if(configuration.Included.Count>0&&!MatchesAny(configuration.Included,hintKeys,metadataKeys,search)&&(hasData||assumed.Count>0||dubbed))return true;
        return MatchesAny(configuration.Hidden,hintKeys,metadataKeys,search);
    }
    private static bool MatchesAny(List<LanguageMatcher> matchers,HashSet<string> hintKeys,HashSet<string> metadataKeys,LanguageSearchText search)
    {
        if(matchers.Count==0)return false;
        var ids=hintKeys.Union(metadataKeys).Select(MediaLanguages.CanonicalId).Where(i=>i is not null).Select(i=>i!).ToList();
        if(matchers.Any(m=>m.LanguageIds.Any(rule=>ids.Any(id=>MediaLanguages.RuleMatches(rule,id)))))return true;
        if(hintKeys.Count>0&&matchers.Any(m=>m.LanguageIds.Count==0&&m.Keys.Overlaps(hintKeys)))return true;
        if(metadataKeys.Count>0&&matchers.Any(m=>m.LanguageIds.Count==0&&m.Keys.Overlaps(metadataKeys)))return true;
        if(search.Value.Length==0)return false;
        return matchers.Any(m=>m.LanguageIds.Count==0&&m.Markers.Any(marker=>StreamDetection.ContainsMarker(marker,search)));
    }
    private static bool IsMultiplicity(string value)=>StreamDetection.NormalizedLanguageName(value) is "Multi Audio" or "Dual Audio";
    private static bool IsDub(string value)=>DubMarkers.Contains(NormalizedKey(value));
    private static bool IndicatesDubbed(LanguageSearchText search)=>DubMarkers.Any(m=>StreamDetection.ContainsMarker(m,search));
    private static LanguageMatcher Matcher(string value)
    {
        var keys=LanguageKeys(value).ToHashSet();
        var markers=StreamDetection.SplitHint(value).Append(value).ToList();
        if(keys.Contains("multi audio"))markers.AddRange(["multi audio","multi-audio","multilang","multi-language"]);
        if(keys.Contains("dual audio"))markers.AddRange(["dual audio","dual-audio"]);
        var seen=new HashSet<string>();
        return new(keys,markers.Select(m=>m.Trim()).Where(m=>m.Length>0&&seen.Add(NormalizedKey(m))).ToList(),MediaLanguages.FilterCanonicalId(value) is {} id?[id]:[]);
    }
    private static List<string> LanguageKeys(string value)
    {
        if(MediaLanguages.CanonicalId(value) is {} direct)return [direct];
        var keys=new List<string>();
        foreach(var candidate in StreamDetection.SplitHint(value).Prepend(value))
        {
            var trimmed=candidate.Trim();if(trimmed.Length==0)continue;
            if(MediaLanguages.CanonicalId(trimmed) is {} id){keys.Add(id);continue;}
            if(StreamDetection.NormalizedLanguageName(trimmed) is {} normalized)keys.Add(NormalizedKey(normalized));
            else if(trimmed.Split('-')[0] is var prefix&&prefix.Length<trimmed.Length&&prefix.Length>0&&StreamDetection.NormalizedLanguageName(prefix) is {} prefixName)keys.Add(NormalizedKey(prefixName));
            var key=NormalizedKey(trimmed);keys.Add(key.Length==0?trimmed.ToLowerInvariant():key);
        }
        return keys.Where(k=>k.Length>0).Distinct().ToList();
    }
    private static bool IsMeaningful(string value)
    {
        if(StreamDetection.NormalizedLanguageName(value) is not null)return true;
        var key=NormalizedKey(value);if(key.Length==0)return value.Any(char.IsLetter);
        if(key.Split(' ').All(t=>AudioDescriptionTokens.Contains(t)||t.All(char.IsDigit)))return false;
        return !Placeholders.Contains(key);
    }
    public static string NormalizedKey(string value)
    {
        var folded=MediaLanguages.SearchKey(value);var builder=new StringBuilder(Math.Min(folded.Length,256));var pending=false;
        foreach(var c in folded)
        {
            if(c is >='0' and <='9' or >='a' and <='z'){if(pending&&builder.Length>0)builder.Append(' ');builder.Append(c);pending=false;}
            else if(builder.Length>0)pending=true;
        }
        return builder.ToString();
    }
}
