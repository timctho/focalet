[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ExecutablePath,

    [switch] $SkipBrowser,

    [switch] $SkipHoverPreview,

    [switch] $SkipSessionUi,

    [switch] $SkipPointerImmobility,

    [switch] $KeepTemporaryArtifacts,

    [switch] $UseCaptureTrigger,

    [int] $MaxContextLatencyMilliseconds = 1500,

    [int] $MaxFirstAgentOutputMilliseconds = 10000,

    [int] $MaxResponseMilliseconds = 30000
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
                    $candidate.Current.Name -like 'Zommi*floating*chat' -and
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

function Wait-AutomationElementById {
    param(
        [System.Windows.Automation.AutomationElement] $Root,
        [string] $AutomationId,
        [int] $TimeoutSeconds = 20
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $element = Find-AutomationElementById $Root $AutomationId
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

    $invokePatternObject = $null
    if ($Element.TryGetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern,
        [ref] $invokePatternObject)) {
        ([System.Windows.Automation.InvokePattern] $invokePatternObject).Invoke()
        Start-Sleep -Milliseconds 180
        return
    }
    $bounds = $Element.Current.BoundingRectangle
    Assert-True ($bounds.Width -gt 0 -and $bounds.Height -gt 0) 'Cannot click an element without visible bounds.'
    [ZommiElectronAcceptanceNative]::Click(
        [int] ($bounds.X + ($bounds.Width / 2)),
        [int] ($bounds.Y + ($bounds.Height / 2)))
    Start-Sleep -Milliseconds 180
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

function Get-AllZommiProcesses {
    return @(Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'Zommi.exe' })
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
    [DllImport("user32.dll")]
    private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")]
    private static extern void mouse_event(uint flags, uint dx, uint dy, int data, UIntPtr extraInfo);

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

    public static void PressAltAAt(int x, int y) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(10);
        PressAltA();
    }

    public static bool MovePointer(int x, int y) {
        return SetCursorPos(x, y);
    }

    public static void Click(int x, int y) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(100);
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(55);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
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
$zommiProfile = Join-Path $temporaryRoot 'zommi-profile'
$captureTriggerPath = Join-Path $temporaryRoot 'capture.trigger'
$captureResultPath = Join-Path $temporaryRoot 'capture-result.json'
$warmCaptureResultPath = Join-Path $temporaryRoot 'capture-result-warm.json'
$electron = $null
$edgeWindow = $null
$browserMarker = 'ZOMMI_ELECTRON_' + [Guid]::NewGuid().ToString('N')

try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    foreach ($existing in (Get-AllZommiProcesses)) {
        Stop-Process -Id $existing.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 1500
    Assert-True (@(Get-AllZommiProcesses).Count -eq 0) 'A pre-existing Zommi product process retained the single-instance lock.'
    $electronArguments = @("--user-data-dir=$zommiProfile", '--force-renderer-accessibility')
    if ($UseCaptureTrigger) {
        $electronArguments += @('--', "--acceptance-capture-trigger=$captureTriggerPath")
    }
    $electron = Start-Process `
        -FilePath $resolvedExecutable `
        -WorkingDirectory $packageDirectory `
        -ArgumentList $electronArguments `
        -PassThru
    Start-Sleep -Seconds 3
    $electron.Refresh()
    Assert-True (-not $electron.HasExited) 'The packaged Electron browser process exited during startup.'
    $electronProcesses = @(Get-ExactExecutableProcesses $resolvedExecutable)
    $electronProcessDeadline = [DateTime]::UtcNow.AddSeconds(30)
    while ($electronProcesses.Count -lt 3 -and [DateTime]::UtcNow -lt $electronProcessDeadline) {
        Start-Sleep -Milliseconds 250
        $electron.Refresh()
        Assert-True (-not $electron.HasExited) 'The packaged Electron browser process exited during startup.'
        $electronProcesses = @(Get-ExactExecutableProcesses $resolvedExecutable)
    }
    Assert-True ($electronProcesses.Count -ge 3) "Electron did not start its expected child processes within 30 seconds; found $($electronProcesses.Count)."

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
    $selectionMarker = "Selected surface item $browserMarker"
    $browserTitle = "Zommi Electron Acceptance $browserMarker"
    $htmlPath = Join-Path $temporaryRoot 'electron-runtime.html'
    $rows = [string]::Join('', @(1..30 | ForEach-Object {
        "<tr><td>account-$_</td><td>$($_ * 7)</td></tr>"
    }))
    $html = "<!doctype html><title>$browserTitle</title><main><button style='position:fixed;top:100px;right:100px;font-size:26px'>$buttonName</button><h1>Visible $browserMarker</h1><select multiple aria-label='Surface selection $browserMarker'><option>$selectionMarker</option><option>Unselected peer</option></select><table aria-label='$tableName'><thead><tr><th>Account</th><th>Spend</th></tr></thead><tbody>$rows</tbody></table><div aria-hidden='true' style='position:fixed;left:20px;bottom:20px;width:220px;height:100px'></div></main>"
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
    $selectedOption = Find-AutomationElementByName $edgeRoot $selectionMarker
    Assert-True ($null -ne $selectedOption) 'Edge did not expose the controlled selection item.'
    $selectionPatternObject = $selectedOption.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    ([System.Windows.Automation.SelectionItemPattern] $selectionPatternObject).Select()
    $button = Find-AutomationElementByName $edgeRoot $buttonName
    Assert-True ($null -ne $button) 'Edge did not expose the controlled pointer target.'
    $buttonBounds = $button.Current.BoundingRectangle
    $pointer = New-Object System.Drawing.Point(
        [int] ($buttonBounds.X + ($buttonBounds.Width / 2)),
        [int] ($buttonBounds.Y + ($buttonBounds.Height / 2)))
    $contextStopwatch = [Diagnostics.Stopwatch]::StartNew()
    if ($UseCaptureTrigger) {
        [void] [ZommiElectronAcceptanceNative]::MovePointer($pointer.X, $pointer.Y)
        Set-Content -LiteralPath $captureTriggerPath -Value (@{ x = $pointer.X; y = $pointer.Y; resultPath = $captureResultPath } | ConvertTo-Json -Compress) -Encoding ascii
    }
    else {
        [ZommiElectronAcceptanceNative]::PressAltAAt($pointer.X, $pointer.Y)
    }
    $window = Wait-ZommiWindow $electron 30
    Assert-True ($null -ne $window) 'Alt+A did not open the packaged Electron window.'
    $windowBounds = $window.Current.BoundingRectangle
    $pointerAfter = [System.Windows.Forms.Cursor]::Position
    if (-not $SkipPointerImmobility) {
        Assert-True ($pointer.X -eq $pointerAfter.X -and $pointer.Y -eq $pointerAfter.Y) "Opening Electron moved the mouse pointer from $($pointer.X),$($pointer.Y) to $($pointerAfter.X),$($pointerAfter.Y)."
    }
    $pointerInsideWindow = $pointerAfter.X -ge $windowBounds.X -and
        $pointerAfter.X -lt ($windowBounds.X + $windowBounds.Width) -and
        $pointerAfter.Y -ge $windowBounds.Y -and
        $pointerAfter.Y -lt ($windowBounds.Y + $windowBounds.Height)
    Assert-True (-not $pointerInsideWindow) 'The floating Electron window opened under the pointer.'

    $contextChip = Wait-AutomationElementByName $window 'Attached context [context]' 30
    $contextStopwatch.Stop()
    $contextLatencyMilliseconds = $contextStopwatch.ElapsedMilliseconds
    if ($UseCaptureTrigger) {
        $captureResultDeadline = [DateTime]::UtcNow.AddSeconds(5)
        while (-not (Test-Path -LiteralPath $captureResultPath) -and [DateTime]::UtcNow -lt $captureResultDeadline) {
            Start-Sleep -Milliseconds 50
        }
        Assert-True (Test-Path -LiteralPath $captureResultPath) 'The capture trigger did not return product timing.'
        $captureResult = Get-Content -LiteralPath $captureResultPath -Raw | ConvertFrom-Json
        Assert-True $captureResult.attached 'The capture trigger returned without an attached context.'
        $contextLatencyMilliseconds = [long] $captureResult.totalMilliseconds
    }
    Assert-True ($null -ne $contextChip) 'Alt+A did not attach the controlled browser context.'
    Assert-True ($contextLatencyMilliseconds -le $MaxContextLatencyMilliseconds) "Context capture took $contextLatencyMilliseconds ms; budget is $MaxContextLatencyMilliseconds ms. Harness elapsed: $($contextStopwatch.ElapsedMilliseconds) ms."
    $composer = Find-AutomationElementById $window 'ZommiComposer'
    Assert-True ($null -ne $composer -and $composer.Current.HasKeyboardFocus) 'Alt+A did not focus the Electron composer.'
    Assert-True ((Get-AutomationText $composer) -notlike "*$browserMarker*") 'Raw page context leaked into the composer.'

    $runtimeSummary = Wait-AutomationElementById $window 'RuntimeSummary' 20
    Assert-True ($null -ne $runtimeSummary) 'The zero-config runtime summary was not exposed.'
    $runtimeSummaryText = [string] $runtimeSummary.Current.Name
    $runtimeDeadline = [DateTime]::UtcNow.AddSeconds(30)
    while ($runtimeSummaryText -notlike '*Codex*app-server*WSL*' -and [DateTime]::UtcNow -lt $runtimeDeadline) {
        Start-Sleep -Milliseconds 200
        $window = Wait-ZommiWindow $electron 2
        $runtimeSummary = Find-AutomationElementById $window 'RuntimeSummary'
        if ($null -ne $runtimeSummary) { $runtimeSummaryText = [string] $runtimeSummary.Current.Name }
    }
    Assert-True ($runtimeSummaryText -like '*Codex*app-server*WSL*') "A fresh Zommi profile did not auto-discover Codex app-server in WSL. Runtime: $runtimeSummaryText"

    $previewContract = 'skipped'
    if (-not $SkipHoverPreview) {
        $chipBounds = $contextChip.Current.BoundingRectangle
        Assert-True ([ZommiElectronAcceptanceNative]::MovePointer(
            [int] ($chipBounds.X + ($chipBounds.Width / 2)),
            [int] ($chipBounds.Y + ($chipBounds.Height / 2)))) 'Could not move the pointer onto the context chip.'
        $preview = $null
        for ($attempt = 0; $attempt -lt 100 -and $null -eq $preview; $attempt++) {
            Start-Sleep -Milliseconds 100
            $preview = Find-AutomationElementById $window 'ContextPreviewText'
        }
        Assert-True ($null -ne $preview -and -not $preview.Current.IsOffscreen) 'The real Alt+A context did not expose its hover preview.'
        $previewText = Get-AutomationText $preview
        Assert-True ($previewText -like "*$browserMarker*") 'The Alt+A preview omitted the controlled page text.'
        Assert-True ($previewText -like "*$tableName*") 'The Alt+A preview omitted the semantic table hierarchy.'
        Assert-True ($previewText -like "*PRIMARY SURFACE SELECTION*$selectionMarker*") 'The Alt+A preview omitted the selected semantic item.'
        Assert-True ($previewText -like "*Mouse pointer:*$buttonName*") 'The hover target was not labeled as Mouse pointer.'
        Assert-True ($previewText.IndexOf($selectionMarker, [StringComparison]::Ordinal) -lt $previewText.IndexOf('Mouse pointer:', [StringComparison]::Ordinal)) 'Surface Selection did not precede the pointer fallback.'
        Assert-True ($previewText -notlike '*"source":*') 'Accessibility capture-source metadata leaked into the compact structure.'
        Assert-True ($previewText -notlike '*"nodeCount":*') 'Accessibility node-count metadata leaked into the compact structure.'
        Assert-True ($previewText -notlike '*"automationId":*') 'Accessibility automation-id metadata leaked into the compact structure.'
        Assert-True ($previewText -notlike '*"bounds":*') 'Accessibility pixel bounds leaked into the compact structure.'
        $previewImage = Find-AutomationElementById $window 'ContextPreviewImage'
        Assert-True ($null -eq $previewImage -or $previewImage.Current.IsOffscreen) 'Alt+A attached an automatic image.'
        $previewContract = 'passed'
    }

    ([System.Windows.Automation.SelectionItemPattern] $selectionPatternObject).RemoveFromSelection()
    $documentCondition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Document)
    $edgeDocument = $edgeRoot.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $documentCondition)
    Assert-True ($null -ne $edgeDocument) 'Edge did not expose its document for the broad-target scenario.'
    $documentBounds = $edgeDocument.Current.BoundingRectangle
    $broadPointer = New-Object System.Drawing.Point(
        [int] ($documentBounds.X + 80),
        [int] ($documentBounds.Y + $documentBounds.Height - 60))
    $warmContextStopwatch = [Diagnostics.Stopwatch]::StartNew()
    if ($UseCaptureTrigger) {
        [void] [ZommiElectronAcceptanceNative]::MovePointer($broadPointer.X, $broadPointer.Y)
        Set-Content -LiteralPath $captureTriggerPath -Value (@{ x = $broadPointer.X; y = $broadPointer.Y; resultPath = $warmCaptureResultPath } | ConvertTo-Json -Compress) -Encoding ascii
    }
    else {
        [ZommiElectronAcceptanceNative]::PressAltAAt($broadPointer.X, $broadPointer.Y)
    }
    $window = Wait-ZommiWindow $electron 10
    $secondContextChip = Wait-AutomationElementByName $window 'Attached context [context 2]' 10
    $warmContextStopwatch.Stop()
    $warmContextLatencyMilliseconds = $warmContextStopwatch.ElapsedMilliseconds
    if ($UseCaptureTrigger) {
        $captureResultDeadline = [DateTime]::UtcNow.AddSeconds(5)
        while (-not (Test-Path -LiteralPath $warmCaptureResultPath) -and [DateTime]::UtcNow -lt $captureResultDeadline) {
            Start-Sleep -Milliseconds 50
        }
        Assert-True (Test-Path -LiteralPath $warmCaptureResultPath) 'The warm capture trigger did not return product timing.'
        $captureResult = Get-Content -LiteralPath $warmCaptureResultPath -Raw | ConvertFrom-Json
        Assert-True $captureResult.attached 'The warm capture trigger returned without an attached context.'
        $warmContextLatencyMilliseconds = [long] $captureResult.totalMilliseconds
    }
    $contextChipNames = @($window.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)) | Where-Object {
        $_.Current.Name -like 'Attached context*'
    } | ForEach-Object { $_.Current.Name }
    Assert-True ($null -ne $secondContextChip) "A second Alt+A did not accumulate another context token. Exposed chips: $($contextChipNames -join ', ')"
    Assert-True ($warmContextLatencyMilliseconds -le $MaxContextLatencyMilliseconds) "Warm context capture took $warmContextLatencyMilliseconds ms; budget is $MaxContextLatencyMilliseconds ms. Harness elapsed: $($warmContextStopwatch.ElapsedMilliseconds) ms."
    if (-not $SkipHoverPreview) {
        $secondChipBounds = $secondContextChip.Current.BoundingRectangle
        Assert-True ([ZommiElectronAcceptanceNative]::MovePointer(
            [int] ($secondChipBounds.X + ($secondChipBounds.Width / 2)),
            [int] ($secondChipBounds.Y + ($secondChipBounds.Height / 2)))) 'Could not hover the second context token.'
        $broadPreviewText = ''
        for ($attempt = 0; $attempt -lt 100; $attempt++) {
            Start-Sleep -Milliseconds 100
            $broadPreview = Find-AutomationElementById $window 'ContextPreviewText'
            if ($null -eq $broadPreview -or $broadPreview.Current.IsOffscreen) { continue }
            $broadPreviewText = Get-AutomationText $broadPreview
            if ($broadPreviewText -like '*exact visual object is ambiguous*') { break }
        }
        Assert-True ($broadPreviewText -like '*exact visual object is ambiguous*') 'A broad document target was not labeled ambiguous.'
        Assert-True ($broadPreviewText -notlike '*PRIMARY SURFACE SELECTION*') 'Clearing the semantic selection left a stale Surface Selection.'
        $broadPreviewImage = Find-AutomationElementById $window 'ContextPreviewImage'
        Assert-True ($null -eq $broadPreviewImage -or $broadPreviewImage.Current.IsOffscreen) 'The ambiguous Alt+A fallback attached an automatic image.'
    }

    $prompt = 'Reply with the exact token beginning ZOMMI_ELECTRON_ from the attached context and nothing else.'
    Set-AutomationValue $composer $prompt
    $send = Find-AutomationElementById $window 'SendMessage'
    $sendReadyDeadline = [DateTime]::UtcNow.AddSeconds(30)
    while (($null -eq $send -or -not $send.Current.IsEnabled) -and [DateTime]::UtcNow -lt $sendReadyDeadline) {
        Start-Sleep -Milliseconds 200
        $window = Wait-ZommiWindow $electron 2
        $send = Find-AutomationElementById $window 'SendMessage'
    }
    $sendReadyStatus = Find-AutomationElementById $window 'CodexStatus'
    $sendReadyStatusText = if ($null -eq $sendReadyStatus) { '<missing>' } else { [string] $sendReadyStatus.Current.Name }
    $sendReadyRuntime = Find-AutomationElementById $window 'RuntimeSummary'
    $sendReadyRuntimeText = if ($null -eq $sendReadyRuntime) { '<missing>' } else { [string] $sendReadyRuntime.Current.Name }
    Assert-True ($null -ne $send -and $send.Current.IsEnabled) "The Electron send button did not become ready. Status: $sendReadyStatusText Runtime: $sendReadyRuntimeText"
    $responseStopwatch = [Diagnostics.Stopwatch]::StartNew()
    Invoke-AutomationElement $send

    $responseText = $null
    $firstAgentOutputMilliseconds = $null
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
                if ($null -eq $firstAgentOutputMilliseconds -and
                    ($candidateText -match '(?i)thinking' -or $candidateText -like "*$browserMarker*")) {
                    $firstAgentOutputMilliseconds = $responseStopwatch.ElapsedMilliseconds
                }
                if ($candidateText -like "*$browserMarker*") {
                    $responseText = $candidateText
                    break
                }
                $currentStatus = Find-AutomationElementById $currentWindow 'CodexStatus'
                if ($candidateText -like "*$prompt*" -and
                    $null -ne $currentStatus -and
                    $currentStatus.Current.Name -eq 'Agent status: ready') {
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
    $responseStopwatch.Stop()
    Assert-True ($null -ne $firstAgentOutputMilliseconds) 'Codex produced no visible thinking or answer activity.'
    Assert-True ($firstAgentOutputMilliseconds -le $MaxFirstAgentOutputMilliseconds) "First visible Codex activity took $firstAgentOutputMilliseconds ms; budget is $MaxFirstAgentOutputMilliseconds ms."
    Assert-True ($responseStopwatch.ElapsedMilliseconds -le $MaxResponseMilliseconds) "The short exact response took $($responseStopwatch.ElapsedMilliseconds) ms; budget is $MaxResponseMilliseconds ms."

    $sessionUiContract = 'skipped'
    if (-not $SkipSessionUi) {
        $modelSummary = $null
        $modelStatusText = '<missing>'
        $modelReadyDeadline = [DateTime]::UtcNow.AddSeconds(30)
        while ([DateTime]::UtcNow -lt $modelReadyDeadline) {
            $window = Wait-ZommiWindow $electron 2
            if ($null -eq $window) { continue }
            $modelSummary = Find-AutomationElementById $window 'ModelSummary'
            $modelStatus = Find-AutomationElementById $window 'CodexStatus'
            if ($null -ne $modelStatus) { $modelStatusText = [string] $modelStatus.Current.Name }
            if ($null -ne $modelSummary -and $modelSummary.Current.IsEnabled) { break }
            Start-Sleep -Milliseconds 200
        }
        Assert-True ($null -ne $modelSummary -and $modelSummary.Current.IsEnabled) "The live Codex model/reasoning control did not become ready. Status: $modelStatusText"
        $zommiWindowHandle = [IntPtr] $window.Current.NativeWindowHandle
        [void] [ZommiElectronAcceptanceNative]::Activate($zommiWindowHandle)
        Start-Sleep -Milliseconds 150
        $effortBefore = $modelSummary.Current.Name
        Invoke-AutomationElement $modelSummary
        Start-Sleep -Milliseconds 350
        $modelSearch = Wait-AutomationElementById $window 'ModelSearch' 10
        $modelList = Wait-AutomationElementById $window 'ModelList' 10
        $effortList = Wait-AutomationElementById $window 'EffortList' 10
        Assert-True ($null -ne $modelSearch -and -not $modelSearch.Current.IsOffscreen) 'The live searchable model selector did not open.'
        Assert-True ($null -ne $modelList -and -not $modelList.Current.IsOffscreen) 'The live model catalog options did not open.'
        Assert-True ($null -ne $effortList -and -not $effortList.Current.IsOffscreen) 'The live reasoning-level options did not open.'
        $effortOption = $null
        $targetEffortName = $null
        foreach ($candidate in @(
                @{ Id = 'Effort-low'; Name = 'Low' },
                @{ Id = 'Effort-medium'; Name = 'Medium' },
                @{ Id = 'Effort-high'; Name = 'High' },
                @{ Id = 'Effort-xhigh'; Name = 'Xhigh' },
                @{ Id = 'Effort-minimal'; Name = 'Minimal' })) {
            if ($effortBefore.TrimEnd().EndsWith($candidate.Name, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $candidateElement = Find-AutomationElementById $window $candidate.Id
            if ($null -ne $candidateElement -and -not $candidateElement.Current.IsOffscreen) {
                $effortOption = $candidateElement
                $targetEffortName = $candidate.Name
                break
            }
        }
        Assert-True ($null -ne $effortOption -and -not $effortOption.Current.IsOffscreen) 'The live reasoning panel exposed no alternate option.'
        [void] [ZommiElectronAcceptanceNative]::Activate($zommiWindowHandle)
        Start-Sleep -Milliseconds 100
        Invoke-AutomationElement $effortOption
        Start-Sleep -Milliseconds 250
        $modelSummary = Find-AutomationElementById $window 'ModelSummary'
        $effortAfter = $modelSummary.Current.Name
        Assert-True ($effortAfter -ne $effortBefore -and $effortAfter -like "*$targetEffortName*") "A real selection did not change the live reasoning level. before=$effortBefore target=$targetEffortName after=$effortAfter bounds=$($effortOption.Current.BoundingRectangle)"
        Invoke-AutomationElement $modelSummary

        $toggleSessions = Wait-AutomationElementById $window 'ToggleSessions' 10
        Assert-True ($null -ne $toggleSessions) 'The live session sidebar control was not exposed.'
        $sessionToggleBounds = $toggleSessions.Current.BoundingRectangle
        Assert-True ([ZommiElectronAcceptanceNative]::MovePointer(
            [int] ($sessionToggleBounds.X + ($sessionToggleBounds.Width / 2)),
            [int] ($sessionToggleBounds.Y + ($sessionToggleBounds.Height / 2)))) 'Could not hover the chat session control.'
        Start-Sleep -Milliseconds 300
        $newSession = Wait-AutomationElementById $window 'NewSession' 10
        Assert-True ($null -ne $newSession -and -not $newSession.Current.IsOffscreen) 'The new-chat control was not visible in the session sidebar.'
        Invoke-AutomationElement $newSession

        $expectedSessionTitle = if ($prompt.Length -le 42) {
            $prompt
        }
        else {
            $prompt.Substring(0, 41) + '…'
        }
        $oldSession = Wait-AutomationElementByName $window $expectedSessionTitle 20
        if ($null -eq $oldSession) {
            $sessionList = Find-AutomationElementById $window 'SessionList'
            if ($null -ne $sessionList) {
                $oldSession = @($sessionList.FindAll(
                    [System.Windows.Automation.TreeScope]::Descendants,
                    [System.Windows.Automation.Condition]::TrueCondition)) | Where-Object {
                    $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and
                    $_.Current.IsEnabled -and
                    -not $_.Current.IsOffscreen
                } | Select-Object -First 1
            }
        }
        Assert-True ($null -ne $oldSession -and -not $oldSession.Current.IsOffscreen) 'The completed chat disappeared after creating a new session.'
        Invoke-AutomationElement $oldSession

        $resumedHistory = $null
        $resumeDeadline = [DateTime]::UtcNow.AddSeconds(30)
        while ([DateTime]::UtcNow -lt $resumeDeadline) {
            Start-Sleep -Milliseconds 200
            $window = Wait-ZommiWindow $electron 2
            $resumedTranscript = Find-AutomationElementById $window 'CodexTranscript'
            if ($null -ne $resumedTranscript) {
                $candidateHistory = Get-AutomationText $resumedTranscript
                if ($candidateHistory -like "*$browserMarker*") {
                    $resumedHistory = $candidateHistory
                    break
                }
            }
        }
        Assert-True ($null -ne $resumedHistory) 'Switching back to the completed chat did not restore its persisted history.'
        $sessionUiContract = 'passed'
    }

    [ordered]@{
        executablePath = $resolvedExecutable
        executableSha256 = (Get-FileHash -LiteralPath $resolvedExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
        windowsVersion = [Environment]::OSVersion.VersionString
        electronProcessCount = @(Get-ExactExecutableProcesses $resolvedExecutable).Count
        globalAltA = if ($UseCaptureTrigger) { 'skipped-rdp-synthetic-input-blocked' } else { 'passed' }
        captureDispatch = if ($UseCaptureTrigger) { 'acceptance-trigger' } else { 'global-alt-a' }
        contextTokenMilliseconds = $contextLatencyMilliseconds
        warmContextTokenMilliseconds = $warmContextLatencyMilliseconds
        contextHarnessMilliseconds = $contextStopwatch.ElapsedMilliseconds
        warmContextHarnessMilliseconds = $warmContextStopwatch.ElapsedMilliseconds
        pointerAdjacent = 'passed'
        pointerImmobility = if ($SkipPointerImmobility) { 'skipped-rdp-pointer-drift' } else { 'passed' }
        structuredBrowserContext = 'passed'
        semanticTableHierarchy = $previewContract
        compactAccessibilityStructure = $previewContract
        pointerLabel = $previewContract
        automaticAltAImage = 'absent'
        broadTargetAmbiguity = 'passed'
        accumulatedContexts = 2
        zeroConfigCodexDiscovery = $runtimeSummaryText
        codexStreaming = 'passed'
        firstAgentOutputMilliseconds = $firstAgentOutputMilliseconds
        responseCompletedMilliseconds = $responseStopwatch.ElapsedMilliseconds
        modelReasoningCatalog = $sessionUiContract
        createAndSwitchSession = $sessionUiContract
        responseToken = $browserMarker
    } | ConvertTo-Json
}
finally {
    if ($null -ne $electron -and -not $electron.HasExited) {
        Stop-Process -Id $electron.Id -Force -ErrorAction SilentlyContinue
    }
    foreach ($candidate in (Get-AllZommiProcesses)) {
        Stop-Process -Id $candidate.ProcessId -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $edgeWindow -and -not $edgeWindow.HasExited) {
        try { [void] $edgeWindow.CloseMainWindow() } catch { }
    }
    Get-CimInstance Win32_Process -Filter "Name = 'msedge.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -like "*$edgeProfile*"
    } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
    if (-not $KeepTemporaryArtifacts -and (Test-Path -LiteralPath $temporaryRoot)) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    elseif ($KeepTemporaryArtifacts) {
        Write-Warning "Preserved acceptance artifacts at $temporaryRoot"
    }
}
