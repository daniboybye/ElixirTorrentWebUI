using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Threading;

namespace ElixirTorrentWebUI.Launcher;

/// <summary>
/// The launcher's main thread: a plain Win32 message pump plus a way to post
/// work onto it.
///
/// This replaces WinUI 3, which the launcher used only for its message loop,
/// its dispatcher, and a hidden window it never drew into. Booting the WinUI
/// runtime cost ~11.6s before any of our code ran and pulled ~200MB of Windows
/// App SDK into the package, for a process whose entire UI is a tray icon and
/// the occasional MessageBox — both pure Win32 already.
/// </summary>
[SupportedOSPlatform("windows10.0.22000.0")]
internal sealed partial class MessageLoop : IDisposable
{
    // WM_APP + 2; TrayIcon owns WM_APP + 1 on its own window.
    private const uint WM_RUN_ACTION = 0x8000 + 2;
    private const uint WM_QUIT = 0x0012;

    private readonly ConcurrentQueue<Action> _pending = new();
    private readonly WndProcDelegate _wndProc;
    private readonly IntPtr _hwnd;
    private readonly uint _threadId;

    public MessageLoop()
    {
        _threadId = GetCurrentThreadId();
        _wndProc = WndProc;

        // A message-only window (HWND_MESSAGE) is enough: it receives posted
        // messages and never appears anywhere, which is exactly what a
        // dispatcher needs.
        _hwnd = CreateWindowExW(
            0, "static", "ElixirTorrentWebUI.Launcher.Loop",
            0, 0, 0, 0, 0,
            new IntPtr(-3), IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

        if (_hwnd == IntPtr.Zero)
        {
            throw new InvalidOperationException(
                "CreateWindowEx failed for the message loop: "
                + Marshal.GetLastPInvokeErrorMessage());
        }

        _originalWndProc = SetWindowLongPtrW(_hwnd, GWLP_WNDPROC,
            Marshal.GetFunctionPointerForDelegate(_wndProc));
    }

    private readonly IntPtr _originalWndProc;
    private const int GWLP_WNDPROC = -4;

    /// <summary>Queues <paramref name="action"/> to run on the loop thread.</summary>
    public void Post(Action action)
    {
        _pending.Enqueue(action);
        _ = PostMessageW(_hwnd, WM_RUN_ACTION, IntPtr.Zero, IntPtr.Zero);
    }

    /// <summary>Runs until <see cref="Quit"/>; returns the quit exit code.</summary>
    public int Run()
    {
        SynchronizationContext.SetSynchronizationContext(new LoopSynchronizationContext(this));

        while (GetMessageW(out var msg, IntPtr.Zero, 0, 0) > 0)
        {
            _ = TranslateMessage(ref msg);
            _ = DispatchMessageW(ref msg);
        }

        return 0;
    }

    /// <summary>Ends <see cref="Run"/>. Safe to call from any thread.</summary>
    public void Quit() => _ = PostThreadMessageW(_threadId, WM_QUIT, IntPtr.Zero, IntPtr.Zero);

    private IntPtr WndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg == WM_RUN_ACTION)
        {
            while (_pending.TryDequeue(out var action))
            {
                action();
            }

            return IntPtr.Zero;
        }

        return CallWindowProcW(_originalWndProc, hwnd, msg, wParam, lParam);
    }

    public void Dispose()
    {
        if (_hwnd != IntPtr.Zero)
        {
            _ = DestroyWindow(_hwnd);
        }
    }

    /// <summary>
    /// Makes `await` continuations resume on the loop thread, which is what the
    /// WinUI dispatcher used to provide. Without it every ConfigureAwait(true)
    /// in DesktopLifetime would resume on a thread-pool thread instead.
    /// </summary>
    private sealed class LoopSynchronizationContext(MessageLoop loop) : SynchronizationContext
    {
        public override void Post(SendOrPostCallback d, object? state) => loop.Post(() => d(state));

        public override void Send(SendOrPostCallback d, object? state)
        {
            using var done = new ManualResetEventSlim(false);
            loop.Post(() =>
            {
                try { d(state); }
                finally { done.Set(); }
            });
            done.Wait();
        }

        public override SynchronizationContext CreateCopy() => new LoopSynchronizationContext(loop);
    }

    private delegate IntPtr WndProcDelegate(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG
    {
        public IntPtr hwnd;
        public uint message;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public int ptX;
        public int ptY;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateWindowExW(
        uint dwExStyle,
        [MarshalAs(UnmanagedType.LPWStr)] string lpClassName,
        [MarshalAs(UnmanagedType.LPWStr)] string lpWindowName,
        uint dwStyle, int X, int Y, int nWidth, int nHeight,
        IntPtr hWndParent, IntPtr hMenu, IntPtr hInstance, IntPtr lpParam);

    [LibraryImport("user32.dll", EntryPoint = "SetWindowLongPtrW", SetLastError = true)]
    private static partial IntPtr SetWindowLongPtrW(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

    [LibraryImport("user32.dll", EntryPoint = "CallWindowProcW")]
    private static partial IntPtr CallWindowProcW(
        IntPtr lpPrevWndFunc, IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [LibraryImport("user32.dll", EntryPoint = "GetMessageW")]
    private static partial int GetMessageW(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool TranslateMessage(ref MSG lpMsg);

    [LibraryImport("user32.dll", EntryPoint = "DispatchMessageW")]
    private static partial IntPtr DispatchMessageW(ref MSG lpMsg);

    [LibraryImport("user32.dll", EntryPoint = "PostMessageW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool PostMessageW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [LibraryImport("user32.dll", EntryPoint = "PostThreadMessageW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool PostThreadMessageW(uint idThread, uint msg, IntPtr wParam, IntPtr lParam);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DestroyWindow(IntPtr hWnd);

    [LibraryImport("kernel32.dll")]
    private static partial uint GetCurrentThreadId();
}
