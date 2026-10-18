using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Security.Cryptography;

namespace Eclipse.Windows.Services;

public sealed class ProviderException(string message, int status=0) : Exception(message) { public int Status { get; }=status; }
public interface IProviderJson
{
    Task<JsonElement> FetchAsync(string url,CancellationToken token,string? body=null,Dictionary<string,string>? headers=null,bool refresh=false);
}
// Metadata only; no decoded bitmaps, whole mapping databases, or unbounded task queues.
public sealed class ProviderJson(HttpMessageHandler? handler=null) : IProviderJson
{
    public static ProviderJson Shared { get; }=new();
    private readonly HttpClient _client=new(handler ?? new SocketsHttpHandler { MaxConnectionsPerServer=2,ConnectTimeout=TimeSpan.FromSeconds(8),PooledConnectionLifetime=TimeSpan.FromMinutes(10) }) { Timeout=Timeout.InfiniteTimeSpan };
    private readonly SemaphoreSlim _slots=new(2);
    private readonly object _gate=new();
    private readonly Dictionary<string,(JsonElement json,DateTime expiry,DateTime used,int bytes)> _cache=[];
    private readonly Dictionary<string,DateTime> _cooldown=[];
    private readonly Dictionary<string,DateTime> _nextRequest=[];
    private int _cacheBytes;
    public async Task<JsonElement> FetchAsync(string url,CancellationToken token,string? body=null,Dictionary<string,string>? headers=null,bool refresh=false)
    {
        var uri=new Uri(url);
        if(uri.Scheme!="https" || uri.UserInfo.Length>0) throw new ProviderException("The metadata address is invalid.");
        token.ThrowIfCancellationRequested();
        var key=url+":"+Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(body ?? "")));
        lock(_gate)
        {
            if(!refresh && _cache.TryGetValue(key,out var hit) && hit.expiry>DateTime.UtcNow)
            { _cache[key]=(hit.json,hit.expiry,DateTime.UtcNow,hit.bytes); return hit.json; }
            if(_cooldown.TryGetValue(uri.Host,out var until) && until>DateTime.UtcNow)
                throw new ProviderException($"{uri.Host} is rate limited. Try again after {until.ToLocalTime():t}.",429);
        }
        using var deadline=CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(TimeSpan.FromSeconds(20));
        var entered=false;
        try
        {
            await _slots.WaitAsync(deadline.Token).ConfigureAwait(false); entered=true;
            TimeSpan pause;
            lock(_gate)
            {
                if(_cooldown.TryGetValue(uri.Host,out var until) && until>DateTime.UtcNow)
                    throw new ProviderException($"{uri.Host} is rate limited. Try again after {until.ToLocalTime():t}.",429);
                var spacing=uri.Host switch {"graphql.anilist.co"=>2d,"animeschedule.net"=>.55,"api.tvmaze.com"=>.25,_=>0};
                var start=_nextRequest.GetValueOrDefault(uri.Host,DateTime.UtcNow);if(start<DateTime.UtcNow)start=DateTime.UtcNow;
                pause=start-DateTime.UtcNow;_nextRequest[uri.Host]=start.AddSeconds(spacing);
            }
            if(pause>TimeSpan.Zero)await Task.Delay(pause,deadline.Token).ConfigureAwait(false);
            lock(_gate)if(_cooldown.TryGetValue(uri.Host,out var limitedUntil)&&limitedUntil>DateTime.UtcNow)throw new ProviderException($"{uri.Host} is rate limited. Wait before retrying.",429);
            using var request=new HttpRequestMessage(body is null ? HttpMethod.Get : HttpMethod.Post,uri);
            request.Headers.UserAgent.ParseAdd("EclipseWindows/0.1");
            if(body is not null) request.Content=new StringContent(body,Encoding.UTF8,"application/json");
            if(headers is not null) foreach(var h in headers) request.Headers.TryAddWithoutValidation(h.Key,h.Value);
            using var response=await _client.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,deadline.Token).ConfigureAwait(false);
            if((int)response.StatusCode==429)
            {
                var delay=response.Headers.RetryAfter?.Delta ?? (response.Headers.RetryAfter?.Date-DateTimeOffset.UtcNow) ?? TimeSpan.FromSeconds(60);
                lock(_gate) _cooldown[uri.Host]=DateTime.UtcNow.AddSeconds(Math.Clamp(delay.TotalSeconds,1,600));
                throw new ProviderException($"{uri.Host} is busy. Wait before refreshing.",429);
            }
            if(!response.IsSuccessStatusCode) throw new ProviderException($"{uri.Host} could not load this metadata (HTTP {(int)response.StatusCode}).",(int)response.StatusCode);
            const int limit=2*1024*1024;
            if(response.Content.Headers.ContentLength>limit) throw new ProviderException("The metadata response exceeded the size limit.");
            await using var input=await response.Content.ReadAsStreamAsync(deadline.Token).ConfigureAwait(false);
            using var output=new MemoryStream();
            var bytes=new byte[16384]; int count;
            while((count=await input.ReadAsync(bytes,deadline.Token).ConfigureAwait(false))>0)
            { if(output.Length+count>limit) throw new ProviderException("The metadata response exceeded the size limit."); output.Write(bytes,0,count); }
            using var doc=JsonDocument.Parse(output.ToArray(),new JsonDocumentOptions { MaxDepth=64 });
            var json=doc.RootElement.Clone(); token.ThrowIfCancellationRequested();
            lock(_gate)
            {
                if(_cache.Remove(key,out var previous)) _cacheBytes-=previous.bytes;
                while(_cache.Count>=48 || _cacheBytes+output.Length>8*1024*1024)
                { var oldest=_cache.MinBy(x=>x.Value.used); _cacheBytes-=oldest.Value.bytes; _cache.Remove(oldest.Key); }
                _cache[key]=(json,DateTime.UtcNow.AddMinutes(10),DateTime.UtcNow,(int)output.Length); _cacheBytes+=(int)output.Length;
            }
            return json;
        }
        catch(OperationCanceledException) when(!token.IsCancellationRequested) { throw new ProviderException($"{uri.Host} took too long to respond."); }
        catch(HttpRequestException) { throw new ProviderException($"Could not connect to {uri.Host}."); }
        catch(IOException) { throw new ProviderException("The metadata connection was interrupted."); }
        catch(JsonException) { throw new ProviderException("The provider returned unreadable metadata."); }
        finally { if(entered) _slots.Release(); }
    }
}
public static class JsonValue
{
    public static JsonElement Child(JsonElement e,string key) => e.ValueKind==JsonValueKind.Object && e.TryGetProperty(key,out var v) ? v : default;
    public static string Text(JsonElement e,string key) => Child(e,key) is {ValueKind:JsonValueKind.String} v ? v.GetString() ?? "" : "";
    public static int Int(JsonElement e,string key) => Child(e,key).TryInt();
    public static int TryInt(this JsonElement e) => e.ValueKind==JsonValueKind.Number && e.TryGetInt32(out var n) ? n : 0;
    public static double Double(JsonElement e,string key) => Child(e,key) is {ValueKind:JsonValueKind.Number} v && v.TryGetDouble(out var n) && double.IsFinite(n) ? n : 0;
    public static bool Bool(JsonElement e,string key) => Child(e,key).ValueKind==JsonValueKind.True;
    public static IEnumerable<JsonElement> Items(JsonElement e) => e.ValueKind==JsonValueKind.Array ? e.EnumerateArray() : [];
    public static IEnumerable<JsonElement> Array(JsonElement e,string key) => Items(Child(e,key));
    public static int? Positive(JsonElement e,string key) => Int(e,key) is >0 and <=1_000_000_000 ? Int(e,key) : null;
}
