[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ExecutablePath,

    [switch] $SkipBrowser
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

function Find-AutomationElementById {
    param(
        [System.Windows.Automation.AutomationElement] $Root,
        [string] $AutomationId
    )
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
        $AutomationId)
    return $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Find-AutomationElementByName {
    param(
        [System.Windows.Automation.AutomationElement] $Root,
        [string] $Name
    )
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty,
        $Name)
    return $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Wait-ZommiWindow {
    param(
        [System.Diagnostics.Process] $Process,
        [int] $TimeoutSeconds = 20
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($Process.HasExited) {
            throw "Electron exited before showing context with code $($Process.ExitCode)."
        }
        $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
            [System.Windows.Automation.TreeScope]::Children,
            [System.Windows.Automation.Condition]::TrueCondition)
        foreach ($candidate in $windows) {
            try {
                if ($candidate.Current.ProcessId -eq $Process.Id -and
                    $candidate.Current.Name -like 'Zommi*floating Codex chat' -and
                    -not $candidate.Current.IsOffscreen) {
                    return $candidate
                }
            }
            catch {
                # Ignore a top-level window that disappears during enumeration.
            }
        }
        Start-Sleep -Milliseconds 100
    }
    return $null
}

function Wait-AutomationElementByName {
    param(
        [System.Windows.Automation.AutomationElement] $Root,
        [string] $Name,
        [int] $TimeoutSeconds = 20
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $element = Find-AutomationElementByName $Root $Name
        if ($null -ne $element) { return $element }
        Start-Sleep -Milliseconds 100
    }
    return $null
}

function Get-AutomationText {
    param([System.Windows.Automation.AutomationElement] $Element)

    $textPatternObject = $null
    if ($Element.TryGetCurrentPattern(
        [System.Windows.Automation.TextPattern]::Pattern,
        [ref] $textPatternObject)) {
        return [string] ([System.Windows.Automation.TextPattern] $textPatternObject).DocumentRange.GetText(-1)
    }
    $valuePatternObject = $null
    if ($Element.TryGetCurrentPattern(
        [System.Windows.Automation.ValuePattern]::Pattern,
        [ref] $valuePatternObject)) {
        return [string] ([System.Windows.Automation.ValuePattern] $valuePatternObject).Current.Value
    }

    $text = [string] $Element.Current.Name
    foreach ($descendant in $Element.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)) {
        try {
            if (-not [string]::IsNullOrWhiteSpace($descendant.Current.Name)) {
                $text += "`n" + $descendant.Current.Name
            }
        }
        catch { }
    }
    return $text
}

function Set-AutomationValue {
    param(
        [System.Windows.Automation.AutomationElement] $Element,
        [string] $Value
    )

    $valuePatternObject = $null
    Assert-True ($Element.TryGetCurrentPattern(
        [System.Windows.Automation.ValuePattern]::Pattern,
        [ref] $valuePatternObject)) 'The Electron composer did not expose ValuePattern.'
    ([System.Windows.Automation.ValuePattern] $valuePatternObject).SetValue($Value)
}

function Invoke-AutomationElement {
    param([System.Windows.Automation.AutomationElement] $Element)

    $invokePattern = $Element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    ([System.Windows.Automation.InvokePattern] $invokePattern).Invoke()
}

function Get-ExactExecutableProcesses {
    param([string] $Path)

    $normalized = [IO.Path]::GetFullPath($Path)
    return @(
        Get-CimInstance Win32_Process | Where-Object {
            $_.Name -eq 'Zommi.exe' -and
            $_.ExecutablePath -and
            [string]::Equals(
                [IO.Path]::GetFullPath($_.ExecutablePath),
                $normalized,
                [StringComparison]::OrdinalIgnoreCase)
        }
    )
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This Electron runtime acceptance requires Windows.'
}

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ZommiElectronAcceptanceNative {
    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, IntPtr processId);
    [DllImport("user32.dll")]
    private static extern bool AttachThreadInput(uint attach, uint attachTo, bool value);
    [DllImport("user32.dll")]
    private static extern bool BringWindowToTop(IntPtr window);
    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")]
    private static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);

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

    public static void PressAltA() {
        const uint keyUp = 0x0002;
        keybd_event(0x12, 0, 0, UIntPtr.Zero);
        keybd_event(0x41, 0, 0, UIntPtr.Zero);
        keybd_event(0x41, 0, keyUp, UIntPtr.Zero);
        keybd_event(0x12, 0, keyUp, UIntPtr.Zero);
    }
}
'@

$resolvedExecutable = [IO.Path]::GetFullPath($ExecutablePath)
$packageDirectory = Split-Path -Parent $resolvedExecutable
$nativeHost = Join-Path $packageDirectory 'resources/native/Zommi.exe'
Assert-True (Test-Path -LiteralPath $resolvedExecutable -PathType Leaf) 'The Electron Zommi.exe is missing.'
Assert-True (Test-Path -LiteralPath $nativeHost -PathType Leaf) 'The packaged Windows native host is missing.'

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('zommi-electron-runtime-' + [Guid]::NewGuid().ToString('N'))
$edgeProfile = Join-Path $temporaryRoot 'edge-profile'
$electron = $null
$edgeWindow = $null
$browserMarker = 'ZOMMI_ELECTRON_' + [Guid]::NewGuid().ToString('N')

try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    $electron = Start-Process `
        -FilePath $resolvedExecutable `
        -WorkingDirectory $packageDirectory `
        -ArgumentList '--force-renderer-accessibility' `
        -PassThru
    Start-Sleep -Seconds 3
    $electron.Refresh()
    Assert-True (-not $electron.HasExited) 'The packaged Electron browser process exited during startup.'
    Assert-True (@(Get-ExactExecutableProcesses $resolvedExecutable).Count -ge 3) 'Electron did not start its expected child processes.'

    if ($SkipBrowser) {
        [ordered]@{
            executablePath = $resolvedExecutable
            electronStartup = 'passed'
            nativeHostPresent = 'passed'
            browserCapture = 'skipped'
        } | ConvertTo-Json
        return
    }

    $edgeCandidates = @(
        @(
            (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
            (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
        ) | Where-Object { Test-Path -LiteralPath $_ }
    )
    Assert-True ($edgeCandidates.Count -gt 0) 'Microsoft Edge is not installed.'
    $edgeExecutable = $edgeCandidates[0]
    $buttonName = "Mouse target $browserMarker"
    $tableName = "Usage table $browserMarker"
    $browserTitle = "Zommi Electron Acceptance $browserMarker"
    $htmlPath = Join-Path $temporaryRoot 'electron-runtime.html'
    $rows = [string]::Join('', @(1..30 | ForEach-Object {
        "<tr><td>account-$_</td><td>$($_ * 7)</td></tr>"
    }))
    $html = "<!doctype html><title>$browserTitle</title><main><button style='position:fixed;top:100px;right:100px;font-size:26px'>$buttonName</button><h1>Visible $browserMarker</h1><table aria-label='$tableName'><thead><tr><th>Account</th><th>Spend</th></tr></thead><tbody>$rows</tbody></table></main>"
    [IO.File]::WriteAllText($htmlPath, $html)
    $browserUri = ([Uri] $htmlPath).AbsoluteUri
    $edgeArguments = '--user-data-dir={0} --no-first-run --no-default-browser-check --force-renderer-accessibility --disable-features=msEdgeFirstRunExperience --new-window {1}' -f (Quote-Argument $edgeProfile), (Quote-Argument $browserUri)
    Start-Process -FilePath $edgeExecutable -ArgumentList $edgeArguments | Out-Null

    for ($attempt = 0; $attempt -lt 150 -and $null -eq $edgeWindow; $attempt++) {
        Start-Sleep -Milliseconds 100
        $edgeWindow = Get-Process msedge -ErrorAction SilentlyContinue | Where-Object {
            $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -like "*$browserTitle*"
        } | Select-Object -First 1
    }
    Assert-True ($null -ne $edgeWindow) 'The isolated Edge acceptance window did not open.'
    [void] [ZommiElectronAcceptanceNative]::Activate([IntPtr] $edgeWindow.MainWindowHandle)
    Start-Sleep -Milliseconds 750

    $edgeRoot = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr] $edgeWindow.MainWindowHandle)
    $button = Find-AutomationElementByName $edgeRoot $buttonName
    Assert-True ($null -ne $button) 'Edge did not expose the controlled pointer target.'
    $buttonBounds = $button.Current.BoundingRectangle
    $pointer = New-Object System.Drawing.Point(
        [int] ($buttonBounds.X + ($buttonBounds.Width / 2)),
        [int] ($buttonBounds.Y + ($buttonBounds.Height / 2)))
    [System.Windows.Forms.Cursor]::Position = $pointer
    Start-Sleep -Milliseconds 250

    [ZommiElectronAcceptanceNative]::PressAltA()
    $window = Wait-ZommiWindow $electron 30
    Assert-True ($null -ne $window) 'Alt+A did not open the packaged Electron window.'
    $windowBounds = $window.Current.BoundingRectangle
    $pointerAfter = [System.Windows.Forms.Cursor]::Position
    Assert-True ($pointer.X -eq $pointerAfter.X -and $pointer.Y -eq $pointerAfter.Y) 'Opening Electron moved the mouse pointer.'
    $pointerInsideWindow = $pointerAfter.X -ge $windowBounds.X -and
        $pointerAfter.X -lt ($windowBounds.X + $windowBounds.Width) -and
        $pointerAfter.Y -ge $windowBounds.Y -and
        $pointerAfter.Y -lt ($windowBounds.Y + $windowBounds.Height)
    Assert-True (-not $pointerInsideWindow) 'The floating Electron window opened under the pointer.'

    $contextChip = Wait-AutomationElementByName $window 'Attached context [context]' 30
    Assert-True ($null -ne $contextChip) 'Alt+A did not attach the controlled browser context.'
    $composer = Find-AutomationElementById $window 'ZommiComposer'
    Assert-True ($null -ne $composer -and $composer.Current.HasKeyboardFocus) 'Alt+A did not focus the Electron composer.'
    Assert-True ((Get-AutomationText $composer) -notlike "*$browserMarker*") 'Raw page context leaked into the composer.'

    $chipBounds = $contextChip.Current.BoundingRectangle
    [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point(
        [int] ($chipBounds.X + ($chipBounds.Width / 2)),
        [int] ($chipBounds.Y + ($chipBounds.Height / 2)))
    $preview = $null
    for ($attempt = 0; $attempt -lt 100 -and $null -eq $preview; $attempt++) {
        Start-Sleep -Milliseconds 100
        $preview = Find-AutomationElementById $window 'ContextPreviewText'
    }
    Assert-True ($null -ne $preview -and -not $preview.Current.IsOffscreen) 'The real Alt+A context did not expose its hover preview.'
    $previewText = Get-AutomationText $preview
    Assert-True ($previewText -like "*$browserMarker*") 'The Alt+A preview omitted the controlled page text.'
    Assert-True ($previewText -like "*$tableName*") 'The Alt+A preview omitted the semantic table hierarchy.'
    Assert-True ($previewText -like "*Mouse pointer:*$buttonName*") 'The hover target was not labeled as Mouse pointer.'
    Assert-True ($previewText -notlike '*"source":*') 'Accessibility capture-source metadata leaked into the compact structure.'
    Assert-True ($previewText -notlike '*"nodeCount":*') 'Accessibility node-count metadata leaked into the compact structure.'
    Assert-True ($previewText -notlike '*"automationId":*') 'Accessibility automation-id metadata leaked into the compact structure.'
    Assert-True ($previewText -notlike '*"bounds":*') 'Accessibility pixel bounds leaked into the compact structure.'
    $previewImage = Find-AutomationElementById $window 'ContextPreviewImage'
    Assert-True ($null -eq $previewImage -or $previewImage.Current.IsOffscreen) 'Alt+A attached an automatic image.'

    $prompt = 'Reply with the exact token beginning ZOMMI_ELECTRON_ from the attached context and nothing else.'
    Set-AutomationValue $composer $prompt
    $send = Find-AutomationElementById $window 'SendMessage'
    Assert-True ($null -ne $send) 'The Electron send button was not exposed.'
    Invoke-AutomationElement $send

    $responseText = $null
    $lastTranscriptText = ''
    $readyWithoutTokenAt = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(180)
    while ([DateTime]::UtcNow -lt $deadline) {
        $currentWindow = Wait-ZommiWindow $electron 2
        if ($null -ne $currentWindow) {
            $transcript = Find-AutomationElementById $currentWindow 'CodexTranscript'
            if ($null -ne $transcript) {
                $candidateText = Get-AutomationText $transcript
                $lastTranscriptText = $candidateText
                if ($candidateText -like "*$browserMarker*") {
                    $responseText = $candidateText
                    break
                }
                $currentStatus = Find-AutomationElementById $currentWindow 'CodexStatus'
                if ($candidateText -like "*$prompt*" -and
                    $null -ne $currentStatus -and
                    $currentStatus.Current.Name -eq 'Codex status: ready') {
                    if ($null -eq $readyWithoutTokenAt) {
                        $readyWithoutTokenAt = [DateTime]::UtcNow
                    }
                    elseif ([DateTime]::UtcNow -ge $readyWithoutTokenAt.AddSeconds(2)) {
                        break
                    }
                }
            }
        }
        Start-Sleep -Milliseconds 250
    }
    if ($null -eq $responseText) {
        $status = Find-AutomationElementById $window 'CodexStatus'
        $statusText = if ($null -eq $status) { '<missing>' } else { $status.Current.Name }
        $transcriptTail = if ($lastTranscriptText.Length -gt 2000) {
            $lastTranscriptText.Substring($lastTranscriptText.Length - 2000)
        }
        else {
            $lastTranscriptText
        }
        throw "Codex did not stream the exact context token through Electron. Status: $statusText Transcript: $transcriptTail"
    }

    [ordered]@{
        executablePath = $resolvedExecutable
        executableSha256 = (Get-FileHash -LiteralPath $resolvedExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
        windowsVersion = [Environment]::OSVersion.VersionString
        electronProcessCount = @(Get-ExactExecutableProcesses $resolvedExecutable).Count
        globalAltA = 'passed'
        pointerAdjacent = 'passed'
        structuredBrowserContext = 'passed'
        semanticTableHierarchy = 'passed'
        compactAccessibilityStructure = 'passed'
        pointerLabel = 'Mouse pointer'
        automaticAltAImage = 'absent'
        codexStreaming = 'passed'
        responseToken = $browserMarker
    } | ConvertTo-Json
}
finally {
    if ($null -ne $electron -and -not $electron.HasExited) {
        Stop-Process -Id $electron.Id -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $resolvedExecutable -PathType Leaf) {
        foreach ($candidate in (Get-ExactExecutableProcesses $resolvedExecutable)) {
            Stop-Process -Id $candidate.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    if ($null -ne $edgeWindow -and -not $edgeWindow.HasExited) {
        try { [void] $edgeWindow.CloseMainWindow() } catch { }
    }
    Get-CimInstance Win32_Process -Filter "Name = 'msedge.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -like "*$edgeProfile*"
    } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
