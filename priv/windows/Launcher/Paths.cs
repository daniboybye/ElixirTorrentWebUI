using System.Reflection;

namespace ElixirTorrentWebUI.Launcher;

/// <summary>
/// Resolves the canonical filesystem locations the launcher depends on.
/// All values are computed lazily so unit tests can override the underlying
/// environment before <see cref="Paths.Current"/> is captured.
/// </summary>
internal sealed class Paths
{
    public const string AppSupportDirectoryName = "ElixirTorrentWebUI";
    public const string ReleaseBinaryName = "elixir_torrent_web_ui.bat";

    public string LauncherExe { get; }
    public string LauncherDirectory { get; }
    public string ReleaseRoot { get; }
    public string ReleaseBinary { get; }
    public string DataDirectory { get; }
    public string InboxDirectory { get; }
    public string ServerLogPath { get; }
    public string LauncherLogPath { get; }

    private Paths(
        string launcherExe,
        string launcherDirectory,
        string releaseRoot,
        string releaseBinary,
        string dataDirectory)
    {
        LauncherExe = launcherExe;
        LauncherDirectory = launcherDirectory;
        ReleaseRoot = releaseRoot;
        ReleaseBinary = releaseBinary;
        DataDirectory = dataDirectory;
        InboxDirectory = Path.Combine(dataDirectory, "inbox");
        ServerLogPath = Path.Combine(dataDirectory, "server.log");
        LauncherLogPath = Path.Combine(dataDirectory, "launcher.log");
    }

    public static Paths Current { get; } = Discover();

    private static Paths Discover()
    {
        var launcherExe = ResolveLauncherExe();
        var launcherDirectory = Path.GetDirectoryName(launcherExe)
            ?? throw new InvalidOperationException(
                "Launcher directory could not be determined.");

        var releaseRoot = ResolveReleaseRoot(launcherDirectory);
        var releaseBinary = Path.Combine(releaseRoot, "bin", ReleaseBinaryName);

        var dataDirectory = ResolveDataDirectory();

        return new Paths(launcherExe, launcherDirectory, releaseRoot, releaseBinary, dataDirectory);
    }

    private static string ResolveLauncherExe()
    {
        var processPath = Environment.ProcessPath;
        if (!string.IsNullOrEmpty(processPath) && File.Exists(processPath))
        {
            return Path.GetFullPath(processPath);
        }

        // Fallback for `dotnet run` scenarios where ProcessPath is dotnet.exe.
        var assemblyLocation = Assembly.GetEntryAssembly()?.Location;
        if (!string.IsNullOrEmpty(assemblyLocation) && File.Exists(assemblyLocation))
        {
            return Path.GetFullPath(assemblyLocation);
        }

        throw new InvalidOperationException(
            "Could not determine the launcher executable path.");
    }

    private static string ResolveReleaseRoot(string launcherDirectory)
    {
        var overrideRoot = Environment.GetEnvironmentVariable("ELIXIR_TORRENT_RELEASE_ROOT");
        if (!string.IsNullOrWhiteSpace(overrideRoot))
        {
            return Path.GetFullPath(overrideRoot);
        }

        // Convention: <install>\Launcher.exe next to <install>\rel\bin\<release>.bat
        var candidate = Path.Combine(launcherDirectory, "rel");
        return Path.GetFullPath(candidate);
    }

    private static string ResolveDataDirectory()
    {
        var overrideDir = Environment.GetEnvironmentVariable("ELIXIR_TORRENT_DATA_DIR");
        if (!string.IsNullOrWhiteSpace(overrideDir))
        {
            return Path.GetFullPath(overrideDir);
        }

        var localAppData = Environment.GetFolderPath(
            Environment.SpecialFolder.LocalApplicationData,
            Environment.SpecialFolderOption.DoNotVerify);

        if (string.IsNullOrWhiteSpace(localAppData))
        {
            localAppData = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                "AppData", "Local");
        }

        return Path.Combine(localAppData, AppSupportDirectoryName);
    }

    public void EnsureDirectories()
    {
        Directory.CreateDirectory(DataDirectory);
        Directory.CreateDirectory(InboxDirectory);
    }
}
