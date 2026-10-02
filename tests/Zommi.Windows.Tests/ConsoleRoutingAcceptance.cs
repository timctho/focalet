using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows.Forms;
using Zommi.Windows;

internal static class ConsoleRoutingAcceptance
{
    public static int Receive(string directory)
    {
        Console.Title = "Zommi isolated console input";
        File.WriteAllText(Path.Combine(directory, "ready.tmp"), GetConsoleWindow().ToInt64().ToString(System.Globalization.CultureInfo.InvariantCulture));
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

    public static async Task RunAsync(CaptureInputTracker tracker)
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
            var window = new nint(long.Parse(File.ReadAllText(Path.Combine(temporary, "ready")), System.Globalization.CultureInfo.InvariantCulture));
            GetWindowThreadProcessId(window, out var processId);
            using var owner = Process.GetProcessById((int)processId);
            var consoleWindow = new CapturePasteTarget(window, 0, processId, owner.StartTime.ToUniversalTime().Ticks);
            if (!consoleWindow.Restore()) throw new InvalidOperationException("Could not activate the isolated console window.");
            await Task.Delay(200);
            var direct = await tracker.PauseAsync();
            if (direct?.Window != window) throw new InvalidOperationException("Capture invoked in a console chose the earlier browser.");
            tracker.Resume();
            await Task.Delay(100);
            using var source = new Form { Text = "Source after console", Size = new System.Drawing.Size(320, 200) };
            source.Controls.Add(new Button { Text = "Source content", Dock = DockStyle.Fill });
            source.Show(); source.Activate(); source.Controls[0].Focus();
            var target = await tracker.PauseAsync();
            if (target?.Window != window) throw new InvalidOperationException("Switching to the source lost the console destination.");
            source.Hide();
            if (!await target.RestoreInputAsync()) throw new InvalidOperationException("Console input restore failed: " + target.RestoreFailure);
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
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint window, out uint process);
}
