namespace Eclipse.Windows.Models;

public sealed record EpisodeReminder(string Id,string RouteToken,ScheduleEntry Entry,
    DateTimeOffset? ScheduledFireDate=null,DateTimeOffset? ScheduledAiringAt=null);
public sealed record ReminderState
{
    public int Version {get;init;}=1;
    public int LocalNotificationEpisodeLeadTime {get;init;}
    public int LocalNotificationSeasonLeadTime {get;init;}=86400;
    public bool LocalNotificationIncludeAnimeSpecials {get;init;}
    public string OwnerId {get;init;}=Guid.NewGuid().ToString("N");
    public IReadOnlyList<EpisodeReminder> Reminders {get;init;}=[];
    public IReadOnlyList<ReminderRoute> RecentRoutes {get;init;}=[];
    public IReadOnlyList<NotificationSubscription> Subscriptions {get;init;}=[];
    public IReadOnlyList<ScheduleEntry> AutoEpisodes {get;init;}=[];
    public IReadOnlyList<NotificationOccurrence> Occurrences {get;init;}=[];
    public IReadOnlyList<NotificationHistoryEntry> History {get;init;}=[];
    public IReadOnlyList<string> DeletedHistoryIds {get;init;}=[];
    public bool PendingPlatformUpdate {get;init;}
    public DateTimeOffset? HistoryClearedAt {get;init;}
}
public sealed record ReminderRoute(string RouteToken,ScheduleEntry Entry,DateTimeOffset ExpiresAt);
public sealed record NotificationSubscription(string Id,string Source,int TmdbId,string Title)
{
    public string Revision {get;init;}=Guid.NewGuid().ToString("N");
    public IReadOnlyList<string> TitleAliases {get;init;}=[];
    public IReadOnlyList<string> AnimeMediaIds {get;init;}=[];
    public IReadOnlyList<string> AnimeSpecialMediaIds {get;init;}=[];
    public IReadOnlyList<int> KnownWesternSeasonIds {get;init;}=[];
    public bool EpisodeNotifications {get;init;}
    public bool FutureSeasonNotifications {get;init;}
    public IReadOnlyDictionary<string,DateTimeOffset> MutedEpisodes {get;init;}=new Dictionary<string,DateTimeOffset>();
    public IReadOnlyList<SeasonPremiere> Premieres {get;init;}=[];
    public bool HasCompleteBaseline {get;init;}
    public DateTimeOffset? LastMetadataSuccess {get;init;}
    public DateTimeOffset? LastMetadataAttempt {get;init;}
}
public sealed record SeasonPremiere(string Id,string Title,string Label,string Provider,int ProviderId,int? Season,string Date,bool Upcoming=true,bool Special=false);
public sealed record SeasonSnapshot(IReadOnlyList<SeasonPremiere> Seasons,bool Complete,IReadOnlyList<string> RegularIds,IReadOnlyList<string> SpecialIds);
public sealed record ReminderPlan(string Tag,string RouteToken,ScheduleEntry Entry,DateTimeOffset FireDate)
{
    public string Id {get;init;}="";
    public string Kind {get;init;}="episode";
    public string? SubscriptionId {get;init;}
    public string Body {get;init;}="";
    public IReadOnlyList<int> EpisodeNumbers {get;init;}=[];
    public int Priority=>Kind=="explicit"?0:Kind=="season"?1:2;
}
public sealed record PendingReminder(string Tag,DateTimeOffset FireDate,string ContentKey="");
public sealed record DeliveredReminder(string Tag,string RouteToken,string OccurrenceKey="");
public sealed record NotificationOccurrence(string Id,string Tag,string RouteToken,ScheduleEntry Entry,DateTimeOffset FireDate,DateTimeOffset EventDate,string Kind,string Body,string? SubscriptionId=null,IReadOnlyList<int>? EpisodeNumbers=null,bool AnnouncementPending=false);
public sealed record NotificationHistoryEntry(string Id,string RouteToken,ScheduleEntry Entry,string Kind,string Body,DateTimeOffset RecordedAt,bool WasOpened=false);
public enum EpisodeNotificationState {Off,Explicit,Followed,Muted,Unavailable}
