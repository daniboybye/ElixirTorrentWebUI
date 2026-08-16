namespace ElixirTorrentWebUI.Launcher;

/// <summary>
/// Immutable state handed from CLI dispatch into the desktop runtime: the log
/// to write to, and a magnet/torrent submit that arrived on the command line
/// and must be processed once the release is up.
/// </summary>
internal sealed record LaunchContext(
    LauncherLog Log,
    LauncherMessage? PendingSubmit);
