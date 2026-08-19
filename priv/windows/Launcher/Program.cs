using System.Runtime.Versioning;

namespace ElixirTorrentWebUI.Launcher;

/// <summary>
/// CLI dispatch + desktop boot. Verbs that do not need a message pump
/// (--version, --pick-folder, --register, …) are handled inline and return
/// immediately; the launcher/submit verbs start a Win32 message loop, which
/// is all the tray icon and the shell dialogs actually require.
/// </summary>
[SupportedOSPlatform("windows10.0.22000.0")]
internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        var command = Cli.Parse(args);

        var log = new LauncherLog(Paths.Current.LauncherLogPath);
        log.Rotate(includeServerLog: command.Verb is CliVerb.Launcher or CliVerb.SubmitMagnet or CliVerb.SubmitTorrent);

        try
        {
            log.Info($"Launcher started verb={command.Verb} pid={Environment.ProcessId} exe={Paths.Current.LauncherExe}");

            return command.Verb switch
            {
                CliVerb.Help => WriteAndExit(Cli.HelpText, 0),
                CliVerb.Version => WriteAndExit(typeof(Program).Assembly.GetName().Version?.ToString() ?? "unknown", 0),
                CliVerb.PickFolder => ShellHelpers.PickFolder(log),
                CliVerb.OpenFile => ShellHelpers.OpenFile(command.Argument ?? string.Empty, log),
                CliVerb.Reveal => ShellHelpers.Reveal(command.Argument ?? string.Empty, log),
                CliVerb.Register => UriHandler.Register(Paths.Current.LauncherExe, log),
                CliVerb.Unregister => UriHandler.Unregister(log),
                CliVerb.CheckDefaults => UriHandler.CheckDefaults(log),
                CliVerb.RegisterDefaults => UriHandler.RegisterDefaults(Paths.Current.LauncherExe, log),
                CliVerb.AwaitDefaultStatus => UriHandler.AwaitDefaultStatus(log),
                CliVerb.SubmitMagnet or CliVerb.SubmitTorrent => SubmitOrLaunch(command, log),
                CliVerb.Launcher => BootDesktop(pendingSubmit: null, log),
                _ => WriteAndExit(Cli.HelpText, 1),
            };
        }
        catch (Exception ex)
        {
            log.Error("Unhandled launcher error", ex);
            try
            {
                UserPrompt.Error($"ElixirTorrent Web launcher failed: {ex.Message}");
            }
            catch
            {
                // Nothing left to do.
            }

            return 3;
        }
        finally
        {
            log.Dispose();
        }
    }

    private static int SubmitOrLaunch(CliCommand command, LauncherLog log)
    {
        if (string.IsNullOrWhiteSpace(command.Argument))
        {
            log.Warn($"{command.Verb} invoked without an argument");
            return 1;
        }

        var kind = command.Verb == CliVerb.SubmitMagnet ? "magnet" : "torrent";
        var message = new LauncherMessage(kind, command.Argument);

        // Fast path: another launcher owns the pipe — forward and exit.
        if (AppInstance.TrySend(message, log))
        {
            log.Info($"Forwarded {kind} to running launcher instance");
            return 0;
        }

        // Slow path: we become the primary and process the submit once
        // the release is ready.
        return BootDesktop(message, log);
    }

    private static int BootDesktop(LauncherMessage? pendingSubmit, LauncherLog log)
    {
        log.Info("BootDesktop: starting message loop");

        using var loop = new MessageLoop(log);
        var lifetime = new DesktopLifetime(new LaunchContext(log, pendingSubmit), loop);

        // Queued rather than called directly: RunAsync must observe the loop's
        // SynchronizationContext, which Run() installs.
        loop.Post(() =>
        {
            _ = lifetime.RunAsync().ContinueWith(
                t =>
                {
                    log.Error("DesktopLifetime.RunAsync faulted", t.Exception);

                    // Quit, do not just log. Everything between EnsureDirectories
                    // and `new TrayIcon` runs before there is any UI at all, so a
                    // throw in PortManager.Choose or the JobObject constructor
                    // otherwise leaves the pump running with no window, no tray
                    // icon and no way to exit short of Task Manager.
                    Environment.ExitCode = 3;
                    loop.Quit();
                },
                TaskContinuationOptions.OnlyOnFaulted);
        });

        loop.Run();

        // DesktopLifetime.Exit() records its outcome in Environment.ExitCode
        // (4 = release would not start, 5 = never became HTTP-ready). Main's
        // return value wins over it, so a literal 0 here would hide failures.
        log.Info($"BootDesktop: loop ended, exitCode={Environment.ExitCode}");
        return Environment.ExitCode;
    }

    private static int WriteAndExit(string message, int exitCode)
    {
        try
        {
            Console.Out.WriteLine(message);
        }
        catch
        {
            // Stdout may be unavailable in pure WinExe context.
        }

        return exitCode;
    }
}
