using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using static Eclipse.Windows.Services.JsonValue;
namespace Eclipse.Windows.Services;

public enum TrackerKind { Trakt, AniList, MAL }
public sealed record TrackerSession(TrackerKind Service, string UserId, string Name, string AccessToken, string? RefreshToken, DateTimeOffset Expires, long Generation);
public sealed class TrackerException(string message) : Exception(message);
public sealed record TrackerResponse(JsonElement Data, int? Pages = null);

// Authenticated responses never enter the public metadata cache. Redirects are disabled before any bearer is sent.
public sealed class TrackerTransport
{
    public static TrackerTransport Shared { get; } = new();
    private readonly HttpClient _http = new(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(25) };
    private readonly SemaphoreSlim _slots = new(2, 2);
    private readonly Dictionary<string, DateTimeOffset> _cooldowns = [];
    private readonly object _cooldownLock = new();
    private DateTimeOffset _nextAniListRequest;
    public async Task<TrackerResponse> SendAsync(TrackerKind kind, string url, HttpMethod method, string? token, CancellationToken ct, object? json = null, IEnumerable<KeyValuePair<string, string>>? form = null)
    {
        var uri = new Uri(url); var host = kind switch { TrackerKind.Trakt => "api.trakt.tv", TrackerKind.AniList => "graphql.anilist.co", _ => "api.myanimelist.net" };
        var tokenEndpoint = kind == TrackerKind.MAL && uri.Host == "myanimelist.net" && uri.AbsolutePath == "/v1/oauth2/token" && token is null;
        if (uri.Scheme != "https" || uri.Host != host && !tokenEndpoint || uri.UserInfo.Length > 0 || !uri.IsDefaultPort) throw new TrackerException("The tracker returned an invalid request address.");
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(TimeSpan.FromSeconds(25)); var caller = ct; ct = deadline.Token;
        var entered = false;
        try
        {
            await _slots.WaitAsync(ct); entered = true;
            lock (_cooldownLock) if (_cooldowns.TryGetValue(host, out var until) && until > DateTimeOffset.UtcNow) throw new TrackerException($"{kind} asked Eclipse to wait before retrying.");
            if(kind==TrackerKind.AniList){TimeSpan pause;lock(_cooldownLock){var now=DateTimeOffset.UtcNow;var start=_nextAniListRequest>now?_nextAniListRequest:now;pause=start-now;_nextAniListRequest=start.AddSeconds(2);}if(pause>TimeSpan.Zero)await Task.Delay(pause,ct);}
            lock(_cooldownLock)if(_cooldowns.TryGetValue(host,out var retryAfter)&&retryAfter>DateTimeOffset.UtcNow)throw new TrackerException($"{kind} asked Eclipse to wait before retrying.");
            using var request = new HttpRequestMessage(method, uri); request.Headers.UserAgent.ParseAdd("Eclipse-Windows/0.1");
            if (token is not null) request.Headers.Authorization = new("Bearer", token);
            if (kind == TrackerKind.Trakt) { request.Headers.Add("trakt-api-version", "2"); request.Headers.Add("trakt-api-key", LocalCredentials.Read("TraktClientId")); }
            if (json is not null) request.Content = new StringContent(JsonSerializer.Serialize(json), Encoding.UTF8, "application/json");
            if (form is not null) request.Content = new FormUrlEncodedContent(form);
            using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
            if (response.StatusCode == HttpStatusCode.TooManyRequests) { var delay = response.Headers.RetryAfter?.Delta ?? (response.Headers.RetryAfter?.Date - DateTimeOffset.UtcNow) ?? TimeSpan.FromSeconds(60); lock (_cooldownLock) _cooldowns[host] = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(Math.Clamp(delay.TotalSeconds, 1, 600)); throw new TrackerException($"{kind} rate limit reached. Try again later."); }
            if (response.StatusCode == HttpStatusCode.Unauthorized) throw new TrackerUnauthorizedException();
            if (!response.IsSuccessStatusCode) throw new TrackerException($"{kind} rejected the request ({(int)response.StatusCode}). No account data was changed locally.");
            if (response.Content.Headers.ContentLength is > 4 * 1024 * 1024) throw new TrackerException("Tracker response exceeds the size limit.");
            using var stream = await response.Content.ReadAsStreamAsync(ct); using var memory = new MemoryStream(); var buffer = new byte[16384]; int read;
            while ((read = await stream.ReadAsync(buffer, ct)) > 0) { if (memory.Length + read > 4 * 1024 * 1024) throw new TrackerException("Tracker response exceeds the size limit."); memory.Write(buffer, 0, read); }
            var data = memory.Length == 0 ? JsonDocument.Parse("{}").RootElement.Clone() : JsonDocument.Parse(memory.ToArray()).RootElement.Clone();
            return new(data, response.Headers.TryGetValues("X-Pagination-Page-Count", out var pages) && int.TryParse(pages.FirstOrDefault(), out var count) ? count : null);
        }
        catch (HttpRequestException) { throw new TrackerException($"{kind} could not be reached. Your connection has been retained."); }
        catch (IOException) { throw new TrackerException($"{kind} response was interrupted. Refresh to check its current state."); }
        catch (JsonException) { throw new TrackerException($"{kind} returned unreadable data."); }
        catch (OperationCanceledException) when (!caller.IsCancellationRequested) { throw new TrackerException($"{kind} did not respond in time."); }
        finally { if (entered) _slots.Release(); }
    }
}
public sealed class TrackerUnauthorizedException : Exception;

public sealed class TrackerAccounts
{
    public static TrackerAccounts Shared { get; } = new();
    private readonly Dictionary<TrackerKind, TrackerSession> _sessions = [];
    private readonly Dictionary<TrackerKind, SemaphoreSlim> _refresh = Enum.GetValues<TrackerKind>().ToDictionary(k => k, _ => new SemaphoreSlim(1, 1));
    private long _generation;
    private PendingAuth? _pending;
    private sealed record PendingAuth(TrackerKind Kind, string State, string Verifier, string Redirect, long Generation, TaskCompletionSource<Uri> Completion) { public DateTimeOffset Expires { get; init; } = DateTimeOffset.UtcNow.AddMinutes(5); }
    public event EventHandler? Changed;
    public TrackerAccounts()
    {
        foreach (var kind in Enum.GetValues<TrackerKind>()) try { var stored = TrackerCredentialStore.Read(kind); if (stored is not null && stored.Service == kind && stored.UserId is { Length: > 0 and < 256 } && (kind == TrackerKind.Trakt || int.TryParse(stored.UserId, out var userId) && userId > 0) && stored.Name is { Length: > 0 and < 256 } && stored.AccessToken is { Length: > 0 and <= 8192 } && stored.Expires > new DateTimeOffset(2000, 1, 1, 0, 0, 0, TimeSpan.Zero)) _sessions[kind] = stored with { Generation = ++_generation }; } catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { }
    }
    public TrackerSession? Session(TrackerKind kind) => _sessions.GetValueOrDefault(kind);
    public bool IsCurrent(TrackerSession s) => _sessions.TryGetValue(s.Service, out var current) && current.Generation == s.Generation && current.UserId == s.UserId;
    public void AssertCurrent(TrackerSession s) { if (!IsCurrent(s)) throw new TrackerException("The connected account changed. Reopen the library before continuing."); }
    private void Store(TrackerSession session)
    {
        // Commit rotated credentials before allowing the next request to use them.
        TrackerCredentialStore.Save(session);
        _sessions[session.Service] = session; Changed?.Invoke(this, EventArgs.Empty);
    }
    public void Disconnect(TrackerKind kind)
    {
        if (_pending?.Kind == kind) { _pending.Completion.TrySetCanceled(); _pending = null; }
        TrackerCredentialStore.Delete(kind);
        _sessions.Remove(kind); ++_generation; Changed?.Invoke(this, EventArgs.Empty);
    }
    public bool Complete(Uri uri)
    {
        var pending = _pending; if (pending is null || pending.Expires <= DateTimeOffset.UtcNow || uri.Scheme != "luna" || uri.Host != $"{pending.Kind.ToString().ToLowerInvariant()}-callback" || uri.AbsolutePath is not ("" or "/") || uri.UserInfo.Length > 0 || !uri.IsDefaultPort || uri.OriginalString.Length > 16384 || pending.Kind != TrackerKind.AniList && uri.Fragment.Length > 0) return false;
        var values = Parameters(uri.Query + "&" + uri.Fragment.TrimStart('#')); if (values.GetValueOrDefault("state") != pending.State) return false;
        _pending = null; return pending.Completion.TrySetResult(uri);
    }
    private static Dictionary<string, string> Parameters(string query)
    {
        var result = new Dictionary<string, string>(); foreach (var part in query.TrimStart('?', '#', '&').Split('&', StringSplitOptions.RemoveEmptyEntries)) { var pair = part.Split('=', 2); var key = Uri.UnescapeDataString(pair[0]); if (result.ContainsKey(key)) return []; result[key] = pair.Length == 2 ? Uri.UnescapeDataString(pair[1]) : ""; }
        return result;
    }
    private static string Random() => Convert.ToBase64String(RandomNumberGenerator.GetBytes(48)).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    private static string Query(IEnumerable<KeyValuePair<string, string>> values) => string.Join('&', values.Select(p => $"{Uri.EscapeDataString(p.Key)}={Uri.EscapeDataString(p.Value)}"));
    private static string Client(TrackerKind kind) => LocalCredentials.Read(kind switch { TrackerKind.AniList => "AniListClientId", TrackerKind.Trakt => "TraktClientId", _ => "MalClientId" });
    public async Task ConnectAsync(TrackerKind kind, CancellationToken ct)
    {
        if (Client(kind).Length == 0) throw new TrackerException($"A {kind} public client ID is required in local configuration.");
        _pending?.Completion.TrySetCanceled(); var generation = ++_generation; var redirect = LocalCredentials.Read(kind == TrackerKind.MAL ? "MalRedirectUri" : $"{kind}RedirectUri"); if (redirect.Length == 0) redirect = $"luna://{kind.ToString().ToLowerInvariant()}-callback";
        if (!Uri.TryCreate(redirect, UriKind.Absolute, out var configured) || configured.Scheme != "luna" || configured.Host != $"{kind.ToString().ToLowerInvariant()}-callback" || configured.AbsolutePath is not ("" or "/")) throw new TrackerException("Configure the registered Eclipse callback URI for this tracker.");
        var pending = new PendingAuth(kind, Random(), Random(), redirect, generation, new(TaskCreationOptions.RunContinuationsAsynchronously)); _pending = pending;
        var values = new Dictionary<string, string> { { "client_id", Client(kind) }, { "redirect_uri", redirect }, { "response_type", kind == TrackerKind.AniList ? "token" : "code" }, { "state", pending.State } };
        if (kind != TrackerKind.AniList) { values["code_challenge"] = kind == TrackerKind.MAL ? pending.Verifier : Convert.ToBase64String(SHA256.HashData(Encoding.ASCII.GetBytes(pending.Verifier))).TrimEnd('=').Replace('+', '-').Replace('/', '_'); values["code_challenge_method"] = kind == TrackerKind.MAL ? "plain" : "S256"; }
        var endpoint = kind switch { TrackerKind.AniList => "https://anilist.co/api/v2/oauth/authorize", TrackerKind.MAL => "https://myanimelist.net/v1/oauth2/authorize", _ => "https://auth.trakt.tv/oauth/authorize" };
        try
        {
            if (!await global::Windows.System.Launcher.LaunchUriAsync(new(endpoint + "?" + Query(values)))) throw new TrackerException("Windows could not open the sign-in browser.");
            var callback = await pending.Completion.Task.WaitAsync(TimeSpan.FromMinutes(5), ct); var result = Parameters(callback.Query + "&" + callback.Fragment.TrimStart('#'));
            if (result.ContainsKey("error")) throw new TrackerException($"{kind} sign-in was cancelled or denied.");
            string access; string? refresh = null; double expires = 31536000;
            if (kind == TrackerKind.AniList) { var fragment = Parameters(callback.Fragment); access = fragment.GetValueOrDefault("access_token", ""); if (fragment.GetValueOrDefault("state") != pending.State) throw new TrackerException("The tracker returned an invalid sign-in response."); }
            else
            {
                var code = result.GetValueOrDefault("code", ""); if (code.Length == 0) throw new TrackerException("The sign-in callback did not contain a code.");
                var fields = new Dictionary<string, string> { { "client_id", Client(kind) }, { "grant_type", "authorization_code" }, { "code", code }, { "redirect_uri", redirect }, { "code_verifier", pending.Verifier } };
                var response = await TokenAsync(kind, fields, ct); access = Text(response, "access_token"); refresh = Text(response, "refresh_token"); expires = Double(response, "expires_in");
            }
            if (access.Length is 0 or > 8192 || refresh?.Length is > 8192) throw new TrackerException("The tracker did not issue usable credentials.");
            var identity = await IdentityAsync(kind, access, ct); if (_generation != generation) throw new TrackerException("This sign-in attempt was replaced. Try connecting again.");
            Store(new(kind, identity.Id, identity.Name, access, refresh, DateTimeOffset.UtcNow + TimeSpan.FromSeconds(Math.Clamp(expires, 60, 31536000)), generation));
        }
        catch (TimeoutException) { throw new TrackerException("Sign-in timed out. Start again when you are ready."); }
        finally { if (ReferenceEquals(_pending, pending)) _pending = null; }
    }
    private static async Task<JsonElement> TokenAsync(TrackerKind kind, Dictionary<string, string> fields, CancellationToken ct) => (await TrackerTransport.Shared.SendAsync(kind, kind == TrackerKind.Trakt ? "https://api.trakt.tv/oauth/token" : "https://myanimelist.net/v1/oauth2/token", HttpMethod.Post, null, ct, kind == TrackerKind.Trakt ? fields : null, kind == TrackerKind.MAL ? fields : null)).Data;
    private static async Task<(string Id, string Name)> IdentityAsync(TrackerKind kind, string token, CancellationToken ct)
    {
        var response = (await TrackerTransport.Shared.SendAsync(kind, kind switch { TrackerKind.Trakt => "https://api.trakt.tv/users/settings", TrackerKind.MAL => "https://api.myanimelist.net/v2/users/@me", _ => "https://graphql.anilist.co" }, kind == TrackerKind.AniList ? HttpMethod.Post : HttpMethod.Get, token, ct, kind == TrackerKind.AniList ? new { query = "query { Viewer { id name } }" } : null)).Data;
        var user = kind switch { TrackerKind.Trakt => Child(response, "user"), TrackerKind.AniList => Child(Child(response, "data"), "Viewer"), _ => response }; var id = kind == TrackerKind.Trakt ? Text(Child(user, "ids"), "slug") : Positive(user, "id")?.ToString(); var name = Text(user, kind == TrackerKind.Trakt ? "username" : "name");
        if (string.IsNullOrWhiteSpace(id) || string.IsNullOrWhiteSpace(name)) throw new TrackerException("The tracker did not confirm the signed-in account."); return (id, name);
    }
    public async Task<TrackerResponse> RequestAsync(TrackerSession session, string path, HttpMethod method, CancellationToken ct, object? json = null, IEnumerable<KeyValuePair<string, string>>? form = null, bool retryUnauthorized = true)
    {
        AssertCurrent(session); var current = Session(session.Service)!;
        async Task<TrackerResponse> Send() => await TrackerTransport.Shared.SendAsync(current.Service, (current.Service switch { TrackerKind.Trakt => "https://api.trakt.tv/", TrackerKind.MAL => "https://api.myanimelist.net/", _ => "https://graphql.anilist.co" }) + path.TrimStart('/'), method, current.AccessToken, ct, json, form);
        try { var response = await Send(); AssertCurrent(session); return response; }
        catch (TrackerUnauthorizedException)
        {
            if (!retryUnauthorized || current.Service == TrackerKind.AniList) throw new TrackerException("Reconnect this tracker to continue.");
            var gate = _refresh[current.Service]; await gate.WaitAsync(ct);
            try { AssertCurrent(session); if (Session(current.Service)!.AccessToken == current.AccessToken) { if (string.IsNullOrEmpty(current.RefreshToken)) throw new TrackerException("Reconnect this tracker to continue."); var data = await TokenAsync(current.Service, new() { { "client_id", Client(current.Service) }, { "grant_type", "refresh_token" }, { "refresh_token", current.RefreshToken } }, ct); AssertCurrent(session); var access = Text(data, "access_token"); var refresh = Text(data, "refresh_token"); if (access.Length == 0 || refresh.Length == 0) throw new TrackerException("The tracker did not renew this session. Reconnect to continue."); Store(current with { AccessToken = access, RefreshToken = refresh, Expires = DateTimeOffset.UtcNow.AddSeconds(Math.Clamp(Double(data, "expires_in"), 60, 31536000)) }); } }
            catch(Exception e) when(e is IOException or UnauthorizedAccessException)
            {
                // The provider may already have consumed a single-use refresh token.
                // Never issue another request with the superseded in-memory session.
                _sessions.Remove(current.Service);++_generation;Changed?.Invoke(this,EventArgs.Empty);
                throw new TrackerException("Windows could not save the renewed credentials. Reconnect this tracker before continuing.");
            }
            finally { gate.Release(); }
            current = Session(session.Service)!; try { var response = await Send(); AssertCurrent(session); return response; } catch (TrackerUnauthorizedException) { throw new TrackerException("Reconnect this tracker to continue."); }
        }
    }
}
