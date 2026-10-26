using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using Jint;
using Jint.Native;

namespace Eclipse.Windows.Services;

public sealed class NuvioRepository
{
    public string Id {get;set;}="";
    public string ManifestUrl {get;set;}="";
    public string Name {get;set;}="";
    public string? Description {get;set;}
    public string? Version {get;set;}
    public int ScraperCount {get;set;}
    public double LastUpdated {get;set;}
    public long SortIndex {get;set;}
    public bool IsEnabled {get;set;}=true;
    public string? ErrorMessage {get;set;}
    [JsonIgnore] public string HostLabel=>Uri.TryCreate(ManifestUrl,UriKind.Absolute,out var uri)?uri.Host:ManifestUrl;
    [JsonIgnore] public string DisplayName=>Name.Trim() is {Length:>0} n?n:HostLabel;
}

public sealed class NuvioScraper
{
    public string Id {get;set;}="";
    public string ProviderKey {get;set;}="";
    public string RepositoryId {get;set;}="";
    public string RepositoryUrl {get;set;}="";
    public string Name {get;set;}="";
    public string Description {get;set;}="";
    public string? Author {get;set;}
    public string Version {get;set;}="1.0.0";
    public string Filename {get;set;}="";
    public string CodeFileName {get;set;}="";
    public List<string> SupportedTypes {get;set;}=["movie","tv"];
    public bool Enabled {get;set;}=true;
    public bool ManifestEnabled {get;set;}=true;
    public bool DeclaresSettings {get;set;}
    public string? Logo {get;set;}
    public List<string> ContentLanguage {get;set;}=[];
    public List<string>? Formats {get;set;}
    [JsonIgnore] public bool IsRunnable=>Enabled&&ManifestEnabled;
    [JsonIgnore] public string DisplayName=>Name.Trim() is {Length:>0} n?n:ProviderKey;
    public bool SupportsType(string type)=>SupportedTypes.Select(NuvioPlugins.NormalizeType).Contains(NuvioPlugins.NormalizeType(type));
}

public sealed class NuvioState
{
    public bool PluginsEnabled {get;set;}=true;
    public List<NuvioRepository> Repositories {get;set;}=[];
    public List<NuvioScraper> Scrapers {get;set;}=[];
    public Dictionary<string,Dictionary<string,JsonElement>> ScraperSettings {get;set;}=[];
}

public sealed record NuvioSettingsOption(string Label,string Value);
public sealed record NuvioSettingsField(string Kind,string Key,string Label,string? Description,IReadOnlyList<NuvioSettingsOption> Options,JsonElement? DefaultValue);

public sealed class NuvioStream : IStreamText
{
    public required string Id {get;init;}
    public required string ScraperId {get;init;}
    public required string ScraperName {get;init;}
    public required string SourceId {get;init;}
    public required string SourceName {get;init;}
    public required string Title {get;init;}
    public string? Name {get;init;}
    public required string Url {get;init;}
    public string? Quality {get;init;}
    public string? Size {get;init;}
    public string? Language {get;init;}
    public string? Provider {get;init;}
    public string? Type {get;init;}
    public IReadOnlyDictionary<string,string>? Headers {get;init;}
    public string DisplayName=>Name?.Trim() is {Length:>0} n?n:Title.Trim() is {Length:>0} t?t:"Stream";
    public string MetadataLabel=>string.Join(" - ",new[]{Quality,Size,Language,Provider}.Select(v=>v?.Trim()).Where(v=>v is {Length:>0}));
    public IReadOnlyList<string> LanguageHints
    {
        get
        {
            var hints=new List<string>();if(Language?.Trim() is {Length:>0} l)hints.Add(l);
            if(Provider is {} p){if(StreamDetection.NormalizedLanguageName(p) is {} n)hints.Add(n);else hints.AddRange(StreamDetection.DetectedLanguageNames(p));}
            return hints;
        }
    }
    public IReadOnlyList<string> MetadataHints=>new[]{Quality,Size,Language,Provider,Type,ScraperName,Url}.Select(v=>v?.Trim()).Where(v=>v is {Length:>0}).Select(v=>v!).ToArray();
    string? IStreamText.Description=>MetadataLabel;
    string? IStreamText.Filename=>null;
    string? IStreamText.FormattedVideoSize=>Size;
}

public abstract record NuvioOutcome
{
    public sealed record Results(IReadOnlyList<NuvioStream> Streams):NuvioOutcome;
    public sealed record NoResults:NuvioOutcome;
    public sealed record UnplayableOnly(int Count,string Kind):NuvioOutcome;
    public sealed record UnsupportedMediaType(string MediaType):NuvioOutcome;
    public sealed record UnresolvedCoordinate:NuvioOutcome;
    public sealed record NotEnabled(string Reason):NuvioOutcome;
    public sealed record SourceUnreachable:NuvioOutcome;
    public sealed record NeedsSetup:NuvioOutcome;
    public sealed record ProviderError(string Reason):NuvioOutcome;
    public sealed record TimedOut:NuvioOutcome;
    public sealed record AppFailure(string Reason):NuvioOutcome;
    public IReadOnlyList<NuvioStream> ResultStreams=>this is Results r?r.Streams:[];
    public bool IsFailure=>this is ProviderError or TimedOut or AppFailure or SourceUnreachable;
    public string DisplayMessage=>this switch
    {
        Results r=>$"{r.Streams.Count} result{(r.Streams.Count==1?"":"s")}",
        NoResults=>"No results found",
        UnplayableOnly u=>u.Kind switch
        {
            "torrent"=>u.Count==1?"1 result, but it is a torrent link Eclipse cannot play":$"{u.Count} results, but they are torrent links Eclipse cannot play",
            "unreadable"=>u.Count==1?"1 result, but Eclipse could not read its link":$"{u.Count} results, but Eclipse could not read their links",
            _=>u.Count==1?"1 result, but Eclipse cannot play its link":$"{u.Count} results, but Eclipse cannot play their links"
        },
        UnresolvedCoordinate=>"Episode not identified",
        UnsupportedMediaType m=>$"This provider does not support {m.MediaType}",
        NotEnabled n=>n.Reason,
        SourceUnreachable=>"This provider's source is not responding",
        NeedsSetup=>"This provider needs to be set up",
        ProviderError=>"Provider error",
        TimedOut=>"Provider timed out",
        AppFailure=>"Eclipse could not run this provider",
        _=>""
    };
    public string? DisplayDetail=>this switch
    {
        UnplayableOnly u=>u.Kind=="unreadable"?"The provider delivered a link that is not a valid web address.":"Eclipse plays direct links only.",
        UnresolvedCoordinate=>"Eclipse could not map this episode to a TMDB season and episode, and will not guess.",
        SourceUnreachable=>"Every request it made was refused or unanswered. This is the plugin's source, not Eclipse.",
        NeedsSetup=>"It did not contact its source at all. Check its settings for a required login or token.",
        ProviderError p=>p.Reason.Trim() is {Length:>0} r?r:"The plugin reported an error.",
        TimedOut=>"The plugin's source did not respond in time.",
        AppFailure a=>a.Reason.Trim() is {Length:>0} r?r:"This is an Eclipse problem, not a plugin problem.",
        _=>null
    };
}

public sealed class NuvioPlugins
{
    private const int MaxRepositories=100,MaxScrapersPerRepository=200,TextLength=2048,CodeBytes=8*1024*1024,StateBytes=4*1024*1024,MaxStreamsPerScraper=40,MaxResultBytes=4*1024*1024;
    private static readonly JsonSerializerOptions Options=new(){PropertyNamingPolicy=JsonNamingPolicy.CamelCase,WriteIndented=true};
    private static readonly SemaphoreSlim Executions=new(4,4);
    public static NuvioPlugins Shared {get;}=new();
    private readonly string _root=LocalProtection.LocalPath("nuvio");
    private readonly object _gate=new();
    private readonly HashSet<string> _installing=[];
    public NuvioState State {get;private set;}=new();
    public string? ReadError {get;private set;}
    public string? Progress {get;private set;}
    public event EventHandler? Changed;

    private NuvioPlugins()
    {
        try
        {
            var path=Path.Combine(_root,"state.json");
            if(File.Exists(path)){if(new FileInfo(path).Length>StateBytes)throw new IOException();State=JsonSerializer.Deserialize<NuvioState>(File.ReadAllText(path),Options)??throw new JsonException();}
        }
        catch{State=new();ReadError="Installed plugin data could not be read. Eclipse preserved it and blocked changes until the plugin data is reset.";}
    }
    public IEnumerable<NuvioRepository> Repositories=>State.Repositories.OrderBy(r=>r.SortIndex);
    public IEnumerable<NuvioScraper> ScrapersFor(string repositoryId)=>State.Scrapers.Where(s=>s.RepositoryId==repositoryId);
    public NuvioRepository? Repository(string id)=>State.Repositories.FirstOrDefault(r=>r.Id==id);
    public NuvioScraper? Scraper(string id)=>State.Scrapers.FirstOrDefault(s=>s.Id==id);
    public IEnumerable<NuvioScraper> ActiveScrapers=>State.PluginsEnabled?Repositories.Where(r=>r.IsEnabled).SelectMany(r=>ScrapersFor(r.Id)).Where(s=>s.IsRunnable&&HasCode(s)):[];
    private string CodePath(string repositoryId,string codeFile)=>Path.Combine(_root,"code",Hex(repositoryId)[..32],codeFile);
    public bool HasCode(NuvioScraper scraper)=>scraper.CodeFileName.Length>0&&File.Exists(CodePath(scraper.RepositoryId,scraper.CodeFileName));

    private void Commit(NuvioState candidate)
    {
        if(ReadError is not null)throw new IOException(ReadError);
        var bytes=JsonSerializer.SerializeToUtf8Bytes(candidate,Options);
        if(bytes.Length>StateBytes)throw new IOException("Installed plugin data exceeds the local size limit.");
        Directory.CreateDirectory(_root);LocalProtection.WriteAtomically(Path.Combine(_root,"state.json"),bytes);
        lock(_gate)State=candidate;
        Changed?.Invoke(this,EventArgs.Empty);
    }
    private NuvioState Copy()=>JsonSerializer.Deserialize<NuvioState>(JsonSerializer.SerializeToUtf8Bytes(State,Options),Options)!;
    public void ResetData()
    {
        try{if(Directory.Exists(_root))Directory.Delete(_root,true);}catch(IOException){}
        ReadError=null;Commit(new());
    }

    public static string Hex(string value)=>Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant();
    public static string RepositoryId(string manifestUrl)=>"nuvio:"+Hex(manifestUrl.ToLowerInvariant())[..32];
    public static string ScraperId(string manifestUrl,string providerKey)=>"nuvio:"+Hex($"{manifestUrl.ToLowerInvariant()}::{providerKey}")[..32];
    public static string CodeFileName(string scraperId)=>Hex(scraperId)[..40]+".js";
    public static string NormalizeType(string value)=>value.ToLowerInvariant() is "series" or "show" or "other"?"tv":value.ToLowerInvariant();
    public static string NormalizeManifestUrl(string raw)
    {
        var trimmed=raw.Trim();if(trimmed.Length==0)throw new SourceException("Enter a plugin repository URL.");
        if(!trimmed.StartsWith("http://",StringComparison.OrdinalIgnoreCase)&&!trimmed.StartsWith("https://",StringComparison.OrdinalIgnoreCase))trimmed="https://"+trimmed;
        if(!Uri.TryCreate(trimmed,UriKind.Absolute,out var uri)||uri.Scheme is not ("http" or "https")||uri.Host.Length==0)throw new SourceException("Enter a valid plugin repository URL.");
        var path=uri.AbsolutePath.TrimEnd('/');if(!path.EndsWith("/manifest.json",StringComparison.OrdinalIgnoreCase))path+="/manifest.json";
        var normalized=new UriBuilder(uri){Path=path,Fragment=""}.Uri.AbsoluteUri;
        if(normalized.Length>TextLength)throw new SourceException("Enter a valid plugin repository URL.");
        return normalized;
    }
    public static string CodeUrl(string manifestUrl,string filename)
    {
        var trimmed=filename.Trim();
        if(trimmed.StartsWith("http://",StringComparison.OrdinalIgnoreCase)||trimmed.StartsWith("https://",StringComparison.OrdinalIgnoreCase))return trimmed;
        if(!Uri.TryCreate(manifestUrl,UriKind.Absolute,out var manifest))return "";
        var path=manifest.AbsolutePath;if(path.EndsWith("/manifest.json",StringComparison.OrdinalIgnoreCase))path=path[..^"/manifest.json".Length];
        var baseUri=new UriBuilder(manifest){Path=path.TrimEnd('/')+"/",Query="",Fragment=""}.Uri;
        if(!Uri.TryCreate(baseUri,trimmed.TrimStart('/'),out var resolved))return "";
        var builder=new UriBuilder(resolved){Fragment=""};if(resolved.Query.Length==0&&manifest.Query.Length>1)builder.Query=manifest.Query[1..];
        return builder.Uri.AbsoluteUri;
    }
    private static string? Origin(string url)=>Uri.TryCreate(url,UriKind.Absolute,out var uri)&&uri.Scheme is "http" or "https"?$"{uri.Scheme}://{uri.Host.ToLowerInvariant()}:{uri.Port}":null;
    private static bool PlatformAllows(JsonElement scraper)
    {
        var disabled=Bounded.Strings(JsonValue.Child(scraper,"disabledPlatforms"),64,128)??[];
        if(disabled.Any(d=>d.ToLowerInvariant() is "windows" or "win"))return false;
        var supported=Bounded.Strings(JsonValue.Child(scraper,"supportedPlatforms"),64,128);
        return supported is null||supported.Count==0||supported.Any(s=>s.ToLowerInvariant() is "all" or "windows" or "win" or "desktop" or "ios" or "android");
    }

    private static async Task<(string Text,Uri Final)> DownloadAsync(string url,TimeSpan timeout,int maxBytes,CancellationToken token)
    {
        if(SourceHttp.HttpUri(url,true) is not {} uri)throw new SourceException("Plugin repositories must use HTTPS.");
        for(var attempt=0;;attempt++)
        {
            using var deadline=CancellationTokenSource.CreateLinkedTokenSource(token);deadline.CancelAfter(timeout);
            try
            {
                using var request=new HttpRequestMessage(HttpMethod.Get,uri);request.Headers.UserAgent.ParseAdd("EclipseWindows/0.1");
                using var response=await SourceHttp.Sandboxed.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,deadline.Token);
                var status=(int)response.StatusCode;
                if(attempt==0&&status is 429 or 500 or 502 or 503 or 504)
                {
                    var delay=response.Headers.RetryAfter?.Delta??(response.Headers.RetryAfter?.Date-DateTimeOffset.UtcNow)??TimeSpan.FromSeconds(.5);
                    await Task.Delay(TimeSpan.FromSeconds(Math.Clamp(delay.TotalSeconds,0,5)),token);continue;
                }
                if(!response.IsSuccessStatusCode)throw new SourceException($"{uri.Host} returned HTTP {status}.",status);
                var final=response.RequestMessage?.RequestUri??uri;
                if(final.Scheme!="https")throw new SourceException("Plugin repositories must use HTTPS.");
                return (Encoding.UTF8.GetString(await SourceHttp.ReadAsync(response,maxBytes,deadline.Token)),final);
            }
            catch(OperationCanceledException) when(!token.IsCancellationRequested){throw new SourceException($"{uri.Host} took too long to respond.");}
            catch(HttpRequestException error){throw new SourceException(error.Message.StartsWith("Requests to local")?error.Message:$"Could not connect to {uri.Host}.");}
            catch(IOException){throw new SourceException($"The connection to {uri.Host} was interrupted.");}
        }
    }

    public async Task<(int Installed,int Failed)> AddRepositoryAsync(string rawUrl,CancellationToken token)
    {
        if(ReadError is not null)throw new SourceException(ReadError);
        var manifestUrl=NormalizeManifestUrl(rawUrl);var id=RepositoryId(manifestUrl);
        lock(_gate){if(State.Repositories.Any(r=>r.Id==id)||!_installing.Add(id))throw new SourceException("That plugin repository is already installed.");}
        try
        {
            if(State.Repositories.Count>=MaxRepositories)throw new SourceException("Eclipse keeps at most 100 plugin repositories.");
            var (repository,scrapers,failed)=await FetchRepositoryAsync(manifestUrl,id,State.Repositories.Count,[],token);
            var candidate=Copy();candidate.Repositories.Add(repository);candidate.Scrapers.RemoveAll(s=>s.RepositoryId==id);candidate.Scrapers.AddRange(scrapers);
            Commit(candidate);
            SourceOrder.Enroll(scrapers.Where(s=>s.IsRunnable&&HasCode(s)).Select(s=>s.Id).ToArray());
            return (scrapers.Count(HasCode),failed);
        }
        catch{RemoveCode(id);throw;}
        finally{lock(_gate)_installing.Remove(id);Progress=null;}
    }
    public async Task RefreshAsync(string repositoryId,CancellationToken token)
    {
        if(Repository(repositoryId) is not {} existing||ReadError is not null)return;
        try
        {
            var previous=ScrapersFor(repositoryId).ToDictionary(s=>s.Id);
            var (repository,scrapers,_)=await FetchRepositoryAsync(existing.ManifestUrl,repositoryId,existing.SortIndex,previous,token);
            if(Repository(repositoryId) is not {} current)return;
            repository.IsEnabled=current.IsEnabled;
            var candidate=Copy();candidate.Repositories[candidate.Repositories.FindIndex(r=>r.Id==repositoryId)]=repository;
            candidate.Scrapers.RemoveAll(s=>s.RepositoryId==repositoryId);candidate.Scrapers.AddRange(scrapers);
            foreach(var key in candidate.ScraperSettings.Keys.Where(k=>candidate.Scrapers.All(s=>s.Id!=k)).ToArray())candidate.ScraperSettings.Remove(key);
            Commit(candidate);
            foreach(var stale in previous.Values.Where(p=>scrapers.All(s=>s.Id!=p.Id))){DeleteCode(stale);SourceOrder.Forget(stale.Id);}
            SourceOrder.Enroll(scrapers.Where(s=>s.IsRunnable&&HasCode(s)).Select(s=>s.Id).ToArray());
        }
        catch(OperationCanceledException){throw;}
        catch(Exception error) when(error is SourceException or IOException or UnauthorizedAccessException or JsonException)
        {
            var candidate=Copy();if(candidate.Repositories.FirstOrDefault(r=>r.Id==repositoryId) is {} r){r.ErrorMessage=error.Message;try{Commit(candidate);}catch(Exception commit) when(commit is IOException or UnauthorizedAccessException){}}
        }
        finally{Progress=null;}
    }
    public async Task RefreshAllAsync(CancellationToken token){foreach(var repository in Repositories.ToArray())await RefreshAsync(repository.Id,token);}

    private async Task<(NuvioRepository,List<NuvioScraper>,int)> FetchRepositoryAsync(string manifestUrl,string repositoryId,long sortIndex,Dictionary<string,NuvioScraper> previous,CancellationToken token)
    {
        Progress="Reading manifest";Changed?.Invoke(this,EventArgs.Empty);
        var (text,final)=await DownloadAsync(manifestUrl,TimeSpan.FromSeconds(10),2*1024*1024,token);
        JsonElement manifest;
        try{using var document=JsonDocument.Parse(text,new JsonDocumentOptions{MaxDepth=32});manifest=document.RootElement.Clone();}catch(JsonException){throw new SourceException("Plugin returned an invalid stream response.");}
        if(JsonValue.Text(manifest,"name") is not {Length:>0} name)throw new SourceException("Plugin manifest is missing a name.");
        if(JsonValue.Text(manifest,"version") is not {Length:>0} version)throw new SourceException("Plugin manifest is missing a version.");
        var seen=new HashSet<string>();
        var candidates=JsonValue.Array(manifest,"scrapers").Where(s=>s.ValueKind==JsonValueKind.Object&&JsonValue.Text(s,"id") is {Length:>0 and <=TextLength} sid&&sid==sid.Trim()&&JsonValue.Text(s,"name").Length is >0 and <=TextLength&&JsonValue.Text(s,"filename").Trim().Length is >0 and <=TextLength&&PlatformAllows(s)&&seen.Add(sid)).Take(MaxScrapersPerRepository).ToArray();
        if(candidates.Length==0)throw new SourceException("Plugin manifest does not contain any providers.");
        var origins=new[]{Origin(manifestUrl),Origin(final.AbsoluteUri)}.Where(o=>o is not null&&o.StartsWith("https://")).Distinct().ToArray();
        var downloads=new Dictionary<string,string?>();var completed=0;
        using var slots=new SemaphoreSlim(6,6);
        await Task.WhenAll(candidates.Select(async info=>
        {
            var key=JsonValue.Text(info,"id");var url=CodeUrl(final.AbsoluteUri,JsonValue.Text(info,"filename"));string? code=null;
            await slots.WaitAsync(token);
            try
            {
                if(Origin(url) is {} origin&&origins.Contains(origin))
                {
                    var (body,codeFinal)=await DownloadAsync(url,TimeSpan.FromSeconds(15),CodeBytes,token);
                    if(Origin(codeFinal.AbsoluteUri) is {} landed&&origins.Contains(landed)&&body.Trim().Length>0)code=body;
                }
            }
            catch(SourceException){}
            finally{slots.Release();lock(downloads){downloads[key]=code;Progress=$"Downloading providers ({++completed} of {candidates.Length})";}}
        }));
        token.ThrowIfCancellationRequested();
        var scrapers=new List<NuvioScraper>();var failed=0;
        foreach(var info in candidates)
        {
            var key=JsonValue.Text(info,"id");var id=ScraperId(manifestUrl,key);var codeFile=CodeFileName(id);
            if(downloads.GetValueOrDefault(key) is {} code){var path=CodePath(repositoryId,codeFile);Directory.CreateDirectory(Path.GetDirectoryName(path)!);LocalProtection.WriteAtomically(path,Encoding.UTF8.GetBytes(code));}
            else{failed++;if(previous.ContainsKey(id)==false)codeFile=File.Exists(CodePath(repositoryId,codeFile))?codeFile:"";}
            var manifestEnabled=JsonValue.Child(info,"enabled").ValueKind!=JsonValueKind.False;
            scrapers.Add(new()
            {
                Id=id,ProviderKey=key,RepositoryId=repositoryId,RepositoryUrl=manifestUrl,Name=JsonValue.Text(info,"name"),Description=Bounded.Text(info,"description",TextLength)??"",Author=Bounded.Text(info,"author",TextLength),
                Version=Bounded.Text(info,"version",TextLength)??"1.0.0",Filename=JsonValue.Text(info,"filename"),CodeFileName=codeFile,
                SupportedTypes=Bounded.Strings(JsonValue.Child(info,"supportedTypes"),32,128) is {Count:>0} types?types:["movie","tv"],
                Enabled=manifestEnabled&&(previous.GetValueOrDefault(id)?.Enabled??true),ManifestEnabled=manifestEnabled,DeclaresSettings=JsonValue.Bool(info,"hasSettings"),
                Logo=Bounded.Text(info,"logo",TextLength),ContentLanguage=Bounded.Strings(JsonValue.Child(info,"contentLanguage"),64,128)??[],
                Formats=Bounded.Strings(JsonValue.Child(info,"formats"),64,128)??Bounded.Strings(JsonValue.Child(info,"supportedFormats"),64,128)
            });
        }
        var repository=new NuvioRepository{Id=repositoryId,ManifestUrl=manifestUrl,Name=name,Description=Bounded.Text(manifest,"description",TextLength),Version=version,ScraperCount=candidates.Length,LastUpdated=DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()/1000.0,SortIndex=sortIndex};
        return (repository,scrapers,failed);
    }
    private void DeleteCode(NuvioScraper scraper){try{if(scraper.CodeFileName.Length>0)File.Delete(CodePath(scraper.RepositoryId,scraper.CodeFileName));}catch(IOException){}}
    private void RemoveCode(string repositoryId){try{var dir=Path.Combine(_root,"code",Hex(repositoryId)[..32]);if(Directory.Exists(dir))Directory.Delete(dir,true);}catch(IOException){}}

    public void Uninstall(string repositoryId)
    {
        var scrapers=ScrapersFor(repositoryId).ToArray();
        var candidate=Copy();candidate.Repositories.RemoveAll(r=>r.Id==repositoryId);candidate.Scrapers.RemoveAll(s=>s.RepositoryId==repositoryId);
        foreach(var s in scrapers)candidate.ScraperSettings.Remove(s.Id);
        Commit(candidate);RemoveCode(repositoryId);
        foreach(var s in scrapers)SourceOrder.Forget(s.Id);
    }
    public void SetPluginsEnabled(bool enabled){var c=Copy();c.PluginsEnabled=enabled;Commit(c);}
    public void SetRepositoryEnabled(string id,bool enabled){var c=Copy();if(c.Repositories.FirstOrDefault(r=>r.Id==id) is {} r){r.IsEnabled=enabled;Commit(c);}}
    public void SetScraperEnabled(string id,bool enabled){var c=Copy();if(c.Scrapers.FirstOrDefault(s=>s.Id==id) is {} s&&s.ManifestEnabled){s.Enabled=enabled;Commit(c);if(enabled&&Scraper(id) is {IsRunnable:true} runnable&&HasCode(runnable))SourceOrder.Enroll([id]);}}
    public void SetAllScrapersEnabled(string repositoryId,bool enabled){var c=Copy();foreach(var s in c.Scrapers.Where(s=>s.RepositoryId==repositoryId&&s.ManifestEnabled))s.Enabled=enabled;Commit(c);if(enabled)SourceOrder.Enroll(ScrapersFor(repositoryId).Where(s=>s.IsRunnable&&HasCode(s)).Select(s=>s.Id).ToArray());}
    public void Reorder(IReadOnlyList<string> order){var c=Copy();foreach(var r in c.Repositories){var i=order.ToList().IndexOf(r.Id);if(i>=0)r.SortIndex=i;}Commit(c);}

    public IReadOnlyDictionary<string,JsonElement> SettingsValues(string scraperId)=>State.ScraperSettings.TryGetValue(scraperId,out var values)?values:new Dictionary<string,JsonElement>();
    public void SetSettingsValue(string scraperId,string key,JsonElement? value)
    {
        if(key.Length is 0 or >TextLength)return;
        var c=Copy();var values=c.ScraperSettings.TryGetValue(scraperId,out var existing)?existing:[];
        if(value is {} v)
        {
            if(v.ValueKind==JsonValueKind.String&&v.GetString()!.Length>8*1024)return;
            if(!values.ContainsKey(key)&&values.Count>=100)return;
            values[key]=v.Clone();
        }
        else values.Remove(key);
        if(values.Count==0)c.ScraperSettings.Remove(scraperId);else c.ScraperSettings[scraperId]=values;
        Commit(c);
    }
    private string SettingsJson(NuvioScraper scraper)=>JsonSerializer.Serialize(SettingsValues(scraper.Id));
    private async Task<string?> ReadCodeAsync(NuvioScraper scraper)
    {
        var path=CodePath(scraper.RepositoryId,scraper.CodeFileName);
        try{var info=new FileInfo(path);if(!info.Exists||info.Length>CodeBytes)return null;return await File.ReadAllTextAsync(path);}catch(IOException){return null;}
    }

    public async Task<IReadOnlyList<NuvioSettingsField>> SettingsFieldsAsync(string scraperId,CancellationToken token)
    {
        if(Scraper(scraperId) is not {} scraper)throw new SourceException("Plugin provider was not found.");
        var code=await ReadCodeAsync(scraper)??throw new SourceException("Plugin provider was not found.");
        var (json,_)=await ExecuteAsync(code,scraper,SettingsJson(scraper),SettingsInvocation,token);
        return ParseSettingsFields(json);
    }
    public async Task<NuvioOutcome> ResolveAsync(NuvioScraper scraper,int tmdbId,string mediaType,int? season,int? episode,CancellationToken token)
    {
        if(mediaType!="movie"&&(season is null||episode is null))return new NuvioOutcome.UnresolvedCoordinate();
        if(ReadError is not null)return new NuvioOutcome.AppFailure("Nuvio's saved provider state is unreadable. Reset it before running providers.");
        if(!State.PluginsEnabled)return new NuvioOutcome.NotEnabled("Nuvio plugins are turned off.");
        if(Scraper(scraper.Id) is not {} current)return new NuvioOutcome.NotEnabled("This provider is no longer installed.");
        if(!current.IsRunnable||Repository(current.RepositoryId) is not {IsEnabled:true} repository)return new NuvioOutcome.NotEnabled("This provider is turned off.");
        if(!HasCode(current))return new NuvioOutcome.NotEnabled("This provider is waiting for its code download to finish.");
        var type=NormalizeType(mediaType);
        if(!current.SupportsType(type))return new NuvioOutcome.UnsupportedMediaType(type=="movie"?"movies":"TV shows");
        var code=await ReadCodeAsync(current);if(code is null)return new NuvioOutcome.AppFailure("The plugin code is missing from storage. Refresh the repository.");
        string json;PluginFetch fetch;
        try{(json,fetch)=await ExecuteAsync(code,current,SettingsJson(current),StreamsInvocation(tmdbId.ToString(),type,season,episode),token);}
        catch(OperationCanceledException){throw;}
        catch(JsRunException error){return error.Failure switch{JsFailure.Timeout=>new NuvioOutcome.TimedOut(),JsFailure.Limit or JsFailure.Bootstrap=>new NuvioOutcome.AppFailure(error.Message),_=>new NuvioOutcome.ProviderError(Humanized(error.Message))};}
        List<NuvioStream> streams;int torrent=0,unreadable=0,discarded=0;
        try{streams=ParseStreams(json,current,repository,ref torrent,ref unreadable,ref discarded);}
        catch(Exception error) when(error is JsonException or FormatException){return new NuvioOutcome.ProviderError("The plugin returned a stream list Eclipse could not read.");}
        if(streams.Count==0)
        {
            if(torrent+unreadable>0)return new NuvioOutcome.UnplayableOnly(torrent+unreadable,unreadable==0?"torrent":torrent==0?"unreadable":"mixed");
            if(fetch.Refusal is {} refusal)return new NuvioOutcome.AppFailure($"Eclipse cut this provider's run short ({refusal}).");
            if(discarded>0)return new NuvioOutcome.ProviderError(discarded==1?"It returned 1 result with no link Eclipse could read.":$"It returned {discarded} results with no link Eclipse could read.");
            if(fetch.MadeNoRequests)return new NuvioOutcome.NeedsSetup();
            if(fetch.EveryRequestFailed)return new NuvioOutcome.SourceUnreachable();
            return new NuvioOutcome.NoResults();
        }
        return new NuvioOutcome.Results(streams.DistinctBy(s=>s.Url).Take(MaxStreamsPerScraper).ToArray());
    }
    private static string Humanized(string message)=>message.Trim() switch{"getStreams not found"=>"The plugin did not load correctly, so Eclipse could not ask it for streams.","Invalid fetch URL."=>"The plugin requested an address Eclipse cannot open.",var m=>m};

    private const string SettingsInvocation="(function(){var onSettings=(globalThis.__nuvio_module&&globalThis.__nuvio_module.exports&&globalThis.__nuvio_module.exports.onSettings)||globalThis.onSettings;if(typeof onSettings!==\"function\"){__capture_result(\"[]\");return;}Promise.resolve(onSettings()).then(function(result){__capture_result(JSON.stringify(result||[]));}).catch(function(error){__capture_error(String((error&&(error.stack||error.message))||error||\"Plugin settings failed\"));});})();";
    private static string StreamsInvocation(string tmdbId,string mediaType,int? season,int? episode)=>
        $"(function(){{var getStreams=(globalThis.__nuvio_module&&globalThis.__nuvio_module.exports&&globalThis.__nuvio_module.exports.getStreams)||globalThis.getStreams;if(typeof getStreams!==\"function\"){{__capture_error(\"getStreams not found\");return;}}Promise.resolve(getStreams({JsonSerializer.Serialize(tmdbId)},{JsonSerializer.Serialize(mediaType)},{season?.ToString()??"undefined"},{episode?.ToString()??"undefined"})).then(function(result){{__capture_result(JSON.stringify(result||[]));}}).catch(function(error){{__capture_error(String((error&&(error.stack||error.message))||error||\"Plugin failed\"));}});}})();";
    private static string ModuleWrapped(string code)=>"(function() {\nvar module = { exports: {} };\nvar exports = module.exports;\nglobalThis.module = module;\nglobalThis.exports = exports;\n"+code+"\nglobalThis.__nuvio_module = module;\n})();";

    private static async Task<(string Json,PluginFetch Fetch)> ExecuteAsync(string code,NuvioScraper scraper,string settingsJson,string invocation,CancellationToken token)
    {
        await Executions.WaitAsync(token);
        using var host=new JsHost("Nuvio "+scraper.DisplayName,TimeSpan.FromSeconds(60),token);
        try
        {
            var done=new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
            var fetch=new PluginFetch(PluginSessions.For(scraper.Id+"|"+JsHost.CodeKey(code+"\0"+settingsJson)));
            var cheerio=new CheerioBridge();
            host.Fault+=error=>done.TrySetException(JsHost.Classify(error,token));
            await using var registration=host.Token.Register(()=>done.TrySetException(token.IsCancellationRequested?new OperationCanceledException():new JsRunException("Plugin timed out while fetching streams.",JsFailure.Timeout)));
            await host.RunAsync(()=>
            {
                Install(host,fetch,cheerio,done,scraper.Id,settingsJson);
                try{host.Engine.Execute(JsHost.Prepare("nuvio-polyfill",JsHost.Resource("NuvioPolyfill.js")));}
                catch(Exception error) when(error is not OperationCanceledException){throw new JsRunException(JsHost.Classify(error,token).Message,JsFailure.Bootstrap);}
                try{var wrapped=ModuleWrapped(code);host.Engine.Execute(JsHost.Prepare("nuvio:"+JsHost.CodeKey(wrapped),wrapped));}
                catch(Exception error) when(error is not OperationCanceledException and not JsRunException){throw new JsRunException("Plugin failed to load: "+JsHost.Classify(error,token).Message);}
                try{host.Engine.Execute(invocation);}
                catch(Exception error) when(error is not OperationCanceledException){done.TrySetException(JsHost.Classify(error,token));}
            });
            return (await done.Task,fetch);
        }
        catch(JsRunException){throw;}
        catch(OperationCanceledException) when(token.IsCancellationRequested){throw;}
        catch(Exception error){throw JsHost.Classify(error,token);}
        finally{Executions.Release();}
    }
    private static void Install(JsHost host,PluginFetch fetch,CheerioBridge cheerio,TaskCompletionSource<string> done,string scraperId,string settingsJson)
    {
        var e=host.Engine;
        e.SetValue("__eclipse_scraper_id",scraperId);e.SetValue("__eclipse_scraper_settings",host.Parse(settingsJson));
        host.Set("__capture_result",a=>{var json=JsHost.Text(a,0);if(Encoding.UTF8.GetByteCount(json)>MaxResultBytes)done.TrySetException(new JsRunException($"Eclipse refused this provider's result set because it was larger than Eclipse's own {MaxResultBytes}-byte limit.",JsFailure.Limit));else done.TrySetResult(json);return JsValue.Undefined;});
        host.Set("__capture_error",a=>{done.TrySetException(new JsRunException(JsHost.Text(a,0)));return JsValue.Undefined;});
        var console=new Jint.Native.JsObject(e);var log=new Jint.Runtime.Interop.ClrFunction(e,"log",(_,_)=>JsValue.Undefined);
        foreach(var name in new[]{"log","info","debug","warn","error"})console.Set(name,log);
        e.SetValue("console",console);
        InstallFetch(host,fetch,"__native_fetch",false);
        host.Set("__schedule_timeout",a=>
        {
            var callback=JsHost.Arg(a,0);if(callback.IsUndefined()||callback.IsNull())return JsValue.Undefined;
            var delay=Math.Clamp(JsHost.Number(a,1),0,60000);
            _=Task.Delay(TimeSpan.FromMilliseconds(delay),host.Token).ContinueWith(t=>{if(!t.IsCanceled)host.Post(()=>host.Call(callback));},TaskScheduler.Default);
            return JsValue.Undefined;
        });
        host.Set("__crypto_hash",a=>JsCrypto.Hash(JsHost.Text(a,0),JsHost.Text(a,1)));
        host.Set("__crypto_hmac",a=>JsCrypto.Hmac(JsHost.Text(a,0),JsHost.Text(a,1),JsHost.Text(a,2)));
        host.Set("__base64_encode",a=>Convert.ToBase64String(Encoding.UTF8.GetBytes(JsHost.Text(a,0))));
        host.Set("__base64_decode",a=>{try{return Encoding.UTF8.GetString(Convert.FromBase64String(JsHost.Text(a,0)));}catch(FormatException){return "";}});
        host.Set("__utf8_to_hex",a=>JsCrypto.Hex(Encoding.UTF8.GetBytes(JsHost.Text(a,0))));
        host.Set("__hex_to_utf8",a=>{var hex=JsHost.Text(a,0).Trim().Replace(" ","").ToLowerInvariant();if(hex.Length%2==1)hex="0"+hex;var bytes=new List<byte>();for(var i=0;i+1<hex.Length;i+=2)if(byte.TryParse(hex.AsSpan(i,2),System.Globalization.NumberStyles.HexNumber,null,out var b))bytes.Add(b);try{return new UTF8Encoding(false,true).GetString(bytes.ToArray());}catch(DecoderFallbackException){return "";}});
        host.Set("__crypto_utf8_to_hex",a=>JsCrypto.Hex(Encoding.UTF8.GetBytes(JsHost.Text(a,0))));
        host.Set("__crypto_hex_to_utf8",a=>Encoding.UTF8.GetString(JsCrypto.FromHex(JsHost.Text(a,0))));
        host.Set("__crypto_digest_hex_raw",a=>JsCrypto.DigestRaw(JsHost.Text(a,0),JsHost.Text(a,1)));
        host.Set("__crypto_hmac_hex_raw",a=>JsCrypto.HmacRaw(JsHost.Text(a,0),JsHost.Text(a,1),JsHost.Text(a,2)));
        host.Set("__crypto_pbkdf2_hex",a=>JsCrypto.Pbkdf2(JsHost.Text(a,0),JsHost.Text(a,1),(int)JsHost.Number(a,2),(int)JsHost.Number(a,3),JsHost.Text(a,4)));
        foreach(var (name,encrypt) in new[]{("__crypto_aes_encrypt_hex",true),("__crypto_aes_decrypt_hex",false),("__crypto_des3_encrypt_hex",true),("__crypto_des3_decrypt_hex",false)})
            host.Set(name,a=>JsCrypto.Cipher(encrypt,JsHost.Text(a,0),JsHost.Text(a,1),JsHost.Text(a,2),JsHost.Text(a,3)));
        host.Set("__crypto_get_random_values_hex",a=>JsCrypto.Random((int)JsHost.Number(a,0)));
        host.Set("__parse_url",a=>host.Object(JsCrypto.ParseUrl(JsHost.Text(a,0),JsHost.Arg(a,1).IsNull()||JsHost.Arg(a,1).IsUndefined()?null:JsHost.Text(a,1))));
        JsValue Handles(int[] handles)=>new Jint.Native.JsArray(e,handles.Select(h=>(JsValue)h).ToArray());
        host.Set("__cheerio_load",a=>cheerio.Load(JsHost.Text(a,0)));
        host.Set("__cheerio_select",a=>Handles(cheerio.Select((int)JsHost.Number(a,0),Selector(JsHost.Text(a,1)))));
        host.Set("__cheerio_text",a=>cheerio.Text((int)JsHost.Number(a,0)));
        host.Set("__cheerio_html",a=>cheerio.Html((int)JsHost.Number(a,0)));
        host.Set("__cheerio_inner_html",a=>cheerio.InnerHtml((int)JsHost.Number(a,0)));
        host.Set("__cheerio_attr",a=>cheerio.Attr((int)JsHost.Number(a,0),JsHost.Text(a,1)) is {} v?v:JsValue.Null);
        host.Set("__cheerio_next",a=>cheerio.Next((int)JsHost.Number(a,0)));
        host.Set("__cheerio_prev",a=>cheerio.Previous((int)JsHost.Number(a,0)));
        host.Set("__cheerio_children",a=>Handles(cheerio.Children((int)JsHost.Number(a,0))));
        host.Set("__cheerio_parent",a=>cheerio.Parent((int)JsHost.Number(a,0)));
        host.Set("__cheerio_matches",a=>cheerio.Matches((int)JsHost.Number(a,0),Selector(JsHost.Text(a,1))));
    }
    private static string Selector(string selector)
    {
        if(selector.Contains(":contains("))selector=System.Text.RegularExpressions.Regex.Replace(selector,":contains\\(([\"'])(.*?)\\1\\)",":contains(\"$2\")");
        return selector.Contains(":eq(")||selector.Contains(":lt(")||selector.Contains(":gt(")?System.Text.RegularExpressions.Regex.Replace(selector,@":(eq|lt|gt)\(\s*(\d{1,6})\s*\)",m=>{var n=int.Parse(m.Groups[2].Value);return m.Groups[1].Value switch{"eq"=>$":nth-child({n+1})","lt"=>$":nth-child(-n+{n})",_=>$":nth-child(n+{n+2})"};}):selector;
    }
    internal static void InstallFetch(JsHost host,PluginFetch fetch,string name,bool binary)
    {
        host.Set(name,a=>
        {
            var url=JsHost.Text(a,0);var method=JsHost.Text(a,1);var headers=PluginFetch.Headers(JsHost.Arg(a,2));
            var rawBody=JsHost.Arg(a,3);var body=rawBody.IsNull()||rawBody.IsUndefined()?null:rawBody.ToString();
            var f=JsHost.Arg(a,4);var follow=f.IsUndefined()||f.IsNull()||f.IsBoolean()&&f.AsBoolean()||f.IsNumber()&&f.AsNumber()!=0;
            var timeout=JsHost.Number(a,5);var resolve=JsHost.Arg(a,6);var reject=JsHost.Arg(a,7);
            _=Task.Run(async()=>
            {
                try{var response=await fetch.SendAsync(url,method,headers,body,follow,timeout<=0?30000:timeout,binary,host.Token);host.Post(()=>host.Call(resolve,fetch.ToJs(host,response)));}
                catch(OperationCanceledException){}
                catch(Exception error){var message=error is JsRunException?error.Message:"Plugin network request failed.";host.Post(()=>host.Call(reject,message));}
            },CancellationToken.None);
            return JsValue.Undefined;
        });
    }

    private static string? Clean(JsonElement value)=>value.ValueKind switch{JsonValueKind.String=>value.GetString()?.Trim() is {Length:>0} s&&s!="[object Object]"?s:null,JsonValueKind.Number=>value.GetRawText(),_=>null};
    private static List<NuvioStream> ParseStreams(string json,NuvioScraper scraper,NuvioRepository repository,ref int torrent,ref int unreadable,ref int discarded)
    {
        using var document=JsonDocument.Parse(json,new JsonDocumentOptions{MaxDepth=64});var root=document.RootElement;
        var rows=root.ValueKind==JsonValueKind.Array?root:root.ValueKind==JsonValueKind.Object&&JsonValue.Child(root,"streams").ValueKind==JsonValueKind.Array?JsonValue.Child(root,"streams"):throw new FormatException();
        var streams=new List<NuvioStream>();var index=-1;
        foreach(var item in rows.EnumerateArray().Take(4000))
        {
            index++;if(item.ValueKind!=JsonValueKind.Object)continue;
            var urlValue=JsonValue.Child(item,"url");var delivered=urlValue.ValueKind==JsonValueKind.Object?Clean(JsonValue.Child(urlValue,"url")):Clean(urlValue);
            if(delivered is null){discarded++;continue;}
            if(delivered.StartsWith("magnet:",StringComparison.OrdinalIgnoreCase)){torrent++;continue;}
            var url=delivered.Contains(' ')&&SourceHttp.HttpUri(delivered.Trim().Replace(" ","%20")) is not null?delivered.Trim().Replace(" ","%20"):delivered;
            if(Encoding.UTF8.GetByteCount(url)>16*1024||SourceHttp.HttpUri(url) is null){unreadable++;continue;}
            var title=Clean(JsonValue.Child(item,"title"))??Clean(JsonValue.Child(item,"name"))??"Stream";
            Dictionary<string,string>? headers=null;
            if(JsonValue.Child(item,"headers") is {ValueKind:JsonValueKind.Object} h)
            {
                headers=[];foreach(var p in h.EnumerateObject())if(p.Name.Trim() is {Length:>0} n&&!n.Equals("Range",StringComparison.OrdinalIgnoreCase)&&Clean(p.Value) is {} v)headers.TryAdd(n,v.Length>8192?v[..8192]:v);
                if(headers.Count==0)headers=null;
            }
            streams.Add(new()
            {
                Id=Hex($"{repository.Id}|{scraper.Id}|{index}|{url}|{title}"),ScraperId=scraper.Id,ScraperName=scraper.DisplayName,SourceId=repository.Id,SourceName=repository.DisplayName,Title=title,
                Name=Clean(JsonValue.Child(item,"name")),Url=url,Quality=Clean(JsonValue.Child(item,"quality")),Size=Clean(JsonValue.Child(item,"size")),Language=Clean(JsonValue.Child(item,"language")),
                Provider=Clean(JsonValue.Child(item,"provider")),Type=Clean(JsonValue.Child(item,"type")),Headers=headers
            });
            if(streams.Count==500)break;
        }
        return streams;
    }
    private static List<NuvioSettingsField> ParseSettingsFields(string json)
    {
        JsonDocument document;
        try{document=JsonDocument.Parse(json,new JsonDocumentOptions{MaxDepth=64});}catch(JsonException){throw new JsRunException("The plugin returned settings Eclipse could not read.");}
        using var _=document;var root=document.RootElement;
        var rows=root.ValueKind==JsonValueKind.Array?root:JsonValue.Child(root,"settings");
        var fields=new List<NuvioSettingsField>();
        foreach(var item in JsonValue.Items(rows).Take(500))
        {
            if(item.ValueKind!=JsonValueKind.Object)continue;
            var kind=Clean(JsonValue.Child(item,"type"))?.ToLowerInvariant();if(kind is not ("header" or "toggle" or "select" or "text"))continue;
            var key=Clean(JsonValue.Child(item,"key"))??"";if(kind!="header"&&key.Length==0)continue;
            var options=JsonValue.Array(item,"options").Take(200).Select(o=>Clean(o) is {} text?new NuvioSettingsOption(text,text):o.ValueKind==JsonValueKind.Object&&Clean(JsonValue.Child(o,"value")) is {} value?new NuvioSettingsOption(Clean(JsonValue.Child(o,"label"))??value,value):null).Where(o=>o is not null).Select(o=>o!).ToArray();
            var raw=JsonValue.Child(item,"defaultValue").ValueKind!=JsonValueKind.Undefined?JsonValue.Child(item,"defaultValue"):JsonValue.Child(item,"default");
            JsonElement? defaultValue=raw.ValueKind is JsonValueKind.True or JsonValueKind.False or JsonValueKind.String||raw.ValueKind==JsonValueKind.Number&&double.IsFinite(raw.GetDouble())?raw.Clone():null;
            fields.Add(new(kind,key,Clean(JsonValue.Child(item,"label"))??Clean(JsonValue.Child(item,"title"))??key,Clean(JsonValue.Child(item,"description")),options,defaultValue));
        }
        return fields;
    }
}
