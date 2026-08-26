using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;

namespace Zommi.Windows;

internal sealed class ChromeDevToolsBrowser : IDisposable
{
    private readonly Process process;
    private readonly string profileDirectory;
    private bool disposed;

    private ChromeDevToolsBrowser(Process process, string profileDirectory, int port)
    {
        this.process = process;
        this.profileDirectory = profileDirectory;
        Port = port;
    }

    public int Port { get; }

    public static async Task<ChromeDevToolsBrowser> StartAsync(CancellationToken cancellationToken)
    {
        var executable = FindExecutable();
        var port = ReserveLoopbackPort();
        var profileDirectory = Path.Combine(
            Path.GetTempPath(),
            $"zommi-chrome-tool-{Guid.NewGuid():N}");
        Directory.CreateDirectory(profileDirectory);

        var startInfo = new ProcessStartInfo
        {
            FileName = executable,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        startInfo.ArgumentList.Add("--headless=new");
        startInfo.ArgumentList.Add($"--remote-debugging-port={port}");
        startInfo.ArgumentList.Add("--remote-debugging-address=127.0.0.1");
        startInfo.ArgumentList.Add($"--user-data-dir={profileDirectory}");
        startInfo.ArgumentList.Add("--no-first-run");
        startInfo.ArgumentList.Add("--no-default-browser-check");
        startInfo.ArgumentList.Add("--disable-component-update");
        startInfo.ArgumentList.Add("--disable-sync");
        startInfo.ArgumentList.Add("about:blank");

        Process? process = null;
        try
        {
            process = Process.Start(startInfo)
                ?? throw new InvalidOperationException("Windows could not start the isolated Chrome tool browser.");
            var browser = new ChromeDevToolsBrowser(process, profileDirectory, port);
            await browser.WaitUntilReadyAsync(cancellationToken).ConfigureAwait(false);
            return browser;
        }
        catch
        {
            if (process is not null)
            {
                TryStopProcess(process);
                process.Dispose();
            }

            TryDeleteDirectory(profileDirectory);
            throw;
        }
    }

    private async Task WaitUntilReadyAsync(CancellationToken cancellationToken)
    {
        using var client = new HttpClient
        {
            Timeout = TimeSpan.FromMilliseconds(750),
        };
        var endpoint = new Uri($"http://127.0.0.1:{Port}/json/version");
        var deadline = DateTimeOffset.UtcNow.AddSeconds(15);
        Exception? lastError = null;

        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (process.HasExited)
            {
                throw new InvalidOperationException(
                    $"The isolated Chrome tool browser exited with code {process.ExitCode} before CDP was ready.");
            }

            try
            {
                using var response = await client.GetAsync(endpoint, cancellationToken).ConfigureAwait(false);
                if (response.IsSuccessStatusCode)
                {
                    return;
                }

                lastError = new InvalidOperationException(
                    $"Chrome CDP returned HTTP {(int)response.StatusCode}.");
            }
            catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException)
            {
                lastError = exception;
            }

            await Task.Delay(100, cancellationToken).ConfigureAwait(false);
        }

        throw new InvalidOperationException(
            $"The isolated Chrome tool browser did not expose CDP on port {Port}.",
            lastError);
    }

    private static string FindExecutable()
    {
        var overridePath = Environment.GetEnvironmentVariable("ZOMMI_CHROME_PATH");
        if (!string.IsNullOrWhiteSpace(overridePath))
        {
            var resolvedOverride = Path.GetFullPath(overridePath);
            if (!File.Exists(resolvedOverride))
            {
                throw new FileNotFoundException(
                    "ZOMMI_CHROME_PATH does not point to an executable.",
                    resolvedOverride);
            }

            return resolvedOverride;
        }

        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var programFilesX86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var candidates = new[]
        {
            Path.Combine(programFiles, "Google", "Chrome", "Application", "chrome.exe"),
            Path.Combine(programFilesX86, "Google", "Chrome", "Application", "chrome.exe"),
            Path.Combine(localAppData, "Google", "Chrome", "Application", "chrome.exe"),
            Path.Combine(programFiles, "Microsoft", "Edge", "Application", "msedge.exe"),
            Path.Combine(programFilesX86, "Microsoft", "Edge", "Application", "msedge.exe"),
        };
        return candidates.FirstOrDefault(File.Exists)
            ?? throw new FileNotFoundException(
                "Chrome tool requires Google Chrome or Microsoft Edge on Windows. " +
                "Set ZOMMI_CHROME_PATH to use another Chromium executable.");
    }

    private static int ReserveLoopbackPort()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        return ((IPEndPoint)listener.LocalEndpoint).Port;
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        TryStopProcess(process);
        process.Dispose();
        TryDeleteDirectory(profileDirectory);
    }

    private static void TryStopProcess(Process candidate)
    {
        try
        {
            if (!candidate.HasExited)
            {
                candidate.Kill(entireProcessTree: true);
                _ = candidate.WaitForExit(3000);
            }
        }
        catch (Exception exception) when (exception is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            // The process already exited or Windows completed teardown first.
        }
    }

    private static void TryDeleteDirectory(string directory)
    {
        for (var attempt = 0; attempt < 5 && Directory.Exists(directory); attempt++)
        {
            try
            {
                Directory.Delete(directory, recursive: true);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                if (attempt < 4)
                {
                    Thread.Sleep(100);
                }
            }
        }
    }
}
