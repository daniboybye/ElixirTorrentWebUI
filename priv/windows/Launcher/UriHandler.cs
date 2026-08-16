using Microsoft.Win32;
using System.Diagnostics;
using System.Runtime.Versioning;
using System.Threading;

namespace ElixirTorrentWebUI.Launcher;

/// <summary>
/// Per-user (HKCU) registration for the <c>magnet:</c> URL protocol and the
/// <c>.torrent</c> file extension, plus the RegisteredApplications entry that
/// lets Settings › Default Apps offer this launcher as an option.
/// No HKLM writes; no elevation required.
/// </summary>
[SupportedOSPlatform("windows")]
internal static class UriHandler
{
    private const string ProgIdTorrent = "ElixirTorrentWebUI.Torrent";
    private const string ProgIdMagnet = "ElixirTorrentWebUI.Magnet";
    private const string AppName = "ElixirTorrentWebUI";
    private const string AppDisplayName = "ElixirTorrent Web";
    private const string AppDescription =
        "A native Windows launcher for the ElixirTorrent BitTorrent engine.";
    private const string TorrentExtension = ".torrent";
    private const string MagnetScheme = "magnet";

    private const string ClassesRoot = @"Software\Classes";
    private const string RegisteredAppsRoot = @"Software\RegisteredApplications";

    /// <summary>
    /// Our HKCU root. <see cref="DefaultHandlerPrompt"/> keeps its "stop asking
    /// me" flag directly under it, so <see cref="Unregister"/> must never
    /// delete this key as a whole.
    /// </summary>
    internal const string AppRegistryRoot = @"Software\ElixirTorrentWebUI";

    private const string CapabilitiesPath = AppRegistryRoot + @"\Capabilities";

    private const string TorrentUserChoicePath =
        @"Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.torrent\UserChoice";

    private const string MagnetUserChoicePath =
        @"Software\Microsoft\Windows\CurrentVersion\Explorer\Associations\UrlAssociations\magnet\UserChoice";

    private const string DefaultAppsSettingsUri =
        "ms-settings:defaultapps?registeredAppUser=" + AppName;

    /// <summary>
    /// Re-writes our registration if (and only if) it already exists, so the
    /// stored exe path and icon index follow the app.
    ///
    /// This is a portable ZIP: the user can move or replace the folder, and an
    /// upgrade can change what the registration should say — the icon index did
    /// exactly that. Without this the shell keeps pointing at whatever the
    /// first `--register` wrote, which shows up as a stale or missing file
    /// icon, or as double-click opening nothing after a move. Never registers
    /// uninvited: no ProgID, no write.
    /// </summary>
    public static void RefreshIfRegistered(string launcherExe, LauncherLog log)
    {
        try
        {
            using var progId = Registry.CurrentUser.OpenSubKey($@"{ClassesRoot}\{ProgIdTorrent}");
            if (progId is null)
            {
                return;
            }

            _ = Register(launcherExe, log);
            log.Info("Refreshed existing HKCU registration");
        }
        catch (Exception ex)
        {
            log.Warn($"Refreshing registration failed: {ex.Message}");
        }
    }

    public static int Register(string launcherExe, LauncherLog log)
    {
        try
        {
            using var classes = Registry.CurrentUser.CreateSubKey(ClassesRoot, writable: true);

            WriteMagnetHandler(classes, launcherExe);
            WriteTorrentHandler(classes, launcherExe);
            WriteApplicationCapabilities(launcherExe);

            log.Info("Registered magnet: and .torrent handlers under HKCU");
            NotifyShellAssociationChanged();
            return 0;
        }
        catch (Exception ex)
        {
            log.Error("Register failed", ex);
            return 2;
        }
    }

    /// <summary>
    /// Prints a compact JSON payload — {"torrent":true,"magnet":false} — that
    /// the release's DefaultHandler module reads to decide whether to nag.
    /// </summary>
    public static int CheckDefaults(LauncherLog log)
    {
        try
        {
            PrintStatus(ReadStatus());
            return 0;
        }
        catch (Exception ex)
        {
            log.Error("CheckDefaults failed", ex);
            PrintStatus(default);
            return 0;
        }
    }

    /// <summary>
    /// Blocks — polling <see cref="ReadStatus"/> on a short interval, all
    /// within this one process — until both are default or ~15s elapses,
    /// then prints the same JSON shape <see cref="CheckDefaults"/> does. This
    /// is what the release's DefaultHandler.await_default/0 shells out to
    /// instead of re-invoking --check-defaults on a fixed timer: it lets the
    /// caller be notified as soon as this process notices the flip, rather
    /// than guessing a poll interval. Windows 10 1903+ forbids programmatic
    /// UserChoice overrides (see <see cref="RegisterDefaults"/>), so this
    /// realistically only converges if the user finishes the
    /// ms-settings:defaultapps flow while this is running — timing out is
    /// the common case, not a bug.
    /// </summary>
    public static int AwaitDefaultStatus(LauncherLog log)
    {
        try
        {
            var deadline = DateTime.UtcNow.AddSeconds(15);
            var status = ReadStatus();

            while (!status.BothDefault && DateTime.UtcNow < deadline)
            {
                Thread.Sleep(150);
                status = ReadStatus();
            }

            PrintStatus(status);
            return 0;
        }
        catch (Exception ex)
        {
            log.Error("AwaitDefaultStatus failed", ex);
            PrintStatus(default);
            return 0;
        }
    }

    /// <summary>
    /// Re-writes the HKCU handler registration and hands off to the
    /// Settings › Default Apps page scoped to this app so the user can
    /// confirm — Windows 10+ intentionally forbids programmatic overrides.
    /// </summary>
    public static int RegisterDefaults(string launcherExe, LauncherLog log)
    {
        var registerResult = Register(launcherExe, log);
        if (registerResult != 0)
        {
            return registerResult;
        }

        try
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = DefaultAppsSettingsUri,
                UseShellExecute = true,
            };
            using var _ = Process.Start(startInfo);
            log.Info("Opened Settings › Default Apps for user confirmation");
            return 0;
        }
        catch (Exception ex)
        {
            log.Error("Opening Default Apps settings failed", ex);
            return 2;
        }
    }

    public static DefaultsStatus ReadStatus()
    {
        return new DefaultsStatus(
            Torrent: MatchesProgId(TorrentUserChoicePath, ProgIdTorrent),
            Magnet: MagnetIsDefault());
    }

    /// <summary>
    /// Whether we are the effective <c>magnet:</c> handler.
    ///
    /// UserChoice alone is not enough: Windows only writes
    /// <c>UrlAssociations\magnet\UserChoice</c> when the user picks between
    /// competing registrations. When we are the only client that registered the
    /// scheme — the common case on a clean machine — no UserChoice key is ever
    /// created, yet we really are the handler, because HKCU\Software\Classes
    /// is what the shell resolves. Requiring UserChoice made the in-page banner
    /// nag forever on exactly the machines where registration had worked.
    /// </summary>
    private static bool MagnetIsDefault()
    {
        if (MatchesProgId(MagnetUserChoicePath, ProgIdMagnet))
        {
            return true;
        }

        // A UserChoice naming someone else beats our class registration.
        using (var userChoice = Registry.CurrentUser.OpenSubKey(MagnetUserChoicePath))
        {
            if (userChoice?.GetValue("ProgId") is string other && other.Length > 0)
            {
                return false;
            }
        }

        return SchemeCommandIsOurs(MagnetScheme);
    }

    /// <summary>
    /// True when the per-user shell command for <paramref name="scheme"/> points
    /// at this executable.
    /// </summary>
    private static bool SchemeCommandIsOurs(string scheme)
    {
        using var command = Registry.CurrentUser.OpenSubKey(
            $@"{ClassesRoot}\{scheme}\shell\open\command");

        return command?.GetValue(null) is string value
            && value.Contains(Paths.Current.LauncherExe, StringComparison.OrdinalIgnoreCase);
    }

    public record struct DefaultsStatus(bool Torrent, bool Magnet)
    {
        public bool BothDefault => Torrent && Magnet;
    }

    private static bool MatchesProgId(string subKey, string expectedProgId)
    {
        using var key = Registry.CurrentUser.OpenSubKey(subKey);
        if (key is null)
        {
            return false;
        }

        var value = key.GetValue("ProgId") as string;
        return string.Equals(value, expectedProgId, StringComparison.OrdinalIgnoreCase);
    }

    private static void PrintStatus(DefaultsStatus status) =>
        Console.Out.WriteLine($"{{\"torrent\":{Bool(status.Torrent)},\"magnet\":{Bool(status.Magnet)}}}");

    private static string Bool(bool value) => value ? "true" : "false";

    public static int Unregister(LauncherLog log)
    {
        try
        {
            using var classes = Registry.CurrentUser.OpenSubKey(ClassesRoot, writable: true);
            classes?.DeleteSubKeyTree(ProgIdTorrent, throwOnMissingSubKey: false);
            classes?.DeleteSubKeyTree(ProgIdMagnet, throwOnMissingSubKey: false);

            using (var ext = classes?.OpenSubKey(TorrentExtension, writable: true))
            {
                var current = ext?.GetValue(null) as string;
                if (string.Equals(current, ProgIdTorrent, StringComparison.OrdinalIgnoreCase))
                {
                    // Only unset the default value if we own it — never stomp
                    // whatever the user chose after we registered.
                    ext?.DeleteValue(string.Empty, throwOnMissingValue: false);
                }
            }

            using (var scheme = classes?.OpenSubKey(MagnetScheme, writable: true))
            {
                var current = scheme?.GetValue(null) as string;
                if (string.Equals(current, "URL:Magnet Protocol", StringComparison.OrdinalIgnoreCase))
                {
                    classes?.DeleteSubKeyTree(MagnetScheme, throwOnMissingSubKey: false);
                }
            }

            using (var registered = Registry.CurrentUser.OpenSubKey(RegisteredAppsRoot, writable: true))
            {
                registered?.DeleteValue(AppName, throwOnMissingValue: false);
            }

            // Capabilities only: deleting AppRegistryRoot would also wipe the
            // dismissal flag, resurrecting a nag the user turned off.
            Registry.CurrentUser.DeleteSubKeyTree(CapabilitiesPath, throwOnMissingSubKey: false);

            log.Info("Unregistered magnet: and .torrent handlers under HKCU");
            NotifyShellAssociationChanged();
            return 0;
        }
        catch (Exception ex)
        {
            log.Error("Unregister failed", ex);
            return 2;
        }
    }

    private static void WriteMagnetHandler(RegistryKey classes, string launcherExe)
    {
        using var progId = classes.CreateSubKey(ProgIdMagnet, writable: true);
        progId.SetValue(string.Empty, "URL:Magnet Protocol");
        progId.SetValue("URL Protocol", string.Empty);
        progId.SetValue("FriendlyTypeName", "Magnet URI");

        using (var icon = progId.CreateSubKey("DefaultIcon", writable: true))
        {
            icon.SetValue(string.Empty, $"\"{launcherExe}\",0");
        }

        using (var command = progId.CreateSubKey(@"shell\open\command", writable: true))
        {
            command.SetValue(string.Empty, $"\"{launcherExe}\" --submit-magnet \"%1\"");
        }

        // Register the top-level scheme entry pointing at our ProgID.
        using var scheme = classes.CreateSubKey(MagnetScheme, writable: true);
        scheme.SetValue(string.Empty, "URL:Magnet Protocol");
        scheme.SetValue("URL Protocol", string.Empty);

        using (var icon = scheme.CreateSubKey("DefaultIcon", writable: true))
        {
            icon.SetValue(string.Empty, $"\"{launcherExe}\",0");
        }

        using (var command = scheme.CreateSubKey(@"shell\open\command", writable: true))
        {
            command.SetValue(string.Empty, $"\"{launcherExe}\" --submit-magnet \"%1\"");
        }
    }

    private static void WriteTorrentHandler(RegistryKey classes, string launcherExe)
    {
        using var progId = classes.CreateSubKey(ProgIdTorrent, writable: true);
        progId.SetValue(string.Empty, "BitTorrent File");
        progId.SetValue("FriendlyTypeName", "BitTorrent File");

        using (var icon = progId.CreateSubKey("DefaultIcon", writable: true))
        {
            // Index 0: the exe embeds one icon, so ",1" resolves to nothing
            // and Explorer falls back to the generic file glyph.
            icon.SetValue(string.Empty, $"\"{launcherExe}\",0");
        }

        using (var command = progId.CreateSubKey(@"shell\open\command", writable: true))
        {
            command.SetValue(string.Empty, $"\"{launcherExe}\" --submit-torrent \"%1\"");
        }

        using var ext = classes.CreateSubKey(TorrentExtension, writable: true);
        // If nothing is registered yet, set us as the default. Otherwise keep
        // the user's choice and only add ourselves to the OpenWithProgIds list.
        var currentDefault = ext.GetValue(null) as string;
        if (string.IsNullOrEmpty(currentDefault))
        {
            ext.SetValue(string.Empty, ProgIdTorrent);
        }

        using var openWith = ext.CreateSubKey("OpenWithProgIds", writable: true);
        openWith.SetValue(ProgIdTorrent, Array.Empty<byte>(), RegistryValueKind.None);
    }

    private static void WriteApplicationCapabilities(string launcherExe)
    {
        using (var registered = Registry.CurrentUser.CreateSubKey(RegisteredAppsRoot, writable: true))
        {
            registered.SetValue(AppName, CapabilitiesPath);
        }

        using var capabilities = Registry.CurrentUser.CreateSubKey(CapabilitiesPath, writable: true);
        capabilities.SetValue("ApplicationName", AppDisplayName);
        capabilities.SetValue("ApplicationDescription", AppDescription);
        capabilities.SetValue("ApplicationIcon", $"\"{launcherExe}\",0");

        using (var fileAssoc = capabilities.CreateSubKey("FileAssociations", writable: true))
        {
            fileAssoc.SetValue(TorrentExtension, ProgIdTorrent);
        }

        using (var urlAssoc = capabilities.CreateSubKey("URLAssociations", writable: true))
        {
            urlAssoc.SetValue(MagnetScheme, ProgIdMagnet);
        }
    }

    private static void NotifyShellAssociationChanged()
    {
        // SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, NULL, NULL)
        const int SHCNE_ASSOCCHANGED = 0x08000000;
        const uint SHCNF_IDLIST = 0x0000;
        NativeShell.SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, IntPtr.Zero, IntPtr.Zero);
    }
}

[SupportedOSPlatform("windows")]
internal static partial class NativeShell
{
    [System.Runtime.InteropServices.LibraryImport("shell32.dll", EntryPoint = "SHChangeNotify")]
    internal static partial void SHChangeNotify(int wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);
}
