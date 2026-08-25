using System.Security.Cryptography;
using System.Text;

namespace Zommi.Core;

internal static class SnapshotChannel
{
    private static readonly string Suffix = ResolveSuffix();

    public static string MapName => $@"Local\Zommi.LiveContext.{Suffix}";

    public static string MutexName => $@"Local\Zommi.LiveContext.Lock.{Suffix}";

    private static string ResolveSuffix()
    {
        var requested = Environment.GetEnvironmentVariable("ZOMMI_CHANNEL");
        if (string.IsNullOrWhiteSpace(requested))
        {
            return "v1";
        }

        if (requested.Length <= 48 && requested.All(character => char.IsAsciiLetterOrDigit(character) || character is '-' or '_' or '.'))
        {
            return requested;
        }

        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(requested));
        return Convert.ToHexString(hash.AsSpan(0, 12)).ToLowerInvariant();
    }
}
