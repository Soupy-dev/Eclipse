using Eclipse.Windows.Services;
namespace Eclipse.Windows.Navigation;

public sealed class LibraryNavigationState
{
    public Guid? Collection { get; set; }
    public TrackerKind? Service { get; set; }
    public string List { get; set; } = "all";
    public int Kind { get; set; }
    public string Filter { get; set; } = "";
    public string? Status { get; set; }
    public string? Genre { get; set; }
    public string? FocusId { get; set; }
    public double Offset { get; set; }
}
