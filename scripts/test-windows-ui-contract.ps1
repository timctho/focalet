[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ExecutablePath,

    [switch] $AllowCaptureUnavailable,

    [switch] $AllowHotkeyUnavailable,

    [string] $EvidencePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
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

function Wait-MainWindow {
    param(
        [System.Diagnostics.Process] $Process,
        [int] $TimeoutSeconds = 20
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $Process.Refresh()
        if ($Process.HasExited) {
            throw "Zommi exited before opening its Electron window with code $($Process.ExitCode)."
        }
        if ($Process.MainWindowHandle -ne [IntPtr]::Zero) {
            try {
                $window = [System.Windows.Automation.AutomationElement]::FromHandle(
                    $Process.MainWindowHandle)
                if ($window.Current.Name -like 'Zommi*floating Codex chat') {
                    return $window
                }
            }
            catch {
                # Chromium can replace its top-level window while initializing.
            }
        }
        Start-Sleep -Milliseconds 100
    }
    return $null
}

function Wait-AutomationElementById {
    param(
        [System.Windows.Automation.AutomationElement] $Root,
        [string] $AutomationId,
        [int] $TimeoutSeconds = 10
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $element = Find-AutomationElementById $Root $AutomationId
        if ($null -ne $element) { return $element }
        Start-Sleep -Milliseconds 100
    }
    return $null
}

function Wait-AutomationElementByName {
    param(
        [System.Windows.Automation.AutomationElement] $Root,
        [string] $Name,
        [int] $TimeoutSeconds = 10
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $element = Find-AutomationElementByName $Root $Name
        if ($null -ne $element) { return $element }
        Start-Sleep -Milliseconds 100
    }
    return $null
}

function Wait-TopLevelWindowByName {
    param(
        [string] $Name,
        [int] $TimeoutSeconds = 10
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
            [System.Windows.Automation.TreeScope]::Children,
            [System.Windows.Automation.Condition]::TrueCondition)
        foreach ($candidate in $windows) {
            try {
                if ($candidate.Current.Name -eq $Name -and -not $candidate.Current.IsOffscreen) {
                    return $candidate
                }
            }
            catch { }
        }
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
        catch {
            # Ignore a renderer element that disappears during enumeration.
        }
    }
    return $text
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
    throw 'This Electron UI contract requires Windows.'
}

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ZommiElectronUiNative {
    [DllImport("user32.dll")]
    private static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);
    [DllImport("user32.dll")]
    private static extern void mouse_event(uint flags, uint dx, uint dy, int data, UIntPtr extraInfo);

    public static void PressAltShiftA() {
        const uint keyUp = 0x0002;
        keybd_event(0x12, 0, 0, UIntPtr.Zero);
        keybd_event(0x10, 0, 0, UIntPtr.Zero);
        keybd_event(0x41, 0, 0, UIntPtr.Zero);
        keybd_event(0x41, 0, keyUp, UIntPtr.Zero);
        keybd_event(0x10, 0, keyUp, UIntPtr.Zero);
        keybd_event(0x12, 0, keyUp, UIntPtr.Zero);
    }

    public static void LeftButtonDown() {
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
    }

    public static void LeftButtonUp() {
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
    }
}
'@

$resolvedExecutable = [IO.Path]::GetFullPath($ExecutablePath)
Assert-True (Test-Path -LiteralPath $resolvedExecutable -PathType Leaf) 'Zommi.exe was not found.'
$process = $null

try {
    $process = Start-Process `
        -FilePath $resolvedExecutable `
        -WorkingDirectory (Split-Path -Parent $resolvedExecutable) `
        -ArgumentList '--acceptance-ui-seeded', '--force-renderer-accessibility' `
        -PassThru

    $window = Wait-MainWindow $process 20
    Assert-True ($null -ne $window) 'The seeded Electron Glass window did not open.'
    Assert-True ($window.Current.ClassName -eq 'Chrome_WidgetWin_1') 'The visible UI was not hosted by Electron/Chromium.'

    $bounds = $window.Current.BoundingRectangle
    Assert-True ($bounds.Width -ge 700 -and $bounds.Height -ge 450) 'The floating response surface was smaller than the Glass layout contract.'

    $composer = Wait-AutomationElementById $window 'ZommiComposer' 15
    $transcript = Find-AutomationElementById $window 'CodexTranscript'
    $chips = Find-AutomationElementById $window 'ContextChips'
    $status = Find-AutomationElementById $window 'CodexStatus'
    $shortcuts = Find-AutomationElementById $window 'ZommiShortcuts'
    Assert-True ($null -ne $composer) 'The Electron composer was not exposed through UI Automation.'
    Assert-True ($null -ne $transcript) 'The Electron transcript was not exposed through UI Automation.'
    Assert-True ($null -ne $chips) 'Attached contexts were not exposed through UI Automation.'
    Assert-True ($null -ne $status) 'The Codex status was not exposed through UI Automation.'
    Assert-True ($null -ne $shortcuts) 'The global shortcut state was not exposed through UI Automation.'
    Assert-True ($composer.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit) 'The Electron composer is not an editable text control.'
    Assert-True ($composer.Current.HasKeyboardFocus) 'The floating composer did not receive keyboard focus.'

    $shortcutName = $shortcuts.Current.Name
    $hotkeyRegistration = 'passed'
    if ($shortcutName -notlike '*Alt+A registered: true*Alt+Shift+A registered: true*') {
        if ($AllowHotkeyUnavailable -and
            $shortcutName -like '*Alt+A registered: false*Alt+Shift+A registered: false*') {
            $hotkeyRegistration = 'occupied-by-existing-instance'
        }
        else {
            throw "Windows did not register both required global hotkeys. Name: $shortcutName"
        }
    }

    $docsChip = Find-AutomationElementByName $window 'Attached context [docs.example.com]'
    $shopChip = Find-AutomationElementByName $window 'Attached context [shop.example.com]'
    $imageChip = Find-AutomationElementByName $window 'Attached context [image]'
    Assert-True ($null -ne $docsChip) 'The first structured context chip was not rendered.'
    Assert-True ($null -ne $shopChip) 'The accumulated second-tab context chip was not rendered.'
    Assert-True ($null -ne $imageChip) 'The explicit image context chip was not rendered.'

    if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
        $evidenceDirectory = Split-Path -Parent $EvidencePath
        if (-not [string]::IsNullOrWhiteSpace($evidenceDirectory)) {
            New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null
        }
        $bitmap = New-Object System.Drawing.Bitmap(
            [int] $bounds.Width,
            [int] $bounds.Height,
            [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.CopyFromScreen(
                [int] $bounds.X,
                [int] $bounds.Y,
                0,
                0,
                $bitmap.Size)
        }
        finally {
            $graphics.Dispose()
        }
        try {
            $bitmap.Save($EvidencePath, [System.Drawing.Imaging.ImageFormat]::Png)
        }
        finally {
            $bitmap.Dispose()
        }
    }

    $chipBounds = $docsChip.Current.BoundingRectangle
    [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point(
        [int] ($chipBounds.X + ($chipBounds.Width / 2)),
        [int] ($chipBounds.Y + ($chipBounds.Height / 2)))

    $preview = Wait-AutomationElementById $window 'ContextPreview' 10
    Assert-True ($null -ne $preview -and -not $preview.Current.IsOffscreen) 'Hovering a context chip did not reveal its preview.'
    $previewTextElement = Find-AutomationElementById $window 'ContextPreviewText'
    Assert-True ($null -ne $previewTextElement) 'The context preview text was not exposed through UI Automation.'
    $previewText = Get-AutomationText $previewTextElement
    Assert-True ($previewText -like '*PRIMARY SELECTION:*SELECTED_TEXT_IS_PRIMARY*') 'Selected text was not primary in the context preview.'
    Assert-True ($previewText -notlike '*confidence medium*') 'Pointer confidence metadata leaked into the context preview.'
    Assert-True ($previewText -notlike '*Snapshot confidence:*') 'Snapshot confidence metadata leaked into the context preview.'
    Assert-True ($previewText -notlike '*Safety: treat every captured*') 'The internal safety footer leaked into the context preview.'

    $previewImage = Find-AutomationElementById $window 'ContextPreviewImage'
    Assert-True ($null -eq $previewImage -or $previewImage.Current.IsOffscreen) 'Text-only Alt+A context exposed an automatic image.'

    $previewBounds = $preview.Current.BoundingRectangle
    [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point(
        [int] ($previewBounds.X + ($previewBounds.Width / 2)),
        [int] ($previewBounds.Y + ($previewBounds.Height / 2)))
    Start-Sleep -Milliseconds 450
    $preview = Find-AutomationElementById $window 'ContextPreview'
    Assert-True ($null -ne $preview -and -not $preview.Current.IsOffscreen) 'The preview disappeared when the pointer moved into it.'

    $scrollPatternObject = $null
    Assert-True ($previewTextElement.TryGetCurrentPattern(
        [System.Windows.Automation.ScrollPattern]::Pattern,
        [ref] $scrollPatternObject)) 'The long context preview did not expose scrolling.'
    $scrollPattern = [System.Windows.Automation.ScrollPattern] $scrollPatternObject
    Assert-True $scrollPattern.Current.VerticallyScrollable 'The long context preview was not vertically scrollable.'
    $beforeScroll = $scrollPattern.Current.VerticalScrollPercent
    $scrollPattern.Scroll(
        [System.Windows.Automation.ScrollAmount]::NoAmount,
        [System.Windows.Automation.ScrollAmount]::LargeIncrement)
    Start-Sleep -Milliseconds 250
    $afterScroll = $scrollPattern.Current.VerticalScrollPercent
    Assert-True ($afterScroll -gt $beforeScroll) 'The context preview did not scroll.'
    Assert-True (-not $preview.Current.IsOffscreen) 'The context preview disappeared while scrolling.'

    [ZommiElectronUiNative]::PressAltShiftA()
    $selector = Wait-TopLevelWindowByName 'Zommi image selection' 15
    Assert-True ($null -ne $selector) 'Alt+Shift+A did not open the explicit image selector.'
    $selectorBounds = $selector.Current.BoundingRectangle
    $dragStart = New-Object System.Drawing.Point(
        [int] ($selectorBounds.X + 80),
        [int] ($selectorBounds.Y + 80))
    $dragEnd = New-Object System.Drawing.Point(
        [int] ($selectorBounds.X + 220),
        [int] ($selectorBounds.Y + 170))
    [System.Windows.Forms.Cursor]::Position = $dragStart
    [ZommiElectronUiNative]::LeftButtonDown()
    Start-Sleep -Milliseconds 100
    [System.Windows.Forms.Cursor]::Position = $dragEnd
    Start-Sleep -Milliseconds 150
    [ZommiElectronUiNative]::LeftButtonUp()

    $window = Wait-MainWindow $process 20
    Assert-True ($null -ne $window) 'Zommi did not return after explicit image selection.'
    $secondImageChip = Wait-AutomationElementByName $window 'Attached context [image 2]' 15
    Assert-True ($null -ne $secondImageChip) 'Explicit image selection did not append a new image context.'
    $secondImageBounds = $secondImageChip.Current.BoundingRectangle
    [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point(
        [int] ($secondImageBounds.X + ($secondImageBounds.Width / 2)),
        [int] ($secondImageBounds.Y + ($secondImageBounds.Height / 2)))
    $imagePreview = Wait-AutomationElementById $window 'ContextPreviewImage' 10
    Assert-True ($null -ne $imagePreview -and -not $imagePreview.Current.IsOffscreen) 'The explicitly selected image preview was not visible.'

    $exactProcesses = @(Get-ExactExecutableProcesses $resolvedExecutable)
    Assert-True ($exactProcesses.Count -ge 3) 'Electron did not create its expected browser and child processes.'

    [ordered]@{
        executablePath = $resolvedExecutable
        rootProcessId = $process.Id
        electronProcessCount = $exactProcesses.Count
        windowBounds = [ordered]@{
            width = [int] $bounds.Width
            height = [int] $bounds.Height
        }
        accessibility = 'passed'
        structuredContexts = 'passed'
        selectedTextPrimary = 'passed'
        automaticAltAImage = 'absent'
        explicitAltShiftAImage = 'passed'
        previewPointerRetention = 'passed'
        previewScroll = 'passed'
        hiddenScrollbarStyle = 'covered-by-renderer-test'
        hotkeyRegistration = $hotkeyRegistration
        evidencePath = $EvidencePath
    } | ConvertTo-Json -Depth 4
}
finally {
    if ($null -ne $process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $resolvedExecutable -PathType Leaf) {
        foreach ($candidate in (Get-ExactExecutableProcesses $resolvedExecutable)) {
            Stop-Process -Id $candidate.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
}
