using System.Runtime.Versioning;

namespace ElixirTorrentWebUI.Launcher;

/// <summary>
/// Owns the launcher runtime once the WinUI 3 dispatcher is running:
/// single-instance guard, port selection, release lifecycle, IPC handler,
/// pending submit, browser open, tray, quit signal, and orderly shutdown.
/// </summary>
[SupportedOSPlatform("windows10.0.22000.0")]
internal sealed class DesktopLifetime
{
    private readonly LauncherLog _log;
    private readonly LauncherMessage? _pendingSubmit;

    private TrayIcon? _tray;
    private ServerLifecycle? _server;
    private TorrentSubmitter? _submitter;
    private AppInstance? _appInstance;

    private readonly MessageLoop _loop;

    public DesktopLifetime(LaunchContext context, MessageLoop loop)
    {
        _log = context.Log;
        _pendingSubmit = context.PendingSubmit;
        _loop = loop;
    }

    public async Task RunAsync()
    {
        _log.Info("DesktopLifetime: RunAsync entered");

        _appInstance = new AppInstance(_log);
        if (!_appInstance.TryAcquire())
        {
            _log.Warn("Another launcher instance already owns the single-instance lock");

            if (_pendingSubmit is not null && AppInstance.TrySend(_pendingSubmit, _log))
            {
                Exit(0);
                return;
            }

            AppInstance.TrySend(new LauncherMessage("focus", null), _log);
            Exit(0);
            return;
        }

        Paths.Current.EnsureDirectories();

        var port = PortManager.Choose();
        _log.Info($"Chosen port: {port}");

        _server = new ServerLifecycle(Paths.Current, _log, port);
        _submitter = new TorrentSubmitter(_server, _log, Paths.Current);

        _appInstance.StartServer(HandleIncomingMessageAsync);

        if (!_server.Start())
        {
            UserPrompt.Error("ElixirTorrent Web could not start its background service. Check launcher.log for details.");
            Exit(4);
            return;
        }

        using var readyCts = new CancellationTokenSource();
        var isReady = await _server.WaitUntilReadyAsync(readyCts.Token).ConfigureAwait(true);

        if (!isReady)
        {
            UserPrompt.Error("ElixirTorrent Web did not become ready in time. Check server.log for details.");
            await ShutdownAsync().ConfigureAwait(true);
            Exit(5);
            return;
        }

        if (_pendingSubmit is not null)
        {
            await HandlePendingSubmitAsync(_pendingSubmit).ConfigureAwait(true);
        }

        BrowserOpener.Open(_server.AppUrl, _log);

        // Keeps the stored exe path and icon index current for an app that can
        // be moved or replaced wholesale.
        UriHandler.RefreshIfRegistered(Paths.Current.LauncherExe, _log);

        try
        {
            DefaultHandlerPrompt.MaybePrompt(Paths.Current.LauncherExe, _log);
        }
        catch (Exception ex)
        {
            _log.Warn($"Default-handler prompt failed: {ex.Message}");
        }

        _tray = new TrayIcon(
            tooltip: $"ElixirTorrent Web — 127.0.0.1:{port}",
            onOpen: () =>
            {
                if (_server is { } s)
                {
                    BrowserOpener.Open(s.AppUrl, _log);
                }
            },
            onQuit: () => _ = QuitAsync(),
            log: _log);
    }

    private Task HandleIncomingMessageAsync(LauncherMessage message)
    {
        // IPC callback runs on a background thread; hop to the loop thread so
        // browser open / server access / tray tweaks stay UI-safe.
        _loop.Post(async () =>
        {
            try
            {
                switch (message.Kind)
                {
                    // No BrowserOpener.Open here: the UI is a LiveView, so an
                    // already-open tab shows the new torrent by itself. Opening
                    // the URL again just stacks up duplicate tabs every time a
                    // .torrent is double-clicked or a magnet link is followed.
                    case "magnet" when !string.IsNullOrWhiteSpace(message.Value) && _submitter is not null:
                        await _submitter.SubmitMagnetAsync(message.Value!, CancellationToken.None).ConfigureAwait(true);
                        break;

                    case "torrent" when !string.IsNullOrWhiteSpace(message.Value) && _submitter is not null:
                        await _submitter.SubmitTorrentFileAsync(message.Value!, CancellationToken.None).ConfigureAwait(true);
                        break;

                    case "focus" when _server is not null:
                        BrowserOpener.Open(_server.AppUrl, _log);
                        break;

                    case "quit":
                        await QuitAsync().ConfigureAwait(true);
                        break;

                    default:
                        _log.Warn($"Unknown IPC kind: {message.Kind}");
                        break;
                }
            }
            catch (Exception ex)
            {
                _log.Error("IPC handler threw", ex);
            }
        });

        return Task.CompletedTask;
    }

    private async Task HandlePendingSubmitAsync(LauncherMessage message)
    {
        if (_submitter is null)
        {
            return;
        }

        try
        {
            switch (message.Kind)
            {
                case "magnet" when !string.IsNullOrWhiteSpace(message.Value):
                    await _submitter.SubmitMagnetAsync(message.Value!, CancellationToken.None).ConfigureAwait(true);
                    break;

                case "torrent" when !string.IsNullOrWhiteSpace(message.Value):
                    await _submitter.SubmitTorrentFileAsync(message.Value!, CancellationToken.None).ConfigureAwait(true);
                    break;
            }
        }
        catch (Exception ex)
        {
            _log.Error("Pending submit failed", ex);
        }
    }

    private async Task QuitAsync()
    {
        _log.Info("Quit requested");
        await ShutdownAsync().ConfigureAwait(true);
        Exit(0);
    }

    private async Task ShutdownAsync()
    {
        try
        {
            _tray?.Dispose();
            _tray = null;
        }
        catch (Exception ex)
        {
            _log.Warn($"Tray dispose failed: {ex.Message}");
        }

        if (_server is not null)
        {
            _log.Info("Shutting down release");
            await _server.ShutdownAsync().ConfigureAwait(true);
        }
    }

    private void Exit(int exitCode)
    {
        _submitter?.Dispose();
        _server?.Dispose();
        _appInstance?.Dispose();

        Environment.ExitCode = exitCode;

        // Ends Run(), which unblocks Main and lets the process exit.
        _loop.Quit();
    }
}
