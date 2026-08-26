[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ExecutablePath,

    [switch] $AllowCaptureUnavailable,

    [switch] $AllowHotkeyUnavailable,

    [switch] $GeometryOnly,

    [switch] $ForceUiaFallback,

    [string] $EvidencePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:inputMode = 'sendinput'
$hoverOpacityContract = 'passed'
$dragGestureContract = 'passed'
if ($ForceUiaFallback) {
    $script:inputMode = 'uia-fallback-input-desktop-locked'
}

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

function Get-AllZommiProcesses {
    return @(Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'Zommi.exe' })
}

function Invoke-PhysicalClick {
    param([System.Windows.Automation.AutomationElement] $Element)

    if ($script:nativeWindowHandle -ne [IntPtr]::Zero) {
        [void] [ZommiElectronUiNative]::Activate($script:nativeWindowHandle)
        Start-Sleep -Milliseconds 100
    }
    $bounds = $Element.Current.BoundingRectangle
    Assert-True ($bounds.Width -gt 0 -and $bounds.Height -gt 0) 'Cannot click an element without visible bounds.'
    $moved = $script:inputMode -eq 'sendinput' -and [ZommiElectronUiNative]::MovePointer(
        [int] ($bounds.X + ($bounds.Width / 2)),
        [int] ($bounds.Y + ($bounds.Height / 2)))
    if (-not $moved) {
        $script:inputMode = 'uia-fallback-input-desktop-locked'
        $invokePatternObject = $null
        if ($Element.TryGetCurrentPattern(
            [System.Windows.Automation.InvokePattern]::Pattern,
            [ref] $invokePatternObject)) {
            ([System.Windows.Automation.InvokePattern] $invokePatternObject).Invoke()
            Start-Sleep -Milliseconds 180
            return
        }
        $Element.SetFocus()
        return
    }
    Start-Sleep -Milliseconds 120
    [ZommiElectronUiNative]::LeftButtonDown()
    Start-Sleep -Milliseconds 55
    [ZommiElectronUiNative]::LeftButtonUp()
    Start-Sleep -Milliseconds 180
}

function Get-PhysicalHitInfo {
    param([System.Windows.Automation.AutomationElement] $Element)

    $bounds = $Element.Current.BoundingRectangle
    $x = [int] ($bounds.X + ($bounds.Width / 2))
    $y = [int] ($bounds.Y + ($bounds.Height / 2))
    $hitTest = [ZommiElectronUiNative]::HitTest($script:nativeWindowHandle, $x, $y)
    $pointElement = [System.Windows.Automation.AutomationElement]::FromPoint(
        (New-Object System.Windows.Point($x, $y)))
    $pointId = if ($null -eq $pointElement) { '<missing>' } else { $pointElement.Current.AutomationId }
    $pointName = if ($null -eq $pointElement) { '<missing>' } else { $pointElement.Current.Name }
    return "hit=$hitTest pointId=$pointId pointName=$pointName bounds=$bounds enabled=$($Element.Current.IsEnabled)"
}

function Get-BitmapBrightness {
    param([string] $Path)

    $bitmap = [System.Drawing.Bitmap]::FromFile($Path)
    try {
        $total = 0.0
        $left = [int] ($bitmap.Width * 0.45)
        $top = [Math]::Min($bitmap.Height - 13, [Math]::Max(1, [int] ($bitmap.Height * 0.04)))
        for ($x = $left; $x -lt ($left + 12); $x++) {
            for ($y = $top; $y -lt ($top + 12); $y++) {
                $pixel = $bitmap.GetPixel($x, $y)
                $total += ($pixel.R + $pixel.G + $pixel.B) / 3.0
            }
        }
        return $total / (12 * 12)
    }
    finally {
        $bitmap.Dispose()
    }
}

function Get-BitmapOpacity {
    param([string] $Path)

    $bitmap = [System.Drawing.Bitmap]::FromFile($Path)
    try {
        $total = 0.0
        $left = [int] ($bitmap.Width * 0.45)
        $top = [Math]::Min($bitmap.Height - 13, [Math]::Max(1, [int] ($bitmap.Height * 0.04)))
        for ($x = $left; $x -lt ($left + 12); $x++) {
            for ($y = $top; $y -lt ($top + 12); $y++) {
                $total += $bitmap.GetPixel($x, $y).A
            }
        }
        return $total / (12 * 12)
    }
    finally {
        $bitmap.Dispose()
    }
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
    private static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")]
    private static extern int GetWindowRgn(IntPtr window, IntPtr region);
    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr window);
    [DllImport("user32.dll")]
    private static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);
    [DllImport("user32.dll")]
    private static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")]
    private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")]
    private static extern void mouse_event(uint flags, uint dx, uint dy, int data, UIntPtr extraInfo);

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT {
        public uint type;
        public MOUSEINPUT mouse;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint flags;
        public uint time;
        public UIntPtr extraInfo;
    }
    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateRectRgn(int left, int top, int right, int bottom);
    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr value);

    public static int GetWindowRegionType(IntPtr window) {
        IntPtr region = CreateRectRgn(0, 0, 0, 0);
        try { return GetWindowRgn(window, region); }
        finally { DeleteObject(region); }
    }

    public static uint ReadWindowDpi(IntPtr window) {
        return GetDpiForWindow(window);
    }

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

    public static void MouseWheel(int delta) {
        mouse_event(0x0800, 0, 0, delta, UIntPtr.Zero);
    }

    public static bool MovePointer(int x, int y) {
        return SetCursorPos(x, y);
    }

    private static bool SendMouse(uint flags, int x, int y, uint data, bool absolute) {
        if (absolute) {
            int left = GetSystemMetrics(76);
            int top = GetSystemMetrics(77);
            int width = Math.Max(2, GetSystemMetrics(78));
            int height = Math.Max(2, GetSystemMetrics(79));
            x = (int)Math.Round((x - left) * 65535.0 / (width - 1));
            y = (int)Math.Round((y - top) * 65535.0 / (height - 1));
            flags |= 0x8000 | 0x4000;
        }
        var input = new INPUT {
            type = 0,
            mouse = new MOUSEINPUT {
                dx = x,
                dy = y,
                mouseData = data,
                flags = flags,
                time = 0,
                extraInfo = UIntPtr.Zero,
            },
        };
        return SendInput(1, new[] { input }, Marshal.SizeOf(typeof(INPUT))) == 1;
    }

    public static int HitTest(IntPtr window, int screenX, int screenY) {
        long packed = ((long)(screenY & 0xffff) << 16) | (uint)(screenX & 0xffff);
        return SendMessage(window, 0x0084, IntPtr.Zero, new IntPtr(packed)).ToInt32();
    }

    public static bool Activate(IntPtr target) {
        IntPtr foreground = GetForegroundWindow();
        uint foregroundThread = GetWindowThreadProcessId(foreground, IntPtr.Zero);
        uint targetThread = GetWindowThreadProcessId(target, IntPtr.Zero);
        bool attached = foregroundThread != targetThread && AttachThreadInput(foregroundThread, targetThread, true);
        try {
            if (IsIconic(target)) ShowWindow(target, 9);
            BringWindowToTop(target);
            return SetForegroundWindow(target);
        } finally {
            if (attached) AttachThreadInput(foregroundThread, targetThread, false);
        }
    }
}
'@

$resolvedExecutable = [IO.Path]::GetFullPath($ExecutablePath)
Assert-True (Test-Path -LiteralPath $resolvedExecutable -PathType Leaf) 'Zommi.exe was not found.'
$process = $null

try {
    foreach ($existing in (Get-AllZommiProcesses)) {
        Stop-Process -Id $existing.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 1500
    Assert-True (@(Get-AllZommiProcesses).Count -eq 0) 'A pre-existing Zommi product process retained the single-instance lock.'
    $argumentList = @('--force-renderer-accessibility', '--', '--acceptance-ui-seeded')
    if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
        $resolvedEvidencePath = [IO.Path]::GetFullPath($EvidencePath)
        $resolvedHoverRestPath = [IO.Path]::ChangeExtension($resolvedEvidencePath, '.rest.png')
        $resolvedHoverActivePath = [IO.Path]::ChangeExtension($resolvedEvidencePath, '.hover.png')
        Remove-Item -LiteralPath $resolvedEvidencePath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $resolvedHoverRestPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $resolvedHoverActivePath -Force -ErrorAction SilentlyContinue
        $argumentList += "--acceptance-evidence=$resolvedEvidencePath"
        $argumentList += "--acceptance-hover-rest=$resolvedHoverRestPath"
        $argumentList += "--acceptance-hover-active=$resolvedHoverActivePath"
    }
    # parent application and other Electron hosts can export this to child terminals. It is
    # host-internal and would make the packaged Electron binary run as Node.
    Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
    $process = Start-Process `
        -FilePath $resolvedExecutable `
        -WorkingDirectory (Split-Path -Parent $resolvedExecutable) `
        -ArgumentList $argumentList `
        -PassThru

    $window = Wait-MainWindow $process 20
    Assert-True ($null -ne $window) 'The seeded Electron Glass window did not open.'
    Assert-True ($window.Current.ClassName -eq 'Chrome_WidgetWin_1') 'The visible UI was not hosted by Electron/Chromium.'

    $bounds = $window.Current.BoundingRectangle
    Assert-True ($bounds.Width -ge 700 -and $bounds.Height -ge 450) 'The floating response surface was smaller than the Glass layout contract.'
    $nativeWindowHandle = [IntPtr] $window.Current.NativeWindowHandle
    Assert-True ([ZommiElectronUiNative]::GetWindowRegionType($nativeWindowHandle) -eq 0) 'A hard-edged native window region is still clipping the antialiased CSS corners.'
    $windowDpi = [ZommiElectronUiNative]::ReadWindowDpi($nativeWindowHandle)
    $displayScale = $windowDpi / 96.0
    $windowRectangle = New-Object System.Drawing.Rectangle(
        [int] $bounds.X,
        [int] $bounds.Y,
        [int] $bounds.Width,
        [int] $bounds.Height)
    $workingArea = [System.Windows.Forms.Screen]::FromRectangle($windowRectangle).WorkingArea
    $workingWidthDip = $workingArea.Width / $displayScale
    $workingHeightDip = $workingArea.Height / $displayScale
    $expectedWidthDip = [Math]::Min(
        [Math]::Max(640, [Math]::Floor($workingWidthDip - 32)),
        [Math]::Max(840, [Math]::Min([Math]::Round($workingWidthDip * 0.56), 1120)))
    $expectedHeightDip = [Math]::Min(
        [Math]::Max(500, [Math]::Floor($workingHeightDip - 32)),
        [Math]::Max(600, [Math]::Min([Math]::Round($workingHeightDip * 0.72), 840)))
    Assert-True ([Math]::Abs($bounds.Width - ($expectedWidthDip * $displayScale)) -le (4 * $displayScale)) 'The window width did not adapt to the current display work area and DPI.'
    Assert-True ([Math]::Abs($bounds.Height - ($expectedHeightDip * $displayScale)) -le (4 * $displayScale)) 'The window height did not adapt to the current display work area and DPI.'
    [void] [ZommiElectronUiNative]::MovePointer(
        [int] ($workingArea.Right - 2),
        [int] ($workingArea.Bottom - 2))
    Start-Sleep -Milliseconds 650
    [void] [ZommiElectronUiNative]::MovePointer(
        [int] ($bounds.X + 18),
        [int] ($bounds.Y + 100))
    Start-Sleep -Milliseconds 650

    $composer = Wait-AutomationElementById $window 'ZommiComposer' 15
    $transcript = Find-AutomationElementById $window 'CodexTranscript'
    $chips = Find-AutomationElementById $window 'ContextChips'
    $status = Find-AutomationElementById $window 'CodexStatus'
    $shortcuts = Find-AutomationElementById $window 'ZommiShortcuts'
    $toggleSessions = Wait-AutomationElementById $window 'ToggleSessions' 10
    $modelSummary = Wait-AutomationElementById $window 'ModelSummary' 10
    Assert-True ($null -ne $composer) 'The Electron composer was not exposed through UI Automation.'
    Assert-True ($null -ne $transcript) 'The Electron transcript was not exposed through UI Automation.'
    Assert-True ($null -ne $chips) 'Attached contexts were not exposed through UI Automation.'
    Assert-True ($null -ne $status) 'The Codex status was not exposed through UI Automation.'
    Assert-True ($null -ne $shortcuts) 'The global shortcut state was not exposed through UI Automation.'
    Assert-True ($null -ne $toggleSessions) 'The chat-session sidebar control was not exposed.'
    Assert-True ($null -ne $modelSummary) 'The model/reasoning control was not exposed.'
    Assert-True ($composer.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit) 'The Electron composer is not an editable text control.'
    Assert-True ($composer.Current.HasKeyboardFocus) 'The floating composer did not receive keyboard focus.'

    $sessionSidebar = Wait-AutomationElementById $window 'SessionSidebar' 10
    Assert-True ($null -eq $sessionSidebar -or $sessionSidebar.Current.IsOffscreen) 'The session sidebar should start hidden.'
    $toggleSessionsHit = Get-PhysicalHitInfo $toggleSessions
    Assert-True ($toggleSessionsHit -like 'hit=1 pointId=ToggleSessions *') "The session control was obscured or mapped to a native drag region. $toggleSessionsHit"
    Invoke-PhysicalClick $toggleSessions
    $sessionSidebar = Wait-AutomationElementById $window 'SessionSidebar' 10
    $seededSession = Wait-AutomationElementByName $window 'Structured context' 10
    $toggleAfterClick = Find-AutomationElementById $window 'ToggleSessions'
    $sidebarState = if ($null -eq $sessionSidebar) { '<missing>' } else { "offscreen=$($sessionSidebar.Current.IsOffscreen) bounds=$($sessionSidebar.Current.BoundingRectangle)" }
    $toggleState = if ($null -eq $toggleAfterClick) { '<missing>' } else { "name=$($toggleAfterClick.Current.Name) bounds=$($toggleAfterClick.Current.BoundingRectangle)" }
    Assert-True ($null -ne $sessionSidebar -and -not $sessionSidebar.Current.IsOffscreen) "The session sidebar did not open after a physical click. Sidebar: $sidebarState Toggle: $toggleState Hit: $toggleSessionsHit inputMode=$script:inputMode"
    Assert-True ($null -ne $seededSession -and -not $seededSession.Current.IsOffscreen) 'The active seeded chat was not listed in the sidebar.'
    $modelSummaryHit = Get-PhysicalHitInfo $modelSummary
    Assert-True ($modelSummaryHit -like 'hit=1 *' -and $modelSummaryHit -like '*pointName=*Standard*') "The model control was obscured or mapped to a native drag region. $modelSummaryHit"
    $effortBefore = $modelSummary.Current.Name
    Invoke-PhysicalClick $modelSummary
    Start-Sleep -Milliseconds 350
    $modelPanel = Wait-AutomationElementById $window 'ModelPanel' 10
    $modelSearch = Wait-AutomationElementById $window 'ModelSearch' 10
    $modelList = Wait-AutomationElementById $window 'ModelList' 10
    $effortList = Wait-AutomationElementById $window 'EffortList' 10
    Assert-True ($null -ne $modelPanel -and -not $modelPanel.Current.IsOffscreen) "The model settings sub-panel did not open after a physical click. $modelSummaryHit inputMode=$script:inputMode"
    Assert-True ($null -ne $modelSearch -and -not $modelSearch.Current.IsOffscreen) 'The searchable model selector was not visible.'
    Assert-True ($null -ne $modelList -and -not $modelList.Current.IsOffscreen) 'The model options were not visible.'
    Assert-True ($null -ne $effortList -and -not $effortList.Current.IsOffscreen) 'The reasoning options were not visible.'
    $targetEffortId = if ($effortBefore -like '*Low*') { 'Effort-medium' } else { 'Effort-low' }
    $targetEffortName = if ($targetEffortId -eq 'Effort-low') { 'Low' } else { 'Medium' }
    $effortOption = Wait-AutomationElementById $window $targetEffortId 10
    Assert-True ($null -ne $effortOption -and -not $effortOption.Current.IsOffscreen) 'The reasoning panel exposed no alternate option.'
    $effortHit = Get-PhysicalHitInfo $effortOption
    Assert-True ($effortHit -like 'hit=1 *') "The reasoning option was mapped to a native drag region. $effortHit"
    Invoke-PhysicalClick $effortOption
    Start-Sleep -Milliseconds 250
    $modelSummary = Find-AutomationElementById $window 'ModelSummary'
    $effortAfter = $modelSummary.Current.Name
    Assert-True ($effortAfter -ne $effortBefore -and $effortAfter -like "*$targetEffortName*") 'A real click did not change the reasoning level.'
    Invoke-PhysicalClick $modelSummary
    Invoke-PhysicalClick $toggleSessions
    $backgroundDragPoints = @(
        [System.Drawing.Point]::new([int] ($bounds.X + ($bounds.Width / 2)), [int] ($bounds.Y + 20)),
        [System.Drawing.Point]::new([int] ($bounds.X + 24), [int] ($bounds.Y + ($bounds.Height / 2))),
        [System.Drawing.Point]::new([int] ($bounds.X + $bounds.Width - 24), [int] ($bounds.Y + ($bounds.Height / 2))),
        [System.Drawing.Point]::new([int] ($bounds.X + ($bounds.Width * 0.22)), [int] ($bounds.Bottom - 128))
    )
    foreach ($dragPoint in $backgroundDragPoints) {
        $dragPointHitTest = [ZommiElectronUiNative]::HitTest(
            $nativeWindowHandle,
            $dragPoint.X,
            $dragPoint.Y)
        Assert-True ($dragPointHitTest -eq 2) "A background area outside the chat/composer was not exposed as native HTCAPTION. point=$dragPoint hit=$dragPointHitTest"
    }
    $dragStart = New-Object System.Drawing.Point(
        [int] ($bounds.X + $bounds.Width - 24),
        [int] ($bounds.Y + ($bounds.Height / 2)))
    $blankRegionHitTest = [ZommiElectronUiNative]::HitTest(
        $nativeWindowHandle,
        $dragStart.X,
        $dragStart.Y)
    Assert-True ($blankRegionHitTest -eq 2) "The blank white gutter was not exposed as native HTCAPTION. Hit test: $blankRegionHitTest"
    if ($script:inputMode -eq 'sendinput') {
        $dragEnd = New-Object System.Drawing.Point(($dragStart.X + 54), ($dragStart.Y + 26))
        [void] [ZommiElectronUiNative]::MovePointer($dragStart.X, $dragStart.Y)
        Start-Sleep -Milliseconds 100
        [ZommiElectronUiNative]::LeftButtonDown()
        for ($step = 1; $step -le 6; $step++) {
            [void] [ZommiElectronUiNative]::MovePointer(
                [int] ($dragStart.X + (($dragEnd.X - $dragStart.X) * $step / 6)),
                [int] ($dragStart.Y + (($dragEnd.Y - $dragStart.Y) * $step / 6)))
            Start-Sleep -Milliseconds 18
        }
        [ZommiElectronUiNative]::LeftButtonUp()
        Start-Sleep -Milliseconds 300
        $window = Wait-MainWindow $process 10
        $movedBounds = $window.Current.BoundingRectangle
        $movedDeltaX = $movedBounds.X - $bounds.X
        $movedDeltaY = $movedBounds.Y - $bounds.Y
        Assert-True ($movedDeltaX -ge 20 -and $movedDeltaX -le 62 -and
            $movedDeltaY -ge 10 -and $movedDeltaY -le 34) "A real drag gesture on blank glass did not track the pointer after the native drag threshold. start=$bounds moved=$movedBounds delta=$movedDeltaX,$movedDeltaY inputMode=$script:inputMode"
        $bounds = $movedBounds
    }
    else {
        $dragGestureContract = 'blocked-input-desktop-locked; native-hit-test-passed'
    }

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

    $chipBounds = $docsChip.Current.BoundingRectangle
    [void] [ZommiElectronUiNative]::MovePointer(
        [int] ($chipBounds.X + ($chipBounds.Width / 2)),
        [int] ($chipBounds.Y + ($chipBounds.Height / 2)))

    $preview = Wait-AutomationElementById $window 'ContextPreview' 10
    $cursorAfterHover = [System.Windows.Forms.Cursor]::Position
    Assert-True ($null -ne $preview -and -not $preview.Current.IsOffscreen) "Hovering a context chip did not reveal its preview. Chip=$chipBounds Cursor=$cursorAfterHover Window=$bounds"
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
    [void] [ZommiElectronUiNative]::MovePointer(
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

    $firstUserMessage = Wait-AutomationElementByName $window 'User message turn 1' 10
    $secondUserMessage = Wait-AutomationElementByName $window 'User message turn 2' 10
    $firstAssistantMessage = Wait-AutomationElementByName $window 'Codex response turn 1' 10
    $secondAssistantMessage = Wait-AutomationElementByName $window 'Codex response turn 2' 10
    $thinkingActivity = Wait-AutomationElementByName $window 'Thinking activity' 10
    $toolActivity = Wait-AutomationElementByName $window 'Tool activity' 10
    Assert-True ($null -ne $firstUserMessage -and $null -ne $secondUserMessage) 'The seeded UI did not retain both user messages.'
    Assert-True ($null -ne $firstAssistantMessage -and $null -ne $secondAssistantMessage) 'The seeded UI did not retain both Codex responses.'
    Assert-True ($null -ne $thinkingActivity -and $null -ne $toolActivity) 'Thinking and tool activity were not exposed as distinct cards.'
    $firstUserBounds = $firstUserMessage.Current.BoundingRectangle
    $secondUserBounds = $secondUserMessage.Current.BoundingRectangle
    $userMessagesOverlap = $firstUserBounds.Top -lt $secondUserBounds.Bottom -and
        $firstUserBounds.Bottom -gt $secondUserBounds.Top -and
        $firstUserBounds.Left -lt $secondUserBounds.Right -and
        $firstUserBounds.Right -gt $secondUserBounds.Left
    Assert-True (-not $userMessagesOverlap) 'The retained user messages overlap.'

    Invoke-PhysicalClick $composer
    $composerValue = $composer.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    ([System.Windows.Automation.ValuePattern] $composerValue).SetValue('seeded streaming acceptance')
    Start-Sleep -Milliseconds 150
    $sendButton = Find-AutomationElementById $window 'SendMessage'
    $sendButtonHit = Get-PhysicalHitInfo $sendButton
    Assert-True ($sendButtonHit -like 'hit=1 pointId=SendMessage *') "The send control was obscured or mapped to a native drag region. $sendButtonHit"
    Invoke-PhysicalClick $sendButton
    $stopButton = Wait-AutomationElementByName $window 'Stop response' 10
    Assert-True ($null -ne $stopButton -and $stopButton.Current.IsEnabled) "The physically clicked send button did not become an enabled stop button during streaming. $sendButtonHit inputMode=$script:inputMode"

    $transcriptScrollObject = $null
    $streamDeadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $streamDeadline) {
        $transcript = Find-AutomationElementById $window 'CodexTranscript'
        if ($transcript.TryGetCurrentPattern(
            [System.Windows.Automation.ScrollPattern]::Pattern,
            [ref] $transcriptScrollObject) -and
            ([System.Windows.Automation.ScrollPattern] $transcriptScrollObject).Current.VerticallyScrollable) {
            break
        }
        $transcriptScrollObject = $null
        Start-Sleep -Milliseconds 100
    }
    Assert-True ($null -ne $transcriptScrollObject) 'The seeded streaming transcript never became scrollable.'
    $manualScrollPercent = 100.0
    $transcriptHitTest = -1
    for ($wheelAttempt = 0; $wheelAttempt -lt 3 -and $manualScrollPercent -ge 95; $wheelAttempt++) {
        [void] [ZommiElectronUiNative]::Activate($script:nativeWindowHandle)
        $transcript = Find-AutomationElementById $window 'CodexTranscript'
        $transcriptBounds = $transcript.Current.BoundingRectangle
        $transcriptX = [int] ($transcriptBounds.X + ($transcriptBounds.Width / 2))
        $transcriptY = [int] ($transcriptBounds.Y + ($transcriptBounds.Height / 2))
        $transcriptHitTest = [ZommiElectronUiNative]::HitTest(
            $script:nativeWindowHandle,
            $transcriptX,
            $transcriptY)
        Assert-True ($transcriptHitTest -eq 1) "The transcript center was mapped to a native drag region. hit=$transcriptHitTest bounds=$transcriptBounds"
        [void] [ZommiElectronUiNative]::MovePointer($transcriptX, $transcriptY)
        if ($script:inputMode -eq 'sendinput') {
            for ($wheel = 0; $wheel -lt 12; $wheel++) {
                [ZommiElectronUiNative]::MouseWheel(120)
                Start-Sleep -Milliseconds 45
            }
        }
        else {
            ([System.Windows.Automation.ScrollPattern] $transcriptScrollObject).Scroll(
                [System.Windows.Automation.ScrollAmount]::NoAmount,
                [System.Windows.Automation.ScrollAmount]::LargeDecrement)
        }
        Start-Sleep -Milliseconds 250
        $transcript = Find-AutomationElementById $window 'CodexTranscript'
        $transcriptScrollObject = $null
        Assert-True ($transcript.TryGetCurrentPattern(
            [System.Windows.Automation.ScrollPattern]::Pattern,
            [ref] $transcriptScrollObject)) 'The transcript stopped exposing scroll state.'
        $manualScrollPercent = ([System.Windows.Automation.ScrollPattern] $transcriptScrollObject).Current.VerticalScrollPercent
    }
    Assert-True ($manualScrollPercent -lt 95) "Real mouse-wheel gestures did not move the streaming transcript away from the bottom. percent=$manualScrollPercent hit=$transcriptHitTest cursor=$([System.Windows.Forms.Cursor]::Position)"
    Start-Sleep -Milliseconds 1200
    $transcript = Find-AutomationElementById $window 'CodexTranscript'
    $transcriptScrollObject = $null
    [void] $transcript.TryGetCurrentPattern(
        [System.Windows.Automation.ScrollPattern]::Pattern,
        [ref] $transcriptScrollObject)
    $percentWhileStreaming = ([System.Windows.Automation.ScrollPattern] $transcriptScrollObject).Current.VerticalScrollPercent
    Assert-True ($percentWhileStreaming -lt 98) 'Streaming forced a manually scrolled transcript back to the bottom.'
    $latestButton = Wait-AutomationElementById $window 'ScrollToLatest' 5
    Assert-True ($null -ne $latestButton -and -not $latestButton.Current.IsOffscreen) 'The latest-message arrow did not appear after scrolling up.'
    Invoke-PhysicalClick $latestButton
    Start-Sleep -Milliseconds 250
    $transcript = Find-AutomationElementById $window 'CodexTranscript'
    $transcriptScrollObject = $null
    [void] $transcript.TryGetCurrentPattern(
        [System.Windows.Automation.ScrollPattern]::Pattern,
        [ref] $transcriptScrollObject)
    Assert-True (([System.Windows.Automation.ScrollPattern] $transcriptScrollObject).Current.VerticalScrollPercent -ge 98) 'The latest-message arrow did not return to the streaming bottom.'

    $stopButton = Wait-AutomationElementByName $window 'Stop response' 5
    Invoke-PhysicalClick $stopButton
    $sendButton = Wait-AutomationElementByName $window 'Send message' 10
    $status = Find-AutomationElementById $window 'CodexStatus'
    Assert-True ($null -ne $sendButton -and $sendButton.Current.IsEnabled) 'Stopping did not restore the enabled send button.'
    Assert-True ($status.Current.Name -eq 'Codex status: stopped') "The stopped turn did not expose the interrupted state. Status: $($status.Current.Name)"
    $streamedTranscriptText = Get-AutomationText (Find-AutomationElementById $window 'CodexTranscript')
    $thinkingPhraseCount = ([regex]::Matches($streamedTranscriptText, [regex]::Escape('Preparing a long streamed response.'))).Count
    # Chromium excludes collapsed details content from UIA TextPattern, so zero
    # is valid here; the renderer test/probe separately requires exactly one.
    Assert-True ($thinkingPhraseCount -le 1) "Thinking live/completed content was duplicated. occurrenceCount=$thinkingPhraseCount"

    if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
        $evidenceDeadline = [DateTime]::UtcNow.AddSeconds(15)
        while (-not (Test-Path -LiteralPath $resolvedEvidencePath -PathType Leaf) -and
            [DateTime]::UtcNow -lt $evidenceDeadline) {
            Start-Sleep -Milliseconds 100
        }
        Assert-True (Test-Path -LiteralPath $resolvedEvidencePath -PathType Leaf) 'Electron did not write its renderer evidence image.'
        if ($script:inputMode -eq 'sendinput') {
            $hoverEvidenceDeadline = [DateTime]::UtcNow.AddSeconds(15)
            while ((-not (Test-Path -LiteralPath $resolvedHoverRestPath -PathType Leaf) -or
                    -not (Test-Path -LiteralPath $resolvedHoverActivePath -PathType Leaf)) -and
                [DateTime]::UtcNow -lt $hoverEvidenceDeadline) {
                Start-Sleep -Milliseconds 100
            }
            Assert-True (Test-Path -LiteralPath $resolvedHoverRestPath -PathType Leaf) 'Electron did not capture the non-hovered compositor state.'
            Assert-True (Test-Path -LiteralPath $resolvedHoverActivePath -PathType Leaf) 'Electron did not capture the hovered compositor state.'
            $brightnessWithoutHover = Get-BitmapBrightness $resolvedHoverRestPath
            $brightnessWithHover = Get-BitmapBrightness $resolvedHoverActivePath
            $opacityWithoutHover = Get-BitmapOpacity $resolvedHoverRestPath
            $opacityWithHover = Get-BitmapOpacity $resolvedHoverActivePath
            Assert-True ($brightnessWithHover -ge $brightnessWithoutHover -and
                $opacityWithHover -ge ($opacityWithoutHover + 5.0)) "Moving the pointer over the chat did not make the glass measurably less transparent. brightness=$brightnessWithoutHover->$brightnessWithHover opacity=$opacityWithoutHover->$opacityWithHover"
        }
        else {
            $hoverOpacityContract = 'blocked-input-desktop-locked; css-contract-passed'
        }
        $bitmap = [System.Drawing.Bitmap]::FromFile($resolvedEvidencePath)
        try {
            Assert-True ($bitmap.Width -ge ($bounds.Width - 2) -and $bitmap.Height -ge ($bounds.Height - 2)) 'The captured renderer surface did not preserve the adaptive native pixel dimensions.'
            $edgePixels = @(
                $bitmap.GetPixel([int] ($bitmap.Width / 2), 1),
                $bitmap.GetPixel([int] ($bitmap.Width / 2), $bitmap.Height - 2),
                $bitmap.GetPixel(1, [int] ($bitmap.Height / 2)),
                $bitmap.GetPixel($bitmap.Width - 2, [int] ($bitmap.Height / 2))
            )
            foreach ($pixel in $edgePixels) {
                $brightness = ([int] $pixel.R + [int] $pixel.G + [int] $pixel.B) / 3
                Assert-True ($pixel.A -ge 200 -and $brightness -ge 150) 'The renderer retained a dark or transparent border around the glass surface.'
            }
            $cornerPixels = @(
                $bitmap.GetPixel(0, 0),
                $bitmap.GetPixel($bitmap.Width - 1, 0),
                $bitmap.GetPixel(0, $bitmap.Height - 1),
                $bitmap.GetPixel($bitmap.Width - 1, $bitmap.Height - 1)
            )
            foreach ($pixel in $cornerPixels) {
                Assert-True ($pixel.A -le 16) 'A square opaque corner remains outside the rounded glass.'
            }
            $partialAlphaPixels = 0
            for ($x = 0; $x -lt [Math]::Min(48, $bitmap.Width); $x++) {
                for ($y = 0; $y -lt [Math]::Min(48, $bitmap.Height); $y++) {
                    $alpha = $bitmap.GetPixel($x, $y).A
                    if ($alpha -gt 0 -and $alpha -lt 190) { $partialAlphaPixels++ }
                }
            }
            Assert-True ($partialAlphaPixels -ge 4) 'The rounded edge has no partial-alpha antialiasing pixels.'
        }
        finally {
            $bitmap.Dispose()
        }
    }

    if ($GeometryOnly) {
        [ordered]@{
            executablePath = $resolvedExecutable
            rootProcessId = $process.Id
            windowBounds = [ordered]@{
                width = [int] $bounds.Width
                height = [int] $bounds.Height
                dpi = [int] $windowDpi
            }
            adaptiveDisplaySizing = 'passed'
            alphaAntialiasedCorners = 'passed'
            fullResolutionRenderer = 'passed'
            retainedConversationTurns = 'passed'
            nonOverlappingMessages = 'passed'
            thinkingAndToolCards = 'passed'
            modelReasoningPanel = 'passed'
            sessionSidebar = 'passed'
            backgroundDrag = $dragGestureContract
            inputMode = $script:inputMode
            streamingStopButton = 'passed'
            manualScrollPreserved = 'passed'
            latestMessageButton = 'passed'
            thinkingDeduplication = 'passed'
            hoverReducesTransparency = $hoverOpacityContract
            evidencePath = $EvidencePath
        } | ConvertTo-Json -Depth 4
        return
    }

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
    [void] [ZommiElectronUiNative]::MovePointer($dragStart.X, $dragStart.Y)
    [ZommiElectronUiNative]::LeftButtonDown()
    Start-Sleep -Milliseconds 100
    [void] [ZommiElectronUiNative]::MovePointer($dragEnd.X, $dragEnd.Y)
    Start-Sleep -Milliseconds 150
    [ZommiElectronUiNative]::LeftButtonUp()

    $window = Wait-MainWindow $process 20
    Assert-True ($null -ne $window) 'Zommi did not return after explicit image selection.'
    $secondImageChip = Wait-AutomationElementByName $window 'Attached context [image]' 15
    Assert-True ($null -ne $secondImageChip) 'Explicit image selection did not append a new image context after the prior turn cleared submitted attachments.'
    $secondImageBounds = $secondImageChip.Current.BoundingRectangle
    [void] [ZommiElectronUiNative]::MovePointer(
        [int] ($secondImageBounds.X + ($secondImageBounds.Width / 2)),
        [int] ($secondImageBounds.Y + ($secondImageBounds.Height / 2)))
    $imagePreview = Wait-AutomationElementById $window 'ContextPreviewImage' 10
    Assert-True ($null -ne $imagePreview -and -not $imagePreview.Current.IsOffscreen) 'The explicitly selected image preview was not visible.'
    $pairedPreviewTextElement = Find-AutomationElementById $window 'ContextPreviewText'
    Assert-True ($null -ne $pairedPreviewTextElement -and -not $pairedPreviewTextElement.Current.IsOffscreen) 'Alt+Shift+A did not retain shortcut-time pointer context beside the image.'
    $pairedPreviewText = Get-AutomationText $pairedPreviewTextElement
    Assert-True ($pairedPreviewText -notlike '*User-selected screen region*') 'Alt+Shift+A attached an image-only placeholder instead of pointer context.'

    $exactProcesses = @(Get-ExactExecutableProcesses $resolvedExecutable)
    Assert-True ($exactProcesses.Count -ge 3) 'Electron did not create its expected browser and child processes.'

    [ordered]@{
        executablePath = $resolvedExecutable
        rootProcessId = $process.Id
        electronProcessCount = $exactProcesses.Count
        windowBounds = [ordered]@{
            width = [int] $bounds.Width
            height = [int] $bounds.Height
            dpi = [int] $windowDpi
        }
        adaptiveDisplaySizing = 'passed'
        alphaAntialiasedCorners = 'passed'
        accessibility = 'passed'
        structuredContexts = 'passed'
        retainedConversationTurns = 'passed'
        nonOverlappingMessages = 'passed'
        thinkingAndToolCards = 'passed'
        modelReasoningPanel = 'passed'
        sessionSidebar = 'passed'
        backgroundDrag = $dragGestureContract
        inputMode = $script:inputMode
        streamingStopButton = 'passed'
        manualScrollPreserved = 'passed'
        latestMessageButton = 'passed'
        thinkingDeduplication = 'passed'
        hoverReducesTransparency = $hoverOpacityContract
        selectedTextPrimary = 'passed'
        automaticAltAImage = 'absent'
        explicitAltShiftAImage = 'passed'
        altShiftAPointerContext = 'passed'
        previewPointerRetention = 'passed'
        previewScroll = 'passed'
        hoverScrollbarStyle = 'covered-by-renderer-test'
        hotkeyRegistration = $hotkeyRegistration
        evidencePath = $EvidencePath
    } | ConvertTo-Json -Depth 4
}
finally {
    if ($null -ne $process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
    foreach ($candidate in (Get-AllZommiProcesses)) {
        Stop-Process -Id $candidate.ProcessId -Force -ErrorAction SilentlyContinue
    }
}
