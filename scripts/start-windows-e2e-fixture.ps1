[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $PackageDirectory,

    [Parameter(Mandatory = $true)]
    [string] $SessionId,

    [Parameter(Mandatory = $true)]
    [string] $StateRoot,

    [Parameter(Mandatory = $true)]
    [string] $Channel
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Quote-Argument {
    param([string] $Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ZommiE2ENativeWindow {
    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr processId);
    [DllImport("user32.dll")]
    private static extern bool AttachThreadInput(uint attach, uint attachTo, bool value);
    [DllImport("user32.dll")]
    private static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int command);
    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);

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

$zommiExecutable = Join-Path $PackageDirectory 'Zommi.exe'
$hookExecutable = Join-Path $PackageDirectory 'Zommi.Hook.exe'
$wrapper = Join-Path $PackageDirectory 'Zommi.WslHook.ps1'
Assert-True (Test-Path -LiteralPath $zommiExecutable) 'Zommi.exe is missing.'
Assert-True (Test-Path -LiteralPath $hookExecutable) 'Zommi.Hook.exe is missing.'
Assert-True (Test-Path -LiteralPath $wrapper) 'Zommi.WslHook.ps1 is missing.'

New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null
$binding = [ordered]@{
    sessionId = $SessionId
    mode = 'active'
    updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
} | ConvertTo-Json
[IO.File]::WriteAllText((Join-Path $StateRoot 'binding.json'), $binding)

$zommiArguments = '--state-root {0} --channel {1}' -f (Quote-Argument $StateRoot), (Quote-Argument $Channel)
$zommi = Start-Process -FilePath $zommiExecutable -ArgumentList $zommiArguments -PassThru
$zommiReady = $false
for ($attempt = 0; $attempt -lt 100; $attempt++) {
    Start-Sleep -Milliseconds 100
    $zommi.Refresh()
    if ($zommi.MainWindowHandle -ne 0 -and $zommi.MainWindowTitle -like 'Zommi*') {
        $zommiReady = $true
        break
    }
}
Assert-True $zommiReady 'The Zommi GUI did not start.'

$edgeCandidates = @(
    @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
    ) | Where-Object { Test-Path $_ }
)
Assert-True ($edgeCandidates.Count -gt 0) 'Microsoft Edge is not installed.'
$edgeExecutable = $edgeCandidates[0]
$marker = [Guid]::NewGuid().ToString('N')
$browserTitle = "Zommi E2E $marker"
$buttonName = "Zommi E2E Target $marker"
$htmlPath = Join-Path $PackageDirectory 'zommi-e2e.html'
$html = "<!doctype html><title>$browserTitle</title><button style='margin:160px;font-size:30px'>$buttonName</button>"
[IO.File]::WriteAllText($htmlPath, $html)
$browserUri = ([Uri] $htmlPath).AbsoluteUri
$edgeProfile = Join-Path $PackageDirectory 'edge-e2e-profile'
$edgeArguments = '--user-data-dir={0} --no-first-run --no-default-browser-check --force-renderer-accessibility --disable-features=msEdgeFirstRunExperience --new-window {1}' -f (Quote-Argument $edgeProfile), (Quote-Argument $browserUri)
Start-Process -FilePath $edgeExecutable -ArgumentList $edgeArguments | Out-Null

$edgeWindow = $null
for ($attempt = 0; $attempt -lt 150 -and $null -eq $edgeWindow; $attempt++) {
    Start-Sleep -Milliseconds 100
    $edgeWindow = Get-Process msedge -ErrorAction SilentlyContinue | Where-Object {
        $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -like "*$browserTitle*"
    } | Select-Object -First 1
}
Assert-True ($null -ne $edgeWindow) 'The isolated Edge window did not start.'
[void] [ZommiE2ENativeWindow]::Activate([IntPtr] $edgeWindow.MainWindowHandle)
Start-Sleep -Milliseconds 750

Add-Type -AssemblyName UIAutomationClient
$automationRoot = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr] $edgeWindow.MainWindowHandle)
$nameCondition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $buttonName)
$button = $automationRoot.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $nameCondition)
Assert-True ($null -ne $button) 'The Edge button was not exposed through UI Automation.'
$bounds = $button.Current.BoundingRectangle
[void] [ZommiE2ENativeWindow]::SetCursorPos([int] ($bounds.X + ($bounds.Width / 2)), [int] ($bounds.Y + ($bounds.Height / 2)))
Start-Sleep -Seconds 2

[ordered]@{
    zommiProcessId = $zommi.Id
    edgeProcessId = $edgeWindow.Id
    edgeProfile = $edgeProfile
    browserUri = $browserUri
    buttonName = $buttonName
    stateRoot = $StateRoot
    channel = $Channel
} | ConvertTo-Json
