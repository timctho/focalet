[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ExecutablePath,

    [int] $TimeoutSeconds = 180
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
                $window.Current.Name -like 'Zommi*floating Codex chat' -and
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
$resolvedExecutable = [IO.Path]::GetFullPath($ExecutablePath)
Assert-True (Test-Path -LiteralPath $resolvedExecutable -PathType Leaf) 'The packaged Zommi.exe is missing.'

Start-Process -FilePath $resolvedExecutable -WorkingDirectory (Split-Path -Parent $resolvedExecutable) | Out-Null
$deadline = [DateTime]::UtcNow.AddSeconds(15)
$window = $null
while ($null -eq $window -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 100
    $window = Find-ZommiWindow $resolvedExecutable
}
Assert-True ($null -ne $window) 'Zommi did not expose its floating window.'

$windowProvider = { Find-ZommiWindow $resolvedExecutable }
$composer = Wait-ElementById $windowProvider 'ZommiComposer'
$send = Wait-ElementById $windowProvider 'SendMessage'
Assert-True ($null -ne $composer) 'The composer was not exposed through UI Automation.'
Assert-True ($null -ne $send) 'The Send button was not exposed through UI Automation.'

$valuePattern = $composer.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
$expectedToken = 'ZOMMI_SEND_COMPLETED_' + [Guid]::NewGuid().ToString('N')
$prompt = "Reply with exactly $expectedToken and nothing else."
([System.Windows.Automation.ValuePattern] $valuePattern).SetValue($prompt)
$invokePattern = $send.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
([System.Windows.Automation.InvokePattern] $invokePattern).Invoke()

$accepted = $false
$completed = $false
$acceptedMilliseconds = $null
$statusText = ''
$transcriptText = ''
$responseText = ''
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
    if ($null -ne $response -and $null -ne $send -and $send.Current.IsEnabled) {
        $completed = $true
        break
    }
}
$stopwatch.Stop()

Assert-True ($transcriptText -notmatch 'Error invoking remote method|operation has timed out') "The UI surfaced the old IPC timeout. Transcript: $transcriptText"
Assert-True $accepted "chat:send was not accepted within $TimeoutSeconds seconds. Status: $statusText Transcript: $transcriptText"
Assert-True ($statusText -notmatch 'turn failed|Codex error') "The Codex turn failed. Status: $statusText Transcript: $transcriptText"
Assert-True $completed "Codex did not complete with the expected response within $TimeoutSeconds seconds. Expected: $expectedToken Status: $statusText Response: $responseText"

[ordered]@{
    executablePath = $resolvedExecutable
    sendAccepted = 'passed'
    acceptedMilliseconds = $acceptedMilliseconds
    turnCompleted = 'passed'
    completedMilliseconds = $stopwatch.ElapsedMilliseconds
    response = $responseText
    remoteTimeout = 'absent'
    status = $statusText
} | ConvertTo-Json
