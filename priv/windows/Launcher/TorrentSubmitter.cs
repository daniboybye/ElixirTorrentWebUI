using System.Net.Http;
using System.Net.Http.Json;
using System.Text.Json.Serialization;

namespace ElixirTorrentWebUI.Launcher;

/// <summary>
/// Forwards magnet URIs and .torrent files into the running release over its
/// loopback HTTP API. Uses the same endpoints the macOS launcher does.
/// </summary>
internal sealed class TorrentSubmitter : IDisposable
{
    private static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(30);
    private const int RetryAttempts = 5;
    private static readonly TimeSpan RetryDelay = TimeSpan.FromMilliseconds(500);

    private readonly ServerLifecycle _server;
    private readonly LauncherLog _log;
    private readonly Paths _paths;
    private readonly HttpClient _http;

    public TorrentSubmitter(ServerLifecycle server, LauncherLog log, Paths paths)
    {
        _server = server;
        _log = log;
        _paths = paths;
        _http = new HttpClient
        {
            Timeout = RequestTimeout,
        };
    }

    public void Dispose() => _http.Dispose();

    public async Task<bool> SubmitMagnetAsync(string magnet, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(magnet))
        {
            return false;
        }

        for (var attempt = 1; attempt <= RetryAttempts; attempt++)
        {
            try
            {
                var payload = new MagnetPayload(magnet.Trim());
                var response = await _http.PostAsJsonAsync(
                        _server.MagnetsEndpoint,
                        payload,
                        SubmitterJsonContext.Default.MagnetPayload,
                        cancellationToken)
                    .ConfigureAwait(false);

                if ((int)response.StatusCode == 202)
                {
                    _log.Info("Magnet submit accepted");
                    return true;
                }

                var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
                _log.Warn($"Magnet submit attempt {attempt}/{RetryAttempts} status={(int)response.StatusCode} body={Truncate(body)}");
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                _log.Warn($"Magnet submit attempt {attempt}/{RetryAttempts} timed out");
            }
            catch (Exception ex)
            {
                _log.Warn($"Magnet submit attempt {attempt}/{RetryAttempts} error: {ex.Message}");
            }

            try
            {
                await Task.Delay(RetryDelay, cancellationToken).ConfigureAwait(false);
            }
            catch (TaskCanceledException)
            {
                return false;
            }
        }

        _log.Warn("Magnet submit gave up after all retries");
        return false;
    }

    public async Task<bool> SubmitTorrentFileAsync(string sourcePath, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(sourcePath) || !File.Exists(sourcePath))
        {
            _log.Warn($"Torrent submit: source file missing at {sourcePath}");
            return false;
        }

        string staged;
        try
        {
            staged = StageTorrent(sourcePath);
        }
        catch (Exception ex)
        {
            _log.Error($"Torrent submit: staging failed for {sourcePath}", ex);
            return false;
        }

        var payload = new TorrentPayload(staged);

        try
        {
            var response = await _http.PostAsJsonAsync(
                    _server.TorrentsEndpoint,
                    payload,
                    SubmitterJsonContext.Default.TorrentPayload,
                    cancellationToken)
                .ConfigureAwait(false);

            if ((int)response.StatusCode == 202)
            {
                _log.Info($"Torrent submit accepted: {sourcePath}");
                return true;
            }

            var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            _log.Warn($"Torrent submit rejected status={(int)response.StatusCode} body={Truncate(body)}");
            return false;
        }
        catch (Exception ex)
        {
            _log.Error("Torrent submit failed", ex);
            return false;
        }
    }

    private string StageTorrent(string sourcePath)
    {
        Directory.CreateDirectory(_paths.InboxDirectory);

        var baseName = SanitizeFileName(Path.GetFileName(sourcePath));
        if (string.IsNullOrWhiteSpace(baseName))
        {
            baseName = "download.torrent";
        }

        var dest = Path.Combine(_paths.InboxDirectory, $"{Guid.NewGuid():N}-{baseName}");
        File.Copy(sourcePath, dest, overwrite: true);
        return dest;
    }

    private static string SanitizeFileName(string name)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var chars = name.Where(ch => !invalid.Contains(ch)).ToArray();
        return new string(chars);
    }

    private static string Truncate(string value) =>
        value.Length <= 500 ? value : value[..500];

    internal sealed record MagnetPayload(
        [property: JsonPropertyName("magnet")] string Magnet);

    internal sealed record TorrentPayload(
        [property: JsonPropertyName("path")] string Path);
}

[JsonSerializable(typeof(TorrentSubmitter.MagnetPayload))]
[JsonSerializable(typeof(TorrentSubmitter.TorrentPayload))]
[JsonSourceGenerationOptions(WriteIndented = false)]
internal sealed partial class SubmitterJsonContext : JsonSerializerContext
{
}
