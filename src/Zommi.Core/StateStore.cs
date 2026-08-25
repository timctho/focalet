using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Zommi.Core;

public interface IContextSnapshotReader
{
    ContextSnapshot? ReadSnapshot();
}

public sealed class StateStore : IContextSnapshotReader
{
    private const string BindingFile = "binding.json";
    private const string SnapshotFile = "snapshot.json";
    private const string DeliveryFile = "delivery.json";
    private const string LaunchIntentFile = "launch-intent.json";

    private readonly JsonSerializerOptions jsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    public StateStore(string rootDirectory)
    {
        RootDirectory = Path.GetFullPath(rootDirectory);
    }

    public string RootDirectory { get; }

    public static string GetDefaultRoot()
    {
        var overrideRoot = Environment.GetEnvironmentVariable("ZOMMI_STATE_ROOT");
        if (!string.IsNullOrWhiteSpace(overrideRoot))
        {
            return Path.GetFullPath(overrideRoot);
        }

        var localData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localData))
        {
            localData = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "share");
        }

        return Path.Combine(localData, "Zommi");
    }

    public BindingState? ReadBinding() => Read<BindingState>(Path.Combine(RootDirectory, BindingFile));

    public void WriteBinding(BindingState binding) => Write(Path.Combine(RootDirectory, BindingFile), binding);

    public ContextSnapshot? ReadSnapshot() => Read<ContextSnapshot>(Path.Combine(RootDirectory, SnapshotFile));

    public void WriteSnapshot(ContextSnapshot snapshot) => Write(Path.Combine(RootDirectory, SnapshotFile), snapshot);

    public void DeleteSnapshot() => TryDelete(Path.Combine(RootDirectory, SnapshotFile));

    public DeliveryReceipt? ReadDelivery() => Read<DeliveryReceipt>(Path.Combine(RootDirectory, DeliveryFile));

    public void WriteDelivery(DeliveryReceipt receipt) => Write(Path.Combine(RootDirectory, DeliveryFile), receipt);

    public SessionLaunchIntent? ReadLaunchIntent() => Read<SessionLaunchIntent>(Path.Combine(RootDirectory, LaunchIntentFile));

    public void WriteLaunchIntent(SessionLaunchIntent intent) => Write(Path.Combine(RootDirectory, LaunchIntentFile), intent);

    public void DeleteLaunchIntent() => TryDelete(Path.Combine(RootDirectory, LaunchIntentFile));

    public IReadOnlyList<SessionPresence> ReadSessions()
    {
        var directory = Path.Combine(RootDirectory, "sessions");
        if (!Directory.Exists(directory))
        {
            return [];
        }

        var sessions = new List<SessionPresence>();
        foreach (var file in Directory.EnumerateFiles(directory, "*.json", SearchOption.TopDirectoryOnly))
        {
            var session = Read<SessionPresence>(file);
            if (session is not null)
            {
                sessions.Add(session);
            }
        }

        return sessions.OrderByDescending(session => session.SeenAtUtc).ToArray();
    }

    public void WriteSession(SessionPresence session)
    {
        var directory = Path.Combine(RootDirectory, "sessions");
        var file = Path.Combine(directory, $"{SafeFileName(session.SessionId)}.json");
        Write(file, session);
    }

    private T? Read<T>(string path)
    {
        try
        {
            if (!File.Exists(path))
            {
                return default;
            }

            return JsonSerializer.Deserialize<T>(File.ReadAllText(path, Encoding.UTF8), jsonOptions);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
        {
            return default;
        }
    }

    private void Write<T>(string path, T value)
    {
        var directory = Path.GetDirectoryName(path) ?? throw new InvalidOperationException("State path has no directory.");
        Directory.CreateDirectory(directory);

        var temporaryPath = Path.Combine(directory, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            var json = JsonSerializer.Serialize(value, jsonOptions);
            File.WriteAllText(temporaryPath, json, new UTF8Encoding(false));
            File.Move(temporaryPath, path, overwrite: true);
        }
        finally
        {
            TryDelete(temporaryPath);
        }
    }

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            // State is advisory and must never block the bound agent runtime.
        }
    }

    private static string SafeFileName(string value)
    {
        if (Guid.TryParse(value, out var id))
        {
            return id.ToString("D");
        }

        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(value));
        return Convert.ToHexString(hash).ToLowerInvariant();
    }
}
