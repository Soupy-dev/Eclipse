using System.Globalization;

namespace Eclipse.Windows.Models;

public sealed record ScheduleEntry(string Id,string Source,string Provider,int MediaId,string Title,DateTimeOffset AiringAt,int Episode,int? Season=null,
    string? Cover=null,int? MalId=null,int? TmdbId=null,bool KnownTime=true,bool Estimated=false,string? Route=null,string? TimetableProvider=null,bool AiringTimeWithdrawn=false,string Format="",bool StreamingRelease=false)
{
    public string TitleId => TmdbId is >0 ? $"tv:{TmdbId}" : Provider=="MAL" ? $"mal:{MediaId}" : Provider=="TVMaze" ? $"tvmaze:{MediaId}" : MediaId>0 ? $"anilist:{MediaId}" : "";
    public string EpisodeLabel => (Season is { } s ? $"S{s:00} · " : "")+(Episode>0 ? $"Episode {Episode}" : "Episode TBA")+(Estimated ? " · Estimated" : "");
    public string DisplayTime(bool local) => KnownTime ? (local ? AiringAt.ToLocalTime() : AiringAt.ToUniversalTime()).ToString("t",CultureInfo.CurrentCulture) : "Time TBA";
}
public static class ScheduleDates
{
    public static DateTimeOffset Start(DateOnly day,TimeZoneInfo zone)
    {
        var time=day.ToDateTime(TimeOnly.MinValue,DateTimeKind.Unspecified);
        // Some regions advance at midnight. Move to the first valid local instant.
        for(var i=0;zone.IsInvalidTime(time) && i<180;i++) time=time.AddMinutes(1);
        var offset=zone.IsAmbiguousTime(time) ? zone.GetAmbiguousTimeOffsets(time).Max() : zone.GetUtcOffset(time);
        return new DateTimeOffset(time,offset);
    }
    public static (DateTimeOffset Start,DateTimeOffset End) Envelope(DateTimeOffset now,int days,TimeZoneInfo local)
    {
        var localDay=DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(now,local).DateTime);
        var utcDay=DateOnly.FromDateTime(now.UtcDateTime);
        var ls=Start(localDay,local); var us=Start(utcDay,TimeZoneInfo.Utc);
        var le=Start(localDay.AddDays(days),local); var ue=Start(utcDay.AddDays(days),TimeZoneInfo.Utc);
        return (ls<us ? ls : us,le>ue ? le : ue);
    }
    public static bool InDay(ScheduleEntry entry,DateOnly day,TimeZoneInfo zone) => entry.AiringAt>=Start(day,zone) && entry.AiringAt<Start(day.AddDays(1),zone);
    public static bool IsDaily(IEnumerable<DateTimeOffset> dates)
    {
        var days=dates.Select(d=>DateOnly.FromDateTime(d.UtcDateTime)).Distinct().Order().ToArray();
        for(var i=0;i+3<days.Length;i++) if(days[i+3].DayNumber-days[i].DayNumber<7) return true;
        return false;
    }
}
public sealed record ScheduleResult(IReadOnlyList<ScheduleEntry> Entries,string Notice)
{
    public IReadOnlySet<string> AuthoritativeSources {get;init;}=new HashSet<string>();
}
