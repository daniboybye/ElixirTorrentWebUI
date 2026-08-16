using System.Runtime.InteropServices;

namespace ElixirTorrentWebUI.Launcher;

/// <summary>
/// Windows Job Object that binds child processes to the launcher's lifetime.
/// When the launcher exits (cleanly or via crash), every process assigned to
/// this job is terminated. This is our safety net when graceful `stop` fails.
/// </summary>
internal sealed class JobObject : IDisposable
{
    private IntPtr _handle;

    public JobObject()
    {
        _handle = NativeMethods.CreateJobObject(IntPtr.Zero, null);
        if (_handle == IntPtr.Zero)
        {
            throw new InvalidOperationException(
                "CreateJobObject failed: " + Marshal.GetLastPInvokeErrorMessage());
        }

        var info = new NativeMethods.JobObjectExtendedLimitInformation
        {
            BasicLimitInformation = new NativeMethods.JobObjectBasicLimitInformation
            {
                LimitFlags = (uint)NativeMethods.JobObjectLimit.KillOnJobClose,
            },
        };

        if (!NativeMethods.SetInformationJobObject(
                _handle,
                NativeMethods.JobObjectExtendedLimitInformationClass,
                ref info,
                Marshal.SizeOf(info)))
        {
            NativeMethods.CloseHandle(_handle);
            _handle = IntPtr.Zero;
            throw new InvalidOperationException(
                "SetInformationJobObject failed: " + Marshal.GetLastPInvokeErrorMessage());
        }
    }

    public bool TryAssign(IntPtr processHandle) =>
        _handle != IntPtr.Zero && NativeMethods.AssignProcessToJobObject(_handle, processHandle);

    public void Dispose()
    {
        if (_handle != IntPtr.Zero)
        {
            NativeMethods.CloseHandle(_handle);
            _handle = IntPtr.Zero;
        }
    }
}
