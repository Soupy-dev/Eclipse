using System.Security.Cryptography;
using System.Text;
using Eclipse.Windows.Models;

namespace Eclipse.Windows.Services;

// Pure scheduling rules mirrored from Apple's LocalNotificationManager. Provider IDs stay typed.
public static class ReminderPolicy
{
    public const int MaximumSaved=200,MaximumScheduled=48;
    public static bool ValidLead(int seconds)=>seconds is 0 or 900 or 3600 or 86400;
    public static bool ValidEntry(ScheduleEntry? e)=>e is not null&&e.Source is "Anime" or "Western"&&
        (e.Source=="Anime"?e.Provider is "AniList" or "MAL"&&e.MediaId is >0 and <=1_000_000_000:e.TmdbId is >0 and <=1_000_000_000||e.Provider=="TVMaze"&&e.MediaId is >0 and <=1_000_000_000)&&
        e.Episode is >0 and <=100000&&e.Season is null or >=0 and <=10000&&e.Title is{Length:>0 and <=500}&&e.AiringAt.Year is >=1800 and <=2200;
    public static bool CanEnable(ScheduleEntry e,DateTimeOffset now)=>ValidEntry(e)&&e.KnownTime&&!e.Estimated&&!e.AiringTimeWithdrawn&&e.AiringAt>now;
    public static bool SameEpisode(ScheduleEntry a,ScheduleEntry b)
    {
        if(a.Source!=b.Source||a.Episode!=b.Episode)return false;
        if(a.Source=="Western")return (a.Season??0)==(b.Season??0)&&(a.TmdbId is >0&&b.TmdbId is >0?a.TmdbId==b.TmdbId:a.Provider==b.Provider&&a.MediaId==b.MediaId);
        if(a.Provider==b.Provider)return a.MediaId==b.MediaId&&!(a.MalId is >0&&b.MalId is >0&&a.MalId!=b.MalId);
        var am=a.Provider=="MAL"?a.MediaId:a.MalId;var bm=b.Provider=="MAL"?b.MediaId:b.MalId;
        return am is >0&&am==bm;
    }
    public static string StableId(ScheduleEntry e)=>e.Source=="Anime"?$"anime:{e.Provider.ToLowerInvariant()}:{e.MediaId}:e{e.Episode}":
        $"western:{(e.TmdbId is >0?"tmdb":"tvmaze")}:{(e.TmdbId is >0?e.TmdbId:e.MediaId)}:s{e.Season??0}:e{e.Episode}";
    public static string Tag(string id)=>Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(id)))[..16];
    public static string RouteToken(string owner,string id)=>Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(owner+"|"+id)))[..32].ToLowerInvariant();
    public static bool ValidSeasonLead(int seconds)=>seconds is 0 or 86400 or 604800;
    public static bool Matches(NotificationSubscription sub,ScheduleEntry entry)
    {
        if(sub.Source!=entry.Source)return false;
        if(sub.Source=="Western"&&entry.TmdbId is >0)return entry.TmdbId==sub.TmdbId;
        if(sub.Source=="Anime")
        {
            var all=sub.AnimeMediaIds.Concat(sub.AnimeSpecialMediaIds).ToArray();var prefix=entry.Provider.ToLowerInvariant()+":";var key=prefix+entry.MediaId;
            if(all.Contains(key))return true;
            if(entry.MalId is{} mal&&all.Contains($"mal:{mal}"))return true;
            if(all.Any(id=>id.StartsWith(prefix,StringComparison.Ordinal)))return false;
        }
        var title=AnimeText.Signature(entry.Title);return title.Length>0&&sub.TitleAliases.Append(sub.Title).Any(a=>AnimeText.Signature(a)==title);
    }
    public static string[] EpisodeKeys(ScheduleEntry e)=>e.Source=="Western"?[StableId(e)]:new[]{StableId(e),e.MalId is{} mal?$"anime:mal:{mal}:e{e.Episode}":""}.Where(k=>k.Length>0).Distinct().ToArray();
    public static bool IsSpecial(NotificationSubscription sub,ScheduleEntry e)
    {
        if(e.Source!="Anime")return false;
        var keys=new[]{$"{e.Provider.ToLowerInvariant()}:{e.MediaId}",e.MalId is{} mal?$"mal:{mal}":""};
        if(keys.Any(sub.AnimeMediaIds.Contains))return false;
        return keys.Any(sub.AnimeSpecialMediaIds.Contains)||e.Format is "SPECIAL" or "OVA" or "OAD" or "MOVIE" or "MUSIC";
    }
    public static EpisodeNotificationState EpisodeState(ReminderState state,ScheduleEntry e,DateTimeOffset now,int days)
    {
        if(state.Reminders.Any(r=>SameEpisode(r.Entry,e)))return EpisodeNotificationState.Explicit;
        if(!CanEnable(e,now))return EpisodeNotificationState.Unavailable;
        var sub=state.Subscriptions.FirstOrDefault(s=>s.EpisodeNotifications&&Matches(s,e));
        if(sub is null||!WithinWindow(e,now,days)||!state.LocalNotificationIncludeAnimeSpecials&&IsSpecial(sub,e))return EpisodeNotificationState.Off;
        return EpisodeKeys(e).Any(k=>sub.MutedEpisodes.TryGetValue(k,out var until)&&until>now)?EpisodeNotificationState.Muted:EpisodeNotificationState.Followed;
    }
    public static bool WithinWindow(ScheduleEntry e,DateTimeOffset now,int days)
    {var day=DateOnly.FromDateTime(now.ToLocalTime().DateTime);return e.AiringAt>=ScheduleDates.Start(day,TimeZoneInfo.Local)&&e.AiringAt<ScheduleDates.Start(day.AddDays(days),TimeZoneInfo.Local);}
    public static string ContentKey(string title,string body,string token)=>Tag(System.Text.Json.JsonSerializer.Serialize(new[]{title,body,token}));
    public static string ContentKey(ReminderPlan plan)=>ContentKey(plan.Entry.Title,plan.Body,plan.RouteToken);
    public static string OccurrenceKey(string id,DateTimeOffset fire)=>Tag(id+"|"+fire.ToUniversalTime().ToString("O"));
    public static bool ReadArgument(string? argument,out string token,out string occurrence)
    {
        token=occurrence="";const string prefix="eclipse-reminder=";
        if(argument is null||!argument.StartsWith(prefix,StringComparison.Ordinal))return false;
        var parts=argument[prefix.Length..].Split("&occurrence=",StringSplitOptions.None);
        if(parts.Length is <1 or >2||parts[0].Length!=32||!Guid.TryParseExact(parts[0],"N",out _))return false;
        if(parts.Length==2&&(parts[1].Length!=16||!parts[1].All(Uri.IsHexDigit)))return false;
        token=parts[0];occurrence=parts.Length==2?parts[1]:"";return true;
    }
    public static IReadOnlyList<ReminderPlan> BuildPlans(ReminderState state,DateTimeOffset now,int days)
    {
        var result=Plan(state,now).Select(p=>p with{Id=state.Reminders.First(r=>Tag(r.Id)==p.Tag).Id,Kind="explicit",Body=EpisodeBody(p.Entry,state.LocalNotificationEpisodeLeadTime)}).ToList();
        foreach(var sub in state.Subscriptions)
        {
            if(sub.EpisodeNotifications)
            {
                var candidates=state.AutoEpisodes.Where(e=>CanEnable(e,now)&&WithinWindow(e,now,days)&&Matches(sub,e)&&(state.LocalNotificationIncludeAnimeSpecials||!IsSpecial(sub,e))&&!state.Reminders.Any(r=>SameEpisode(r.Entry,e))&&!EpisodeKeys(e).Any(k=>sub.MutedEpisodes.TryGetValue(k,out var until)&&until>now)).DistinctBy(StableId);
                foreach(var bucket in candidates.GroupBy(e=>e.AiringAt.ToUnixTimeSeconds()/300))
                {
                    var rows=bucket.OrderBy(e=>e.Episode).ToArray();var grouped=rows.Length>=3;
                    foreach(var group in grouped?new[]{rows}:rows.Select(e=>new[]{e}))
                    {
                        var first=group[0];var previous=state.Occurrences.LastOrDefault(o=>o.SubscriptionId==sub.Id&&o.Kind=="followed"&&SameEpisode(o.Entry,first));
                        var id=grouped?$"follow:{sub.Id}:batch:{bucket.Key}":previous?.Id??$"follow:{sub.Id}:{StableId(first)}";var preferred=first.AiringAt.AddSeconds(-state.LocalNotificationEpisodeLeadTime);
                        result.Add(new(Tag(id),RouteToken(state.OwnerId,id),first,preferred>now?preferred:first.AiringAt){Id=id,Kind=grouped?"batch":"followed",SubscriptionId=sub.Id,EpisodeNumbers=group.Select(e=>e.Episode).ToArray(),Body=grouped?$"{group.Length} episodes have reached their scheduled release time.":EpisodeBody(first,state.LocalNotificationEpisodeLeadTime)});
                    }
                }
            }
            if(sub.FutureSeasonNotifications)foreach(var premiere in sub.Premieres.Where(p=>p.Upcoming&&!p.Special))
            {
                if(AnimeReconciliation.Day(premiere.Date) is not{} date)continue;
                var local=date.ToDateTime(new TimeOnly(9,0),DateTimeKind.Unspecified);if(TimeZoneInfo.Local.IsInvalidTime(local))continue;var eventAt=new DateTimeOffset(local,TimeZoneInfo.Local.GetUtcOffset(local));if(eventAt<=now)continue;
                var id=$"season:{sub.Id}:{premiere.Id}";var preferred=eventAt.AddSeconds(-state.LocalNotificationSeasonLeadTime);
                var entry=new ScheduleEntry(id,sub.Source,premiere.Provider,premiere.ProviderId,premiere.Title,eventAt,0,premiere.Season,TmdbId:sub.TmdbId);
                result.Add(new(Tag(id),RouteToken(state.OwnerId,id),entry,preferred>now?preferred:eventAt){Id=id,Kind="season",SubscriptionId=sub.Id,Body=state.LocalNotificationSeasonLeadTime>0?$"{premiere.Label} premieres soon. Open Eclipse to refresh the latest date.":$"{premiere.Label} is scheduled to premiere today."});
            }
        }
        return result.Where(p=>!state.Occurrences.Any(o=>o.Id==p.Id&&o.FireDate<=now&&Math.Abs((o.EventDate-p.Entry.AiringAt).TotalSeconds)<=2))
            .OrderBy(p=>p.FireDate).ThenBy(p=>p.Priority).ThenBy(p=>p.Id,StringComparer.Ordinal).Take(MaximumScheduled).ToArray();
    }
    private static string EpisodeBody(ScheduleEntry e,int lead)=>$"{(e.Season is{} s?$"S{s:00} E{e.Episode:00}":$"Episode {e.Episode}")} "+(lead>0?"is scheduled to air soon.":e.StreamingRelease?"is scheduled to release now.":"has reached its scheduled airtime.");
    public static DateTimeOffset? FireDate(EpisodeReminder reminder,int lead,DateTimeOffset now)
    {
        var e=reminder.Entry;if(!CanEnable(e,now))return null;
        // A previously scheduled lead-time occurrence must not become a second alert at airtime.
        if(reminder.ScheduledFireDate<=now&&reminder.ScheduledAiringAt is{} previous&&Math.Abs((previous-e.AiringAt).TotalSeconds)<=2)return null;
        var preferred=e.AiringAt.AddSeconds(-lead);return preferred>now?preferred:e.AiringAt;
    }
    public static IReadOnlyList<EpisodeReminder> Merge(IReadOnlyList<EpisodeReminder> saved,IReadOnlyList<ScheduleEntry> entries,DateTimeOffset now)
    {
        var result=new List<EpisodeReminder>();
        foreach(var reminder in saved)
        {
            var matches=entries.Where(e=>ValidEntry(e)&&SameEpisode(reminder.Entry,e)&&(!e.Estimated&&e.KnownTime||e.AiringTimeWithdrawn)).ToArray();
            var current=reminder;
            // Conflicting remote rows cannot manufacture a new confirmed time.
            if(matches.Length>0&&matches.Select(e=>(e.AiringAt,e.KnownTime,e.AiringTimeWithdrawn)).Distinct().Count()==1)
                current=reminder with{Entry=matches[0] with{Cover=null}};
            result.Add(current);
        }
        return result;
    }
    public static IReadOnlyList<ReminderPlan> Plan(ReminderState state,DateTimeOffset now)=>state.Reminders.Select(r=>(Reminder:r,Fire:FireDate(r,state.LocalNotificationEpisodeLeadTime,now)))
        .Where(p=>p.Fire is not null).OrderBy(p=>p.Fire).ThenBy(p=>p.Reminder.Id,StringComparer.Ordinal).Take(MaximumScheduled)
        .Select(p=>new ReminderPlan(Tag(p.Reminder.Id),p.Reminder.RouteToken,p.Reminder.Entry,p.Fire!.Value)).ToArray();
}
