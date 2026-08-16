using System.IO.Pipes;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ElixirTorrentWebUI.Launcher;

/// <summary>
/// Enforces single-instance behavior and provides an inbound message pipe so
/// subsequent launcher invocations forward magnet/torrent URIs into the
/// already-running instance instead of starting a second release.
/// </summary>
internal sealed class AppInstance : IDisposable
{
    private const string MutexName = @"Local\ElixirTorrentWebUI.Launcher.Instance";
    private const string PipeName = "ElixirTorrentWebUI.Launcher.Pipe.{user}";
    private const int PipeTimeoutMs = 3000;

    private readonly LauncherLog _log;
    private Mutex? _mutex;
    private CancellationTokenSource? _serverCts;
    private Task? _serverTask;

    public AppInstance(LauncherLog log)
    {
        _log = log;
    }

    /// <summary>
    /// Attempts to acquire the single-instance lock. Returns true if this
    /// process is the primary instance; false when another launcher is
    /// already running (the caller should forward its inputs instead).
    /// </summary>
    public bool TryAcquire()
    {
        // Local\ namespace: per-user session; no privilege elevation needed.
        _mutex = new Mutex(initiallyOwned: false, MutexName, out var createdNew);

        if (createdNew)
        {
            try
            {
                if (!_mutex.WaitOne(0))
                {
                    _mutex.Dispose();
                    _mutex = null;
                    return false;
                }
            }
            catch (AbandonedMutexException)
            {
                // Previous owner crashed; we now own it.
            }

            return true;
        }

        try
        {
            var owned = _mutex.WaitOne(0);
            if (owned)
            {
                return true;
            }
        }
        catch (AbandonedMutexException)
        {
            return true;
        }

        _mutex.Dispose();
        _mutex = null;
        return false;
    }

    public void StartServer(Func<LauncherMessage, Task> handler)
    {
        _serverCts = new CancellationTokenSource();
        _serverTask = Task.Run(() => AcceptLoopAsync(handler, _serverCts.Token));
    }

    /// <summary>
    /// Fires-and-waits for a single message send to the running instance.
    /// Never throws — returns false on any I/O or timeout failure.
    /// </summary>
    public static bool TrySend(LauncherMessage message, LauncherLog? log = null)
    {
        try
        {
            using var client = new NamedPipeClientStream(
                serverName: ".",
                pipeName: ResolvePipeName(),
                PipeDirection.Out,
                PipeOptions.Asynchronous);

            client.Connect(PipeTimeoutMs);

            var json = JsonSerializer.Serialize(message, LauncherJsonContext.Default.LauncherMessage);
            var payload = System.Text.Encoding.UTF8.GetBytes(json + "\n");
            client.Write(payload, 0, payload.Length);
            client.Flush();
            return true;
        }
        catch (Exception ex)
        {
            log?.Warn($"Forward to primary instance failed: {ex.Message}");
            return false;
        }
    }

    private static string ResolvePipeName()
    {
        // One pipe per interactive user, so two logged-in accounts get
        // independent primary instances rather than fighting for the pipe.
        var user = Environment.UserName;
        return PipeName.Replace("{user}", user, StringComparison.Ordinal);
    }

    private async Task AcceptLoopAsync(Func<LauncherMessage, Task> handler, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            NamedPipeServerStream? server = null;
            try
            {
                server = new NamedPipeServerStream(
                    pipeName: ResolvePipeName(),
                    PipeDirection.In,
                    maxNumberOfServerInstances: 1,
                    PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous);

                await server.WaitForConnectionAsync(ct).ConfigureAwait(false);

                using var reader = new StreamReader(server, System.Text.Encoding.UTF8, leaveOpen: true);
                var line = await reader.ReadLineAsync(ct).ConfigureAwait(false);

                if (!string.IsNullOrWhiteSpace(line))
                {
                    var message = JsonSerializer.Deserialize(line, LauncherJsonContext.Default.LauncherMessage);
                    if (message is not null)
                    {
                        _log.Info($"IPC received kind={message.Kind}");
                        await handler(message).ConfigureAwait(false);
                    }
                }
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception ex)
            {
                _log.Warn($"IPC accept failed: {ex.Message}");
            }
            finally
            {
                server?.Dispose();
            }
        }
    }

    public void Dispose()
    {
        try
        {
            _serverCts?.Cancel();
            _serverTask?.Wait(TimeSpan.FromSeconds(1));
        }
        catch
        {
            // Nothing actionable at teardown.
        }

        _serverCts?.Dispose();

        try
        {
            _mutex?.ReleaseMutex();
        }
        catch (ApplicationException)
        {
            // Not owner of the mutex on this thread — nothing to release.
        }

        _mutex?.Dispose();
    }
}

/// <summary>
/// Payload sent through the single-instance pipe.
/// <see cref="Kind"/> is one of <c>magnet</c>, <c>torrent</c>, <c>focus</c>.
/// </summary>
internal sealed record LauncherMessage(
    [property: JsonPropertyName("kind")] string Kind,
    [property: JsonPropertyName("value")] string? Value);

[JsonSerializable(typeof(LauncherMessage))]
[JsonSourceGenerationOptions(WriteIndented = false)]
internal sealed partial class LauncherJsonContext : JsonSerializerContext
{
}
