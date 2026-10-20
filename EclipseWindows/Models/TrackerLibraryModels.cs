namespace Eclipse.Windows.Models;

using Eclipse.Windows.Services;
public sealed record TrackerList(string Id, string Name);
public sealed record TrackerEntry(TrackerKind Service, int RemoteId, int ListEntryId, MediaTitle Title, string Status, int Progress, double Score, IReadOnlyList<string> Genres, IReadOnlyList<string> CustomLists) : System.ComponentModel.INotifyPropertyChanged
{
    private MediaTitle _title = Title;
    public MediaTitle Title { get => _title; set { _title = value; PropertyChanged?.Invoke(this, new(nameof(Title))); } }
    public event System.ComponentModel.PropertyChangedEventHandler? PropertyChanged;
    public int? EpisodeCount { get; init; }
    public bool CustomListsKnown { get; init; }
    public string Summary => $"{Status.Replace('_', ' ')}" + (Progress > 0 ? $" · {Progress} episodes" : "") + (Score > 0 ? $" · {Score:0.#}/10" : "");
    public override string ToString() => Title.Title;
}
public sealed record TrackerLibraryResult(IReadOnlyList<TrackerEntry> Entries, IReadOnlyList<TrackerList> Lists, bool Complete, string Notice);
public sealed record TrackerEdit(string? Status = null, int? Progress = null, double? Score = null);
