using System.Globalization;
using System.Net;
using System.Net.Sockets;

namespace ElixirTorrentWebUI.Launcher;

/// <summary>
/// Chooses which loopback port the launcher will drive the release on.
///
/// Priority:
///  1. explicit PORT environment variable (validated 1–65535);
///  2. a random ephemeral port claimed by binding 127.0.0.1:0 and reading back
///     the assigned port. The listener is closed immediately; the port stays
///     available for the release to grab moments later. This is standard
///     "port hole" allocation and mirrors what tooling like Kestrel does when
///     asked for port 0.
/// </summary>
internal static class PortManager
{
    private const string PortEnv = "PORT";
    private const int MinPort = 1;
    private const int MaxPort = 65535;

    public static int Choose()
    {
        var fromEnv = Environment.GetEnvironmentVariable(PortEnv);
        if (!string.IsNullOrWhiteSpace(fromEnv)
            && int.TryParse(fromEnv, NumberStyles.Integer, CultureInfo.InvariantCulture, out var explicitPort)
            && explicitPort is >= MinPort and <= MaxPort)
        {
            return explicitPort;
        }

        return AllocateEphemeralLoopbackPort();
    }

    public static bool IsListening(int port)
    {
        try
        {
            using var probe = new TcpClient();
            var task = probe.ConnectAsync(IPAddress.Loopback, port);
            return task.Wait(TimeSpan.FromMilliseconds(400)) && probe.Connected;
        }
        catch
        {
            return false;
        }
    }

    private static int AllocateEphemeralLoopbackPort()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        try
        {
            return ((IPEndPoint)listener.LocalEndpoint).Port;
        }
        finally
        {
            listener.Stop();
        }
    }
}
