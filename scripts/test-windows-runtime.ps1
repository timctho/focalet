[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ExecutablePath,

    [string] $HookExecutablePath,

    [switch] $SkipBrowser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Quote-Argument {
    param([string] $Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-CapturedProcess {
    param(
        [string] $FilePath,
        [string] $Arguments,
        [AllowNull()][string] $StandardInput
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $null -ne $StandardInput

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    Assert-True ($process.Start()) "Could not start $FilePath."
    if ($null -ne $StandardInput) {
        $process.StandardInput.WriteLine($StandardInput)
        $process.StandardInput.Close()
    }

    $standardOutput = $process.StandardOutput.ReadToEnd()
    $standardError = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StandardOutput = $standardOutput
        StandardError = $standardError
    }
}

function Invoke-Hook {
    param([string] $Executable, [string] $GlobalArguments, [string] $SessionId)
    $hookEvent = @{
        session_id = $SessionId
        turn_id = 'windows-runtime-turn'
        cwd = 'C:\zommi-acceptance'
        hook_event_name = 'UserPromptSubmit'
        model = 'acceptance-model'
        prompt = 'Use the current context.'
    } | ConvertTo-Json -Compress

    return Invoke-CapturedProcess $Executable "--zommi-hook $GlobalArguments" $hookEvent
}

if (-not [Environment]::Is64BitOperatingSystem -or [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This acceptance script requires 64-bit Windows.'
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('zommi-runtime-' + [Guid]::NewGuid().ToString('N'))
$stateRoot = Join-Path $temporaryRoot 'state'
$executable = Join-Path $temporaryRoot 'Zommi.exe'
$hookExecutable = Join-Path $temporaryRoot 'Zommi.Hook.exe'
$channel = 'acceptance-' + [Guid]::NewGuid().ToString('N')
$sessionA = '11111111-1111-1111-1111-111111111111'
$sessionB = '22222222-2222-2222-2222-222222222222'
$globalArguments = '--state-root {0} --channel {1}' -f (Quote-Argument $stateRoot), (Quote-Argument $channel)
$owner = $null
$explorerWindow = $null
$edgeWindow = $null
$edgeProfile = $null
$results = [ordered]@{}

try {
    if ([string]::IsNullOrWhiteSpace($HookExecutablePath)) {
        $HookExecutablePath = Join-Path (Split-Path -Parent $ExecutablePath) 'Zommi.Hook.exe'
    }
    Assert-True (Test-Path -LiteralPath $HookExecutablePath) 'Zommi.Hook.exe was not found next to the Windows prototype.'
    New-Item -ItemType Directory -Force -Path $temporaryRoot, $stateRoot | Out-Null
    Copy-Item -LiteralPath $ExecutablePath -Destination $executable
    Copy-Item -LiteralPath $HookExecutablePath -Destination $hookExecutable

    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ZommiNativeWindow {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr processId);
    [DllImport("user32.dll")]
    private static extern bool AttachThreadInput(uint attach, uint attachTo, bool value);
    [DllImport("user32.dll")]
    private static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int command);

    public static bool Activate(IntPtr target) {
        IntPtr foreground = GetForegroundWindow();
        uint foregroundThread = GetWindowThreadProcessId(foreground, IntPtr.Zero);
        uint targetThread = GetWindowThreadProcessId(target, IntPtr.Zero);
        bool attached = foregroundThread != targetThread && AttachThreadInput(foregroundThread, targetThread, true);
        try {
            ShowWindow(target, 9);
            BringWindowToTop(target);
            return SetForegroundWindow(target);
        } finally {
            if (attached) AttachThreadInput(foregroundThread, targetThread, false);
        }
    }
}
'@

    $gui = Start-Process -FilePath $executable -ArgumentList $globalArguments -PassThru
    $guiReady = $false
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        Start-Sleep -Milliseconds 100
        $gui.Refresh()
        if ($gui.MainWindowHandle -ne 0 -and $gui.MainWindowTitle -like 'Zommi*') {
            $guiReady = $true
            break
        }
    }
    Assert-True $guiReady 'Zommi did not open a native Windows GUI window.'
    $results.gui = 'passed'
    [void] $gui.CloseMainWindow()
    Assert-True ($gui.WaitForExit(5000)) 'Zommi GUI did not close cleanly.'

    if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
        Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $HookExecutablePath) 'Zommi.WslHook.ps1') -Destination (Join-Path $temporaryRoot 'Zommi.WslHook.ps1')
        $wslDiscovery = Invoke-CapturedProcess $executable "--acceptance-discover-wsl $globalArguments" $null
        Assert-True ($wslDiscovery.ExitCode -eq 0) "WSL hook discovery failed: $($wslDiscovery.StandardError)"
        $wslJson = $wslDiscovery.StandardOutput | ConvertFrom-Json
        Assert-True ($wslJson.hooksPath -like '\\wsl.localhost\*\.codex\hooks.json') 'WSL hook discovery returned an invalid hooks path.'
        Assert-True ($wslJson.command -like '*Zommi.WslHook.ps1*') 'WSL hook discovery returned an invalid command.'
        $results.wslHookDiscovery = 'passed'
    }

    $ownerOutput = Join-Path $temporaryRoot 'owner.stdout.txt'
    $ownerError = Join-Path $temporaryRoot 'owner.stderr.txt'
    $ownerArguments = "--acceptance-probe --session $sessionA --seconds 60 $globalArguments"
    $owner = Start-Process -FilePath $executable -ArgumentList $ownerArguments -RedirectStandardOutput $ownerOutput -RedirectStandardError $ownerError -PassThru
    $ownerReady = $false
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        Start-Sleep -Milliseconds 100
        if (Test-Path $ownerOutput) {
            $readyText = Get-Content -Raw $ownerOutput
            if ($readyText -like "READY $sessionA*") {
                $ownerReady = $true
                break
            }
        }
        if ($owner.HasExited) {
            break
        }
    }
    if (-not $ownerReady) {
        $probeError = if (Test-Path $ownerError) { Get-Content -Raw $ownerError } else { '' }
        throw "The shared-memory probe did not become ready. $probeError"
    }

    $boundHook = Invoke-Hook $hookExecutable $globalArguments $sessionA
    Assert-True ($boundHook.ExitCode -eq 0) "The bound hook failed: $($boundHook.StandardError)"
    $boundJson = $boundHook.StandardOutput | ConvertFrom-Json
    $additionalContext = $boundJson.hookSpecificOutput.additionalContext
    Assert-True ($additionalContext -like '*https://windows-runtime-probe.example/zommi*') 'The Windows hook did not read the shared-memory snapshot.'
    Assert-True ($additionalContext -like "*Exact Codex session: $sessionA*") 'The Windows hook output did not preserve the exact session id.'

    $wrongHook = Invoke-Hook $hookExecutable $globalArguments $sessionB
    Assert-True ($wrongHook.ExitCode -eq 0) "The wrong-session hook failed: $($wrongHook.StandardError)"
    Assert-True ([string]::IsNullOrWhiteSpace($wrongHook.StandardOutput)) 'An unbound session received Zommi context.'
    $results.exactSessionHook = 'passed'

    Stop-Process -Id $owner.Id -Force
    $owner.WaitForExit()
    $owner = $null
    Start-Sleep -Milliseconds 250
    $closedHook = Invoke-Hook $hookExecutable $globalArguments $sessionA
    Assert-True ([string]::IsNullOrWhiteSpace($closedHook.StandardOutput)) 'Context survived after the shared-memory owner exited.'
    Assert-True (-not (Test-Path (Join-Path $stateRoot 'snapshot.json'))) 'A snapshot was written to disk.'
    $results.ephemeralSharedMemory = 'passed'

    $explorerFolder = Join-Path $temporaryRoot ('explorer-marker-' + [Guid]::NewGuid().ToString('N'))
    $selectedFile = Join-Path $explorerFolder 'selected-zommi-file.txt'
    New-Item -ItemType Directory -Path $explorerFolder | Out-Null
    [IO.File]::WriteAllText($selectedFile, 'zommi acceptance')
    Start-Process -FilePath explorer.exe -ArgumentList (Quote-Argument $explorerFolder) | Out-Null
    $shell = New-Object -ComObject Shell.Application
    for ($attempt = 0; $attempt -lt 100 -and $null -eq $explorerWindow; $attempt++) {
        Start-Sleep -Milliseconds 100
        foreach ($candidate in @($shell.Windows())) {
            try {
                if ([string]::Equals([string] $candidate.Document.Folder.Self.Path, $explorerFolder, [StringComparison]::OrdinalIgnoreCase)) {
                    $explorerWindow = $candidate
                    break
                }
            } catch {
                # A shell surface without a Folder view is not the target Explorer window.
            }
        }
    }
    Assert-True ($null -ne $explorerWindow) 'The acceptance Explorer window did not open.'
    $explorerWindow.Document.SelectItem($selectedFile, 29)
    $explorerCapture = $null
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        [void] [ZommiNativeWindow]::Activate([IntPtr] ([int64] $explorerWindow.HWND))
        Start-Sleep -Milliseconds 500
        $explorerCapture = Invoke-CapturedProcess $executable "--acceptance-capture-once $globalArguments" $null
        if ($explorerCapture.ExitCode -eq 0) {
            break
        }
    }
    Assert-True ($null -ne $explorerCapture -and $explorerCapture.ExitCode -eq 0) "Explorer capture failed. stdout=$($explorerCapture.StandardOutput) stderr=$($explorerCapture.StandardError) foreground=$([ZommiNativeWindow]::GetForegroundWindow()) expected=$($explorerWindow.HWND)"
    $explorerJson = $explorerCapture.StandardOutput | ConvertFrom-Json
    Assert-True ($explorerJson.snapshot.surfaceKind -eq 'File Explorer') 'Explorer was not classified as File Explorer.'
    Assert-True ([string]::Equals([string] $explorerJson.snapshot.locator.value, $explorerFolder, [StringComparison]::OrdinalIgnoreCase)) 'Explorer folder-path capture was incorrect.'
    Assert-True (@($explorerJson.snapshot.selection) -contains $selectedFile) 'Explorer selection capture was incorrect.'
    $results.explorerPathAndSelection = 'passed'
    $explorerWindow.Quit()
    $explorerWindow = $null

    if (-not $SkipBrowser) {
        $edgeCandidates = @(
            @(
                (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
                (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
            ) | Where-Object { Test-Path $_ }
        )
        Assert-True ($edgeCandidates.Count -gt 0) 'Microsoft Edge is not installed.'
        $edgeExecutable = $edgeCandidates[0]
        $browserMarker = [Guid]::NewGuid().ToString('N')
        $browserTitle = "Zommi Acceptance $browserMarker"
        $buttonName = "Zommi Target $browserMarker"
        $htmlPath = Join-Path $temporaryRoot 'zommi-browser-acceptance.html'
        $html = "<!doctype html><title>$browserTitle</title><button style='margin:160px;font-size:30px'>$buttonName</button>"
        [IO.File]::WriteAllText($htmlPath, $html)
        $browserUri = ([Uri] $htmlPath).AbsoluteUri
        $edgeProfile = Join-Path $temporaryRoot 'edge-profile'
        $edgeArguments = '--user-data-dir={0} --no-first-run --no-default-browser-check --force-renderer-accessibility --disable-features=msEdgeFirstRunExperience --new-window {1}' -f (Quote-Argument $edgeProfile), (Quote-Argument $browserUri)
        Start-Process -FilePath $edgeExecutable -ArgumentList $edgeArguments | Out-Null

        for ($attempt = 0; $attempt -lt 150 -and $null -eq $edgeWindow; $attempt++) {
            Start-Sleep -Milliseconds 100
            $edgeWindow = Get-Process msedge -ErrorAction SilentlyContinue | Where-Object {
                $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -like "*$browserTitle*"
            } | Select-Object -First 1
        }
        Assert-True ($null -ne $edgeWindow) 'The isolated Edge acceptance window did not open.'
        [void] [ZommiNativeWindow]::Activate([IntPtr] $edgeWindow.MainWindowHandle)
        Start-Sleep -Milliseconds 750

        Add-Type -AssemblyName UIAutomationClient
        $automationRoot = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr] $edgeWindow.MainWindowHandle)
        $nameCondition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $buttonName)
        $button = $automationRoot.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $nameCondition)
        Assert-True ($null -ne $button) 'The browser did not expose the acceptance button through UI Automation.'
        $bounds = $button.Current.BoundingRectangle
        [void] [ZommiNativeWindow]::SetCursorPos([int] ($bounds.X + ($bounds.Width / 2)), [int] ($bounds.Y + ($bounds.Height / 2)))
        Start-Sleep -Milliseconds 250

        $browserCapture = $null
        for ($attempt = 0; $attempt -lt 5; $attempt++) {
            [void] [ZommiNativeWindow]::Activate([IntPtr] $edgeWindow.MainWindowHandle)
            Start-Sleep -Milliseconds 300
            $browserCapture = Invoke-CapturedProcess $executable "--acceptance-capture-once $globalArguments" $null
            if ($browserCapture.ExitCode -eq 0) {
                break
            }
        }
        Assert-True ($null -ne $browserCapture -and $browserCapture.ExitCode -eq 0) "Browser capture failed. stdout=$($browserCapture.StandardOutput) stderr=$($browserCapture.StandardError)"
        $browserJson = $browserCapture.StandardOutput | ConvertFrom-Json
        Assert-True ($browserJson.snapshot.surfaceKind -eq 'Browser') 'Edge was not classified as a browser.'
        Assert-True ([string]::Equals([string] $browserJson.snapshot.locator.value, $browserUri, [StringComparison]::OrdinalIgnoreCase)) 'Browser URL capture was incorrect.'
        Assert-True ($browserJson.snapshot.indicatedTarget.name -eq $buttonName) 'Browser pointer-target capture was incorrect.'
        $results.browserUrlAndTarget = 'passed'
        [void] $edgeWindow.CloseMainWindow()
        $edgeWindow = $null
    }

    $results.windowsVersion = [Environment]::OSVersion.VersionString
    $results.executableSha256 = (Get-FileHash -Algorithm SHA256 $executable).Hash.ToLowerInvariant()
    $results | ConvertTo-Json
} finally {
    if ($null -ne $owner -and -not $owner.HasExited) {
        Stop-Process -Id $owner.Id -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $explorerWindow) {
        try { $explorerWindow.Quit() } catch { }
    }
    if ($null -ne $edgeWindow) {
        try { [void] $edgeWindow.CloseMainWindow() } catch { }
    }
    if ($null -ne $edgeProfile) {
        Get-CimInstance Win32_Process -Filter "Name = 'msedge.exe'" -ErrorAction SilentlyContinue | Where-Object {
            $_.CommandLine -like "*$edgeProfile*"
        } | ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Milliseconds 250
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}
