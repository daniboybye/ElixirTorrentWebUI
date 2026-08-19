using System.Globalization;
using System.Text;

namespace ElixirTorrentWebUI.Launcher;

/// <summary>
/// Bounded, rotating text log for launcher diagnostics.
/// The log lives beside the release server log under LOCALAPPDATA.
///
/// Rotation policy: <see cref="MaxBytes"/> byte cap, <see cref="MaxRotated"/>
/// retained rotations (path, path.1, path.2, …). Rotation runs once during
/// <see cref="Rotate"/> and never mid-write, keeping the hot path lock-cheap.
/// </summary>
internal sealed class LauncherLog : IDisposable
{
    private const long MaxBytes = 512 * 1024;
    private const int MaxRotated = 3;

    private readonly string _path;
    private readonly object _sync = new();
    private StreamWriter? _writer;
    private bool _disposed;

    public LauncherLog(string path)
    {
        _path = path;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
    }

    /// <summary>
    /// Rotates the current log (if any) and any previously rotated files.
    /// Call once during launcher startup, before opening the writer.
    /// </summary>
    public void Rotate(bool includeServerLog = false)
    {
        lock (_sync)
        {
            RotateFileFamily(_path);

            // Only the launcher verb owns server.log. Rotating it from a
            // one-shot verb (--reveal, --check-defaults, …) renames the file the
            // running instance still has open: FileShare.Delete lets the rename
            // through, so the release keeps writing into server.log.1 while a
            // new server.log never appears.
            if (includeServerLog)
            {
                RotateFileFamily(Paths.Current.ServerLogPath);
            }
        }
    }

    /// <summary>Rotates a single family: file, file.1, …, file.MaxRotated.</summary>
    private static void RotateFileFamily(string path)
    {
        try
        {
            if (!File.Exists(path))
            {
                return;
            }

            var info = new FileInfo(path);
            if (info.Length < MaxBytes)
            {
                return;
            }

            // Rotate older files: file.(N-1) -> file.N, dropping the oldest.
            for (var i = MaxRotated; i >= 1; i--)
            {
                var older = $"{path}.{i}";
                if (i == MaxRotated && File.Exists(older))
                {
                    File.Delete(older);
                }
                else if (File.Exists(older))
                {
                    File.Move(older, $"{path}.{i + 1}", overwrite: true);
                }
            }

            File.Move(path, $"{path}.1", overwrite: true);
        }
        catch
        {
            // Never let logging bring the launcher down.
        }
    }

    public void Info(string message) => Write("INFO", message);

    public void Warn(string message) => Write("WARN", message);

    public void Error(string message, Exception? exception = null)
    {
        if (exception is null)
        {
            Write("ERROR", message);
        }
        else
        {
            Write("ERROR", message + Environment.NewLine + exception);
        }
    }

    private void Write(string level, string message)
    {
        try
        {
            lock (_sync)
            {
                if (_disposed)
                {
                    return;
                }

                _writer ??= OpenWriter();
                _writer.WriteLine(FormatLine(level, message));
                _writer.Flush();
            }
        }
        catch
        {
            // Never let logging bring the launcher down.
        }
    }

    private StreamWriter OpenWriter()
    {
        // ReadWrite, not just Read: each CLI helper verb is a separate process
        // running while the primary instance holds this file open, and a
        // writer-exclusive share mode makes their opens fail — losing exactly
        // the diagnostics needed to debug them. Delete lets Rotate() rename the
        // file out from under an open handle. Append writes at the OS
        // end-of-file, one flushed line at a time, so lines never tear.
        var stream = new FileStream(
            _path,
            FileMode.Append,
            FileAccess.Write,
            FileShare.ReadWrite | FileShare.Delete,
            bufferSize: 4096,
            options: FileOptions.SequentialScan);

        return new StreamWriter(stream, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false))
        {
            AutoFlush = false,
        };
    }

    private static string FormatLine(string level, string message) =>
        string.Create(CultureInfo.InvariantCulture, $"{DateTime.UtcNow:yyyy-MM-ddTHH:mm:ss.fffZ} [{level}] {message}");

    /// <summary>
    /// Opens the release server log for append; used to redirect the release
    /// stdout/stderr. Rotation has already dropped anything over the cap.
    /// </summary>
    public static FileStream OpenServerLogForAppend(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        return new FileStream(
            path,
            FileMode.Append,
            FileAccess.Write,
            FileShare.Read | FileShare.Delete,
            bufferSize: 4096,
            options: FileOptions.SequentialScan);
    }

    public void Dispose()
    {
        lock (_sync)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            _writer?.Dispose();
            _writer = null;
        }
    }
}
