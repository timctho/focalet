using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows.Forms;
using Zommi.Windows;

internal static class ConsoleRoutingAcceptance
{
    public static int Receive(string directory)
    {
        var title = "Zommi console " + Path.GetFileName(directory);
        Console.Title = title;
        File.WriteAllText(Path.Combine(directory, "ready.tmp"), JsonSerializer.Serialize(new { window = GetConsoleWindow().ToInt64(), title }));
        File.Move(Path.Combine(directory, "ready.tmp"), Path.Combine(directory, "ready"));
        var received = new System.Text.StringBuilder();
        var deadline = Stopwatch.StartNew();
        while (deadline.Elapsed < TimeSpan.FromMinutes(2))
        {
            if (Console.KeyAvailable)
            {
                var key = Console.ReadKey(intercept: true);
                if (key.KeyChar != '\0')
                {
                    received.Append(key.KeyChar);
                    File.WriteAllText(Path.Combine(directory, "received"), received.ToString());
                }
            }
            else Thread.Sleep(10);
        }
        return 0;
    }

    public static async Task RunAsync()
    {
        var temporary = Path.Combine(Path.GetTempPath(), "zommi-console-input-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temporary);
        // ShellExecute starts the console-subsystem dotnet host in its own
        // console instead of inheriting the CI runner's redirected handles.
        // There is no command interpreter or personal profile in this receiver.
        var runtime = new DirectoryInfo(System.Runtime.InteropServices.RuntimeEnvironment.GetRuntimeDirectory());
        var dotnet = Path.Combine(runtime.Parent!.Parent!.Parent!.FullName, "dotnet.exe");
        var start = new ProcessStartInfo(dotnet) { UseShellExecute = true };
        start.ArgumentList.Add(typeof(ConsoleRoutingAcceptance).Assembly.Location);
        start.ArgumentList.Add("--console-receiver");
        start.ArgumentList.Add(temporary);
        using var host = Process.Start(start) ?? throw new InvalidOperationException("Could not start the isolated console host.");
        try
        {
            await ForegroundRoutingAcceptance.WaitFor(() => File.Exists(Path.Combine(temporary, "ready")), "The console fixture did not start.", 15000);
            using var ready = JsonDocument.Parse(File.ReadAllText(Path.Combine(temporary, "ready")));
            var nativeWindow = new nint(ready.RootElement.GetProperty("window").GetInt64());
            var title = ready.RootElement.GetProperty("title").GetString()!;
            nint window = 0;
            // GetConsoleWindow is a hidden compatibility HWND when Windows
            // delegates the visible console to Windows Terminal. Find only our
            // unique synthetic title, and wait for the UI before activating it.
            await ForegroundRoutingAcceptance.WaitFor(() =>
            {
                var named = FindWindow(null, title);
                window = named != 0 && IsWindowVisible(named) ? named : IsWindowVisible(nativeWindow) ? nativeWindow : 0;
                return window != 0;
            }, $"No visible console fixture window appeared (native HWND {nativeWindow}).");
            SetWindowPos(window, new nint(-1), 0, 0, 0, 0, 0x0043);
            await Task.Delay(150);
            Console.WriteLine($"Console fixture window: native={nativeWindow}; visible={window}; foreground={GetForegroundWindow()}");
            GetWindowThreadProcessId(window, out var processId);
            using var owner = Process.GetProcessById((int)processId);
            var consoleWindow = new CapturePasteTarget(window, 0, processId, owner.StartTime.ToUniversalTime().Ticks);
            if (!consoleWindow.Restore()) throw new InvalidOperationException("Could not activate the isolated console window.");
            await Task.Delay(200);
            var target = CapturePasteTarget.RememberWindow();
            if (target?.Window != window) throw new InvalidOperationException("Explicit console paste chose the earlier browser.");
            const string marker = "zommi-console-paste-fixture";
            Clipboard.SetText(marker);
            if (!target.Paste(CapturePasteTarget.GetClipboardSequenceNumber())) throw new InvalidOperationException("Console paste was not dispatched.");
            string ReadReceived()
            {
                try { return File.ReadAllText(Path.Combine(temporary, "received")); }
                catch (IOException) { return ""; }
            }
            await ForegroundRoutingAcceptance.WaitFor(() => ReadReceived() == marker,
                "The actual console did not receive the paste at its input.");
            await Task.Delay(100);
            if (ReadReceived() != marker) throw new InvalidOperationException("The console received unexpected extra keys: " + JsonSerializer.Serialize(ReadReceived()));
        }
        finally
        {
            if (!host.HasExited) host.Kill(entireProcessTree: true);
            await host.WaitForExitAsync();
            Directory.Delete(temporary, recursive: true);
        }
    }

    [DllImport("kernel32.dll")] private static extern nint GetConsoleWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern nint FindWindow(string? className, string title);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(nint window);
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool SetWindowPos(nint window, nint after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint window, out uint process);
}
