using System.IO;
using System.IO.MemoryMappedFiles;
using System.Text;
using System.Text.Json;
using Zommi.Core;

namespace Zommi.Windows;

internal sealed class SharedSnapshotStore : IContextSnapshotReader, IDisposable
{
    private const string MapName = @"Local\Zommi.LiveContext.v1";
    private const string MutexName = @"Local\Zommi.LiveContext.Lock.v1";
    private const int Capacity = 64 * 1024;
    private readonly MemoryMappedFile memoryMap;
    private readonly Mutex mutex = new(initiallyOwned: false, MutexName);

    private SharedSnapshotStore()
    {
        memoryMap = MemoryMappedFile.CreateOrOpen(MapName, Capacity, MemoryMappedFileAccess.ReadWrite);
        DeleteSnapshot();
    }

    public static SharedSnapshotStore CreateOwner() => new();

    public ContextSnapshot? ReadSnapshot()
    {
        var lockTaken = false;
        try
        {
            lockTaken = WaitForLock(mutex);
            if (!lockTaken)
            {
                return null;
            }

            using var accessor = memoryMap.CreateViewAccessor(0, Capacity, MemoryMappedFileAccess.Read);
            var length = accessor.ReadInt32(0);
            if (length <= 0 || length > Capacity - sizeof(int))
            {
                return null;
            }

            var payload = new byte[length];
            _ = accessor.ReadArray(sizeof(int), payload, 0, length);
            return JsonSerializer.Deserialize<ContextSnapshot>(payload);
        }
        catch (Exception exception) when (exception is IOException or JsonException or UnauthorizedAccessException)
        {
            return null;
        }
        finally
        {
            if (lockTaken)
            {
                mutex.ReleaseMutex();
            }
        }
    }

    public void WriteSnapshot(ContextSnapshot snapshot)
    {
        var payload = JsonSerializer.SerializeToUtf8Bytes(snapshot);
        if (payload.Length > Capacity - sizeof(int))
        {
            throw new InvalidOperationException("The structured context snapshot is too large for the ephemeral buffer.");
        }

        var lockTaken = false;
        try
        {
            lockTaken = WaitForLock(mutex);
            if (!lockTaken)
            {
                return;
            }

            using var accessor = memoryMap.CreateViewAccessor(0, Capacity, MemoryMappedFileAccess.Write);
            accessor.Write(0, 0);
            accessor.WriteArray(sizeof(int), payload, 0, payload.Length);
            accessor.Write(0, payload.Length);
            accessor.Flush();
        }
        finally
        {
            if (lockTaken)
            {
                mutex.ReleaseMutex();
            }
        }
    }

    public void DeleteSnapshot()
    {
        var lockTaken = false;
        try
        {
            lockTaken = WaitForLock(mutex);
            if (!lockTaken)
            {
                return;
            }

            using var accessor = memoryMap.CreateViewAccessor(0, sizeof(int), MemoryMappedFileAccess.Write);
            accessor.Write(0, 0);
            accessor.Flush();
        }
        finally
        {
            if (lockTaken)
            {
                mutex.ReleaseMutex();
            }
        }
    }

    public void Dispose()
    {
        DeleteSnapshot();
        memoryMap.Dispose();
        mutex.Dispose();
    }

    private static bool WaitForLock(Mutex value)
    {
        try
        {
            return value.WaitOne(TimeSpan.FromMilliseconds(100));
        }
        catch (AbandonedMutexException)
        {
            return true;
        }
    }
}

internal sealed class SharedSnapshotReader : IContextSnapshotReader
{
    public ContextSnapshot? ReadSnapshot()
    {
        try
        {
            using var map = MemoryMappedFile.OpenExisting(MapName, MemoryMappedFileRights.Read);
            using var mutex = Mutex.OpenExisting(MutexName);
            var lockTaken = false;
            try
            {
                lockTaken = WaitForLock(mutex);
                if (!lockTaken)
                {
                    return null;
                }

                using var accessor = map.CreateViewAccessor(0, Capacity, MemoryMappedFileAccess.Read);
                var length = accessor.ReadInt32(0);
                if (length <= 0 || length > Capacity - sizeof(int))
                {
                    return null;
                }

                var payload = new byte[length];
                _ = accessor.ReadArray(sizeof(int), payload, 0, length);
                return JsonSerializer.Deserialize<ContextSnapshot>(payload);
            }
            finally
            {
                if (lockTaken)
                {
                    mutex.ReleaseMutex();
                }
            }
        }
        catch (Exception exception) when (exception is FileNotFoundException or WaitHandleCannotBeOpenedException or IOException or JsonException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private const string MapName = @"Local\Zommi.LiveContext.v1";
    private const string MutexName = @"Local\Zommi.LiveContext.Lock.v1";
    private const int Capacity = 64 * 1024;

    private static bool WaitForLock(Mutex value)
    {
        try
        {
            return value.WaitOne(TimeSpan.FromMilliseconds(100));
        }
        catch (AbandonedMutexException)
        {
            return true;
        }
    }
}
