using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;
using Eclipse.Windows.Models;
using Windows.Storage;

namespace Eclipse.Windows.Services;

public sealed class TmdbException(string message) : Exception(message);

// Cache metadata, never UI objects. A single client and four request slots serve all pages.
public sealed class TmdbService
{
    public static TmdbService Shared { get; } = new();
    private readonly HttpClient _client;
    private readonly Func<string> _credentialProvider;
    private readonly SemaphoreSlim _requests = new(4);
    private readonly Dictionary<string, (JsonElement Data, DateTime Expires, DateTime Used, int Bytes)> _cache = [];
    private int _cacheBytes;
    private readonly object _cacheLock = new();
    private const int CacheLimit = 32;
    private const int ResponseLimit = 2 * 1024 * 1024;

    public TmdbService() : this(null, null) { }

    internal TmdbService(HttpMessageHandler? handler, Func<string>? credentialProvider)
    {
        _credentialProvider = credentialProvider ?? ReadCredential;
        _client = new HttpClient(handler ?? new SocketsHttpHandler
        { MaxConnectionsPerServer = 4, ConnectTimeout = TimeSpan.FromSeconds(10), PooledConnectionLifetime = TimeSpan.FromMinutes(10) })
        { BaseAddress = new Uri("https://api.themoviedb.org/3/"), Timeout = Timeout.InfiniteTimeSpan };
    }

    public async Task<CatalogPage> BrowseAsync(string type, string order, int genre, int page, CancellationToken token, bool refresh = false)
    {
        var query = new Dictionary<string, string> { ["page"] = page.ToString(), ["include_adult"] = "false" };
        string path;
        if (order == "trending") path = $"trending/{type}/week";
        else if (genre > 0)
        {
            path = $"discover/{type}";
            query["with_genres"] = genre.ToString();
            query["sort_by"] = order == "top_rated" ? "vote_average.desc" : "popularity.desc";
            if (order == "top_rated") query["vote_count.gte"] = "200";
        }
        else path = $"{type}/{order}";
        return MapPage(await GetAsync(path, query, token, refresh), type);
    }

    public async Task<CatalogPage> SearchAsync(string type, string query, int page, CancellationToken token, bool refresh = false) =>
        MapPage(await GetAsync($"search/{type}", new() { ["query"] = query, ["page"] = page.ToString(), ["include_adult"] = "false" }, token, refresh), type);

    public async Task<IReadOnlyList<MediaGenre>> GenresAsync(string type, CancellationToken token) =>
        Array(await GetAsync($"genre/{type}/list", null, token), "genres")
            .Where(item => Integer(item, "id") > 0).Select(item => new MediaGenre(Integer(item, "id"), Text(item, "name"))).ToArray();

    public async Task<MediaTitle> DetailsAsync(string id, CancellationToken token, bool refresh = false)
    {
        if (!MediaTitle.TryParseId(id, out var type, out var number)) throw new TmdbException("This title could not be found.");
        var data = await GetAsync($"{type}/{number}", new() { ["append_to_response"] = "credits,images", ["include_image_language"]="en,null" }, token, refresh);
        if (data.TryGetProperty("adult", out var adult) && adult.ValueKind == JsonValueKind.True)
            throw new TmdbException("This title is not available in browsing.");
        return MapTitle(data, type) ?? throw new TmdbException("This title could not be found.");
    }

    public async Task<IReadOnlyList<MediaEpisode>> EpisodesAsync(int seriesId, int season, CancellationToken token, bool refresh = false)
        => (await SeasonInventoryAsync(seriesId,season,token,refresh)).Episodes;

    public async Task<SeasonInventory> SeasonInventoryAsync(int seriesId,int season,CancellationToken token,bool refresh=false)
    {
        if(seriesId is <=0 or >1_000_000_000||season is <0 or >10000)throw new TmdbException("Invalid episode inventory identity.");
        var data = await GetAsync($"tv/{seriesId}/season/{season}", null, token, refresh);
        static bool ExactSeason(JsonElement row,string name,int expected)=>row.TryGetProperty(name,out var value)&&value.ValueKind==JsonValueKind.Number&&value.TryGetInt32(out var number)&&number==expected;
        if(!ExactSeason(data,"season_number",season))throw new TmdbException("TMDB returned a different season identity.");
        var raw=Array(data,"episodes").ToArray();
        if(raw.Length>AnimeReconciliation.MaximumEpisodes||raw.Any(e=>Integer(e,"id")<=0||!ExactSeason(e,"season_number",season)||!AnimeReconciliation.Count(Integer(e,"episode_number")))||raw.Select(e=>Integer(e,"id")).Distinct().Count()!=raw.Length||raw.Select(e=>Integer(e,"episode_number")).Distinct().Count()!=raw.Length)
            throw new TmdbException("TMDB returned an invalid episode inventory.");
        var episodes=raw.Select(item => new MediaEpisode(Integer(item, "episode_number"), Text(item, "name"),
            Minutes(Integer(item, "runtime")), Text(item, "overview"), Text(item, "air_date"), Text(item,"still_path"))
            {SourceEpisodeId=Integer(item,"id"),TmdbSeasonNumber=season,TmdbEpisodeNumber=Integer(item,"episode_number"),RuntimeMinutes=Integer(item,"runtime") is >0 and <=1000?Integer(item,"runtime"):null}).ToArray();
        return new(Integer(data,"id"),season,Text(data,"name"),episodes);
    }

    public async Task<CatalogPage> DiscoverAsync(string type,Dictionary<string,string> filters,int page,CancellationToken token)
    {
        var query=new Dictionary<string,string>(filters) { ["page"]=Math.Clamp(page,1,5).ToString(),["include_adult"]="false" };
        return MapPage(await GetAsync($"discover/{type}",query,token),type);
    }
    public async Task<CatalogPage> RelatedAsync(MediaTitle title,CancellationToken token) =>
        MapPage(await GetAsync($"{title.MediaType}/{title.TmdbId}/recommendations",null,token),title.MediaType);
    public async Task<MediaTitle?> FindImdbAsync(string imdb,CancellationToken token)
    {
        if(!System.Text.RegularExpressions.Regex.IsMatch(imdb,"^tt[0-9]{5,12}$"))return null;
        var data=await GetAsync($"find/{imdb}",new(){["external_source"]="imdb_id"},token);
        var rows=Array(data,"tv_results").Select(r=>MapTitle(r,"tv")).OfType<MediaTitle>().DistinctBy(r=>r.Id).ToArray();
        return rows.Length==1 ? rows[0] : null;
    }
    public async Task<JsonElement> ExtraAsync(MediaTitle title,string kind,CancellationToken token)
    {
        if(kind is not ("images" or "videos" or "external_ids")) throw new ArgumentException("Unknown metadata section");
        return await GetAsync($"{title.MediaType}/{title.TmdbId}/{kind}",null,token);
    }
    public async Task<string?> PosterPathAsync(int showId,CancellationToken token)
    {
        if(showId is <=0 or >1_000_000_000)return null;
        var row=await GetAsync($"tv/{showId}",null,token);
        return Integer(row,"id")==showId?Text(row,"poster_path"):null;
    }

    private static string ReadCredential()
    {
        try
        {
            var path = Path.Combine(ApplicationData.Current.LocalFolder.Path, "settings.local.json");
            if (!File.Exists(path)) throw new TmdbException("TMDB is not configured on this device.");
            using var data = JsonDocument.Parse(File.ReadAllText(path));
            var credential = Text(data.RootElement, "TmdbApiKey").Trim();
            if (credential.Length == 0 || credential.Contains("$(")) throw new TmdbException("TMDB is not configured on this device.");
            return credential;
        }
        catch (TmdbException) { throw; }
        catch { throw new TmdbException("TMDB local configuration could not be read."); }
    }

    private async Task<JsonElement> GetAsync(string path, Dictionary<string, string>? query, CancellationToken token, bool refresh = false)
    {
        query ??= [];
        query["language"] = "en-US";
        var parameters = string.Join("&", query.OrderBy(item => item.Key).Select(item => $"{Uri.EscapeDataString(item.Key)}={Uri.EscapeDataString(item.Value)}"));
        var cacheKey = path + "?" + parameters;
        token.ThrowIfCancellationRequested();
        lock (_cacheLock)
        {
            if (!refresh && _cache.TryGetValue(cacheKey, out var cached) && cached.Expires > DateTime.UtcNow)
            { _cache[cacheKey] = (cached.Data, cached.Expires, DateTime.UtcNow,cached.Bytes); return cached.Data; }
        }
        var credential = _credentialProvider();
        var isV3Key = credential.Length == 32 && credential.All(Uri.IsHexDigit);
        var uri = cacheKey + (isV3Key ? "&api_key=" + Uri.EscapeDataString(credential) : "");
        // ResponseHeadersRead ends HttpClient's own timeout at headers. Keep a deadline
        // across queueing, headers and the entire streamed body instead.
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(TimeSpan.FromSeconds(20));
        var requestToken = deadline.Token;
        var entered = false;
        try
        {
            await _requests.WaitAsync(requestToken).ConfigureAwait(false);
            entered = true;
            using var request = new HttpRequestMessage(HttpMethod.Get, uri);
            if (!isV3Key) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", credential);
            using var response = await _client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, requestToken).ConfigureAwait(false);
            if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
                throw new TmdbException("TMDB could not authenticate. Check this device's local configuration.");
            if (response.StatusCode == HttpStatusCode.TooManyRequests)
                throw new TmdbException("TMDB is busy. Please wait a moment, then retry.");
            if (response.StatusCode == HttpStatusCode.NotFound) throw new TmdbException("This title is no longer available on TMDB.");
            if (!response.IsSuccessStatusCode) throw new TmdbException("TMDB is temporarily unavailable. Please retry.");
            if (response.Content.Headers.ContentLength > ResponseLimit) throw new TmdbException("TMDB returned too much data. Please retry.");
            await using var stream = await response.Content.ReadAsStreamAsync(requestToken).ConfigureAwait(false);
            using var buffer = new MemoryStream();
            var chunk = new byte[16384];
            int count;
            while ((count = await stream.ReadAsync(chunk, requestToken).ConfigureAwait(false)) > 0)
            {
                if (buffer.Length + count > ResponseLimit) throw new TmdbException("TMDB returned too much data. Please retry.");
                buffer.Write(chunk, 0, count);
            }
            using var document = JsonDocument.Parse(buffer.ToArray());
            var result = document.RootElement.Clone();
            token.ThrowIfCancellationRequested();
            lock (_cacheLock)
            {
                if(_cache.Remove(cacheKey,out var old))_cacheBytes-=old.Bytes;
                while(_cache.Count>=CacheLimit||_cacheBytes+buffer.Length>8*1024*1024)
                {var oldest=_cache.MinBy(item=>item.Value.Used);_cacheBytes-=oldest.Value.Bytes;_cache.Remove(oldest.Key);}
                _cache[cacheKey] = (result, DateTime.UtcNow.AddMinutes(10), DateTime.UtcNow,(int)buffer.Length);_cacheBytes+=(int)buffer.Length;
            }
            return result;
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested) { throw new TmdbException("TMDB took too long to respond. Please retry."); }
        catch (HttpRequestException) { throw new TmdbException("Could not connect to TMDB. Check your connection and retry."); }
        catch (JsonException) { throw new TmdbException("TMDB returned an unreadable response. Please retry."); }
        catch (IOException) { throw new TmdbException("The TMDB connection was interrupted. Please retry."); }
        finally { if (entered) _requests.Release(); }
    }

    private static CatalogPage MapPage(JsonElement data, string type) => new(
        Array(data, "results").Select(item => MapTitle(item, Text(item, "media_type") is { Length: > 0 } media ? media : type))
            .OfType<MediaTitle>().DistinctBy(item => item.Id).ToArray(), Integer(data, "page"), Integer(data, "total_pages"));

    private static MediaTitle? MapTitle(JsonElement item, string type)
    {
        if (type is not ("movie" or "tv") || Integer(item, "id") <= 0 ||
            (item.TryGetProperty("adult", out var adult) && adult.ValueKind == JsonValueKind.True)) return null;
        var name = Text(item, type == "movie" ? "title" : "name");
        if (string.IsNullOrWhiteSpace(name)) return null;
        var runtime = Integer(item, "runtime");
        var episodeCount = Integer(item, "number_of_episodes");
        var cast = item.TryGetProperty("credits", out var credits) ? Array(credits, "cast") : [];
        return new MediaTitle
        {
            TmdbId = Integer(item, "id"), MediaType = type, Title = name,
            OriginalTitle=Text(item,type=="movie" ? "original_title" : "original_name"), OriginalLanguage=Text(item,"original_language"),
            GenreIds=Array(item,"genre_ids").Select(value=>value.ValueKind==JsonValueKind.Number && value.TryGetInt32(out var n) ? n : 0)
                .Concat(Array(item,"genres").Select(value=>Integer(value,"id"))).Where(n=>n>0).Distinct().ToArray(),
            Status=Text(item,"status"),
            RuntimeMinutes=runtime is >0 and <=1000?runtime:null,
            LogoPath=Text(Array(JsonValue.Child(item,"images"),"logos").OrderByDescending(value=>Text(value,"iso_639_1")=="en").FirstOrDefault(),"file_path"),
            Synopsis = Text(item, "overview"), Tagline = Text(item, "tagline"), ReleaseDate = Text(item, type == "movie" ? "release_date" : "first_air_date"),
            Genre = string.Join(" · ", Array(item, "genres").Take(3).Select(value => Text(value, "name"))),
            Duration = type == "movie" ? (runtime > 0 ? Minutes(runtime) : "") : (episodeCount > 0 ? $"{episodeCount} episodes" : ""),
            Score = item.TryGetProperty("vote_average", out var score) && score.ValueKind == JsonValueKind.Number && score.TryGetDouble(out var rating) ? rating : 0,
            PosterPath = Text(item, "poster_path"), BackdropPath = Text(item, "backdrop_path"),
            Seasons = Array(item, "seasons").Where(value => Integer(value, "episode_count") > 0)
                .Select(value => new MediaSeason(Integer(value, "season_number"), Text(value, "name"), Integer(value, "episode_count")))
                .OrderBy(value => value.Number == 0 ? int.MaxValue : value.Number).ToArray(),
            Cast = cast.Take(12).Select(value => new CastMember(Text(value, "name"), Text(value, "character"), Text(value,"profile_path"))).ToArray()
        };
    }

    private static string Minutes(int value) => value <= 0 ? "Runtime not listed" : value >= 60 ? $"{value / 60}h {value % 60}m" : $"{value} min";
    private static string Text(JsonElement item, string key) => item.ValueKind == JsonValueKind.Object && item.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() ?? "" : "";
    private static int Integer(JsonElement item, string key) => item.ValueKind == JsonValueKind.Object && item.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number) ? number : 0;
    private static IEnumerable<JsonElement> Array(JsonElement item, string key) => item.ValueKind == JsonValueKind.Object && item.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.Array ? value.EnumerateArray() : [];
}
