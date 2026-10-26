using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Eclipse.Windows.Services;

internal static class Bounded
{
    public static string? Text(JsonElement e,string key,int maxBytes)=>Text(JsonValue.Child(e,key),maxBytes);
    public static string? Text(JsonElement value,int maxBytes)
    {
        if(value.ValueKind!=JsonValueKind.String)return null;
        var text=value.GetString();if(string.IsNullOrEmpty(text))return null;
        if(Encoding.UTF8.GetByteCount(text)<=maxBytes)return text;
        var count=0;var end=0;
        foreach(var rune in text.EnumerateRunes()){if(count+rune.Utf8SequenceLength>maxBytes)break;count+=rune.Utf8SequenceLength;end+=rune.Utf16SequenceLength;}
        return end==0?null:text[..end];
    }
    public static string? Exact(JsonElement e,string key,int maxBytes)=>JsonValue.Child(e,key) is {ValueKind:JsonValueKind.String} v&&v.GetString() is {Length:>0} s&&Encoding.UTF8.GetByteCount(s)<=maxBytes?s:null;
    public static List<string>? Strings(JsonElement value,int maxCount,int maxBytes)
    {
        if(value.ValueKind!=JsonValueKind.Array)return null;
        var result=new List<string>();
        foreach(var item in value.EnumerateArray()){if(result.Count>=maxCount)break;if(Text(item,maxBytes) is {} s)result.Add(s);}
        return result;
    }
    public static string? LossyText(JsonElement e,string key,int maxBytes)=>JsonValue.Child(e,key) is {ValueKind:JsonValueKind.Number} n&&n.TryGetInt64(out var i)?i.ToString(CultureInfo.InvariantCulture):Text(e,key,maxBytes);
    public static int? FlexibleInt(JsonElement e,string key)
    {
        var v=JsonValue.Child(e,key);
        if(v.ValueKind==JsonValueKind.Number){if(v.TryGetInt32(out var i))return i;if(v.TryGetDouble(out var d)&&d==Math.Floor(d)&&Math.Abs(d)<int.MaxValue)return (int)d;return null;}
        if(v.ValueKind!=JsonValueKind.String)return null;
        var trimmed=v.GetString()!.Trim();if(int.TryParse(trimmed,NumberStyles.Integer,CultureInfo.InvariantCulture,out var parsed))return parsed;
        var runs=Regex.Matches(trimmed,"[0-9]+");return runs.Count==1&&int.TryParse(runs[0].Value,out var run)?run:null;
    }
    public static int? Int(JsonElement e,string key)=>JsonValue.Child(e,key) is {ValueKind:JsonValueKind.Number} v&&v.TryGetInt32(out var i)?i:null;
}

public sealed record StremioResource(string Name,IReadOnlyList<string>? Types,IReadOnlyList<string>? IdPrefixes,bool Detailed);

public sealed record StremioCatalogExtra(string Name,bool? IsRequired,IReadOnlyList<string>? Options,int? OptionsLimit);

public sealed record StremioCatalog(string Type,string Id,string? Name,IReadOnlyList<StremioCatalogExtra>? Extra)
{
    public bool SupportsSearch=>Extra?.Any(e=>e.Name=="search")==true;
    public bool CanSearchWithQueryOnly=>SupportsSearch&&(Extra?.All(e=>e.IsRequired!=true||e.Name=="search")??true);
    public bool IsHomeFeedCapable=>(Extra??[]).Where(e=>e.IsRequired==true).All(e=>e.Name=="skip");
    public bool ShouldSendInitialSkip=>Extra?.Any(e=>e.Name=="skip"&&e.IsRequired==true)==true;
    public string? EclipseMediaType=>Type.ToLowerInvariant() switch{"movie"=>"movie","series" or "tv" or "anime"=>"tv",_=>null};
    public bool SupportsType(string requested)=>Type==requested||requested=="series"&&Type is "tv" or "anime";
    internal static StremioCatalog? Parse(JsonElement e)
    {
        if(Bounded.Exact(e,"type",64) is not {} type||Bounded.Exact(e,"id",512) is not {} id)return null;
        List<StremioCatalogExtra>? extra=null;
        if(JsonValue.Child(e,"extra").ValueKind==JsonValueKind.Array)
        {
            extra=[];
            foreach(var item in JsonValue.Array(e,"extra").Take(32))
            {
                if(item.ValueKind==JsonValueKind.String){if(Bounded.Text(item,64) is {} plain)extra.Add(new(plain,null,null,null));continue;}
                if(Bounded.Text(item,"name",64) is not {} name)continue;
                var limit=Bounded.Int(item,"optionsLimit");
                extra.Add(new(name,JsonValue.Child(item,"isRequired").ValueKind is JsonValueKind.True or JsonValueKind.False?JsonValue.Bool(item,"isRequired"):null,Bounded.Strings(JsonValue.Child(item,"options"),64,512),limit is >=0 and <=10000?limit:null));
            }
        }
        else
        {
            var supported=Bounded.Strings(JsonValue.Child(e,"extraSupported"),32,64)??[];var required=Bounded.Strings(JsonValue.Child(e,"extraRequired"),32,64)??[];
            if(supported.Count+required.Count>0)extra=supported.Concat(required).Distinct().Take(32).Select(n=>new StremioCatalogExtra(n,required.Contains(n),null,null)).ToList();
        }
        return new(type,id,Bounded.Text(e,"name",1024),extra);
    }
}

public sealed class StremioManifest
{
    public required string Id {get;init;}
    public required string Name {get;init;}
    public string? Description {get;init;}
    public string? Version {get;init;}
    public string? Logo {get;init;}
    public IReadOnlyList<string>? Types {get;init;}
    public IReadOnlyList<StremioResource>? Resources {get;init;}
    public IReadOnlyList<string>? IdPrefixes {get;init;}
    public IReadOnlyList<StremioCatalog>? Catalogs {get;init;}
    public bool? Configurable {get;init;}
    public bool? ConfigurationRequired {get;init;}
    private bool Has(string name)=>Resources?.Any(r=>r.Name==name)==true;
    public bool SupportsStreams=>Has("stream");
    public bool SupportsSubtitles=>Has("subtitles");
    public bool SupportsCatalogs=>Has("catalog");
    public bool SupportsMeta=>Has("meta");
    public bool SupportsInstallableResources=>SupportsStreams||SupportsSubtitles||SupportsCatalogs;
    public IEnumerable<StremioCatalog> SearchableCatalogs=>Catalogs?.Where(c=>c.CanSearchWithQueryOnly)??[];
    public IReadOnlyList<StremioCatalog> HomeCatalogs=>SupportsCatalogs?(Catalogs??[]).Where(c=>c.IsHomeFeedCapable&&c.EclipseMediaType is not null).Take(512).ToArray():[];
    public IReadOnlyList<string>? StreamIdPrefixes=>ResourcePrefixes("stream");
    public IReadOnlyList<string>? SubtitleIdPrefixes=>ResourcePrefixes("subtitles");
    private IReadOnlyList<string>? ResourcePrefixes(string name){var p=(Resources??[]).Where(r=>r.Detailed&&r.Name==name).SelectMany(r=>r.IdPrefixes??[]).Where(x=>x.Length>0).ToArray();return p.Length==0?IdPrefixes:p;}
    public static StremioManifest? Parse(JsonElement e)
    {
        if(e.ValueKind!=JsonValueKind.Object||Bounded.Exact(e,"id",512) is not {} id||Bounded.Text(e,"name",1024) is not {} name)return null;
        var resources=new List<StremioResource>();
        foreach(var r in JsonValue.Array(e,"resources").Take(64))
        {
            if(r.ValueKind==JsonValueKind.String){if(Bounded.Text(r,64) is {} simple)resources.Add(new(simple,null,null,false));continue;}
            if(r.ValueKind!=JsonValueKind.Object||Bounded.Text(r,"name",64) is not {} resourceName)continue;
            var types=Bounded.Strings(JsonValue.Child(r,"types"),32,64)??(Bounded.Text(r,"type",64) is {} single?[single]:null);
            resources.Add(new(resourceName,types,Bounded.Strings(JsonValue.Child(r,"idPrefixes"),128,256),true));
        }
        var hints=JsonValue.Child(e,"behaviorHints");
        return new()
        {
            Id=id,Name=name,Description=Bounded.Text(e,"description",16*1024),Version=Bounded.Text(e,"version",128),Logo=Bounded.Text(e,"logo",16*1024),
            Types=Bounded.Strings(JsonValue.Child(e,"types"),32,64),Resources=JsonValue.Child(e,"resources").ValueKind==JsonValueKind.Array?resources:null,
            IdPrefixes=Bounded.Strings(JsonValue.Child(e,"idPrefixes"),128,256),
            Catalogs=JsonValue.Child(e,"catalogs").ValueKind==JsonValueKind.Array?JsonValue.Array(e,"catalogs").Take(512).Select(StremioCatalog.Parse).Where(c=>c is not null).Select(c=>c!).ToArray():null,
            Configurable=JsonValue.Child(hints,"configurable").ValueKind is JsonValueKind.True or JsonValueKind.False?JsonValue.Bool(hints,"configurable"):null,
            ConfigurationRequired=JsonValue.Child(hints,"configurationRequired").ValueKind is JsonValueKind.True or JsonValueKind.False?JsonValue.Bool(hints,"configurationRequired"):null
        };
    }
}

public sealed record StremioSubtitle(string? Id,string? Url,string? Lang,string? Name,string? Title)
{
    public string DisplayName=>Name is {Length:>0}?Name:Title is {Length:>0}?Title:Lang is {Length:>0}?Lang.ToUpperInvariant():Id??"Subtitle";
    internal static StremioSubtitle Parse(JsonElement e)
    {
        string? First(int max,params string[] keys){foreach(var k in keys)if(JsonValue.Text(e,k).Trim() is {Length:>0} v&&Encoding.UTF8.GetByteCount(v)<=max)return v;return null;}
        var id=JsonValue.Child(e,"id") is {ValueKind:JsonValueKind.Number} n&&n.TryGetInt64(out var i)?i.ToString(CultureInfo.InvariantCulture):Bounded.Text(e,"id",256);
        return new(id,First(16*1024,"url","file","src"),First(64,"lang","language"),First(512,"name","label"),First(512,"title"));
    }
}

public sealed class StremioStream : IStreamText
{
    public string? Url {get;init;}
    public string? InfoHash {get;init;}
    public string? ExternalUrl {get;init;}
    public string? YtId {get;init;}
    public string? Title {get;init;}
    public string? Name {get;init;}
    public string? Description {get;init;}
    public string? Lang {get;init;}
    public string? Language {get;init;}
    public IReadOnlyList<string>? Languages {get;init;}
    public bool? NotWebReady {get;init;}
    public string? BingeGroup {get;init;}
    public IReadOnlyDictionary<string,string>? ProxyHeaders {get;init;}
    public string? Filename {get;init;}
    public long? VideoSize {get;init;}
    public IReadOnlyList<StremioSubtitle>? Subtitles {get;init;}
    public string Key=>Url??InfoHash??ExternalUrl??YtId??"";
    public bool IsDirectHttp=>Url is {Length:>0} u&&(u.StartsWith("http://",StringComparison.OrdinalIgnoreCase)||u.StartsWith("https://",StringComparison.OrdinalIgnoreCase));
    public bool UsesTorrentTransport=>InfoHash?.Trim().Length>0||Url?.Trim().StartsWith("magnet:",StringComparison.OrdinalIgnoreCase)==true;
    public bool HasExternalDestination=>ExternalUrl?.Trim().Length>0||YtId?.Trim().Length>0;
    public string DisplayName
    {
        get
        {
            foreach(var v in new[]{Name,Title})if(v?.Trim() is {Length:>0} t)return t;
            if(Description?.Trim() is {Length:>0} d)return d.Split('\n','\r')[0];
            return "Stream";
        }
    }
    public string? FormattedVideoSize=>VideoSize is >0 and var size?Sizes.File(size):null;
    public IReadOnlyList<string> LanguageHints=>new[]{Lang,Language}.Select(v=>v?.Trim()).Where(v=>v is {Length:>0}).Select(v=>v!).Concat(Languages??[]).ToArray();
    string? IStreamText.Filename=>Filename;
    internal static StremioStream? Parse(JsonElement e)
    {
        if(e.ValueKind!=JsonValueKind.Object)return null;
        var hints=JsonValue.Child(e,"behaviorHints");
        bool? notWebReady=JsonValue.Child(hints,"notWebReady") switch{{ValueKind:JsonValueKind.True}=>true,{ValueKind:JsonValueKind.False}=>false,{ValueKind:JsonValueKind.Number} n when n.TryGetInt64(out var i)=>i!=0,_=>null};
        long? size=JsonValue.Child(hints,"videoSize") switch{{ValueKind:JsonValueKind.Number} n when n.TryGetInt64(out var i)=>i,{ValueKind:JsonValueKind.Number} n when n.TryGetDouble(out var d)&&double.IsFinite(d)&&Math.Abs(d)<9e18=>(long)Math.Truncate(d),{ValueKind:JsonValueKind.String} s when long.TryParse(s.GetString(),out var p)=>p,_=>null};
        Dictionary<string,string>? proxy=null;
        if(JsonValue.Child(JsonValue.Child(hints,"proxyHeaders"),"request") is {ValueKind:JsonValueKind.Object} request)
        {
            proxy=[];
            foreach(var p in request.EnumerateObject().OrderBy(p=>p.Name,StringComparer.OrdinalIgnoreCase).Take(64))
            {
                var value=p.Value.ValueKind switch{JsonValueKind.String=>p.Value.GetString(),JsonValueKind.True=>"true",JsonValueKind.False=>"false",JsonValueKind.Number=>p.Value.GetRawText(),_=>null};
                if(value is not null&&Encoding.UTF8.GetByteCount(p.Name)<=128&&Encoding.UTF8.GetByteCount(value)<=16*1024)proxy[p.Name]=value;
            }
            if(proxy.Count==0)proxy=null;
        }
        return new()
        {
            Url=Bounded.Text(e,"url",16*1024),InfoHash=Bounded.Text(e,"infoHash",256),ExternalUrl=Bounded.Text(e,"externalUrl",4*1024),YtId=Bounded.Text(e,"ytId",128),
            Title=Bounded.Text(e,"title",1024),Name=Bounded.Text(e,"name",1024),Description=Bounded.Text(e,"description",2*1024),Lang=Bounded.Text(e,"lang",64),Language=Bounded.Text(e,"language",64),
            Languages=Bounded.Strings(JsonValue.Child(e,"languages"),16,64)??(Bounded.Text(e,"languages",64) is {} single?[single]:null),
            NotWebReady=notWebReady,BingeGroup=Bounded.Text(hints,"bingeGroup",1024),ProxyHeaders=proxy,Filename=Bounded.Text(hints,"filename",1024),VideoSize=size,
            Subtitles=JsonValue.Child(e,"subtitles").ValueKind==JsonValueKind.Array?JsonValue.Array(e,"subtitles").Take(64).Where(s=>s.ValueKind==JsonValueKind.Object).Select(StremioSubtitle.Parse).ToArray():null
        };
    }
    public static List<StremioStream> ParseList(JsonElement items,int limit)
    {
        var result=new List<StremioStream>();var seen=new HashSet<string>();
        foreach(var item in JsonValue.Items(items).Take(limit))
        {
            if(Parse(item) is not {} stream)continue;
            var key=stream.Url?.Trim()??stream.InfoHash?.Trim()??stream.ExternalUrl?.Trim();
            if(key is {Length:>0}&&!seen.Add(key))continue;
            result.Add(stream);
        }
        return result;
    }
}

public sealed record StremioVideo(string Id,string? Title,string? Released,int? Season,int? Episode,IReadOnlyList<StremioStream>? Streams);

public sealed class StremioMeta
{
    public required string Id {get;init;}
    public string? Type {get;init;}
    public required string Name {get;init;}
    public string? ImdbId {get;init;}
    public int? TmdbId {get;init;}
    public string? Poster {get;init;}
    public string? Background {get;init;}
    public string? Description {get;init;}
    public string? ReleaseInfo {get;init;}
    public string? Released {get;init;}
    public string? ImdbRating {get;init;}
    public IReadOnlyList<string>? Genres {get;init;}
    public IReadOnlyList<StremioVideo>? Videos {get;init;}
    public string? DefaultVideoId {get;init;}
    public static StremioMeta? Parse(JsonElement e)
    {
        if(e.ValueKind!=JsonValueKind.Object||Bounded.Exact(e,"id",2048) is not {} id||Bounded.Text(e,"name",1024) is not {} name)return null;
        var genres=Bounded.Strings(JsonValue.Child(e,"genres"),32,256)??(JsonValue.Text(e,"genres") is {Length:>0} g?g.Split(',').Select(x=>x.Trim()).Where(x=>x.Length>0).Take(32).ToList():null);
        List<StremioVideo>? videos=null;
        if(JsonValue.Child(e,"videos").ValueKind==JsonValueKind.Array)
        {
            videos=[];
            foreach(var v in JsonValue.Array(e,"videos").Take(128))
                if(v.ValueKind==JsonValueKind.Object&&Bounded.Exact(v,"id",2048) is {} videoId)
                    videos.Add(new(videoId,Bounded.Text(v,"title",1024),Bounded.Text(v,"released",128),Bounded.Int(v,"season"),Bounded.Int(v,"episode"),JsonValue.Child(v,"streams").ValueKind==JsonValueKind.Array?StremioStream.ParseList(JsonValue.Child(v,"streams"),64):null));
            if(videos.Count==0)videos=null;
        }
        return new()
        {
            Id=id,Type=Bounded.Text(e,"type",64),Name=name,ImdbId=Bounded.LossyText(e,"imdb_id",64)??Bounded.LossyText(e,"imdbId",64),
            TmdbId=Bounded.FlexibleInt(e,"tmdb_id")??Bounded.FlexibleInt(e,"tmdbId")??Bounded.FlexibleInt(e,"moviedb_id")??Bounded.FlexibleInt(e,"moviedbId"),
            Poster=Bounded.Text(e,"poster",16*1024),Background=Bounded.Text(e,"background",16*1024),Description=Bounded.Text(e,"description",16*1024),
            ReleaseInfo=Bounded.Text(e,"releaseInfo",512),Released=Bounded.Text(e,"released",128),ImdbRating=Bounded.Text(e,"imdbRating",128),Genres=genres,Videos=videos,
            DefaultVideoId=Bounded.Text(JsonValue.Child(e,"behaviorHints"),"defaultVideoId",2048)
        };
    }
}

public abstract record StremioOutcome
{
    public sealed record Results(int Count):StremioOutcome;
    public sealed record NoResults:StremioOutcome;
    public sealed record UnplayableOnly(int Count):StremioOutcome;
    public sealed record ExternalOnly(int Count):StremioOutcome;
    public sealed record AddonError(string Message):StremioOutcome;
    public sealed record AppFailure(string Reason):StremioOutcome;
    public bool IsFailure=>this is AddonError or AppFailure;
    public bool ExplainsEmptyList=>this is AppFailure or UnplayableOnly or ExternalOnly or AddonError;
    public string DisplayMessage=>this switch
    {
        Results r=>$"{r.Count} result{(r.Count==1?"":"s")}",
        NoResults=>"No results found",
        UnplayableOnly u=>u.Count==1?"1 result, but it is a torrent link Eclipse cannot play":$"{u.Count} results, but they are torrent links Eclipse cannot play",
        ExternalOnly x=>x.Count==1?"1 result, but it opens in another service":$"{x.Count} results, but they open in another service",
        AddonError=>"Addon error",
        AppFailure f=>$"Eclipse cut this addon's run short ({f.Reason})",
        _=>""
    };
    public string? DisplayDetail=>this switch
    {
        UnplayableOnly=>"Eclipse plays direct links only.",
        ExternalOnly=>"This addon links out to another app instead of handing Eclipse a stream.",
        AddonError a=>a.Message.Trim() is {Length:>0} m?m:"This addon did not return a usable response.",
        AppFailure f=>f.Reason.Trim() is {Length:>0} r?$"{r}. This is Eclipse, not the addon.":"Eclipse stopped this addon's run before it finished. This is Eclipse, not the addon.",
        _=>null
    };
}

public static class Sizes
{
    public static string File(long bytes)
    {
        if(bytes<1000)return bytes==1?"1 byte":$"{bytes} bytes";
        string[] units=["KB","MB","GB","TB","PB"];double value=bytes;var unit=-1;
        while(value>=1000&&unit<units.Length-1){value/=1000;unit++;}
        var digits=unit switch{0=>0,1=>1,_=>2};
        return value.ToString(digits==0?"0":"0."+new string('#',digits),CultureInfo.CurrentCulture)+" "+units[unit];
    }
}
