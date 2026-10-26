using System.Runtime.InteropServices;
using System.Text;
using Windows.Storage;

namespace Eclipse.Windows.Services;

public static class LocalProtection
{
    [StructLayout(LayoutKind.Sequential)] private struct Blob { public int Size; public IntPtr Data; }
    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern bool CryptProtectData(ref Blob input, string description, IntPtr entropy, IntPtr reserved, IntPtr prompt, uint flags, out Blob output);
    [DllImport("crypt32.dll", SetLastError = true)] private static extern bool CryptUnprotectData(ref Blob input, IntPtr description, IntPtr entropy, IntPtr reserved, IntPtr prompt, uint flags, out Blob output);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr pointer);
    public static byte[] Transform(byte[] bytes, bool protect, string description, string failure)
    {
        var input = new Blob { Size = bytes.Length, Data = Marshal.AllocHGlobal(Math.Max(1, bytes.Length)) }; Blob output = default;
        try { Marshal.Copy(bytes, 0, input.Data, bytes.Length); var ok = protect ? CryptProtectData(ref input, description, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output) : CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output); if (!ok) throw new IOException(failure); var result = new byte[output.Size]; Marshal.Copy(output.Data, result, 0, result.Length); return result; }
        finally { Marshal.FreeHGlobal(input.Data); if (output.Data != IntPtr.Zero) LocalFree(output.Data); }
    }
    public static string Protect(string value, string description) => Convert.ToBase64String(Transform(Encoding.UTF8.GetBytes(value), true, description, "Windows could not protect this value."));
    public static string Unprotect(string value) => Encoding.UTF8.GetString(Transform(Convert.FromBase64String(value), false, "", "Windows could not read this protected value."));
    public static void WriteAtomically(string path, byte[] bytes) { var temporary = path + ".tmp"; try { File.WriteAllBytes(temporary, bytes); File.Move(temporary, path, true); } finally { if (File.Exists(temporary)) File.Delete(temporary); } }
    public static string LocalPath(string name) => Path.Combine(ApplicationData.Current.LocalFolder.Path, name);
}
