using System.Runtime.InteropServices;
using System.Text.Json;
using Windows.Storage;
namespace Eclipse.Windows.Services;

// DPAPI user protection plus package LocalState: refresh tokens must not roam to another device.
public static class TrackerCredentialStore
{
    [StructLayout(LayoutKind.Sequential)] private struct Blob { public int Size; public IntPtr Data; }
    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern bool CryptProtectData(ref Blob input, string description, IntPtr entropy, IntPtr reserved, IntPtr prompt, uint flags, out Blob output);
    [DllImport("crypt32.dll", SetLastError = true)] private static extern bool CryptUnprotectData(ref Blob input, IntPtr description, IntPtr entropy, IntPtr reserved, IntPtr prompt, uint flags, out Blob output);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr pointer);
    private static string PathFor(TrackerKind kind) => Path.Combine(ApplicationData.Current.LocalFolder.Path, $"tracker-{kind}.protected");
    private static byte[] Transform(byte[] bytes, bool protect)
    {
        var input = new Blob { Size = bytes.Length, Data = Marshal.AllocHGlobal(bytes.Length) }; Blob output = default;
        try { Marshal.Copy(bytes, 0, input.Data, bytes.Length); var ok = protect ? CryptProtectData(ref input, "Eclipse tracker account", IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output) : CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output); if (!ok) throw new IOException("Windows could not protect or read the tracker credentials."); var result = new byte[output.Size]; Marshal.Copy(output.Data, result, 0, result.Length); return result; }
        finally { Marshal.FreeHGlobal(input.Data); if (output.Data != IntPtr.Zero) LocalFree(output.Data); }
    }
    public static TrackerSession? Read(TrackerKind kind) { var path = PathFor(kind); if (!File.Exists(path)) return null; if (new FileInfo(path).Length > 65536) throw new IOException(); return JsonSerializer.Deserialize<TrackerSession>(Transform(File.ReadAllBytes(path), false)); }
    public static void Save(TrackerSession session) { if (session.AccessToken.Length is 0 or > 8192 || session.RefreshToken?.Length is > 8192) throw new IOException("The tracker issued credentials exceeding the supported size."); var bytes = Transform(JsonSerializer.SerializeToUtf8Bytes(session), true); if (bytes.Length > 65536) throw new IOException("The protected account exceeds the local size limit."); var path = PathFor(session.Service); var temporary = path + ".tmp"; try { File.WriteAllBytes(temporary, bytes); File.Move(temporary, path, true); } finally { if (File.Exists(temporary)) File.Delete(temporary); } }
    public static void Delete(TrackerKind kind) => File.Delete(PathFor(kind));
}
