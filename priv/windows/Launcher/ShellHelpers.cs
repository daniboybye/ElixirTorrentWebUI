using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace ElixirTorrentWebUI.Launcher;

/// <summary>
/// Blocking shell helpers exposed as one-shot CLI subcommands. No WinForms —
/// the folder picker talks directly to the Vista+ IFileOpenDialog COM API,
/// which is the same interface every modern Windows folder picker (Explorer
/// itself, WinUI 3's Windows.Storage.Pickers.FolderPicker, WinForms'
/// FolderBrowserDialog) is built on. Standalone so `--pick-folder` never
/// pays the WinUI 3 boot cost.
/// </summary>
[SupportedOSPlatform("windows10.0.22000.0")]
internal static class ShellHelpers
{
    /// <summary>
    /// Shows the modern Vista+ folder picker (COM IFileOpenDialog with
    /// FOS_PICKFOLDERS) and prints the chosen path. Cancel/close returns
    /// exit 0 with empty stdout — callers treat that as "user cancelled".
    /// </summary>
    public static int PickFolder(LauncherLog log)
    {
        try
        {
            var picked = FolderPickerCom.Pick(
                title: "Choose the folder where torrent files will be saved");

            if (!string.IsNullOrWhiteSpace(picked))
            {
                Console.Out.WriteLine(picked);
            }

            return 0;
        }
        catch (Exception ex)
        {
            log.Error("PickFolder failed", ex);
            return 2;
        }
    }

    /// <summary>Opens a path with its default application via ShellExecute.</summary>
    public static int OpenFile(string path, LauncherLog log)
    {
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
        {
            log.Warn($"OpenFile: missing target {path}");
            return 1;
        }

        try
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = path,
                UseShellExecute = true,
            };

            using var process = Process.Start(startInfo);
            return 0;
        }
        catch (Exception ex)
        {
            log.Error($"OpenFile failed for {path}", ex);
            return 2;
        }
    }

    private static string Quote(string value) => "\"" + value + "\"";

    /// <summary>
    /// Selects the file (or opens the directory) in a new Explorer window.
    /// </summary>
    public static int Reveal(string path, LauncherLog log)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return 1;
        }

        try
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = "explorer.exe",
                UseShellExecute = false,
                CreateNoWindow = false,
            };

            // Backslashes, and a canonical drive letter. The caller is Elixir,
            // whose Path functions normalize to "c:/Users/..." — most Windows
            // APIs accept that, but explorer's /select, does not: it silently
            // opens a default folder instead of selecting anything, which looks
            // exactly like "it opened the wrong place".
            var full = Path.GetFullPath(path);

            // Raw Arguments, not ArgumentList: explorer wants the exact string
            // /select,"C:\dir\file" — one token, with the quotes around the
            // path only. ArgumentList quotes each element separately, so
            // "/select," and the path arrive as two operands and explorer
            // ignores the switch.
            if (Directory.Exists(full))
            {
                startInfo.Arguments = Quote(full);
            }
            else if (File.Exists(full))
            {
                startInfo.Arguments = "/select," + Quote(full);
            }
            else
            {
                log.Warn($"Reveal: target missing {full}");
                return 1;
            }

            log.Info($"Reveal: explorer.exe {startInfo.Arguments}");

            using var process = Process.Start(startInfo);
            return 0;
        }
        catch (Exception ex)
        {
            log.Error($"Reveal failed for {path}", ex);
            return 2;
        }
    }
}

/// <summary>
/// A throwaway top-level window used purely to own a shell dialog and to carry
/// foreground activation.
///
/// The picker runs in a one-shot CLI process spawned by the release, which has
/// no window of its own. A dialog with no owner is not brought forward by the
/// shell, so it lands behind the browser the user is actually looking at. A
/// message-only window will not do — those cannot own dialogs — so this is a
/// real (if zero-sized and unpainted) top-level window.
/// </summary>
[SupportedOSPlatform("windows10.0.22000.0")]
internal sealed partial class OwnerWindow : IDisposable
{
    private const uint WS_POPUP = 0x80000000;
    private const uint WS_EX_TOOLWINDOW = 0x00000080;
    private const uint WS_EX_TOPMOST = 0x00000008;
    private const int SW_SHOWNORMAL = 1;

    private static readonly IntPtr HWND_TOPMOST = new(-1);
    private const uint SWP_NOMOVE = 0x0002;
    private const uint SWP_NOSIZE = 0x0001;
    private const uint SWP_SHOWWINDOW = 0x0040;

    public IntPtr Handle { get; private set; }

    private OwnerWindow(IntPtr handle) => Handle = handle;

    public static OwnerWindow Create()
    {
        // "static" is a stock system class, so there is no window class to
        // register (and none to leak) for a window this short-lived.
        // TOPMOST, not just foreground. This process is spawned by the release
        // and has no foreground rights, so SetForegroundWindow is ignored by
        // Windows — which is why the picker kept opening behind the browser
        // while the browser's own file dialog came up in front. A topmost owner
        // places the dialog above other windows without needing those rights.
        var hwnd = CreateWindowExW(
            WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
            "static",
            string.Empty,
            WS_POPUP,
            0, 0, 0, 0,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

        if (hwnd != IntPtr.Zero)
        {
            _ = ShowWindow(hwnd, SW_SHOWNORMAL);
            _ = SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);

            // Still attempted: when the launcher *does* happen to hold
            // foreground rights this also gives the dialog keyboard focus.
            _ = SetForegroundWindow(hwnd);
        }

        return new OwnerWindow(hwnd);
    }

    public void Dispose()
    {
        if (Handle != IntPtr.Zero)
        {
            _ = DestroyWindow(Handle);
            Handle = IntPtr.Zero;
        }
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateWindowExW(
        uint dwExStyle,
        [MarshalAs(UnmanagedType.LPWStr)] string lpClassName,
        [MarshalAs(UnmanagedType.LPWStr)] string lpWindowName,
        uint dwStyle,
        int X, int Y, int nWidth, int nHeight,
        IntPtr hWndParent, IntPtr hMenu, IntPtr hInstance, IntPtr lpParam);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetForegroundWindow(IntPtr hWnd);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetWindowPos(
        IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DestroyWindow(IntPtr hWnd);
}

/// <summary>
/// Minimal COM wrapper around IFileOpenDialog with FOS_PICKFOLDERS.
/// Kept internal to <see cref="ShellHelpers"/>; no ambient state.
/// </summary>
[SupportedOSPlatform("windows10.0.22000.0")]
internal static class FolderPickerCom
{
    // FILEOPENDIALOG_OPTIONS bits used here.
    private const uint FOS_PICKFOLDERS = 0x00000020;
    private const uint FOS_FORCEFILESYSTEM = 0x00000040;
    private const uint FOS_PATHMUSTEXIST = 0x00000800;
    private const uint FOS_FILEMUSTEXIST = 0x00001000;

    private const uint SIGDN_FILESYSPATH = 0x80058000;

    // HRESULT for user-cancelled dialog: 0x800704C7.
    private const int ERROR_CANCELLED_HRESULT = unchecked((int)0x800704C7);

    public static string? Pick(string title)
    {
        var dialog = (IFileOpenDialog)new FileOpenDialogCoClass();

        try
        {
            dialog.GetOptions(out var options);
            dialog.SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM
                | FOS_PATHMUSTEXIST | FOS_FILEMUSTEXIST);

            dialog.SetTitle(title);

            // Own the dialog with a real top-level window. With IntPtr.Zero the
            // shell has nothing to parent to, so the picker opens behind
            // whatever the user was looking at — this process has no window of
            // its own, being a one-shot CLI invocation from the release.
            using var owner = OwnerWindow.Create();

            // Show is [PreserveSig]: it RETURNS an HRESULT, it does not throw.
            // Cancel comes back as ERROR_CANCELLED, and ignoring it meant we
            // went on to call GetResult on a dialog that has no result, which
            // fails with E_UNEXPECTED "Catastrophic failure".
            var hr = dialog.Show(owner.Handle);
            if (hr == ERROR_CANCELLED_HRESULT)
            {
                return null;
            }

            if (hr < 0)
            {
                Marshal.ThrowExceptionForHR(hr);
            }

            dialog.GetResult(out var item);
            try
            {
                item.GetDisplayName(SIGDN_FILESYSPATH, out var pszPath);
                try
                {
                    return Marshal.PtrToStringUni(pszPath);
                }
                finally
                {
                    if (pszPath != IntPtr.Zero)
                    {
                        Marshal.FreeCoTaskMem(pszPath);
                    }
                }
            }
            finally
            {
                Marshal.ReleaseComObject(item);
            }
        }
        finally
        {
            Marshal.ReleaseComObject(dialog);
        }
    }

    // -- COM interop -----------------------------------------------------------

    [ComImport]
    [Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")]
    [ClassInterface(ClassInterfaceType.None)]
    private class FileOpenDialogCoClass
    {
    }

    [ComImport]
    [Guid("d57c7288-d4ad-4768-be02-9d969532d960")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileOpenDialog
    {
        // IModalWindow
        [PreserveSig]
        int Show(IntPtr hwndOwner);

        // IFileDialog
        void SetFileTypes(uint cFileTypes, [MarshalAs(UnmanagedType.LPArray)] IntPtr rgFilterSpec);
        void SetFileTypeIndex(uint iFileType);
        void GetFileTypeIndex(out uint piFileType);
        void Advise(IntPtr pfde, out uint pdwCookie);
        void Unadvise(uint dwCookie);
        void SetOptions(uint fos);
        void GetOptions(out uint pfos);
        void SetDefaultFolder(IShellItem psi);
        void SetFolder(IShellItem psi);
        void GetFolder(out IShellItem ppsi);
        void GetCurrentSelection(out IShellItem ppsi);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string pszName);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string pszText);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
        void GetResult(out IShellItem ppsi);
        void AddPlace(IShellItem psi, int fdap);
        void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string pszDefaultExtension);
        void Close(int hr);
        void SetClientGuid([In] ref Guid guid);
        void ClearClientData();
        void SetFilter(IntPtr pFilter);

        // IFileOpenDialog
        void GetResults(out IntPtr ppenum);
        void GetSelectedItems(out IntPtr ppsai);
    }

    [ComImport]
    [Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItem
    {
        void BindToHandler(IntPtr pbc, [In] ref Guid bhid, [In] ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(uint sigdnName, out IntPtr ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, uint hint, out int piOrder);
    }
}
