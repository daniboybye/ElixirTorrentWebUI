using System.Diagnostics;

namespace ElixirTorrentWebUI.Launcher;

internal static class BrowserOpener
{
    /// <summary>
    /// Opens the given absolute URL in the user's default browser via
    /// ShellExecute. Never throws — logs and returns false on failure.
    /// </summary>
    public static bool Open(Uri url, LauncherLog log)
    {
        ArgumentNullException.ThrowIfNull(url);

        try
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = url.AbsoluteUri,
                UseShellExecute = true,
            };

            using var process = Process.Start(startInfo);
            log.Info($"Opened browser at {url}");
            return true;
        }
        catch (Exception ex)
        {
            log.Error($"Failed to open browser at {url}", ex);
            return false;
        }
    }
}
