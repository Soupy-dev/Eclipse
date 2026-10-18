using System.Text.Json;
using Eclipse.Windows.Models;
using Windows.Storage;

namespace Eclipse.Windows.Services;

public sealed class PreferenceStore
{
    public static readonly JsonSerializerOptions JsonOptions = new() { PropertyNamingPolicy=JsonNamingPolicy.CamelCase, PropertyNameCaseInsensitive=true, WriteIndented=true };
    public static PreferenceStore Shared { get; } = new();
    private readonly string _path;
    public BrowsingPreferences Value { get; private set; } = new();
    public int Revision { get; private set; }
    public event EventHandler? Changed;
    public string? ReadError { get; private set; }
    private PreferenceStore()
    {
        // Package user data is local. Cloud/profile account synchronization is not implied.
        _path=Path.Combine(ApplicationData.Current.LocalFolder.Path,"browsing-preferences.json");
        try
        {
            if (File.Exists(_path))
            {
                if(new FileInfo(_path).Length>256*1024) throw new IOException();
                Value=JsonSerializer.Deserialize<BrowsingPreferences>(File.ReadAllText(_path),JsonOptions) ?? throw new JsonException();
            }
            Value.Normalize();
        }
        catch { Value=new(); ReadError="Saved browsing settings could not be read. The original file has been preserved."; }
    }
    public void Save(BrowsingPreferences value)
    {
        if(ReadError is not null) throw new IOException(ReadError);
        value.Normalize();
        var json=JsonSerializer.Serialize(value,JsonOptions);
        if(System.Text.Encoding.UTF8.GetByteCount(json)>256*1024)throw new IOException("Browsing settings exceed the local size limit.");
        var temporary=_path+".tmp";
        File.WriteAllText(temporary,json);
        File.Move(temporary,_path,true);
        Value=value; ++Revision; Changed?.Invoke(this,EventArgs.Empty);
    }
    public BrowsingPreferences Copy() => JsonSerializer.Deserialize<BrowsingPreferences>(JsonSerializer.Serialize(Value,JsonOptions),JsonOptions)!;
}

public static class LocalCredentials
{
    public static string Read(string key)
    {
        try
        {
            var path=Path.Combine(ApplicationData.Current.LocalFolder.Path,"settings.local.json");
            using var document=JsonDocument.Parse(File.ReadAllText(path));
            var value=document.RootElement.TryGetProperty(key,out var element) && element.ValueKind==JsonValueKind.String ? element.GetString()?.Trim() ?? "" : "";
            return value.Length<=2048 && !value.Contains("$(") ? value : "";
        }
        catch { return ""; }
    }
}
