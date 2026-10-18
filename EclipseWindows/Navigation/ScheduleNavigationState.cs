namespace Eclipse.Windows.Navigation;

// Only navigation identifiers survive Back; calendar rows, artwork and views do not.
public sealed class ScheduleNavigationState
{
    public DateOnly? SelectedDay { get; set; }
    public string? VisibleEntryId { get; set; }
    public string? FocusEntryId { get; set; }
    public bool RestoreKeyboardFocus { get; set; }
}
