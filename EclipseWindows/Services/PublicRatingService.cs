using Eclipse.Windows.Models;
using static Eclipse.Windows.Services.JsonValue;
namespace Eclipse.Windows.Services;

public sealed class PublicRatingService
{
    public static PublicRatingService Shared { get; } = new();
    public async Task<int> TraktIdAsync(MediaTitle title, CancellationToken ct)
    {
        var key = LocalCredentials.Read("TraktClientId"); if (title.TmdbId <= 0 || key.Length == 0) return 0; var type = title.MediaType == "movie" ? "movie" : "show";
        var data = await ProviderJson.Shared.FetchAsync($"https://api.trakt.tv/search/tmdb/{title.TmdbId}?type={type}", ct, headers: new() { { "trakt-api-key", key }, { "trakt-api-version", "2" } });
        var matches = Items(data).Where(e => Text(e, "type") == type && Int(Child(Child(e, type), "ids"), "tmdb") == title.TmdbId).Select(e => Int(Child(Child(e, type), "ids"), "trakt")).Where(id => id > 0).Distinct().ToArray(); return matches.Length == 1 ? matches[0] : 0;
    }
    public async Task<(double Trakt, double Mal)> RatingsAsync(MediaTitle title, CancellationToken ct)
    {
        double trakt = 0, mal = 0;
        try { var id = await TraktIdAsync(title, ct); if (id > 0) { var data = await ProviderJson.Shared.FetchAsync($"https://api.trakt.tv/{(title.MediaType == "movie" ? "movies" : "shows")}/{id}/ratings", ct, headers: new() { { "trakt-api-key", LocalCredentials.Read("TraktClientId") }, { "trakt-api-version", "2" } }); trakt = Double(data, "rating"); } } catch (ProviderException) { }
        var anime = title.AniListId is > 0 || title.MalId is > 0 || title.GenreIds.Contains(16) && title.OriginalLanguage is "ja" or "zh" or "ko";
        if (anime)
        {
            try { var id = title.MalId; if (id is not > 0 && title.TmdbId > 0) { var metadata = await AnimeMetadataService.Shared.DetailsAsync($"{title.MediaType}:{title.TmdbId}", ct); id = metadata.MalId; } if (id is > 0) { var result = await AnimeMetadataService.Shared.MalAsync(id.Value, ct); mal = result.Score; } } catch (ProviderException) { } catch (TmdbException) { }
        }
        return (trakt is > 0 and <= 10 ? trakt : 0, mal is > 0 and <= 10 ? mal : 0);
    }
}
