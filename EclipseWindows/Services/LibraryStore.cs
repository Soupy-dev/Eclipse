using System.Text.Json;
using Eclipse.Windows.Models;
using Windows.Storage;
namespace Eclipse.Windows.Services;

// One local profile until the profile system is ported; never share authenticated caches with it.
public static class LocalProfile
{
    public static readonly Guid Id = Guid.Parse("ec115e00-0000-4000-a000-000000000001");
    public static Guid BookmarksId
    {
        get { var bytes = Id.ToByteArray(true); var ns = Guid.Parse("3e02ad8c-842c-4b9f-ae08-b37d4464b9c5").ToByteArray(true); for (var i = 0; i < 16; i++) bytes[i] ^= ns[i]; bytes[6] = (byte)((bytes[6] & 15) | 80); bytes[8] = (byte)((bytes[8] & 63) | 128); return new Guid(bytes, true); }
    }
}
public sealed class LocalJsonFile<T> where T : class, new()
{
    private readonly string _path; private readonly int _limit;
    private readonly Func<T, bool>? _validate;
    public string? Error { get; private set; }
    public T Value { get; private set; }
    public LocalJsonFile(string name, int limit = 16 * 1024 * 1024, Func<T, bool>? validate = null)
    {
        _limit = limit; _validate = validate; _path = Path.Combine(ApplicationData.Current.LocalFolder.Path, name);
        try { if (File.Exists(_path) && new FileInfo(_path).Length > limit) throw new IOException(); Value = File.Exists(_path) ? JsonSerializer.Deserialize<T>(File.ReadAllText(_path), PreferenceStore.JsonOptions) ?? throw new JsonException() : new(); if (validate is not null && !validate(Value)) throw new JsonException(); }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { Value = new(); Error = $"Saved {name} could not be read. The original file has been preserved."; }
    }
    public void Save(T value)
    {
        if (Error is not null) throw new IOException(Error);
        if (_validate is not null && !_validate(value)) throw new IOException("The local data is invalid or exceeds its limits.");
        var bytes = JsonSerializer.SerializeToUtf8Bytes(value, PreferenceStore.JsonOptions); if (bytes.Length > _limit) throw new IOException("The local data size limit has been reached.");
        var tmp = _path + ".tmp"; try { File.WriteAllBytes(tmp, bytes); File.Move(tmp, _path, true); Value = value; } finally { if (File.Exists(tmp)) File.Delete(tmp); }
    }
    public T Copy() => JsonSerializer.Deserialize<T>(JsonSerializer.Serialize(Value, PreferenceStore.JsonOptions), PreferenceStore.JsonOptions)!;
}
public sealed class LibraryStore
{
    public static LibraryStore Shared { get; } = new();
    private readonly LocalJsonFile<List<LibraryCollection>> _file = new($"library-{LocalProfile.Id}.json", validate: Valid);
    private static bool Valid(List<LibraryCollection> list) => list.Count + (list.Any(c => c is not null && (c.Id == LocalProfile.BookmarksId || c.Name?.Trim().Equals("Bookmarks", StringComparison.OrdinalIgnoreCase) == true)) ? 0 : 1) <= 200 && list.Where(c => c is not null && c.Id != LocalProfile.BookmarksId && c.Name?.Trim().Equals("Bookmarks", StringComparison.OrdinalIgnoreCase) != true).Select(c => c.Id).Distinct().Count() == list.Count(c => c is not null && c.Id != LocalProfile.BookmarksId && c.Name?.Trim().Equals("Bookmarks", StringComparison.OrdinalIgnoreCase) != true) && list.All(c => c is not null && c.Name is { Length: > 0 and <= 200 } && c.Description?.Length is not > 2000 && c.Id != Guid.Empty && c.Items is { Count: <= 20000 } && c.Items.All(i => i is not null && double.IsFinite(i.DateAdded) && i.SearchResult is { } m && m.Id is > 0 and <= 1000000000 && m.MediaType is "movie" or "tv" && m.Provider is null && m.VoteAverage is null or >= 0 and <= 10 && double.IsFinite(m.Popularity)));
    public event EventHandler? Changed;
    public string? Error => _file.Error;
    public IReadOnlyList<LibraryCollection> Collections => Normalize(_file.Value);
    private static List<LibraryCollection> Normalize(List<LibraryCollection> input)
    {
        var bookmarks = input.Where(c => c.Id == LocalProfile.BookmarksId || c.Name.Trim().Equals("Bookmarks", StringComparison.OrdinalIgnoreCase)).ToArray();
        var pinned = new LibraryCollection { Id = LocalProfile.BookmarksId, Name = "Bookmarks", Items = bookmarks.SelectMany(c => c.Items).GroupBy(i => i.Id).Select(g => g.MaxBy(i => i.DateAdded)!).ToList() };
        return [pinned, .. input.Where(c => !bookmarks.Contains(c)).DistinctBy(c => c.Id)];
    }
    private void Save(List<LibraryCollection> list) { _file.Save(Normalize(list)); Changed?.Invoke(this, EventArgs.Empty); }
    public Guid Create(string name, string? description)
    {
        name = ValidName(name); var list = Collections.ToList(); if (list.Count >= 200) throw new IOException("Collection limit reached."); var collection = new LibraryCollection { Name = name, Description = description?.Trim()[..Math.Min(description.Trim().Length, 2000)] }; list.Add(collection); Save(list); return collection.Id;
    }
    private static string ValidName(string name) { name = name.Trim(); if (name.Length is 0 or > 200 || name.Equals("Bookmarks", StringComparison.OrdinalIgnoreCase)) throw new IOException("Choose a name of 1–200 characters other than Bookmarks."); return name; }
    public void Rename(Guid id, string name, string? description) { if (id == LocalProfile.BookmarksId) throw new IOException("Bookmarks is a pinned collection."); var list = Collections.ToList(); var index = list.FindIndex(c => c.Id == id); if (index < 0) throw new IOException("Collection no longer exists."); list[index] = list[index] with { Name = ValidName(name), Description = description?.Trim() }; Save(list); }
    public void Delete(Guid id) { if (id == LocalProfile.BookmarksId) throw new IOException("Bookmarks is a pinned collection."); Save(Collections.Where(c => c.Id != id).ToList()); }
    public void SetMembership(MediaTitle title, IReadOnlySet<Guid> selected)
    {
        if (title.TmdbId <= 0) throw new IOException("Choose a verified TMDB match before adding this title to a local collection.");
        var snapshot = LibraryMedia.From(title); var list = Collections.Select(c => c with { Items = c.Items.ToList() }).ToList();
        foreach (var collection in list) { if (selected.Contains(collection.Id)) { if (!collection.Items.Any(i => i.Id == snapshot.Identity)) { if (collection.Items.Count >= 20000) throw new IOException("Collection item limit reached."); collection.Items.Add(new() { SearchResult = snapshot, DateAdded = (DateTimeOffset.UtcNow - new DateTimeOffset(2001, 1, 1, 0, 0, 0, TimeSpan.Zero)).TotalSeconds }); } } else collection.Items.RemoveAll(i => i.Id == snapshot.Identity); }
        Save(list);
    }
    public void Move(Guid collection, string? item, int delta)
    {
        var list = Collections.Select(c => c with { Items = c.Items.ToList() }).ToList();
        if (item is null) { var from = list.FindIndex(c => c.Id == collection); var to = from + delta; if (from < 1 || to < 1 || to >= list.Count) return; var entry = list[from]; list.RemoveAt(from); list.Insert(to, entry); }
        else { var c = list.FirstOrDefault(c => c.Id == collection); if (c is null) return; var from = c.Items.FindIndex(i => i.Id == item); var to = from + delta; if (from < 0 || to < 0 || to >= c.Items.Count) return; var entry = c.Items[from]; c.Items.RemoveAt(from); c.Items.Insert(to, entry); }
        Save(list);
    }
}
