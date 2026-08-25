using Zommi.Core;

namespace Zommi.Windows;

internal sealed record ContextAttachment
{
    public required string Token { get; init; }

    public ContextSnapshot? Snapshot { get; init; }

    public byte[]? ImagePng { get; init; }

    public string PreviewText => Snapshot is null
        ? "User-selected screen region"
        : ContextFormatter.FormatPreview(Snapshot, DateTimeOffset.UtcNow);

    public string? ImageDataUrl => ImagePng is null
        ? null
        : $"data:image/png;base64,{Convert.ToBase64String(ImagePng)}";
}
