using System.Text.Json;
namespace Eclipse.Windows.Services;

// DPAPI user protection plus package LocalState: refresh tokens must not roam to another device.
public static class TrackerCredentialStore
{
    private static string PathFor(TrackerKind kind) => LocalProtection.LocalPath($"tracker-{kind}.protected");
    private static byte[] Transform(byte[] bytes, bool protect) => LocalProtection.Transform(bytes, protect, "Eclipse tracker account", "Windows could not protect or read the tracker credentials.");
    public static TrackerSession? Read(TrackerKind kind) { var path = PathFor(kind); if (!File.Exists(path)) return null; if (new FileInfo(path).Length > 65536) throw new IOException(); return JsonSerializer.Deserialize<TrackerSession>(Transform(File.ReadAllBytes(path), false)); }
    public static void Save(TrackerSession session) { if (session.AccessToken.Length is 0 or > 8192 || session.RefreshToken?.Length is > 8192) throw new IOException("The tracker issued credentials exceeding the supported size."); var bytes = Transform(JsonSerializer.SerializeToUtf8Bytes(session), true); if (bytes.Length > 65536) throw new IOException("The protected account exceeds the local size limit."); LocalProtection.WriteAtomically(PathFor(session.Service), bytes); }
    public static void Delete(TrackerKind kind) => File.Delete(PathFor(kind));
}
