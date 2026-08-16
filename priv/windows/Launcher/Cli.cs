namespace ElixirTorrentWebUI.Launcher;

/// <summary>
/// Command line dispatch: one verb per CLI mode. Parsing is intentionally
/// hand-rolled to keep the launcher dependency-free and single-file friendly.
/// </summary>
internal enum CliVerb
{
    /// <summary>No arguments — run as the desktop launcher.</summary>
    Launcher,
    Help,
    Version,
    PickFolder,
    OpenFile,
    Reveal,
    SubmitMagnet,
    SubmitTorrent,
    Register,
    Unregister,
    CheckDefaults,
    RegisterDefaults,
    AwaitDefaultStatus,
}

internal sealed record CliCommand(CliVerb Verb, string? Argument);

internal static class Cli
{
    public static CliCommand Parse(string[] args)
    {
        if (args.Length == 0)
        {
            return new CliCommand(CliVerb.Launcher, null);
        }

        return args[0] switch
        {
            "--help" or "-h" or "/?" => new CliCommand(CliVerb.Help, null),
            "--version" or "-v" => new CliCommand(CliVerb.Version, null),
            "--pick-folder" => new CliCommand(CliVerb.PickFolder, null),
            "--open-file" => new CliCommand(CliVerb.OpenFile, Argument(args, 1)),
            "--reveal" => new CliCommand(CliVerb.Reveal, Argument(args, 1)),
            "--submit-magnet" => new CliCommand(CliVerb.SubmitMagnet, Argument(args, 1)),
            "--submit-torrent" => new CliCommand(CliVerb.SubmitTorrent, Argument(args, 1)),
            "--register" => new CliCommand(CliVerb.Register, null),
            "--unregister" => new CliCommand(CliVerb.Unregister, null),
            "--check-defaults" => new CliCommand(CliVerb.CheckDefaults, null),
            "--register-defaults" => new CliCommand(CliVerb.RegisterDefaults, null),
            "--await-default-status" => new CliCommand(CliVerb.AwaitDefaultStatus, null),
            _ => InferPositional(args),
        };
    }

    private static CliCommand InferPositional(string[] args)
    {
        // Explorer / shell hand-off can pass a bare argument. Treat magnets
        // and .torrent files as ingest requests so the launcher stays a
        // drop-in target for `assoc` registrations.
        var value = args[0];
        if (value.StartsWith("magnet:", StringComparison.OrdinalIgnoreCase))
        {
            return new CliCommand(CliVerb.SubmitMagnet, value);
        }

        if (value.EndsWith(".torrent", StringComparison.OrdinalIgnoreCase))
        {
            return new CliCommand(CliVerb.SubmitTorrent, value);
        }

        return new CliCommand(CliVerb.Help, null);
    }

    private static string? Argument(string[] args, int index) =>
        index < args.Length ? args[index] : null;

    public static string HelpText =>
        """
        ElixirTorrentWebUI Launcher

        Usage:
          (no arguments)             Launch the desktop app and open the UI in the default browser.
          --submit-magnet <uri>      Add a magnet URI to the running instance (starts one if needed).
          --submit-torrent <path>    Add a .torrent file to the running instance.
          --pick-folder              Show the Windows folder picker and print the chosen path.
          --open-file <path>         Open a file with its default application (ShellExecute).
          --reveal <path>            Select the file (or open the directory) in File Explorer.
          --register                 Register magnet:/.torrent handlers under HKCU (no admin needed).
          --unregister               Remove the HKCU handler registrations.
          --check-defaults           Print JSON telling whether we are the default for .torrent/magnet.
          --register-defaults        Re-register and open Settings › Default Apps for user confirmation.
          --await-default-status     Block (up to ~15s) until both are default, then print the same JSON.
          --version                  Print version and exit.
          --help                     Show this text.
        """;
}
