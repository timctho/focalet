namespace Zommi.Windows;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        RuntimeOptions.Apply(args);

        if (args.Contains("--electron-host", StringComparer.OrdinalIgnoreCase))
        {
            return ElectronNativeHost.Run();
        }

        if (args.Contains("--acceptance-capture-once", StringComparer.OrdinalIgnoreCase))
        {
            return AcceptanceProbe.CaptureOnce();
        }

        if (args.Contains("--acceptance-selected-text", StringComparer.OrdinalIgnoreCase))
        {
            return AcceptanceProbe.SelectedTextCapture();
        }

        Console.Error.WriteLine("Zommi.Windows is the capture-only Electron native host. Start the packaged Zommi desktop application instead.");
        return 2;
    }
}
