[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ExecutablePath,

    [int] $TimeoutSeconds = 180,

    [switch] $RequireChromeTool,

    [switch] $InterruptStreaming,

    [int] $MaxSendAcceptedMilliseconds = 1000,

    [int] $MaxFirstAgentOutputMilliseconds = 15000,

    [int] $MaxTurnCompletedMilliseconds = 30000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Find-ElementById {
    param(
        [System.Windows.Automation.AutomationElement] $Root,
        [string] $AutomationId
    )

    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
        $AutomationId)
    return $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Find-ElementByName {
    param(
        [System.Windows.Automation.AutomationElement] $Root,
        [string] $Name
    )

    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty,
        $Name)
    return $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Wait-ElementById {
    param(
        [scriptblock] $RootProvider,
        [string] $AutomationId,
        [int] $TimeoutSeconds = 15
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $root = & $RootProvider
        if ($null -ne $root) {
            $element = Find-ElementById $root $AutomationId
            if ($null -ne $element) { return $element }
        }
        Start-Sleep -Milliseconds 100
    }
    return $null
}

function Get-ElementText {
    param([System.Windows.Automation.AutomationElement] $Element)

    $textPattern = $null
    if ($Element.TryGetCurrentPattern(
        [System.Windows.Automation.TextPattern]::Pattern,
        [ref] $textPattern)) {
        return ([System.Windows.Automation.TextPattern] $textPattern).DocumentRange.GetText(-1)
    }

    return [string] $Element.Current.Name
}

function Invoke-PhysicalClick {
    param([System.Windows.Automation.AutomationElement] $Element)

    $invokePattern = $null
    if ($Element.TryGetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern,
        [ref] $invokePattern)) {
        ([System.Windows.Automation.InvokePattern] $invokePattern).Invoke()
        Start-Sleep -Milliseconds 100
        return
    }

    $bounds = $Element.Current.BoundingRectangle
    Assert-True ($bounds.Width -gt 0 -and $bounds.Height -gt 0) 'Cannot click an element without visible bounds.'
    [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point(
        [int] ($bounds.X + ($bounds.Width / 2)),
        [int] ($bounds.Y + ($bounds.Height / 2)))
    Start-Sleep -Milliseconds 100
    [ZommiSendAcceptanceNative]::LeftButtonDown()
    Start-Sleep -Milliseconds 55
    [ZommiSendAcceptanceNative]::LeftButtonUp()
}

function Test-ChromeMcpLifecycle {
    param([System.Windows.Automation.AutomationElement] $Root)

    $elements = $Root.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($element in $elements) {
        try {
            if ([string] $element.Current.Name -match '^chrome\s+\S+\s+(new_page|navigate_page|take_snapshot|evaluate_script)$') {
                return $true
            }
        }
        catch {
            # Activity elements can disappear while a turn is streaming.
        }
    }
    return $false
}

function Find-ZommiWindow {
    param([string] $ResolvedExecutable)

    $processIds = @(
        Get-CimInstance Win32_Process -Filter "Name = 'Zommi.exe'" | Where-Object {
            $_.ExecutablePath -and
            [string]::Equals(
                [IO.Path]::GetFullPath($_.ExecutablePath),
                $ResolvedExecutable,
                [StringComparison]::OrdinalIgnoreCase)
        } | ForEach-Object ProcessId
    )
    $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
        [System.Windows.Automation.TreeScope]::Children,
        [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($window in $windows) {
        try {
            if ($processIds -contains $window.Current.ProcessId -and
                $window.Current.Name -like 'Zommi*floating*chat' -and
                -not $window.Current.IsOffscreen) {
                return $window
            }
        }
        catch {
            # Desktop windows can disappear during enumeration.
        }
    }
    return $null
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This send acceptance requires Windows.'
}

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ZommiSendAcceptanceNative {
    [DllImport("user32.dll")]
    private static extern void mouse_event(uint flags, uint dx, uint dy, int data, UIntPtr extraInfo);

    public static void LeftButtonDown() { mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero); }
    public static void LeftButtonUp() { mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero); }
}
'@
$resolvedExecutable = [IO.Path]::GetFullPath($ExecutablePath)
Assert-True (Test-Path -LiteralPath $resolvedExecutable -PathType Leaf) 'The packaged Zommi.exe is missing.'
$fixtureDirectory = $null

try {
foreach ($existing in @(Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'Zommi.exe' })) {
    Stop-Process -Id $existing.ProcessId -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 1500
if ($InterruptStreaming) {
    $expectedToken = 'ZOMMI_STOP_SHOULD_NOT_COMPLETE_' + [Guid]::NewGuid().ToString('N')
    $prompt = "Use the terminal tool to run sleep 30, then reply with exactly $expectedToken."
}
elseif ($RequireChromeTool) {
    $fixtureDirectory = Join-Path ([IO.Path]::GetTempPath()) ('zommi-chrome-tool-acceptance-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $fixtureDirectory | Out-Null
    $expectedToken = 'ZOMMI_CHROME_TOOL_' + [Guid]::NewGuid().ToString('N')
    $fixturePath = Join-Path $fixtureDirectory 'secret.html'
    [IO.File]::WriteAllText(
        $fixturePath,
        "<!doctype html><title>Private Zommi Chrome acceptance</title><main id='secret'>$expectedToken</main>")
    $fixtureUri = ([Uri] $fixturePath).AbsoluteUri
    $prompt = "Use the Chrome MCP browser tools to open $fixtureUri, read the exact token beginning ZOMMI_CHROME_TOOL_, and reply with that token only. Do not use shell, web search, attached snapshots, or accessibility automation."
}
else {
    $expectedToken = 'ZOMMI_SEND_COMPLETED_' + [Guid]::NewGuid().ToString('N')
    $prompt = "Reply with exactly $expectedToken and nothing else."
}

Start-Process `
    -FilePath $resolvedExecutable `
    -WorkingDirectory (Split-Path -Parent $resolvedExecutable) `
    -ArgumentList @('--force-renderer-accessibility') | Out-Null
$deadline = [DateTime]::UtcNow.AddSeconds(15)
$window = $null
while ($null -eq $window -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 100
    $window = Find-ZommiWindow $resolvedExecutable
}
Assert-True ($null -ne $window) 'Zommi did not expose its floating window.'

# A normal first launch intentionally remains the compact orb. Starting the
# exact executable again exercises the product's single-instance activation
# path, which opens and focuses the existing floating chat without synthetic
# keyboard or pointer input.
Start-Process `
    -FilePath $resolvedExecutable `
    -WorkingDirectory (Split-Path -Parent $resolvedExecutable) | Out-Null

$windowProvider = { Find-ZommiWindow $resolvedExecutable }
$composer = $null
$send = $null
$readyStatusText = '<missing>'
$readyDeadline = [DateTime]::UtcNow.AddSeconds(30)
while ([DateTime]::UtcNow -lt $readyDeadline) {
    $window = & $windowProvider
    if ($null -ne $window) {
        $composer = Find-ElementById $window 'ZommiComposer'
        $send = Find-ElementById $window 'SendMessage'
        $readyStatus = Find-ElementById $window 'CodexStatus'
        if ($null -ne $readyStatus) { $readyStatusText = [string] $readyStatus.Current.Name }
        if ($null -ne $composer -and $null -ne $send -and $send.Current.IsEnabled) { break }
    }
    Start-Sleep -Milliseconds 100
}
Assert-True ($null -ne $composer) 'The composer was not exposed through UI Automation.'
Assert-True ($null -ne $send -and $send.Current.IsEnabled) "The Send button did not become ready. Status: $readyStatusText"

if ($RequireChromeTool) {
    $chromeReady = $false
    $chromeReadyDeadline = [DateTime]::UtcNow.AddSeconds(30)
    while ([DateTime]::UtcNow -lt $chromeReadyDeadline) {
        $window = & $windowProvider
        if ($null -ne $window) {
            $readyStatus = Find-ElementById $window 'CodexStatus'
            if ($null -ne $readyStatus) {
                $readyStatusText = [string] $readyStatus.Current.Name
                if ($readyStatusText -like '*Chrome control ready*') {
                    $chromeReady = $true
                    break
                }
            }
        }
        Start-Sleep -Milliseconds 100
    }
    Assert-True $chromeReady "Chrome MCP did not become ready before its required-tool turn. Status: $readyStatusText"
    $composer = Find-ElementById $window 'ZommiComposer'
    $send = Find-ElementById $window 'SendMessage'
}

$valuePattern = $composer.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
([System.Windows.Automation.ValuePattern] $valuePattern).SetValue($prompt)
$inputDispatchStopwatch = [Diagnostics.Stopwatch]::StartNew()
Invoke-PhysicalClick $send
$inputDispatchStopwatch.Stop()
# UIA Invoke is synchronous and can block the acceptance process while Chromium
# updates its accessibility tree. Start the product-response clock only after
# Windows has returned from dispatching the input; report dispatch separately.
$stopwatch = [Diagnostics.Stopwatch]::StartNew()

if ($InterruptStreaming) {
    $accepted = $false
    $stopButton = $null
    $statusText = ''
    $transcriptText = ''
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
        $window = Find-ZommiWindow $resolvedExecutable
        if ($null -eq $window) { continue }
        $composer = Find-ElementById $window 'ZommiComposer'
        $stopButton = Find-ElementByName $window 'Stop response'
        $status = Find-ElementById $window 'CodexStatus'
        $transcript = Find-ElementById $window 'CodexTranscript'
        if ($null -ne $status) { $statusText = [string] $status.Current.Name }
        if ($null -ne $transcript) { $transcriptText = Get-ElementText $transcript }
        if ($null -ne $composer) {
            $currentValuePattern = $composer.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
            $accepted = [string]::IsNullOrEmpty(([System.Windows.Automation.ValuePattern] $currentValuePattern).Current.Value)
        }
        if ($accepted -and $null -ne $stopButton -and $stopButton.Current.IsEnabled) { break }
    }
    Assert-True $accepted "The live turn was not accepted before interruption. Status: $statusText"
    Assert-True ($null -ne $stopButton) 'The live send button did not become Stop response.'
    Invoke-PhysicalClick $stopButton

    $stopped = $false
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
        $window = Find-ZommiWindow $resolvedExecutable
        if ($null -eq $window) { continue }
        $send = Find-ElementByName $window 'Send message'
        $status = Find-ElementById $window 'CodexStatus'
        $transcript = Find-ElementById $window 'CodexTranscript'
        if ($null -ne $status) { $statusText = [string] $status.Current.Name }
        if ($null -ne $transcript) { $transcriptText = Get-ElementText $transcript }
        if ($null -ne $send -and $send.Current.IsEnabled -and $statusText -eq 'Agent status: stopped') {
            $stopped = $true
            break
        }
    }
    $stopwatch.Stop()
    Assert-True ($transcriptText -notmatch 'Error invoking remote method|operation has timed out|Could not stop response') "The live interrupt surfaced an error. Transcript: $transcriptText"
    Assert-True $stopped "turn/interrupt did not complete as interrupted. Status: $statusText Transcript: $transcriptText"
    $unexpectedResponse = Find-ElementByName $window $expectedToken
    Assert-True ($null -eq $unexpectedResponse) 'The interrupted turn still completed its forbidden final response.'
    [ordered]@{
        executablePath = $resolvedExecutable
        turnAccepted = 'passed'
        stopButton = 'passed'
        turnInterrupt = 'passed'
        interruptedStatus = 'passed'
        inputDispatchMilliseconds = $inputDispatchStopwatch.ElapsedMilliseconds
        elapsedMilliseconds = $stopwatch.ElapsedMilliseconds
        status = $statusText
    } | ConvertTo-Json
    return
}

$accepted = $false
$completed = $false
$acceptedMilliseconds = $null
$firstAgentOutputMilliseconds = $null
$statusText = ''
$transcriptText = ''
$responseText = ''
$sawChromeMcp = $false
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
while ([DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 100
    $window = Find-ZommiWindow $resolvedExecutable
    if ($null -eq $window) { continue }
    $composer = Find-ElementById $window 'ZommiComposer'
    $send = Find-ElementById $window 'SendMessage'
    $status = Find-ElementById $window 'CodexStatus'
    $transcript = Find-ElementById $window 'CodexTranscript'
    $response = Find-ElementByName $window $expectedToken
    if ($null -ne $status) { $statusText = [string] $status.Current.Name }
    if ($null -ne $transcript) { $transcriptText = Get-ElementText $transcript }
    if ($null -ne $response) { $responseText = Get-ElementText $response }
    if ($RequireChromeTool -and -not $sawChromeMcp) { $sawChromeMcp = Test-ChromeMcpLifecycle $window }
    if ($null -eq $firstAgentOutputMilliseconds -and
        ($transcriptText -match '(?i)thinking' -or $null -ne $response -or $sawChromeMcp)) {
        $firstAgentOutputMilliseconds = $stopwatch.ElapsedMilliseconds
    }
    if ($transcriptText -match 'Error invoking remote method|operation has timed out' -or
        $statusText -match 'turn failed|Codex error') { break }
    if ($null -ne $composer) {
        $currentValuePattern = $composer.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        if (-not $accepted -and
            [string]::IsNullOrEmpty(([System.Windows.Automation.ValuePattern] $currentValuePattern).Current.Value)) {
            $accepted = $true
            $acceptedMilliseconds = $stopwatch.ElapsedMilliseconds
        }
    }
    if ($null -ne $response -and $null -ne $send -and $send.Current.IsEnabled -and
        (-not $RequireChromeTool -or $sawChromeMcp)) {
        $completed = $true
        break
    }
}
$stopwatch.Stop()

Assert-True ($transcriptText -notmatch 'Error invoking remote method|operation has timed out') "The UI surfaced the old IPC timeout. Transcript: $transcriptText"
Assert-True $accepted "chat:send was not accepted within $TimeoutSeconds seconds. Status: $statusText Transcript: $transcriptText"
Assert-True ($statusText -notmatch 'turn failed|Codex error') "The Codex turn failed. Status: $statusText Transcript: $transcriptText"
Assert-True $completed "Codex did not complete with the expected response within $TimeoutSeconds seconds. Expected: $expectedToken Status: $statusText Response: $responseText"
Assert-True ($acceptedMilliseconds -le $MaxSendAcceptedMilliseconds) "The UI took $acceptedMilliseconds ms to accept send; budget is $MaxSendAcceptedMilliseconds ms."
Assert-True ($null -ne $firstAgentOutputMilliseconds -and $firstAgentOutputMilliseconds -le $MaxFirstAgentOutputMilliseconds) "First visible agent output took $firstAgentOutputMilliseconds ms; budget is $MaxFirstAgentOutputMilliseconds ms."
Assert-True ($stopwatch.ElapsedMilliseconds -le $MaxTurnCompletedMilliseconds) "The short response took $($stopwatch.ElapsedMilliseconds) ms; budget is $MaxTurnCompletedMilliseconds ms."
if ($RequireChromeTool) {
    Assert-True $sawChromeMcp 'The packaged UI did not expose a Chrome MCP tool lifecycle.'
}

[ordered]@{
    executablePath = $resolvedExecutable
    sendAccepted = 'passed'
    inputDispatchMilliseconds = $inputDispatchStopwatch.ElapsedMilliseconds
    acceptedMilliseconds = $acceptedMilliseconds
    firstAgentOutputMilliseconds = $firstAgentOutputMilliseconds
    turnCompleted = 'passed'
    completedMilliseconds = $stopwatch.ElapsedMilliseconds
    response = $responseText
    chromeMcp = if ($RequireChromeTool) { 'passed' } else { 'not requested' }
    remoteTimeout = 'absent'
    status = $statusText
} | ConvertTo-Json
}
finally {
    foreach ($candidate in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Zommi.exe' })) {
        Stop-Process -Id $candidate.ProcessId -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $fixtureDirectory -and (Test-Path -LiteralPath $fixtureDirectory)) {
        Remove-Item -LiteralPath $fixtureDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
