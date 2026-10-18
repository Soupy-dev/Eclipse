namespace Eclipse.Windows.Models;
public sealed record ScheduleDisplayRow(ScheduleEntry Entry,bool Local)
{
    public string Time=>Entry.DisplayTime(Local);
    public string Title=>Entry.Title;
    public string Episode=>Entry.EpisodeLabel;
    public string Provider=>(Entry.TimetableProvider??Entry.Provider)+(Local?" · Local time":" · UTC");
}
public sealed record ScheduleDay(DateOnly Date,int Count)
{
    public DateOnly Today {get;init;}=DateOnly.FromDateTime(DateTime.Now);
    public string DayLabel=>Date==Today?"Today":Date==Today.AddDays(1)?"Tomorrow":Date.ToString("ddd");
    public string Number=>Date.Day.ToString();
    public string CountLabel=>Count.ToString();
    public string Heading=>$"{Date:dddd, MMMM d}";
    public override string ToString()=>$"{Date:ddd, MMM d} · {Count} episode{(Count==1?"":"s")}";
}
