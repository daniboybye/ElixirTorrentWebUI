using System.Diagnostics;
using System.Net.Http;

namespace ElixirTorrentWebUI.Launcher;

/// <summary>
/// Owns the mix-release child process: starts it under a Job Object, redirects
/// its stdout/stderr into the rotated <c>server.log</c>, performs the HTTP
/// readiness probe, and shuts it down through the release's own <c>stop</c>
/// command with a kill-fallback if graceful shutdown times out.
/// </summary>
internal sealed class ServerLifecycle : IDisposable
{
    private static readonly TimeSpan ReadyPollInterval = TimeSpan.FromMilliseconds(250);
    private static readonly TimeSpan ReadyTimeout = TimeSpan.FromSeconds(60);
    private static readonly TimeSpan GracefulStopTimeout = TimeSpan.FromSeconds(20);
    private static readonly TimeSpan ReadyProbeTimeout = TimeSpan.FromSeconds(2);

    private readonly Paths _paths;
    private readonly LauncherLog _log;
    private readonly JobObject _job;
    private readonly HttpClient _http;
    private readonly int _port;

    // stdout and stderr drain concurrently into one FileStream, which is not
    // thread-safe. Guards every write/flush pair and the teardown close.
    private readonly object _serverLogSync = new();

    private Process? _release;
    private FileStream? _serverLogHandle;
    private bool _disposed;

    public ServerLifecycle(Paths paths, LauncherLog log, int port)
    {
        _paths = paths;
        _log = log;
        _port = port;
        _job = new JobObject();
        _http = new HttpClient
        {
            Timeout = ReadyProbeTimeout,
        };
    }

    public Uri AppUrl => new($"http://127.0.0.1:{_port}/");

    public Uri TorrentsEndpoint => new(AppUrl, "api/torrents");

    public Uri MagnetsEndpoint => new(AppUrl, "api/magnets");

    /// <summary>Attempts to start the release; returns true on success.</summary>
    public bool Start()
    {
        if (_release is { HasExited: false })
        {
            return true;
        }

        if (!File.Exists(_paths.ReleaseBinary))
        {
            _log.Error($"Release binary missing at {_paths.ReleaseBinary}");
            return false;
        }

        _paths.EnsureDirectories();

        try
        {
            _serverLogHandle = LauncherLog.OpenServerLogForAppend(_paths.ServerLogPath);
        }
        catch (Exception ex)
        {
            _log.Warn($"Could not open server.log for redirection: {ex.Message}");
        }

        var startInfo = BuildProcessStart("start");
        var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };

        try
        {
            if (!process.Start())
            {
                _log.Error("Process.Start returned false for release start");
                return false;
            }
        }
        catch (Exception ex)
        {
            _log.Error("Failed to spawn release process", ex);
            return false;
        }

        try
        {
            if (!_job.TryAssign(process.Handle))
            {
                _log.Warn("Could not assign release process to Job Object; safety-net kill on crash disabled");
            }
        }
        catch (Exception ex)
        {
            _log.Warn($"Job Object assignment threw: {ex.Message}");
        }

        _release = process;
        process.Exited += OnReleaseExited;

        _ = Task.Run(() => DrainAsync(process.StandardOutput));
        _ = Task.Run(() => DrainAsync(process.StandardError));

        _log.Info($"Release started (pid={process.Id}) on port {_port}");
        return true;
    }

    public async Task<bool> WaitUntilReadyAsync(CancellationToken cancellationToken)
    {
        var deadline = DateTime.UtcNow + ReadyTimeout;

        while (DateTime.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();

            if (await IsHealthyAsync(cancellationToken).ConfigureAwait(false))
            {
                _log.Info($"Release HTTP-ready on port {_port}");
                return true;
            }

            try
            {
                await Task.Delay(ReadyPollInterval, cancellationToken).ConfigureAwait(false);
            }
            catch (TaskCanceledException)
            {
                return false;
            }
        }

        _log.Warn($"Release did not become HTTP-ready within {ReadyTimeout.TotalSeconds}s");
        return false;
    }

    public async Task ShutdownAsync()
    {
        try
        {
            InvokeReleaseStop();
            await WaitUntilPortClosedAsync().ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _log.Warn($"Graceful stop failed: {ex.Message}");
        }

        try
        {
            if (_release is { HasExited: false } running)
            {
                _log.Warn($"Killing release process tree (pid={running.Id})");
                running.Kill(entireProcessTree: true);
                if (!running.WaitForExit((int)TimeSpan.FromSeconds(3).TotalMilliseconds))
                {
                    _log.Warn("Release process tree did not exit within 3s of kill");
                }
            }
        }
        catch (Exception ex)
        {
            _log.Warn($"Release kill fallback failed: {ex.Message}");
        }
    }

    private ProcessStartInfo BuildProcessStart(string command)
    {
        // cmd.exe hosts the release .bat with a hidden window; without cmd.exe
        // Windows shows the batch console for a frame. UseShellExecute must be
        // false so we can redirect stdout/err into the rotated server.log.
        var startInfo = new ProcessStartInfo
        {
            FileName = Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe",
            WorkingDirectory = _paths.DataDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = System.Text.Encoding.UTF8,
            StandardErrorEncoding = System.Text.Encoding.UTF8,
        };

        startInfo.ArgumentList.Add("/D");
        startInfo.ArgumentList.Add("/C");
        startInfo.ArgumentList.Add(_paths.ReleaseBinary);
        startInfo.ArgumentList.Add(command);

        InjectReleaseEnvironment(startInfo.Environment);
        return startInfo;
    }

    private void InjectReleaseEnvironment(IDictionary<string, string?> environment)
    {
        environment["PHX_SERVER"] = "true";
        environment["ELIXIR_TORRENT_DESKTOP"] = "1";
        environment["PORT"] = _port.ToString(System.Globalization.CultureInfo.InvariantCulture);
        environment["ELIXIR_TORRENT_LAUNCHER"] = _paths.LauncherExe;
        environment["ELIXIR_TORRENT_DATA_DIR"] = _paths.DataDirectory;
    }

    private void InvokeReleaseStop()
    {
        var startInfo = BuildProcessStart("stop");
        using var stopProcess = Process.Start(startInfo);
        if (stopProcess is null)
        {
            _log.Warn("Release stop: Process.Start returned null");
            return;
        }

        if (!stopProcess.WaitForExit((int)GracefulStopTimeout.TotalMilliseconds))
        {
            _log.Warn($"Release stop did not return within {GracefulStopTimeout.TotalSeconds}s");
        }
    }

    private async Task WaitUntilPortClosedAsync()
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(10);
        while (DateTime.UtcNow < deadline)
        {
            if (!PortManager.IsListening(_port))
            {
                return;
            }

            await Task.Delay(150).ConfigureAwait(false);
        }
    }

    private async Task<bool> IsHealthyAsync(CancellationToken cancellationToken)
    {
        try
        {
            using var response = await _http.GetAsync(AppUrl, HttpCompletionOption.ResponseHeadersRead, cancellationToken)
                .ConfigureAwait(false);
            return (int)response.StatusCode < 500;
        }
        catch
        {
            return false;
        }
    }

    private async Task DrainAsync(StreamReader reader)
    {
        try
        {
            string? line;
            while ((line = await reader.ReadLineAsync().ConfigureAwait(false)) is not null)
            {
                var bytes = System.Text.Encoding.UTF8.GetBytes(line + Environment.NewLine);

                lock (_serverLogSync)
                {
                    if (_disposed || _serverLogHandle is not { } handle)
                    {
                        continue;
                    }

                    handle.Write(bytes);
                    handle.Flush();
                }
            }
        }
        catch
        {
            // The reader closes once the process exits; nothing actionable.
        }
    }

    private void OnReleaseExited(object? sender, EventArgs e)
    {
        try
        {
            if (sender is Process process)
            {
                _log.Warn($"Release process exited (pid={process.Id}, code={process.ExitCode})");
            }
        }
        catch
        {
            // Process handle can already be released here; nothing actionable.
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        try
        {
            _release?.Dispose();
        }
        catch
        {
            // Nothing actionable at teardown.
        }

        // Under the drain tasks' lock, so a line arriving mid-teardown cannot
        // write into a disposed FileStream.
        lock (_serverLogSync)
        {
            _disposed = true;
            _serverLogHandle?.Dispose();
            _serverLogHandle = null;
        }

        _http.Dispose();
        _job.Dispose();
    }

}
