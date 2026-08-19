using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace ElixirTorrentWebUI.Launcher;

/// <summary>
/// System tray icon backed entirely by Shell_NotifyIcon P/Invoke — no
/// WinForms, no external NuGet. The icon lives on its own message-only HWND
/// so its lifetime is independent of anything else the launcher creates.
///
/// Actions:
///   * Left double-click → Open (opens the browser).
///   * Right click / context key → popup menu (Open, separator, Quit).
/// </summary>
[SupportedOSPlatform("windows10.0.22000.0")]
internal sealed partial class TrayIcon : IDisposable
{
    private const uint WM_TRAYICON = 0x8000 + 1;   // WM_APP + 1
    private const int TrayIconId = 1;
    private const int MenuIdOpen = 100;
    private const int MenuIdQuit = 200;

    private readonly Action _onOpen;
    private readonly Action _onQuit;
    private readonly LauncherLog _log;

    private readonly IntPtr _hIcon;
    private readonly bool _ownsIcon;
    private readonly IntPtr _hwnd;
    private readonly WndProcDelegate _wndProc;
    private readonly GCHandle _wndProcHandle;
    private readonly ushort _classAtom;

    private bool _iconAdded;
    private bool _disposed;

    public TrayIcon(string tooltip, Action onOpen, Action onQuit, LauncherLog log)
    {
        _onOpen = onOpen;
        _onQuit = onQuit;
        _log = log;

        (_hIcon, _ownsIcon) = LoadOwnIcon();
        _wndProc = TrayWndProc;
        _wndProcHandle = GCHandle.Alloc(_wndProc);

        (_hwnd, _classAtom) = CreateMessageWindow();

        var nid = new NOTIFYICONDATAW
        {
            cbSize = (uint)Marshal.SizeOf<NOTIFYICONDATAW>(),
            hWnd = _hwnd,
            uID = TrayIconId,
            uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP,
            uCallbackMessage = WM_TRAYICON,
            hIcon = _hIcon,
            szTip = TruncateTooltip(tooltip),
            uVersion = NOTIFYICON_VERSION_4,
        };

        _iconAdded = Shell_NotifyIconW(NIM_ADD, ref nid);
        if (!_iconAdded)
        {
            log.Warn($"Shell_NotifyIcon NIM_ADD failed: {Marshal.GetLastPInvokeErrorMessage()}");
            return;
        }

        // Opt into modern (Vista+) notification semantics.
        _ = Shell_NotifyIconW(NIM_SETVERSION, ref nid);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;

        if (_iconAdded)
        {
            var nid = new NOTIFYICONDATAW
            {
                cbSize = (uint)Marshal.SizeOf<NOTIFYICONDATAW>(),
                hWnd = _hwnd,
                uID = TrayIconId,
            };
            _ = Shell_NotifyIconW(NIM_DELETE, ref nid);
            _iconAdded = false;
        }

        if (_hwnd != IntPtr.Zero)
        {
            _ = DestroyWindow(_hwnd);
        }

        if (_classAtom != 0)
        {
            _ = UnregisterClassW(new IntPtr(_classAtom), GetModuleHandleW(null));
        }

        if (_ownsIcon && _hIcon != IntPtr.Zero)
        {
            _ = DestroyIcon(_hIcon);
        }

        if (_wndProcHandle.IsAllocated)
        {
            _wndProcHandle.Free();
        }
    }

    // -- Window/message plumbing ------------------------------------------------

    private (IntPtr Hwnd, ushort Atom) CreateMessageWindow()
    {
        var className = $"ElixirTorrentWebUI.Launcher.TrayHost.{Environment.ProcessId}";
        var moduleHandle = GetModuleHandleW(null);

        var wc = new WNDCLASSEXW
        {
            cbSize = (uint)Marshal.SizeOf<WNDCLASSEXW>(),
            style = 0,
            lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_wndProc),
            cbClsExtra = 0,
            cbWndExtra = 0,
            hInstance = moduleHandle,
            hIcon = IntPtr.Zero,
            hCursor = IntPtr.Zero,
            hbrBackground = IntPtr.Zero,
            lpszMenuName = IntPtr.Zero,
            lpszClassName = className,
            hIconSm = IntPtr.Zero,
        };

        var atom = RegisterClassExW(ref wc);
        if (atom == 0)
        {
            throw new InvalidOperationException(
                "RegisterClassEx failed for tray host: " + Marshal.GetLastPInvokeErrorMessage());
        }

        var hwnd = CreateWindowExW(
            dwExStyle: 0,
            lpClassName: className,
            lpWindowName: "ElixirTorrentWebUI.Launcher.TrayHost",
            dwStyle: 0,
            X: 0, Y: 0, nWidth: 0, nHeight: 0,
            hWndParent: HWND_MESSAGE,
            hMenu: IntPtr.Zero,
            hInstance: moduleHandle,
            lpParam: IntPtr.Zero);

        if (hwnd == IntPtr.Zero)
        {
            _ = UnregisterClassW(new IntPtr(atom), moduleHandle);
            throw new InvalidOperationException(
                "CreateWindowEx failed for tray host: " + Marshal.GetLastPInvokeErrorMessage());
        }

        return (hwnd, atom);
    }

    private IntPtr TrayWndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        try
        {
            if (msg == WM_TRAYICON)
            {
                // With NOTIFYICON_VERSION_4, iconId is in HIWORD(wParam),
                // event is in LOWORD(lParam), cursor pos in wParam (x,y).
                var eventCode = (uint)((long)lParam & 0xFFFF);

                switch (eventCode)
                {
                    case WM_LBUTTONDBLCLK:
                        _onOpen();
                        break;

                    case WM_CONTEXTMENU:
                    case WM_RBUTTONUP:
                        ShowContextMenu();
                        break;
                }

                return IntPtr.Zero;
            }
        }
        catch (Exception ex)
        {
            _log.Warn($"TrayWndProc threw: {ex.Message}");
        }

        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }

    private void ShowContextMenu()
    {
        var menu = CreatePopupMenu();
        if (menu == IntPtr.Zero)
        {
            return;
        }

        try
        {
            _ = AppendMenuW(menu, MF_STRING, (IntPtr)MenuIdOpen, "Open UI");
            _ = AppendMenuW(menu, MF_SEPARATOR, IntPtr.Zero, null);
            _ = AppendMenuW(menu, MF_STRING, (IntPtr)MenuIdQuit, "Quit");

            if (!GetCursorPos(out var pt))
            {
                pt = default;
            }

            // TrackPopupMenu requires the owner window to be the foreground
            // one, otherwise the menu doesn't disappear on outside-click.
            _ = SetForegroundWindow(_hwnd);

            var chosen = TrackPopupMenuEx(
                menu,
                TPM_RETURNCMD | TPM_LEFTALIGN | TPM_RIGHTBUTTON,
                pt.X,
                pt.Y,
                _hwnd,
                IntPtr.Zero);

            _ = PostMessageW(_hwnd, WM_NULL, IntPtr.Zero, IntPtr.Zero);

            switch (chosen)
            {
                case MenuIdOpen:
                    _onOpen();
                    break;

                case MenuIdQuit:
                    _onQuit();
                    break;
            }
        }
        finally
        {
            _ = DestroyMenu(menu);
        }
    }

    // -- Icon --------------------------------------------------------------------

    private static (IntPtr Handle, bool Owned) LoadOwnIcon()
    {
        // Prefer the icon embedded in the launcher exe (ApplicationIcon).
        // Fallback to the system application icon so tray always shows something.
        var large = IntPtr.Zero;
        var small = IntPtr.Zero;

        try
        {
            // ExtractIconEx fills both out-params, so returning one without
            // destroying the other leaked an icon handle for the process's
            // lifetime.
            var extracted = ExtractIconExW(Paths.Current.LauncherExe, 0, out large, out small, 1);
            if (extracted > 0 && large != IntPtr.Zero)
            {
                if (small != IntPtr.Zero)
                {
                    _ = DestroyIcon(small);
                }

                return (large, true);
            }

            if (extracted > 0 && small != IntPtr.Zero)
            {
                return (small, true);
            }
        }
        catch
        {
            // Fall through to the system icon.
        }

        if (large != IntPtr.Zero)
        {
            _ = DestroyIcon(large);
        }

        if (small != IntPtr.Zero)
        {
            _ = DestroyIcon(small);
        }

        // IDI_APPLICATION = 32512. Shared system icon: it must never be passed
        // to DestroyIcon, which is why Dispose tracks ownership separately.
        return (LoadIconW(IntPtr.Zero, new IntPtr(32512)), false);
    }

    private static string TruncateTooltip(string tooltip)
    {
        // szTip is 128 wide chars, null terminator inclusive.
        const int max = 127;
        return tooltip.Length <= max ? tooltip : tooltip[..max];
    }

    // -- P/Invoke ---------------------------------------------------------------

    private delegate IntPtr WndProcDelegate(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    private const uint NIM_ADD = 0x00000000;
    private const uint NIM_DELETE = 0x00000002;
    private const uint NIM_SETVERSION = 0x00000004;

    private const uint NIF_MESSAGE = 0x00000001;
    private const uint NIF_ICON = 0x00000002;
    private const uint NIF_TIP = 0x00000004;
    private const uint NIF_SHOWTIP = 0x00000080;

    private const uint NOTIFYICON_VERSION_4 = 4;

    private const uint WM_LBUTTONDBLCLK = 0x0203;
    private const uint WM_RBUTTONUP = 0x0205;
    private const uint WM_CONTEXTMENU = 0x007B;
    private const uint WM_NULL = 0x0000;

    private const uint MF_STRING = 0x00000000;
    private const uint MF_SEPARATOR = 0x00000800;

    private const uint TPM_RETURNCMD = 0x0100;
    private const uint TPM_LEFTALIGN = 0x0000;
    private const uint TPM_RIGHTBUTTON = 0x0002;

    private static readonly IntPtr HWND_MESSAGE = new(-3);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NOTIFYICONDATAW
    {
        public uint cbSize;
        public IntPtr hWnd;
        public uint uID;
        public uint uFlags;
        public uint uCallbackMessage;
        public IntPtr hIcon;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szTip;

        public uint dwState;
        public uint dwStateMask;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string szInfo;

        public uint uVersion;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string szInfoTitle;

        public uint dwInfoFlags;
        public Guid guidItem;
        public IntPtr hBalloonIcon;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WNDCLASSEXW
    {
        public uint cbSize;
        public uint style;
        public IntPtr lpfnWndProc;
        public int cbClsExtra;
        public int cbWndExtra;
        public IntPtr hInstance;
        public IntPtr hIcon;
        public IntPtr hCursor;
        public IntPtr hbrBackground;
        public IntPtr lpszMenuName;

        [MarshalAs(UnmanagedType.LPWStr)]
        public string lpszClassName;

        public IntPtr hIconSm;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int X;
        public int Y;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Shell_NotifyIconW(uint dwMessage, ref NOTIFYICONDATAW lpData);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern ushort RegisterClassExW(ref WNDCLASSEXW lpwcx);

    [LibraryImport("user32.dll", EntryPoint = "UnregisterClassW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool UnregisterClassW(IntPtr lpClassName, IntPtr hInstance);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateWindowExW(
        uint dwExStyle,
        [MarshalAs(UnmanagedType.LPWStr)] string lpClassName,
        [MarshalAs(UnmanagedType.LPWStr)] string lpWindowName,
        uint dwStyle,
        int X, int Y, int nWidth, int nHeight,
        IntPtr hWndParent,
        IntPtr hMenu,
        IntPtr hInstance,
        IntPtr lpParam);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DestroyWindow(IntPtr hWnd);

    [LibraryImport("user32.dll", EntryPoint = "DefWindowProcW", SetLastError = false)]
    private static partial IntPtr DefWindowProcW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [LibraryImport("kernel32.dll", EntryPoint = "GetModuleHandleW", StringMarshalling = StringMarshalling.Utf16)]
    private static partial IntPtr GetModuleHandleW([MarshalAs(UnmanagedType.LPWStr)] string? lpModuleName);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr LoadIconW(IntPtr hInstance, IntPtr lpIconName);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DestroyIcon(IntPtr hIcon);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern uint ExtractIconExW(
        [MarshalAs(UnmanagedType.LPWStr)] string lpszFile,
        int nIconIndex,
        out IntPtr phiconLarge,
        out IntPtr phiconSmall,
        uint nIcons);

    [LibraryImport("user32.dll", SetLastError = true)]
    private static partial IntPtr CreatePopupMenu();

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DestroyMenu(IntPtr hMenu);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AppendMenuW(
        IntPtr hMenu,
        uint uFlags,
        IntPtr uIDNewItem,
        [MarshalAs(UnmanagedType.LPWStr)] string? lpNewItem);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int TrackPopupMenuEx(
        IntPtr hmenu,
        uint fuFlags,
        int x, int y,
        IntPtr hwnd,
        IntPtr lptpm);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetCursorPos(out POINT lpPoint);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetForegroundWindow(IntPtr hWnd);

    [LibraryImport("user32.dll", EntryPoint = "PostMessageW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool PostMessageW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
}
