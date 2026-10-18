namespace Eclipse.Windows.Navigation;

public sealed class TitleRequestedEventArgs(string titleId,Models.ScheduleEntry? airing=null) : EventArgs
{
    public string TitleId { get; } = titleId;
    public Models.ScheduleEntry? Airing {get;}=airing;
}
