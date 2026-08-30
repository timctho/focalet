namespace Zommi.Windows;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Contains("--capture-host", StringComparer.OrdinalIgnoreCase))
        {
            return CaptureNativeHost.Run();
        }

        if (args.Contains("--acceptance-capture-once", StringComparer.OrdinalIgnoreCase))
        {
            return AcceptanceProbe.CaptureOnce();
        }

        if (args.Contains("--acceptance-selected-text", StringComparer.OrdinalIgnoreCase))
        {
            return AcceptanceProbe.SelectedTextCapture();
        }

        Console.Error.WriteLine("Zommi.Capture is a capture-only helper. Start the packaged Flutter Zommi application instead.");
        return 2;
    }
}
