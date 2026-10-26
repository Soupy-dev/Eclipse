using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace Eclipse.Windows.Services;

public class SourceException(string message,int status=0) : Exception(message) { public int Status {get;}=status; }

public static class SourceHttp
{
    public const string DesktopUserAgent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36";
    private static readonly string[] TrackingHosts=["google-analytics.com","googletagmanager.com","doubleclick.net","googlesyndication.com","facebook.net","facebook.com","mixpanel.com","segment.io","segment.com","amplitude.com","appsflyer.com","branch.io","hotjar.com","clarity.ms","scorecardresearch.com","quantserve.com","newrelic.com","sentry.io","datadoghq-browser-agent.com"];
    public static HttpClient Addons {get;}=new(new SocketsHttpHandler{AutomaticDecompression=DecompressionMethods.All,MaxAutomaticRedirections=5,ConnectTimeout=TimeSpan.FromSeconds(10),PooledConnectionLifetime=TimeSpan.FromMinutes(5),MaxConnectionsPerServer=6,UseCookies=false}){Timeout=Timeout.InfiniteTimeSpan};
    public static HttpClient Sandboxed {get;}=new(CreateSandboxHandler(null,true)){Timeout=Timeout.InfiniteTimeSpan};

    public static SocketsHttpHandler CreateSandboxHandler(CookieContainer? cookies,bool redirects=false)=>new()
    {
        AutomaticDecompression=DecompressionMethods.All,AllowAutoRedirect=redirects,MaxAutomaticRedirections=5,UseProxy=false,UseCookies=cookies is not null,CookieContainer=cookies??new(),
        ConnectTimeout=TimeSpan.FromSeconds(10),PooledConnectionLifetime=TimeSpan.FromMinutes(2),PooledConnectionIdleTimeout=TimeSpan.FromSeconds(30),MaxConnectionsPerServer=8,ConnectCallback=PublicConnectAsync
    };
    public static bool IsTracking(Uri uri){var host=uri.Host.ToLowerInvariant();return TrackingHosts.Any(t=>host==t||host.EndsWith("."+t));}
    public static string Redacted(Uri uri)=>uri.IsDefaultPort?$"{uri.Scheme}://{uri.Host}":$"{uri.Scheme}://{uri.Host}:{uri.Port}";
    public static Uri? HttpUri(string? value,bool httpsOnly=false)
    {
        var trimmed=value?.Trim();
        if(trimmed is not {Length:>0 and <=8192}||trimmed.Any(char.IsControl)||!Uri.TryCreate(trimmed,UriKind.Absolute,out var uri))return null;
        if(uri.Scheme!="https"&&(httpsOnly||uri.Scheme!="http")||uri.UserInfo.Length>0||uri.Host.Length==0)return null;
        return uri;
    }

    private static async ValueTask<Stream> PublicConnectAsync(SocketsHttpConnectionContext context,CancellationToken token)
    {
        var host=context.DnsEndPoint.Host;
        var addresses=IPAddress.TryParse(host.Trim('[',']'),out var literal)?[literal]:await Dns.GetHostAddressesAsync(host,token).ConfigureAwait(false);
        var allowed=addresses.Where(IsPublic).ToArray();
        if(allowed.Length==0)throw new HttpRequestException(addresses.Length==0?"The host did not resolve.":"Requests to local or private network addresses are blocked for plugins.");
        Exception? last=null;
        foreach(var address in allowed)
        {
            var socket=new Socket(address.AddressFamily,SocketType.Stream,ProtocolType.Tcp){NoDelay=true};
            try{await socket.ConnectAsync(new IPEndPoint(address,context.DnsEndPoint.Port),token).ConfigureAwait(false);return new NetworkStream(socket,true);}
            catch(Exception error) when(error is SocketException or IOException){socket.Dispose();last=error;}
            catch{socket.Dispose();throw;}
        }
        throw new HttpRequestException("Could not connect to the host.",last);
    }
    public static bool IsPublic(IPAddress address)
    {
        if(address.IsIPv4MappedToIPv6)address=address.MapToIPv4();
        if(IPAddress.IsLoopback(address)||address.Equals(IPAddress.Any)||address.Equals(IPAddress.IPv6Any)||address.Equals(IPAddress.None))return false;
        if(address.AddressFamily==AddressFamily.InterNetwork)
        {
            var b=address.GetAddressBytes();
            return !(b[0] is 0 or 10 or 127||b[0]>=224||b[0]==100&&b[1] is >=64 and <=127||b[0]==169&&b[1]==254||b[0]==172&&b[1] is >=16 and <=31||b[0]==192&&b[1]==168||b[0]==192&&b[1]==0&&b[2] is 0 or 2||b[0]==198&&b[1] is 18 or 19||b[0]==198&&b[1]==51&&b[2]==100||b[0]==203&&b[1]==0&&b[2]==113);
        }
        if(address.AddressFamily!=AddressFamily.InterNetworkV6)return false;
        var v6=address.GetAddressBytes();
        if(address.IsIPv6LinkLocal||address.IsIPv6SiteLocal||address.IsIPv6Multicast||address.IsIPv6UniqueLocal||address.IsIPv6Teredo)return false;
        if(v6[0]==0x20&&v6[1]==0x01&&v6[2]==0x0d&&v6[3]==0xb8)return false;
        if(v6[0]==0x00&&v6[1]==0x64&&v6[2]==0xff&&v6[3]==0x9b)return IsPublic(new IPAddress(v6[12..16]));
        if(v6[0]==0x20&&v6[1]==0x02)return IsPublic(new IPAddress(v6[2..6]));
        return (v6[0]&0xe0)==0x20;
    }

    public static async Task<byte[]> ReadAsync(HttpResponseMessage response,int limit,CancellationToken token)
    {
        if(response.Content.Headers.ContentLength>limit)throw new SourceException("The response exceeded the size limit.");
        await using var input=await response.Content.ReadAsStreamAsync(token).ConfigureAwait(false);
        using var output=new MemoryStream();var buffer=new byte[16384];int count;
        while((count=await input.ReadAsync(buffer,token).ConfigureAwait(false))>0)
        {
            if(output.Length+count>limit)throw new SourceException("The response exceeded the size limit.");
            output.Write(buffer,0,count);
        }
        return output.ToArray();
    }
    public static async Task<string> TextAsync(HttpClient client,Uri uri,int limit,TimeSpan timeout,CancellationToken token)
    {
        using var deadline=CancellationTokenSource.CreateLinkedTokenSource(token);deadline.CancelAfter(timeout);
        try
        {
            using var request=new HttpRequestMessage(HttpMethod.Get,uri);request.Headers.UserAgent.ParseAdd("EclipseWindows/0.1");
            using var response=await client.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,deadline.Token).ConfigureAwait(false);
            if(!response.IsSuccessStatusCode)throw new SourceException($"{uri.Host} returned HTTP {(int)response.StatusCode}.",(int)response.StatusCode);
            return Encoding.UTF8.GetString(await ReadAsync(response,limit,deadline.Token).ConfigureAwait(false));
        }
        catch(OperationCanceledException) when(!token.IsCancellationRequested){throw new SourceException($"{uri.Host} took too long to respond.");}
        catch(HttpRequestException){throw new SourceException($"Could not connect to {uri.Host}.");}
        catch(IOException){throw new SourceException($"The connection to {uri.Host} was interrupted.");}
    }
}
