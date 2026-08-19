using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace ElixirTorrentWebUI.Launcher;

/// <summary>
/// Thin wrapper around <c>user32.MessageBoxW</c>. The launcher has no XAML
/// runtime and no window of its own, so the Win32 message box is the whole
/// modal story here.
/// </summary>
[SupportedOSPlatform("windows10.0.22000.0")]
internal static partial class UserPrompt
{
    private const string Caption = "ElixirTorrent Web";

    public static void Error(string message) =>
        _ = MessageBoxW(IntPtr.Zero, message, Caption, MB_OK | MB_ICONERROR | MB_TOPMOST);

    public static void Warn(string message) =>
        _ = MessageBoxW(IntPtr.Zero, message, Caption, MB_OK | MB_ICONWARNING | MB_TOPMOST);

    /// <summary>
    /// Yes / No / Cancel prompt. Returns 6 for Yes, 7 for No, 2 for Cancel —
    /// same integers Win32 documents for MessageBox return values.
    /// </summary>
    public static int Question(string message, string caption)
    {
        return MessageBoxW(IntPtr.Zero, message, caption,
            MB_YESNOCANCEL | MB_ICONQUESTION | MB_TOPMOST);
    }

    public const int IDYES = 6;
    public const int IDNO = 7;
    public const int IDCANCEL = 2;

    private const uint MB_OK = 0x00000000;
    private const uint MB_YESNOCANCEL = 0x00000003;
    private const uint MB_ICONERROR = 0x00000010;
    private const uint MB_ICONQUESTION = 0x00000020;
    private const uint MB_ICONWARNING = 0x00000030;
    private const uint MB_TOPMOST = 0x00040000;

    [LibraryImport("user32.dll", EntryPoint = "MessageBoxW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    private static partial int MessageBoxW(
        IntPtr hWnd,
        string lpText,
        string lpCaption,
        uint uType);
}
