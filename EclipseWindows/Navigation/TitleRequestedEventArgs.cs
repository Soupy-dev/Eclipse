namespace Eclipse.Windows.Navigation;

public sealed class TitleRequestedEventArgs(string titleId,Models.ScheduleEntry? airing=null,string? manualTmdbMatch=null) : EventArgs
{
    public string TitleId { get; } = titleId;
    public Models.ScheduleEntry? Airing {get;}=airing;
    public string? ManualTmdbMatch {get;}=manualTmdbMatch;
}
