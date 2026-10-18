using Eclipse.Windows.Models;
using Eclipse.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Eclipse.Windows.Views;

internal static class NotificationOptions
{
    public static NotificationSubscription Selection(MediaTitle title)
    {
        var anime = title.AniListId is > 0 || title.MalId is > 0 || title.Provider is "AniList" or "MAL"||title.GenreIds.Contains(16)&&title.OriginalLanguage is "ja" or "zh" or "ko";
        var regular = new List<string>(); var special = new List<string>();
        var rootCour=title.AnimeStructure?.Cours.FirstOrDefault(c=>title.AniListId is{} rootAni&&c.Node.AniListId==rootAni||title.MalId is{} rootMal&&c.Node.MalId==rootMal);
        var root=rootCour?.Regular==false||rootCour is null&&title.Format is "SPECIAL" or "OVA" or "OAD" or "MOVIE" or "MUSIC"?special:regular;
        if (title.AniListId is { } ani) root.Add($"anilist:{ani}");
        if (title.MalId is { } mal) root.Add($"mal:{mal}");
        foreach (var cour in title.AnimeStructure?.Cours ?? [])
        {
            var list = cour.Regular ? regular : special;
            if (cour.Node.AniListId is { } courAni) list.Add($"anilist:{courAni}");
            if (cour.Node.MalId is { } m) list.Add($"mal:{m}");
        }
        var id = (anime ? "anime:" : "western:") + (title.TmdbId > 0 ? $"tmdb:{title.TmdbId}" : title.AniListId is { } a ? $"anilist:{a}" : $"mal:{title.MalId}");
        var existing = EpisodeReminderService.Shared.State.Subscriptions.FirstOrDefault(s => s.Id == id || s.Source == (anime ? "Anime" : "Western") &&
            (title.TmdbId > 0 && s.TmdbId == title.TmdbId || anime && s.AnimeMediaIds.Intersect(regular).Any()));
        var selection=existing ?? new NotificationSubscription(id, anime ? "Anime" : "Western", title.TmdbId, title.TmdbRootTitle.Length > 0 ? title.TmdbRootTitle : title.Title);
        return selection with { AnimeMediaIds = selection.AnimeMediaIds.Concat(regular).Except(special.Except(regular)).Distinct().Take(256).ToArray(), AnimeSpecialMediaIds = selection.AnimeSpecialMediaIds.Concat(special).Except(regular).Distinct().Take(256).ToArray(), TitleAliases = selection.TitleAliases.Concat(new[] { title.Title, title.OriginalTitle, title.TmdbRootTitle }).Where(s => s.Length > 0).Distinct().Take(64).ToArray() };
    }
    public static async Task<bool> ShowAsync(XamlRoot root, NotificationSubscription selection)
    {
        var episodes = new CheckBox { Content = "Upcoming episodes", IsChecked = selection.EpisodeNotifications };
        var seasons = new CheckBox { Content = "Future seasons", IsChecked = selection.FutureSeasonNotifications,
            IsEnabled = selection.Source != "Anime" || selection.AnimeMediaIds.Any(id => id.StartsWith("anilist:", StringComparison.Ordinal)) };
        var panel = new StackPanel { Spacing = 16, MaxWidth = 440 };
        panel.Children.Add(new TextBlock { Text = "Choose what Eclipse checks on this device.", TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(episodes); panel.Children.Add(seasons);
        if (!seasons.IsEnabled) panel.Children.Add(new TextBlock { Text = "Future anime seasons require a verified AniList identity.", TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(new TextBlock { Text = "Open Eclipse periodically to discover new episodes, seasons, and changed dates. Scheduled alerts can arrive while Eclipse is closed.", TextWrapping = TextWrapping.Wrap, FontSize = 13 });
        var dialog = new ContentDialog { XamlRoot = root, Title = selection.Title, Content = panel, PrimaryButtonText = "Save", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return false;
        await EpisodeReminderService.Shared.FollowAsync(selection with { EpisodeNotifications = episodes.IsChecked == true, FutureSeasonNotifications = seasons.IsChecked == true });
        return true;
    }
}
