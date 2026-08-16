using Microsoft.Win32;
using System.Runtime.Versioning;

namespace ElixirTorrentWebUI.Launcher;

/// <summary>
/// One-shot boot-time nag that asks the user whether to make this launcher
/// the default program for both <c>.torrent</c> files and <c>magnet:</c> links.
/// Windows 10+ intentionally blocks silent default-app changes, so on Yes we
/// re-write our HKCU registration and hand off to Settings › Default Apps
/// (scoped to this app) where the user can confirm.
/// </summary>
[SupportedOSPlatform("windows10.0.22000.0")]
internal static class DefaultHandlerPrompt
{
    // Shared with UriHandler so this flag and --unregister cannot drift apart.
    private const string PromptStateKeyPath = UriHandler.AppRegistryRoot;
    private const string DismissedValueName = "DefaultHandlerPromptDismissed";

    public static void MaybePrompt(string launcherExe, LauncherLog log)
    {
        if (WasDismissed())
        {
            return;
        }

        UriHandler.DefaultsStatus status;
        try
        {
            status = UriHandler.ReadStatus();
        }
        catch (Exception ex)
        {
            log.Warn($"DefaultHandlerPrompt: reading status failed — {ex.Message}");
            return;
        }

        if (status.BothDefault)
        {
            return;
        }

        var choice = UserPrompt.Question(
            "Make ElixirTorrent Web your default torrent app?\r\n\r\n" +
            "Set as the default program for .torrent files and magnet links so " +
            "double-clicking or clicking a link opens them here.\r\n\r\n" +
            "Choose No to be asked again next time, or Cancel to stop asking.",
            "ElixirTorrent Web");

        switch (choice)
        {
            case UserPrompt.IDYES:
                var result = UriHandler.RegisterDefaults(launcherExe, log);
                if (result != 0)
                {
                    UserPrompt.Warn(
                        "Could not open Settings › Default Apps automatically. " +
                        "Open Settings › Apps › Default apps and search for ElixirTorrent Web.");
                }

                break;

            case UserPrompt.IDCANCEL:
                MarkDismissed();
                break;

            default:
                break;
        }
    }

    private static bool WasDismissed()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(PromptStateKeyPath);
            return key?.GetValue(DismissedValueName) is int value && value != 0;
        }
        catch
        {
            return false;
        }
    }

    private static void MarkDismissed()
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(PromptStateKeyPath, writable: true);
            key.SetValue(DismissedValueName, 1, RegistryValueKind.DWord);
        }
        catch
        {
            // Best effort — we'll simply prompt again next launch.
        }
    }
}
