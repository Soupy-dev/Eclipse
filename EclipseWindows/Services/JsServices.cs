using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using Jint;
using Jint.Native;

namespace Eclipse.Windows.Services;

public sealed class ServiceAuthor { [JsonRequired,JsonPropertyName("name")] public string Name {get;set;}="";[JsonRequired,JsonPropertyName("icon")] public string Icon {get;set;}=""; }

public sealed class ServiceMetadata
{
    [JsonRequired,JsonPropertyName("sourceName")] public string SourceName {get;set;}="";
    [JsonRequired,JsonPropertyName("author")] public ServiceAuthor Author {get;set;}=new();
    [JsonRequired,JsonPropertyName("iconUrl")] public string IconUrl {get;set;}="";
    [JsonRequired,JsonPropertyName("version")] public string Version {get;set;}="";
    [JsonRequired,JsonPropertyName("language")] public string Language {get;set;}="";
    [JsonRequired,JsonPropertyName("baseUrl")] public string BaseUrl {get;set;}="";
    [JsonRequired,JsonPropertyName("streamType")] public string StreamType {get;set;}="";
    [JsonRequired,JsonPropertyName("quality")] public string Quality {get;set;}="";
    [JsonRequired,JsonPropertyName("searchBaseUrl")] public string SearchBaseUrl {get;set;}="";
    [JsonRequired,JsonPropertyName("scriptUrl")] public string ScriptUrl {get;set;}="";
    [JsonPropertyName("softsub")] public bool? Softsub {get;set;}
    [JsonPropertyName("multiStream")] public bool? MultiStream {get;set;}
    [JsonPropertyName("multiSubs")] public bool? MultiSubs {get;set;}
    [JsonPropertyName("type")] public string? Type {get;set;}
    [JsonPropertyName("novel")] public bool? Novel {get;set;}
    [JsonPropertyName("settings")] public bool? Settings {get;set;}
}

public sealed class JsService
{
    public required Guid Id {get;init;}
    public required ServiceMetadata Metadata {get;init;}
    public required string Script {get;init;}
    public required string Url {get;init;}
    public bool IsActive {get;init;}
    public long SortIndex {get;init;}
    public string SourceId=>"service:"+Id.ToString().ToUpperInvariant();
}

public sealed record ServiceSetting(string Key,string Value,string Type,string? Comment,IReadOnlyList<string>? Options);
public sealed record ServiceSearchItem(string Title,string ImageUrl,string Href);
public sealed record ServiceMediaItem(string Description,string Aliases,string Airdate);
public sealed record ServiceEpisodeLink(int Number,string Href);
public sealed record ServiceStreamOption(string Name,string Url,IReadOnlyDictionary<string,string>? Headers,IReadOnlyList<string> LanguageHints,IReadOnlyList<string> MetadataHints);

public sealed partial class JsServices
{
    private sealed record Entry(Guid Id,string Url,string JsonMetadata,bool IsActive,long SortIndex);
    private static readonly JsonSerializerOptions Options=new(){PropertyNamingPolicy=JsonNamingPolicy.CamelCase,WriteIndented=true};
    private static readonly JsonSerializerOptions MetadataOptions=new(){RespectNullableAnnotations=true};
    private static readonly SemaphoreSlim Operations=new(6,6);
    private static readonly string[] LanguageKeys=["lang","language","languages","languageCode","languageCodes","langCode","langCodes","locale","locales","audio","audioLang","audioLangs","audioLanguage","audioLanguages","dub","dubLang","dubLanguage","dubLanguages"];
    private static readonly string[] MetadataKeys=["title","name","label","quality","provider","type","filename","file","streamName","server","source","codec","video","audio","audioTrack","audioTracks"];
    private static readonly string[] UrlKeys=["streamUrl","url","file","src","link","stream"];
    [GeneratedRegex(@"const\s+(\w+)\s*=\s*([^;]+);")] private static partial Regex SettingLine();
    [GeneratedRegex(@"//\s*(.+)$")] private static partial Regex SettingComment();
    public static JsServices Shared {get;}=new();
    private readonly string _root=LocalProtection.LocalPath("services");
    public IReadOnlyList<JsService> Services {get;private set;}=[];
    public string? ReadError {get;private set;}
    public string? Progress {get;private set;}
    public bool IsDownloading {get;private set;}
    public event EventHandler? Changed;
    static JsServices(){Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);}

    private JsServices()
    {
        try
        {
            var path=Path.Combine(_root,"services.json");if(!File.Exists(path))return;
            if(new FileInfo(path).Length>8*1024*1024)throw new IOException();
            var entries=JsonSerializer.Deserialize<List<Entry>>(File.ReadAllText(path),Options)??[];
            Services=entries.Select(Load).Where(s=>s is not null).Select(s=>s!).OrderBy(s=>s.SortIndex).ToArray();
        }
        catch{ReadError="Saved services could not be read. The original file has been preserved.";}
    }
    private string ScriptPath(Guid id)=>Path.Combine(_root,"scripts",id.ToString("N")+".js");
    private JsService? Load(Entry e)
    {
        try
        {
            var metadata=JsonSerializer.Deserialize<ServiceMetadata>(e.JsonMetadata,MetadataOptions);var path=ScriptPath(e.Id);
            if(metadata is null||!File.Exists(path)||new FileInfo(path).Length>5_000_000)return null;
            return new(){Id=e.Id,Metadata=metadata,Script=File.ReadAllText(path),Url=e.Url,IsActive=e.IsActive,SortIndex=e.SortIndex};
        }
        catch(Exception error) when(error is JsonException or IOException){return null;}
    }
    private void Persist(IReadOnlyList<JsService> services,IEnumerable<JsService>? changedScripts=null)
    {
        if(ReadError is not null)throw new IOException(ReadError);
        Directory.CreateDirectory(Path.Combine(_root,"scripts"));
        foreach(var service in changedScripts??[])LocalProtection.WriteAtomically(ScriptPath(service.Id),Encoding.UTF8.GetBytes(service.Script));
        var ordered=services.Select((s,i)=>new JsService{Id=s.Id,Metadata=s.Metadata,Script=s.Script,Url=s.Url,IsActive=s.IsActive,SortIndex=i}).ToArray();
        LocalProtection.WriteAtomically(Path.Combine(_root,"services.json"),JsonSerializer.SerializeToUtf8Bytes(ordered.Select(s=>new Entry(s.Id,s.Url,JsonSerializer.Serialize(s.Metadata),s.IsActive,s.SortIndex)).ToList(),Options));
        foreach(var orphan in Directory.GetFiles(Path.Combine(_root,"scripts"),"*.js").Where(f=>ordered.All(s=>ScriptPath(s.Id)!=f)))try{File.Delete(orphan);}catch(IOException){}
        Services=ordered;Changed?.Invoke(this,EventArgs.Empty);
    }
    public IEnumerable<JsService> Active=>Services.Where(s=>s.IsActive);
    public static Guid ServiceId(ServiceMetadata metadata)
    {
        var hash=Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes($"{metadata.SourceName}_{metadata.Author.Name}_{metadata.Version}"))).ToLowerInvariant();
        return Guid.Parse($"{hash[..8]}-{hash[8..12]}-{hash[12..16]}-{hash[16..20]}-{hash[20..32]}");
    }

    private static async Task<byte[]> DownloadAsync(string url,int limit,string invalid,string failed,CancellationToken token)
    {
        if(SourceHttp.HttpUri(url) is not {} uri)throw new SourceException(invalid);
        using var deadline=CancellationTokenSource.CreateLinkedTokenSource(token);deadline.CancelAfter(TimeSpan.FromSeconds(30));
        try
        {
            using var request=new HttpRequestMessage(HttpMethod.Get,uri);request.Headers.UserAgent.ParseAdd(SourceHttp.DesktopUserAgent);request.Headers.TryAddWithoutValidation("DNT","1");request.Headers.TryAddWithoutValidation("Sec-GPC","1");
            request.Headers.CacheControl=new(){NoCache=true};
            using var response=await SourceHttp.Sandboxed.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,deadline.Token);
            if(response.StatusCode!=System.Net.HttpStatusCode.OK)throw new SourceException(failed);
            return await SourceHttp.ReadAsync(response,limit,deadline.Token);
        }
        catch(OperationCanceledException) when(!token.IsCancellationRequested){throw new SourceException(failed);}
        catch(HttpRequestException){throw new SourceException(failed);}
        catch(IOException){throw new SourceException(failed);}
    }
    private static async Task<ServiceMetadata> MetadataAsync(string url,CancellationToken token)
    {
        var bytes=await DownloadAsync(url,1_000_000,"Invalid URL provided","Failed to download metadata",token);
        try{return JsonSerializer.Deserialize<ServiceMetadata>(bytes,MetadataOptions)??throw new SourceException("Invalid JSON format");}
        catch(JsonException){throw new SourceException("Invalid JSON format");}
    }
    private static async Task<string> ScriptAsync(string url,CancellationToken token)
    {
        var bytes=await DownloadAsync(url,5_000_000,"Invalid script URL in metadata","Failed to download JavaScript file",token);
        try{return new UTF8Encoding(false,true).GetString(bytes);}catch(DecoderFallbackException){throw new SourceException("Invalid JavaScript content");}
    }
    public static bool LooksLikeServiceUrl(string text)=>SourceHttp.HttpUri(text) is {} uri&&uri.AbsolutePath.EndsWith(".json",StringComparison.OrdinalIgnoreCase);

    public async Task<JsService> DownloadAsync(string jsonUrl,CancellationToken token)
    {
        IsDownloading=true;
        try
        {
            Progress="Downloading metadata...";Changed?.Invoke(this,EventArgs.Empty);
            var metadata=await MetadataAsync(jsonUrl.Trim(),token);
            Progress="Downloading JavaScript...";Changed?.Invoke(this,EventArgs.Empty);
            var script=await ScriptAsync(metadata.ScriptUrl,token);
            Progress="Saving service...";
            var id=ServiceId(metadata);
            var service=new JsService{Id=id,Metadata=metadata,Script=script,Url=jsonUrl.Trim(),IsActive=true,SortIndex=Services.Count};
            Persist([..Services.Where(s=>s.Id!=id),service],[service]);
            SourceOrder.Append(service.SourceId);
            return Services.First(s=>s.Id==id);
        }
        finally{IsDownloading=false;Progress=null;Changed?.Invoke(this,EventArgs.Empty);}
    }
    public async Task<bool> UpdateAllAsync(CancellationToken token)
    {
        if(Services.Count==0||IsDownloading)return false;
        IsDownloading=true;
        try
        {
            foreach(var service in Services.ToArray())
            {
                token.ThrowIfCancellationRequested();
                Progress=$"Updating {service.Metadata.SourceName}...";Changed?.Invoke(this,EventArgs.Empty);
                try
                {
                    var metadata=await MetadataAsync(service.Url,token);
                    if(metadata.Version==service.Metadata.Version)continue;
                    var script=await ScriptAsync(metadata.ScriptUrl,token);
                    var existing=ParseSettings(service.Script);if(existing.Count>0)script=ApplySettings(script,existing);
                    if(Services.FirstOrDefault(s=>s.Id==service.Id) is not {} current)continue;
                    var updated=new JsService{Id=current.Id,Metadata=metadata,Script=script,Url=current.Url,IsActive=current.IsActive,SortIndex=current.SortIndex};
                    Persist(Services.Select(s=>s.Id==current.Id?updated:s).ToArray(),[updated]);
                }
                catch(OperationCanceledException){throw;}
                catch(Exception error) when(error is SourceException or IOException){}
            }
            return true;
        }
        finally{IsDownloading=false;Progress=null;Changed?.Invoke(this,EventArgs.Empty);}
    }
    public async Task AutoUpdateIfNeededAsync(CancellationToken token)
    {
        var path=Path.Combine(_root,"last-update.txt");
        try{if(File.Exists(path)&&double.TryParse(File.ReadAllText(path),System.Globalization.CultureInfo.InvariantCulture,out var last)&&DateTimeOffset.UtcNow.ToUnixTimeSeconds()-last<3600)return;}catch(IOException){}
        if(await UpdateAllAsync(token)){Directory.CreateDirectory(_root);File.WriteAllText(path,DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString(System.Globalization.CultureInfo.InvariantCulture));}
    }
    public void Remove(JsService service){Persist(Services.Where(s=>s.Id!=service.Id).ToArray());SourceOrder.Forget(service.SourceId);}
    public void SetActive(JsService service,bool active)=>Persist(Services.Select(s=>s.Id==service.Id?new JsService{Id=s.Id,Metadata=s.Metadata,Script=s.Script,Url=s.Url,IsActive=active,SortIndex=s.SortIndex}:s).ToArray());
    public void Reorder(IReadOnlyList<Guid> order)=>Persist(Services.OrderBy(s=>order.Contains(s.Id)?order.ToList().IndexOf(s.Id):int.MaxValue).ThenBy(s=>s.SortIndex).ToArray());

    public static List<ServiceSetting> ParseSettings(string script)
    {
        var settings=new List<ServiceSetting>();var inside=false;
        foreach(var raw in script.Split('\n'))
        {
            var line=raw.Trim(' ','\t','\r');
            if(line.Contains("// Settings start")){inside=true;continue;}
            if(line.Contains("// Settings end"))break;
            if(!inside||!line.StartsWith("const "))continue;
            var match=SettingLine().Match(line);if(!match.Success)continue;
            var value=match.Groups[2].Value.Trim();string? comment=null;List<string>? options=null;
            if(SettingComment().Match(line) is {Success:true} c)
            {
                var rc=c.Groups[1].Value;var start=rc.IndexOf('[');var end=rc.IndexOf(']');
                if(start>=0&&end>start)
                {
                    var cleaned=rc[(start+1)..end].Split(',').Select(o=>StripQuotes(o.Trim())).Where(o=>o.Length>0).ToList();if(cleaned.Count>0)options=cleaned;
                    var rest=(rc[..start]+rc[(end+1)..]).Trim();comment=rest.Length==0?null:rest;
                }
                else comment=rc.Trim();
            }
            var (type,clean)=value.Length>=2&&Quote(value[0])&&Quote(value[^1])?("string",StripQuotes(value)):value.ToLowerInvariant() is "true" or "false"?("bool",value.ToLowerInvariant()):value.Contains('.')?("float",value):long.TryParse(value,out _)?("int",value):("string",StripQuotes(value));
            settings.Add(new(match.Groups[1].Value,clean,type,comment,options));
        }
        return settings;
    }
    private static string StringLiteral(string value)=>"\""+string.Concat(value.Select(c=>c switch{'"'=>"\\\"",'\\'=>"\\\\",'/'=>"\\/",'\b'=>"\\b",'\f'=>"\\f",'\n'=>"\\n",'\r'=>"\\r",'\t'=>"\\t",<(char)0x20=>$"\\u{(int)c:x4}",_=>c.ToString()}))+"\"";
    private static bool Quote(char c)=>"\"'“”‘’".Contains(c);
    private static string StripQuotes(string value){var t=value.Trim();return t.Length>=2&&Quote(t[0])&&Quote(t[^1])?t[1..^1]:t;}
    public static string ApplySettings(string script,IReadOnlyList<ServiceSetting> settings)
    {
        var lines=script.Split('\n');var map=settings.GroupBy(s=>s.Key).ToDictionary(g=>g.Key,g=>g.Last());var inside=false;
        for(var i=0;i<lines.Length;i++)
        {
            var line=lines[i].Trim(' ','\t','\r');
            if(line.Contains("// Settings start")){inside=true;continue;}
            if(line.Contains("// Settings end"))break;
            if(!inside||!line.StartsWith("const ")||SettingLine().Match(line) is not {Success:true} match||!map.TryGetValue(match.Groups[1].Value,out var setting))continue;
            var value=setting.Type=="string"?StringLiteral(setting.Value):setting.Value;
            var parts=new List<string>();if(setting.Comment?.Trim().Length>0)parts.Add(setting.Comment);if(setting.Options is {Count:>0} o)parts.Add("["+string.Join(", ",o.Select(x=>$"\"{x}\""))+"]");
            var leading=lines[i][..(lines[i].Length-lines[i].TrimStart().Length)];
            lines[i]=$"{leading}const {setting.Key} = {value};{(parts.Count==0?"":" // "+string.Join(' ',parts))}";
        }
        return string.Join('\n',lines);
    }
    public void UpdateSettings(JsService service,IReadOnlyList<ServiceSetting> settings)
    {
        if(Services.FirstOrDefault(s=>s.Id==service.Id) is not {} current)return;
        var updated=new JsService{Id=current.Id,Metadata=current.Metadata,Script=ApplySettings(current.Script,settings),Url=current.Url,IsActive=current.IsActive,SortIndex=current.SortIndex};
        Persist(Services.Select(s=>s.Id==current.Id?updated:s).ToArray(),[updated]);
    }

    private static async Task<string?> InvokeAsync(JsService service,string function,string argument,CancellationToken token,TimeSpan? timeout=null)
    {
        await Operations.WaitAsync(token);
        using var host=new JsHost("Service "+service.Metadata.SourceName,timeout??TimeSpan.FromSeconds(20),token);
        try
        {
            var done=new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
            host.Fault+=_=>done.TrySetResult(null);
            await using var registration=host.Token.Register(()=>{if(token.IsCancellationRequested)done.TrySetCanceled(token);else done.TrySetResult(null);});
            var fetch=new PluginFetch(PluginSessions.For(service.SourceId),300,8);
            await host.RunAsync(()=>
            {
                Install(host,fetch,service);
                host.Engine.Execute(JsHost.Prepare("service-prelude",JsHost.Resource("ServicePrelude.js")));
                try{host.Engine.Execute(JsHost.Prepare("service:"+JsHost.CodeKey(service.Script),service.Script));}catch(Exception error) when(error is not OperationCanceledException){done.TrySetResult(null);return;}
                var callable=host.Engine.GetValue(function);
                if(callable.IsUndefined()||callable.IsNull()){done.TrySetResult(null);return;}
                JsValue result;
                try{result=host.Engine.Invoke(callable,argument);}catch(Exception error) when(error is not OperationCanceledException){done.TrySetResult(null);return;}
                void Deliver(JsValue value){done.TrySetResult(value.IsString()&&value.AsString().Length<=4*1024*1024?value.AsString():null);}
                if(result.IsObject()&&result.AsObject().Get("then") is {} then&&!then.IsUndefined()&&!then.IsNull())
                {
                    var onResolve=new Jint.Runtime.Interop.ClrFunction(host.Engine,"",(_,a)=>{Deliver(a.Length>0?a[0]:JsValue.Undefined);return JsValue.Undefined;});
                    var onReject=new Jint.Runtime.Interop.ClrFunction(host.Engine,"",(_,_)=>{done.TrySetResult(null);return JsValue.Undefined;});
                    host.Engine.Invoke(then,result,[onResolve,onReject]);
                }
                else if(result.IsNull()||result.IsUndefined())done.TrySetResult(null);
                else Deliver(result);
            });
            return await done.Task;
        }
        catch(OperationCanceledException) when(token.IsCancellationRequested){throw;}
        catch(Exception){return null;}
        finally{Operations.Release();}
    }
    private static void Install(JsHost host,PluginFetch fetch,JsService service)
    {
        var e=host.Engine;
        var console=new Jint.Native.JsObject(e);var log=new Jint.Runtime.Interop.ClrFunction(e,"log",(_,_)=>JsValue.Undefined);
        console.Set("log",log);console.Set("error",log);e.SetValue("console",console);e.SetValue("log",log);
        host.Set("_0xB4F2",_=>"eclipse-cranci-1");
        host.Set("btoa",a=>Convert.ToBase64String(Encoding.UTF8.GetBytes(JsHost.Text(a,0))));
        host.Set("atob",a=>{try{return new UTF8Encoding(false,true).GetString(Convert.FromBase64String(JsHost.Text(a,0)));}catch(Exception error) when(error is FormatException or DecoderFallbackException){return JsValue.Null;}});
        var timers=new HashSet<int>();var next=0;
        JsValue Schedule(JsValue[] a,bool repeat)
        {
            var callback=JsHost.Arg(a,0);if(callback.IsUndefined()||callback.IsNull()||timers.Count>=64)return 0;
            var id=++next;timers.Add(id);var delay=Math.Clamp(JsHost.Number(a,1),repeat?16:0,60000);
            void Arm()=>_=Task.Delay(TimeSpan.FromMilliseconds(delay),host.Token).ContinueWith(t=>{if(!t.IsCanceled)host.Post(()=>{if(!timers.Contains(id))return;if(!repeat)timers.Remove(id);try{host.Call(callback);}catch(Jint.Runtime.JavaScriptException){}if(repeat&&timers.Contains(id))Arm();});},TaskScheduler.Default);
            Arm();return id;
        }
        host.Set("setTimeout",a=>Schedule(a,false));host.Set("setInterval",a=>Schedule(a,true));
        host.Set("clearTimeout",a=>{timers.Remove((int)JsHost.Number(a,0));return JsValue.Undefined;});host.Set("clearInterval",a=>{timers.Remove((int)JsHost.Number(a,0));return JsValue.Undefined;});
        host.Set("fetchNative",a=>
        {
            var url=JsHost.Text(a,0);var headers=PluginFetch.Headers(JsHost.Arg(a,1));var resolve=JsHost.Arg(a,2);var reject=JsHost.Arg(a,3);
            _=Task.Run(async()=>
            {
                try
                {
                    var response=await fetch.SendAsync(url,"GET",headers,null,true,30000,false,host.Token);
                    if(Challenge(response)){host.Post(()=>host.Call(reject,ChallengeMessage));return;}
                    host.Post(()=>host.Call(resolve,Decode(response,null)));
                }
                catch(OperationCanceledException){}
                catch(Exception error){host.Post(()=>host.Call(reject,error is JsRunException?error.Message:"Service network request failed"));}
            },CancellationToken.None);
            return JsValue.Undefined;
        });
        host.Set("fetchV2Native",a=>
        {
            var url=JsHost.Text(a,0);var headers=PluginFetch.Headers(JsHost.Arg(a,1));var method=JsHost.Text(a,2);if(method.Length==0)method="GET";
            var rawBody=JsHost.Arg(a,3);var body=rawBody.IsNull()||rawBody.IsUndefined()?null:rawBody.ToString();
            var r=JsHost.Arg(a,4);var redirect=r.IsUndefined()||r.IsNull()||r.IsBoolean()&&r.AsBoolean()||r.IsNumber()&&r.AsNumber()!=0;
            var encoding=JsHost.Text(a,5);var resolve=JsHost.Arg(a,6);
            var bodyEmpty=string.IsNullOrEmpty(body)||body is "null" or "undefined";
            if(method.ToUpperInvariant()=="GET"&&!bodyEmpty){host.Post(()=>host.Call(resolve,host.Object(new Dictionary<string,JsValue>{["error"]="GET request must not have a body"})));return JsValue.Undefined;}
            _=Task.Run(async()=>
            {
                try
                {
                    var response=await fetch.SendAsync(url,method,headers,bodyEmpty?null:body,redirect,30000,false,host.Token,true);
                    var challenged=Challenge(response);
                    host.Post(()=>
                    {
                        var responseHeaders=new Jint.Native.JsObject(host.Engine);foreach(var (k,v) in response.Headers)responseHeaders.Set(k,v);
                        var values=new Dictionary<string,JsValue>{["status"]=response.Status,["ok"]=response.Ok&&!challenged,["url"]=response.Url,["headers"]=responseHeaders,["body"]=challenged?"":Decode(response,encoding)};
                        if(challenged)values["error"]=ChallengeMessage;
                        host.Call(resolve,host.Object(values));
                    });
                }
                catch(OperationCanceledException){}
                catch(Exception error){var message=error is JsRunException?error.Message:"Service network request failed";host.Post(()=>host.Call(resolve,host.Object(new Dictionary<string,JsValue>{["error"]=message})));}
            },CancellationToken.None);
            return JsValue.Undefined;
        });
        host.Set("networkFetchNative",a=>
        {
            var reject=JsHost.Arg(a,3);host.Post(()=>host.Call(reject,"networkFetch is not available in Eclipse for Windows yet."));return JsValue.Undefined;
        });
    }
    private const string ChallengeMessage="This source requires an interactive security challenge, which Eclipse for Windows cannot complete yet.";
    public static bool Challenge(PluginResponse response)
    {
        var body=response.Body.Length>200_000?response.Body[..200_000].ToLowerInvariant():response.Body.ToLowerInvariant();
        var headers=response.Headers.ToDictionary(h=>h.Key.ToLowerInvariant(),h=>h.Value.ToLowerInvariant());
        if(headers.TryGetValue("cf-mitigated",out var mitigated)&&mitigated.Contains("challenge"))return true;
        var document=body.Contains("<html")||body.Contains("<!doctype");
        if(body.Contains("__cf_chl_")||body.Contains("cf_chl_opt")||body.Contains("enable javascript and cookies")||document&&(body.Contains("check.ddos-guard.net")||body.Contains("/.well-known/ddos-guard/"))||body.Contains("just a moment")&&body.Contains("cloudflare"))return true;
        if(response.Status is not (403 or 429 or 503))return false;
        return body.Contains("challenges.cloudflare.com")||body.Contains("cf-turnstile")||response.Status!=429&&body.Contains("challenge-platform")||body.Contains("cf-spinner")||body.Contains("jschl")||body.Contains("ddos-guard")&&(body.Contains("checking your browser")||body.Contains("please wait"));
    }
    private static string Decode(PluginResponse response,string? declared)
    {
        if(response.Raw is null)return response.Body;
        Encoding? encoding=null;
        if(response.Headers.FirstOrDefault(h=>h.Key.Equals("Content-Type",StringComparison.OrdinalIgnoreCase)).Value is {} type&&Regex.Match(type,@"charset=[""']?([\w-]+)",RegexOptions.IgnoreCase) is {Success:true} m)
            try{encoding=Encoding.GetEncoding(m.Groups[1].Value);}catch(ArgumentException){}
        if(encoding is null&&declared is {Length:>0})try{encoding=Encoding.GetEncoding(declared);}catch(ArgumentException){}
        return (encoding??Encoding.UTF8).GetString(response.Raw);
    }
    private static string Bounded(string? value,int bytes){if(value is null)return "";if(Encoding.UTF8.GetByteCount(value)<=bytes)return value;var end=0;var count=0;foreach(var rune in value.EnumerateRunes()){if(count+rune.Utf8SequenceLength>bytes)break;count+=rune.Utf8SequenceLength;end+=rune.Utf16SequenceLength;}return value[..end];}
    private static bool Clean(string value)=>!value.Any(char.IsControl);

    public static async Task<IReadOnlyList<ServiceSearchItem>> SearchAsync(JsService service,string keyword,CancellationToken token,int? maxResults=null)
    {
        var bytes=Encoding.UTF8.GetBytes(keyword);var bounded=bytes.Length<=1024?keyword:Encoding.UTF8.GetString(bytes,0,1024).TrimEnd('�');
        bounded=bounded.Trim();if(bounded.Length==0)return [];
        var json=await InvokeAsync(service,"searchResults",bounded,token);
        if(json is null)return [];
        try
        {
            using var document=JsonDocument.Parse(json,new JsonDocumentOptions{MaxDepth=12});
            var limit=Math.Clamp(maxResults??1200,0,1200);var items=new List<ServiceSearchItem>();
            foreach(var item in JsonValue.Items(document.RootElement))
            {
                if(items.Count>=limit)break;
                if(JsonValue.Child(item,"title").ValueKind!=JsonValueKind.String||JsonValue.Child(item,"image").ValueKind!=JsonValueKind.String||JsonValue.Child(item,"href").ValueKind!=JsonValueKind.String)continue;
                var title=JsonValue.Text(item,"title");var image=JsonValue.Text(item,"image");var href=JsonValue.Text(item,"href");
                if(Encoding.UTF8.GetByteCount(title)>512||Encoding.UTF8.GetByteCount(image)>16*1024||Encoding.UTF8.GetByteCount(href)>16*1024||!Clean(image)||!Clean(href)||title.Trim().Length==0)continue;
                items.Add(new(title.Trim(),image,href));
            }
            return items;
        }
        catch(JsonException){return [];}
    }
    public static async Task<(IReadOnlyList<ServiceMediaItem> Details,IReadOnlyList<ServiceEpisodeLink> Episodes)> DetailsAsync(JsService service,string href,CancellationToken token)
    {
        if(SourceHttp.HttpUri(href) is null)return ([],[]);
        var details=InvokeAsync(service,"extractDetails",href,token);var episodes=EpisodesAsync(service,href,token);
        var detailJson=await details;var items=new List<ServiceMediaItem>();
        if(detailJson is not null)
            try{using var document=JsonDocument.Parse(detailJson,new JsonDocumentOptions{MaxDepth=12});foreach(var item in JsonValue.Items(document.RootElement).Take(16))items.Add(new(Bounded(JsonValue.Text(item,"description"),64*1024),Bounded(JsonValue.Text(item,"aliases"),8*1024),Bounded(JsonValue.Text(item,"airdate"),256)));}
            catch(JsonException){}
        return (items,await episodes);
    }
    public static async Task<IReadOnlyList<ServiceEpisodeLink>> EpisodesAsync(JsService service,string href,CancellationToken token)
    {
        if(SourceHttp.HttpUri(href) is null)return [];
        var json=await InvokeAsync(service,"extractEpisodes",href,token);if(json is null)return [];
        try
        {
            using var document=JsonDocument.Parse(json,new JsonDocumentOptions{MaxDepth=12});var episodes=new List<ServiceEpisodeLink>();var index=0;
            foreach(var item in JsonValue.Items(document.RootElement))
            {
                index++;if(episodes.Count>=4096)break;
                if(JsonValue.Text(item,"href") is not {Length:>0} link||!Clean(link)||Encoding.UTF8.GetByteCount(link)>16*1024)continue;
                if(EpisodeNumber(JsonValue.Child(item,"number"),index) is {} number)episodes.Add(new(number,link));
            }
            return episodes;
        }
        catch(JsonException){return [];}
    }
    private static int? EpisodeNumber(JsonElement value,int fallback)
    {
        if(value.ValueKind==JsonValueKind.Number&&value.TryGetDouble(out var d)&&double.IsFinite(d)){var r=Math.Round(d);return Math.Abs(r)<=100_000?(int)r:null;}
        if(value.ValueKind==JsonValueKind.String&&value.GetString() is {} s)
        {
            if(s.Length<=16&&int.TryParse(s,out var i))return Math.Abs(i)<=100_000?i:null;
            if(double.TryParse(s,System.Globalization.NumberStyles.Float,System.Globalization.CultureInfo.InvariantCulture,out var parsed)&&double.IsFinite(parsed)){var r=Math.Round(parsed);return Math.Abs(r)<=100_000?(int)r:null;}
        }
        return fallback;
    }
    public static async Task<IReadOnlyList<ServiceStreamOption>> StreamsAsync(JsService service,string href,CancellationToken token)
    {
        if(SourceHttp.HttpUri(href) is null)return [];
        var json=await InvokeAsync(service,"extractStreamUrl",href,token);
        if(json is null)return [];
        if(SourceHttp.HttpUri(json.Trim()) is not null)return [new("Stream 1",json.Trim(),null,[],[])];
        try
        {
            using var document=JsonDocument.Parse(json,new JsonDocumentOptions{MaxDepth=12});var root=document.RootElement;
            if(root.ValueKind==JsonValueKind.Array)return StringOptions(JsonValue.Items(root).Where(v=>v.ValueKind==JsonValueKind.String).Select(v=>v.GetString()!).ToArray());
            if(root.ValueKind!=JsonValueKind.Object)return [];
            var envelope=Headers(JsonValue.Child(root,"headers"));
            var streams=JsonValue.Child(root,"streams");var stream=JsonValue.Child(root,"stream");
            if(streams.ValueKind==JsonValueKind.Array&&streams.EnumerateArray().Any(s=>s.ValueKind==JsonValueKind.Object))
                return streams.EnumerateArray().Where(s=>s.ValueKind==JsonValueKind.Object).Take(1200).Select((s,i)=>Option(s,i,envelope)).Where(o=>o is not null).Select(o=>o!).Take(200).ToArray();
            if(stream.ValueKind==JsonValueKind.Object)return Option(stream,0,envelope) is {} single?[single]:[];
            var strings=streams.ValueKind==JsonValueKind.Array?streams.EnumerateArray().Where(v=>v.ValueKind==JsonValueKind.String).Select(v=>v.GetString()!).ToArray():stream.ValueKind==JsonValueKind.String?[stream.GetString()!]:[];
            var options=StringOptions(strings);
            return envelope is null?options:options.Select(o=>o with{Headers=envelope}).ToArray();
        }
        catch(JsonException){return [];}
    }
    private static IReadOnlyDictionary<string,string>? Headers(JsonElement value)
    {
        if(value.ValueKind!=JsonValueKind.Object)return null;
        var headers=new Dictionary<string,string>();
        foreach(var p in value.EnumerateObject().Take(64))if(p.Value.ValueKind is JsonValueKind.String or JsonValueKind.Number&&p.Name.Trim().Length is >0 and <=128&&!p.Name.Equals("Range",StringComparison.OrdinalIgnoreCase)){var v=p.Value.ValueKind==JsonValueKind.String?p.Value.GetString()!:p.Value.GetRawText();if(v.Length<=16*1024&&v.Trim().Length>0)headers[p.Name.Trim()]=v.Trim();}
        return headers.Count==0?null:headers;
    }
    private static ServiceStreamOption? Option(JsonElement source,int index,IReadOnlyDictionary<string,string>? envelope)
    {
        var url=UrlKeys.Select(k=>JsonValue.Text(source,k)).FirstOrDefault(u=>u.Length is >0 and <=64*1024);if(url is null)return null;
        var title=new[]{"title","name","label","quality"}.Select(k=>JsonValue.Text(source,k).Trim()).FirstOrDefault(t=>t.Length>0);
        IEnumerable<string> Values(string[] keys)=>keys.SelectMany(k=>JsonValue.Child(source,k) is var v&&v.ValueKind==JsonValueKind.String?[v.GetString()!]:v.ValueKind==JsonValueKind.Number?[v.GetRawText()]:v.ValueKind==JsonValueKind.Array?v.EnumerateArray().Where(x=>x.ValueKind==JsonValueKind.String).Take(32).Select(x=>x.GetString()!):[]).Select(s=>s.Trim()).Where(s=>s.Length is >0 and <=2048);
        return new(title??$"Stream {index+1}",url,Headers(JsonValue.Child(source,"headers"))??envelope,Values(LanguageKeys).ToArray(),Values(MetadataKeys).ToArray());
    }
    private static IReadOnlyList<ServiceStreamOption> StringOptions(IReadOnlyList<string> streams)
    {
        static bool IsUrl(string v)=>SourceHttp.HttpUri(v) is not null;
        var options=new List<ServiceStreamOption>();var unnamed=1;var count=Math.Min(streams.Count,1200);
        for(var i=0;i<count&&options.Count<200;)
        {
            if(IsUrl(streams[i])){options.Add(new($"Stream {unnamed++}",streams[i],null,[],[]));i++;}
            else if(i+1<count&&IsUrl(streams[i+1])){options.Add(new(streams[i],streams[i+1],null,[],[streams[i]]));i+=2;}
            else i++;
        }
        return options;
    }
}
