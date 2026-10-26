using System.Collections.Concurrent;
using System.Net;
using System.Net.Http;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using AngleSharp.Dom;
using AngleSharp.Html.Parser;
using Jint;
using Jint.Native;
using Jint.Native.Json;
using Jint.Native.Object;
using Jint.Runtime;
using Jint.Runtime.Interop;

namespace Eclipse.Windows.Services;

public enum JsFailure { Script, Timeout, Limit, Bootstrap }

public sealed class JsRunException(string message,JsFailure failure=JsFailure.Script) : Exception(message) { public JsFailure Failure {get;}=failure; }

public sealed class JsHost : IDisposable
{
    private static readonly ConcurrentDictionary<string,Prepared<Acornima.Ast.Script>> Scripts=new();
    private readonly BlockingCollection<Action> _work=new();
    private const long RetainedLimit=1024L*1024*1024;
    private readonly CancellationTokenSource _lifetime;
    private readonly long _baseline=GC.GetTotalMemory(false);
    private long _checked;
    public Engine Engine {get;}
    public CancellationToken Token=>_lifetime.Token;
    public event Action<Exception>? Fault;

    public JsHost(string name,TimeSpan runTimeout,CancellationToken token)
    {
        _lifetime=CancellationTokenSource.CreateLinkedTokenSource(token);_lifetime.CancelAfter(runTimeout);
        Engine=new Engine(o=>o.LimitMemory(1024L*1024*1024).LimitRecursion(512).MaxStatements(100_000_000).TimeoutInterval(TimeSpan.FromSeconds(20)).CancellationToken(_lifetime.Token).RegexTimeoutInterval(TimeSpan.FromSeconds(5)).MaxArraySize(10_000_000));
        new Thread(Loop,64*1024*1024){IsBackground=true,Name=name,Priority=ThreadPriority.BelowNormal}.Start();
    }
    public static string Resource(string name)
    {
        using var stream=Assembly.GetExecutingAssembly().GetManifestResourceStream("Eclipse.Scripts."+name)??throw new JsRunException("A bundled runtime script is missing.",JsFailure.Bootstrap);
        using var reader=new StreamReader(stream);return reader.ReadToEnd();
    }
    public static Prepared<Acornima.Ast.Script> Prepare(string key,string code)
    {
        if(Scripts.TryGetValue(key,out var hit))return hit;
        var prepared=Engine.PrepareScript(code,key);
        if(Scripts.Count>24)Scripts.Clear();
        return Scripts[key]=prepared;
    }
    public static string CodeKey(string code)=>Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(code)));

    public void Post(Action action){if(_work.IsAddingCompleted)return;try{_work.Add(action);}catch(InvalidOperationException){}}
    public Task RunAsync(Action action)
    {
        var done=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var registration=_lifetime.Token.Register(()=>done.TrySetCanceled(_lifetime.Token));
        Post(()=>{try{action();done.TrySetResult();}catch(Exception error){done.TrySetException(error);throw;}finally{registration.Dispose();}});
        return done.Task;
    }
    private void Loop()
    {
        foreach(var action in _work.GetConsumingEnumerable())
        {
            if(_lifetime.IsCancellationRequested)continue;
            try{action();Engine.Advanced.ProcessTasks();CheckMemory();}
            catch(Exception error){Fault?.Invoke(error);if(error is JsRunException{Failure:JsFailure.Limit})_lifetime.Cancel();}
        }
    }
    private void CheckMemory()
    {
        if(GC.GetTotalMemory(false)-_baseline<=RetainedLimit||Environment.TickCount64-_checked<2000)return;
        _checked=Environment.TickCount64;
        if(GC.GetTotalMemory(true)-_baseline<=RetainedLimit)return;
        throw new JsRunException("Eclipse stopped this script at its memory limit.",JsFailure.Limit);
    }
    public void Dispose(){try{_lifetime.Cancel();}catch(ObjectDisposedException){}_work.CompleteAdding();}

    public void Set(string name,Func<JsValue[],JsValue> body)=>Engine.SetValue(name,new ClrFunction(Engine,name,(_,arguments)=>
    {
        try{return body(arguments);}
        catch(JavaScriptException){throw;}
        catch(Exception error) when(error is not OperationCanceledException){throw Error(error.Message);}
    }));
    public JavaScriptException Error(string message)=>new(Engine.Intrinsics.Error.Construct(message));
    public static string Text(JsValue[] arguments,int index)=>index<arguments.Length&&!arguments[index].IsUndefined()&&!arguments[index].IsNull()?arguments[index].ToString():"";
    public static double Number(JsValue[] arguments,int index)=>index<arguments.Length&&arguments[index].IsNumber()?arguments[index].AsNumber():0;
    public static JsValue Arg(JsValue[] arguments,int index)=>index<arguments.Length?arguments[index]:JsValue.Undefined;
    public void Call(JsValue function,params JsValue[] arguments){if(function.IsUndefined()||function.IsNull())return;Engine.Invoke(function,arguments);}
    public JsValue Parse(string json)=>new JsonParser(Engine).Parse(json);
    public string Stringify(JsValue value)=>new JsonSerializer(Engine).Serialize(value).ToString();
    public JsObject Object(IEnumerable<KeyValuePair<string,JsValue>> values){var o=new JsObject(Engine);foreach(var pair in values)o.Set(pair.Key,pair.Value);return o;}

    public static Exception Classify(Exception error,CancellationToken outer)=>error switch
    {
        JsRunException=>error,
        JavaScriptException js=>new JsRunException(js.Message),
        ExecutionCanceledException or OperationCanceledException when outer.IsCancellationRequested=>new OperationCanceledException(),
        ExecutionCanceledException or OperationCanceledException or TimeoutException=>new JsRunException("timed out",JsFailure.Timeout),
        MemoryLimitExceededException=>new JsRunException("Eclipse stopped this script at its memory limit.",JsFailure.Limit),
        StatementsCountOverflowException=>new JsRunException("Eclipse stopped this script at its statement limit.",JsFailure.Limit),
        RecursionDepthOverflowException=>new JsRunException("Eclipse stopped this script at its recursion limit.",JsFailure.Limit),
        Acornima.ParseErrorException parse=>new JsRunException("Script failed to load: "+parse.Message),
        _=>new JsRunException(error.Message)
    };
}

public sealed record PluginResponse(bool Ok,int Status,string StatusText,string Url,IReadOnlyDictionary<string,string> Headers,string Body,byte[]? Raw);

public sealed class PluginFetch(HttpClient client,int maxPerRun=150,int maxConcurrent=8)
{
    private const int MaxBytes=12*1024*1024,MaxHeaderValue=8*1024,MaxHeaders=64,MaxHeaderBytes=32*1024;
    private static readonly HashSet<string> Forbidden=["proxy-authorization","set-cookie"];
    private static readonly HashSet<string> Withheld=["proxy-authenticate","www-authenticate"];
    private static readonly HashSet<string> Managed=["accept-encoding","connection","content-length","host","keep-alive","proxy-authenticate","proxy-authorization","proxy-connection","te","trailer","transfer-encoding","upgrade"];
    private static readonly HashSet<string> SharedHosts=["api.themoviedb.org","image.tmdb.org","graphql.anilist.co","api.jikan.moe","api.myanimelist.net","kitsu.io","raw.githubusercontent.com","api.github.com"];
    private static readonly string[] Methods=["GET","POST","PUT","PATCH","DELETE","HEAD","OPTIONS"];
    private readonly SemaphoreSlim _slots=new(maxConcurrent,maxConcurrent);
    private int _requests,_own,_ownFailures;
    public int Requests=>_requests;
    public bool MadeNoRequests=>_requests==0;
    public bool EveryRequestFailed=>_own>0&&_ownFailures==_own;
    public string? Refusal {get;private set;}

    public static Dictionary<string,string> Headers(JsValue value)
    {
        var result=new Dictionary<string,string>(StringComparer.Ordinal);
        if(value.IsUndefined()||value.IsNull()||!value.IsObject())return result;
        var obj=value.AsObject();
        void Read(ObjectInstance source)
        {
            foreach(var property in source.GetOwnProperties())
            {
                var name=property.Key.ToString().Trim();var raw=source.Get(property.Key);
                if(name.Length==0||name.Equals("Range",StringComparison.OrdinalIgnoreCase)||!(raw.IsString()||raw.IsNumber()))continue;
                var text=raw.ToString().Trim();if(text.Length==0||text=="[object Object]")continue;
                result[name]=text.Length>MaxHeaderValue?text[..MaxHeaderValue]:text;
            }
        }
        Read(obj);
        if(result.Count==0&&obj.Get("_headers") is {} nested&&nested.IsObject())Read(nested.AsObject());
        return result;
    }
    private Dictionary<string,string> Sanitized(Dictionary<string,string> headers)
    {
        var candidates=new SortedDictionary<string,string>(StringComparer.Ordinal);
        foreach(var (rawName,rawValue) in headers)
        {
            var name=rawName.Trim().ToLowerInvariant();var value=rawValue.Trim();
            if(name.Length==0||value.Length==0||Forbidden.Contains(name))continue;
            candidates[name]=value.Length>MaxHeaderValue?value[..MaxHeaderValue]:value;
        }
        var accepted=new Dictionary<string,string>();var total=0;
        foreach(var (name,value) in candidates)
        {
            if(accepted.Count>=MaxHeaders)break;
            if(Encoding.UTF8.GetByteCount(name)>128||!name.All(c=>c<128&&(char.IsAsciiLetterOrDigit(c)||"!#$%&'*+-.^_`|~".Contains(c)))||!value.All(c=>c==9||c>=32&&c!=127)||Managed.Contains(name))continue;
            var size=Encoding.UTF8.GetByteCount(name)+Encoding.UTF8.GetByteCount(value)+4;
            if(total+size>MaxHeaderBytes)break;
            total+=size;accepted[name]=value;
        }
        return accepted;
    }
    public async Task<PluginResponse> SendAsync(string url,string method,Dictionary<string,string> headers,string? body,bool followRedirects,double timeoutMilliseconds,bool binary,CancellationToken token,bool keepRaw=false)
    {
        if(Interlocked.Increment(ref _requests)>maxPerRun){Refusal="the plugin used its budget of network requests";throw new JsRunException($"This plugin used its budget of {maxPerRun} network requests for one lookup.");}
        if(SourceHttp.HttpUri(url) is not {} uri)throw new JsRunException("Invalid fetch URL.");
        if(SourceHttp.IsTracking(uri))throw new JsRunException("Plugin network request blocked by sandbox.");
        var verb=method.Length==0?"GET":method.ToUpperInvariant();if(!Methods.Contains(verb))throw new JsRunException("Invalid fetch method.");
        byte[]? payload=null;
        if(!string.IsNullOrEmpty(body)&&verb!="GET")
        {
            try{payload=binary?Convert.FromBase64String(body):Encoding.UTF8.GetBytes(body);}catch(FormatException){throw new JsRunException("Invalid binary request body.");}
            if(payload.Length>2*1024*1024)throw new JsRunException("Plugin request body is too large.");
        }
        var sanitized=Sanitized(headers);sanitized.TryAdd("user-agent",SourceHttp.DesktopUserAgent);
        var own=!SharedHosts.Contains(uri.Host.ToLowerInvariant());if(own)Interlocked.Increment(ref _own);
        await _slots.WaitAsync(token).ConfigureAwait(false);
        using var deadline=CancellationTokenSource.CreateLinkedTokenSource(token);deadline.CancelAfter(TimeSpan.FromSeconds(Math.Clamp(timeoutMilliseconds/1000,.25,30)));
        try
        {
            var current=uri;var currentVerb=verb;var currentPayload=payload;HttpResponseMessage? response=null;
            for(var hop=0;;hop++)
            {
                using var request=new HttpRequestMessage(new HttpMethod(currentVerb),current);
                if(currentPayload is not null)request.Content=new ByteArrayContent(currentPayload);
                foreach(var (name,value) in sanitized)if(!request.Headers.TryAddWithoutValidation(name,value))request.Content?.Headers.TryAddWithoutValidation(name,value);
                response?.Dispose();
                response=await client.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,deadline.Token).ConfigureAwait(false);
                var status=(int)response.StatusCode;
                if(!followRedirects||status is not (301 or 302 or 303 or 307 or 308)||response.Headers.Location is not {} location||hop>=10)break;
                var next=location.IsAbsoluteUri?location:new Uri(current,location);
                if(SourceHttp.HttpUri(next.AbsoluteUri) is null||current.Scheme=="https"&&next.Scheme=="http")break;
                if(status==303||(status is 301 or 302&&currentVerb=="POST")){currentVerb="GET";currentPayload=null;}
                current=next;
            }
            using(response)
            {
                var bytes=await SourceHttp.ReadAsync(response,MaxBytes,deadline.Token).ConfigureAwait(false);
                var code=(int)response.StatusCode;if(own&&(code==0||code>=500))Interlocked.Increment(ref _ownFailures);
                var responseHeaders=new Dictionary<string,string>();
                foreach(var header in response.Headers.Concat(response.Content.Headers))if(!Withheld.Contains(header.Key.ToLowerInvariant())){var value=string.Join(", ",header.Value);responseHeaders[header.Key]=value.Length>MaxHeaderValue?value[..MaxHeaderValue]:value;}
                return new(code is >=200 and <=299,code,response.ReasonPhrase??"",response.RequestMessage?.RequestUri?.AbsoluteUri??current.AbsoluteUri,responseHeaders,Encoding.UTF8.GetString(bytes),binary||keepRaw?bytes:null);
            }
        }
        catch(SourceException){Refusal="the response was larger than Eclipse's own limit";if(own)Interlocked.Increment(ref _ownFailures);throw new JsRunException($"The response exceeded Eclipse's {MaxBytes}-byte limit.");}
        catch(OperationCanceledException) when(!token.IsCancellationRequested){if(own)Interlocked.Increment(ref _ownFailures);throw new JsRunException("TimeoutError");}
        catch(HttpRequestException error){if(own)Interlocked.Increment(ref _ownFailures);throw new JsRunException(error.Message.StartsWith("Requests to local")?"Plugin network request blocked by sandbox.":"Plugin network request failed.");}
        catch(IOException){if(own)Interlocked.Increment(ref _ownFailures);throw new JsRunException("Plugin network request failed.");}
        finally{_slots.Release();}
    }
    public JsObject ToJs(JsHost host,PluginResponse response)
    {
        var headers=new JsObject(host.Engine);foreach(var (k,v) in response.Headers)headers.Set(k,v);
        var values=new Dictionary<string,JsValue>{["ok"]=response.Ok,["status"]=response.Status,["statusText"]=response.StatusText,["url"]=response.Url,["headers"]=headers,["body"]=response.Body};
        if(response.Raw is not null)values["bodyBase64"]=Convert.ToBase64String(response.Raw);
        return host.Object(values);
    }
}

public static class PluginSessions
{
    private static readonly object Gate=new();
    private static readonly Dictionary<string,HttpClient> Clients=[];
    private static readonly LinkedList<string> Order=new();
    public static HttpClient For(string key)
    {
        lock(Gate)
        {
            if(Clients.TryGetValue(key,out var client)){Order.Remove(key);Order.AddLast(key);return client;}
            client=new HttpClient(SourceHttp.CreateSandboxHandler(new CookieContainer())){Timeout=Timeout.InfiniteTimeSpan};
            Clients[key]=client;Order.AddLast(key);
            while(Order.Count>32){var oldest=Order.First!.Value;Order.RemoveFirst();Clients.Remove(oldest);}
            return client;
        }
    }
}

public sealed class CheerioBridge
{
    private const int MaxDocuments=32,MaxSourceBytes=6*1024*1024,MaxLiveBytes=48*1024*1024,MaxElements=100_000;
    private static readonly HashSet<string> Blocks=["address","article","aside","blockquote","br","dd","div","dl","dt","fieldset","figcaption","figure","footer","form","h1","h2","h3","h4","h5","h6","header","hr","li","main","nav","ol","p","pre","section","table","tbody","td","tfoot","th","thead","tr","ul"];
    private readonly HtmlParser _parser=new();
    private readonly Dictionary<int,IDocument> _documents=[];
    private readonly List<int> _documentOrder=[];
    private readonly Dictionary<int,int> _documentBytes=[];
    private readonly Dictionary<int,IElement> _elements=[];
    private readonly Dictionary<int,int> _owners=[];
    private int _next=1,_oldestElement=1,_liveBytes;
    public bool HitLimit {get;private set;}
    public int Load(string html)
    {
        var bytes=Encoding.UTF8.GetByteCount(html);
        if(bytes>MaxSourceBytes){HitLimit=true;throw new JsRunException($"cheerio.load was given {bytes} bytes of HTML; Eclipse parses at most {MaxSourceBytes} bytes in one document.",JsFailure.Limit);}
        var handle=_next++;_documents[handle]=_parser.ParseDocument(html);_documentOrder.Add(handle);_documentBytes[handle]=bytes*8;_liveBytes+=bytes*8;
        while(_documentOrder.Count>1&&(_documentOrder.Count>MaxDocuments||_liveBytes>MaxLiveBytes))
        {
            var oldest=_documentOrder[0];_documentOrder.RemoveAt(0);_documents.Remove(oldest);_liveBytes-=_documentBytes.Remove(oldest,out var size)?size:0;
            foreach(var element in _owners.Where(p=>p.Value==oldest).Select(p=>p.Key).ToArray()){_elements.Remove(element);_owners.Remove(element);}
        }
        return handle;
    }
    private int Register(IElement element,int owner)
    {
        var handle=_next++;_elements[handle]=element;_owners[handle]=owner;
        while(_elements.Count>MaxElements&&_oldestElement<_next){var h=_oldestElement++;if(_elements.Remove(h))_owners.Remove(h);}
        return handle;
    }
    private void RequireLive(int handle)
    {
        if(handle>0&&handle<_next&&!_documents.ContainsKey(handle)&&!_elements.ContainsKey(handle)){HitLimit=true;throw new JsRunException($"This cheerio node is no longer available: Eclipse keeps at most {MaxDocuments} loaded documents and {MaxElements} selected nodes per run.",JsFailure.Limit);}
    }
    private int Owner(int handle)=>_owners.TryGetValue(handle,out var owner)?owner:handle;
    public int[] Select(int handle,string selector)
    {
        try
        {
            if(_documents.TryGetValue(handle,out var document))return document.QuerySelectorAll(selector).Select(e=>Register(e,handle)).ToArray();
            if(_elements.TryGetValue(handle,out var element)){var owner=Owner(handle);return element.QuerySelectorAll(selector).Select(e=>Register(e,owner)).ToArray();}
        }
        catch(Exception error) when(error is DomException or ArgumentException or InvalidOperationException){return [];}
        RequireLive(handle);return [];
    }
    public string Text(int handle)
    {
        if(_documents.TryGetValue(handle,out var document))return Normalize(document.DocumentElement);
        if(_elements.TryGetValue(handle,out var element))return Normalize(element);
        RequireLive(handle);return "";
    }
    private static string Normalize(INode? root)
    {
        if(root is null)return "";
        var builder=new StringBuilder();var pendingSpace=false;
        void Walk(INode node)
        {
            if(node is IText text)
            {
                foreach(var c in text.Data){if(char.IsWhiteSpace(c)){pendingSpace=builder.Length>0;continue;}if(pendingSpace){builder.Append(' ');pendingSpace=false;}builder.Append(c);}
                return;
            }
            if(node is IElement element&&element.LocalName is "script" or "style" or "template")return;
            var block=node is IElement e&&Blocks.Contains(e.LocalName);
            if(block&&builder.Length>0)pendingSpace=true;
            foreach(var child in node.ChildNodes)Walk(child);
            if(block&&builder.Length>0)pendingSpace=true;
        }
        Walk(root);
        return builder.ToString();
    }
    public string Html(int handle)
    {
        if(_documents.TryGetValue(handle,out var document))return document.DocumentElement?.OuterHtml??"";
        if(_elements.TryGetValue(handle,out var element))return element.OuterHtml;
        RequireLive(handle);return "";
    }
    public string InnerHtml(int handle)
    {
        if(_documents.TryGetValue(handle,out var document))return document.DocumentElement?.OuterHtml??"";
        if(_elements.TryGetValue(handle,out var element))return element.InnerHtml;
        RequireLive(handle);return "";
    }
    public string? Attr(int handle,string name){if(_elements.TryGetValue(handle,out var element))return element.GetAttribute(name)??"";RequireLive(handle);return null;}
    public int Next(int handle){if(_elements.TryGetValue(handle,out var element))return element.NextElementSibling is {} sibling?Register(sibling,Owner(handle)):0;RequireLive(handle);return 0;}
    public int Previous(int handle){if(_elements.TryGetValue(handle,out var element))return element.PreviousElementSibling is {} sibling?Register(sibling,Owner(handle)):0;RequireLive(handle);return 0;}
    public int Parent(int handle){if(_elements.TryGetValue(handle,out var element))return element.ParentElement is {} parent?Register(parent,Owner(handle)):0;RequireLive(handle);return 0;}
    public int[] Children(int handle)
    {
        if(_documents.TryGetValue(handle,out var document))return document.Children.Select(e=>Register(e,handle)).ToArray();
        if(_elements.TryGetValue(handle,out var element)){var owner=Owner(handle);return element.Children.Select(e=>Register(e,owner)).ToArray();}
        RequireLive(handle);return [];
    }
    public bool Matches(int handle,string selector)
    {
        if(!_elements.TryGetValue(handle,out var element)){RequireLive(handle);return false;}
        try{return element.Matches(selector);}catch(Exception error) when(error is DomException or ArgumentException or InvalidOperationException){return false;}
    }
}

public static class JsCrypto
{
    private const int MaxHexInput=12*1024*1024;
    public static string Hex(ReadOnlySpan<byte> data){if(data.Length>MaxHexInput)throw new JsRunException($"Refusing to hex-encode {data.Length} bytes: the limit is {MaxHexInput} bytes.");return Convert.ToHexString(data).ToLowerInvariant();}
    public static byte[] FromHex(string hex)
    {
        var filtered=new string(hex.ToLowerInvariant().Where(c=>c is >='0' and <='9' or >='a' and <='f').ToArray());
        if(filtered.Length%2==1)filtered="0"+filtered;
        return Convert.FromHexString(filtered);
    }
    private static HashAlgorithmName Name(string name)=>name.ToUpperInvariant() switch{"MD5"=>HashAlgorithmName.MD5,"SHA1"=>HashAlgorithmName.SHA1,"SHA384"=>HashAlgorithmName.SHA384,"SHA512"=>HashAlgorithmName.SHA512,_=>HashAlgorithmName.SHA256};
    private static byte[] Digest(HashAlgorithmName name,byte[] data)=>name.Name switch{"MD5"=>MD5.HashData(data),"SHA1"=>SHA1.HashData(data),"SHA384"=>SHA384.HashData(data),"SHA512"=>SHA512.HashData(data),_=>SHA256.HashData(data)};
    private static byte[] Mac(HashAlgorithmName name,byte[] key,byte[] data)=>name.Name switch{"MD5"=>HMACMD5.HashData(key,data),"SHA1"=>HMACSHA1.HashData(key,data),"SHA384"=>HMACSHA384.HashData(key,data),"SHA512"=>HMACSHA512.HashData(key,data),_=>HMACSHA256.HashData(key,data)};
    public static string Hash(string algorithm,string value)
    {
        var data=Encoding.UTF8.GetBytes(value);
        return algorithm.ToUpperInvariant() switch{"MD5"=>Hex(MD5.HashData(data)),"SHA1"=>Hex(SHA1.HashData(data)),"SHA512"=>Hex(SHA512.HashData(data)),"HEX"=>Hex(data),_=>Hex(SHA256.HashData(data))};
    }
    public static string Hmac(string algorithm,string value,string key)
    {
        var name=algorithm.ToUpperInvariant() is "MD5" or "SHA1" or "SHA512"?Name(algorithm):HashAlgorithmName.SHA256;
        return Hex(Mac(name,Encoding.UTF8.GetBytes(key),Encoding.UTF8.GetBytes(value)));
    }
    public static string DigestRaw(string name,string dataHex)=>Hex(Digest(Name(name),FromHex(dataHex)));
    public static string HmacRaw(string name,string keyHex,string dataHex)=>Hex(Mac(Name(name),FromHex(keyHex),FromHex(dataHex)));
    public static string Pbkdf2(string passHex,string saltHex,int iterations,int keyBits,string hash)
    {
        var length=Math.Max(1,keyBits/8);
        if(length>1024)throw new JsRunException($"PBKDF2 derives at most 1024 bytes; {length} were requested.");
        if(iterations>1_000_000)throw new JsRunException($"PBKDF2 runs at most 1000000 iterations; {iterations} were requested.");
        var name=hash.ToUpperInvariant() switch{"SHA1" or "MD5"=>HashAlgorithmName.SHA1,"SHA384"=>HashAlgorithmName.SHA384,"SHA512"=>HashAlgorithmName.SHA512,_=>HashAlgorithmName.SHA256};
        return Hex(Rfc2898DeriveBytes.Pbkdf2(FromHex(passHex),FromHex(saltHex),Math.Max(1,iterations),name,length));
    }
    public static string Random(int count){count=Math.Clamp(count,0,65536);return count==0?"":Hex(RandomNumberGenerator.GetBytes(count));}
    public static string Cipher(bool encrypt,string algorithmMode,string keyHex,string ivHex,string dataHex)
    {
        var noPadding=algorithmMode.EndsWith("-NoPadding");var baseMode=noPadding?algorithmMode[..^"-NoPadding".Length]:algorithmMode;
        var parts=baseMode.ToUpperInvariant().Split('-');var algo=parts[0];var mode=parts.Length>1?parts[^1]:"CBC";
        var key=FromHex(keyHex);var iv=FromHex(ivHex);var input=FromHex(dataHex);
        try
        {
            if(algo=="AES"&&mode=="GCM")
            {
                using var gcm=new AesGcm(key,16);
                if(encrypt){var cipher=new byte[input.Length];var tag=new byte[16];gcm.Encrypt(iv,input,cipher,tag);return Hex([..cipher,..tag]);}
                if(input.Length<16)throw new JsRunException("AES-GCM decryption needs the 16-byte authentication tag appended to the ciphertext.");
                var plain=new byte[input.Length-16];gcm.Decrypt(iv,input.AsSpan(0,input.Length-16),input.AsSpan(input.Length-16),plain);return Hex(plain);
            }
            using SymmetricAlgorithm algorithm=algo is "DES3" or "3DES"?TripleDES.Create():Aes.Create();
            algorithm.Key=key;var padding=noPadding?PaddingMode.None:PaddingMode.PKCS7;var block=algorithm.BlockSize/8;
            if(mode=="ECB")return Hex(encrypt?algorithm.EncryptEcb(input,padding):algorithm.DecryptEcb(input,padding));
            var vector=new byte[block];iv.AsSpan(0,Math.Min(iv.Length,block)).CopyTo(vector);
            return Hex(encrypt?algorithm.EncryptCbc(input,vector,padding):algorithm.DecryptCbc(input,vector,padding));
        }
        catch(CryptographicException error){throw new JsRunException($"{algo}-{mode} {(encrypt?"encryption":"decryption")} failed. Check the key length ({key.Length} bytes) and IV length ({iv.Length} bytes). {error.Message}");}
        catch(ArgumentException){throw new JsRunException($"{algo}-{mode} {(encrypt?"encryption":"decryption")} failed. Check the key length ({key.Length} bytes) and IV length ({iv.Length} bytes).");}
    }
    public static Dictionary<string,JsValue> ParseUrl(string value,string? baseUrl)
    {
        Uri? uri=null;
        if(baseUrl is {Length:>0}&&Uri.TryCreate(baseUrl,UriKind.Absolute,out var root))Uri.TryCreate(root,value,out uri);
        else Uri.TryCreate(value,UriKind.Absolute,out uri);
        if(uri is null||!uri.IsAbsoluteUri)return new(){["href"]=value};
        var port=uri.IsDefaultPort?"":uri.Port.ToString();var host=port.Length==0?uri.Host:$"{uri.Host}:{port}";
        return new(){["href"]=uri.AbsoluteUri,["protocol"]=uri.Scheme+":",["host"]=host,["hostname"]=uri.Host,["port"]=port,["pathname"]=uri.AbsolutePath.Length==0?"/":uri.AbsolutePath,["search"]=uri.Query,["hash"]=uri.Fragment,["origin"]=$"{uri.Scheme}://{host}"};
    }
}
