namespace Zommi.Core;

public static class ContextTokens
{
    public static string Create(ContextSnapshot snapshot, IEnumerable<string>? existingTokens = null)
    {
        var label = Abbreviate(snapshot);
        var token = $"[{label}]";
        var existing = existingTokens is null
            ? new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            : new HashSet<string>(existingTokens, StringComparer.OrdinalIgnoreCase);
        if (!existing.Contains(token))
        {
            return token;
        }

        for (var suffix = 2; suffix < 1000; suffix++)
        {
            token = $"[{label} {suffix}]";
            if (!existing.Contains(token))
            {
                return token;
            }
        }

        return $"[{label} {Guid.NewGuid():N}]";
    }

    public static string CreateImage(IEnumerable<string>? existingTokens = null)
    {
        var existing = existingTokens is null
            ? new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            : new HashSet<string>(existingTokens, StringComparer.OrdinalIgnoreCase);
        if (!existing.Contains("[image]"))
        {
            return "[image]";
        }

        for (var suffix = 2; suffix < 1000; suffix++)
        {
            var token = $"[image {suffix}]";
            if (!existing.Contains(token))
            {
                return token;
            }
        }

        return $"[image {Guid.NewGuid():N}]";
    }

    public static string Abbreviate(ContextSnapshot snapshot)
    {
        if (snapshot.Locator is { } locator &&
            locator.Kind.Equals("URL", StringComparison.OrdinalIgnoreCase) &&
            Uri.TryCreate(locator.Value, UriKind.Absolute, out var uri))
        {
            var host = uri.IdnHost;
            if (host.StartsWith("www.", StringComparison.OrdinalIgnoreCase))
            {
                host = host[4..];
            }

            return Bound(host, 30, "context");
        }

        return Bound(snapshot.Application, 30, "context").ToLowerInvariant().Replace(' ', '-');
    }

    private static string Bound(string? value, int maximumLength, string fallback)
    {
        value = value?.Trim();
        if (string.IsNullOrWhiteSpace(value))
        {
            return fallback;
        }

        return value.Length <= maximumLength
            ? value
            : string.Concat(value.AsSpan(0, maximumLength - 1), "…");
    }
}
