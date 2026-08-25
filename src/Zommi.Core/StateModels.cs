using System.Text.Json.Serialization;

namespace Zommi.Core;

[JsonConverter(typeof(JsonStringEnumConverter<CaptureMode>))]
public enum CaptureMode
{
    Active,
    Paused,
    Frozen,
    Detached,
}

public sealed record BindingState
{
    public string? SessionId { get; init; }

    public CaptureMode Mode { get; init; } = CaptureMode.Detached;

    public DateTimeOffset UpdatedAtUtc { get; init; }
}

public sealed record LocatorInfo
{
    public required string Kind { get; init; }

    public required string Value { get; init; }
}

public sealed record IndicatedTargetInfo
{
    public string? Name { get; init; }

    public string? ControlType { get; init; }

    public string? AutomationId { get; init; }

    public string? Bounds { get; init; }

    public required string Confidence { get; init; }
}

public sealed record ContextSnapshot
{
    public required string SnapshotId { get; init; }

    public DateTimeOffset ObservedAtUtc { get; init; }

    public DateTimeOffset ExpiresAtUtc { get; init; }

    public required string SurfaceKind { get; init; }

    public required string Application { get; init; }

    public required string ProcessName { get; init; }

    public string? WindowTitle { get; init; }

    public LocatorInfo? Locator { get; init; }

    public IReadOnlyList<string> Selection { get; init; } = [];

    public IndicatedTargetInfo? IndicatedTarget { get; init; }

    public required string Confidence { get; init; }

    public string? Limitation { get; init; }
}

public sealed record SessionPresence
{
    public required string SessionId { get; init; }

    public string? WorkingDirectory { get; init; }

    public string? Model { get; init; }

    public required string State { get; init; }

    public DateTimeOffset SeenAtUtc { get; init; }
}

public sealed record DeliveryReceipt
{
    public required string SessionId { get; init; }

    public required string SnapshotId { get; init; }

    public string? TurnId { get; init; }

    public DateTimeOffset DeliveredAtUtc { get; init; }
}
