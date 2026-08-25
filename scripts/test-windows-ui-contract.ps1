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

function Find-ProcessWindow {
    param(
        [System.Diagnostics.Process] $Process,
        [string] $Title,
        [int] $TimeoutSeconds = 15
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $desktop = [System.Windows.Automation.AutomationElement]::RootElement
        $windows = $desktop.FindAll(
            [System.Windows.Automation.TreeScope]::Children,
            [System.Windows.Automation.Condition]::TrueCondition)
        foreach ($candidate in $windows) {
            try {
                if ($candidate.Current.ProcessId -eq $Process.Id -and
                    $candidate.Current.Name -like $Title) {
                    return $candidate
                }
            } catch {
                # A top-level window can disappear while the desktop is enumerated.
            }
        }
        Start-Sleep -Milliseconds 100
    }
    return $null
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

function Find-AutomationElement {
    param(
        [System.Windows.Automation.AutomationElement] $Root,
        [string] $Name
    )

    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty,
        $Name)
    return $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Find-DocumentElement {
    param(
        [System.Windows.Automation.AutomationElement] $Root,
        [int] $Index
    )

    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Document)
    $documents = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if ($documents.Count -le $Index) { return $null }
    return $documents[$Index]
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
    return [string] $Element.Current.Name
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This UI contract requires Windows.'
}

Add-Type -AssemblyName UIAutomationClient
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Drawing;
using System.Drawing.Imaging;

public static class ZommiUiNative {
    [StructLayout(LayoutKind.Sequential)]
    private struct Rect { public int Left; public int Top; public int Right; public int Bottom; }
    private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);
    private delegate bool EnumChildProc(IntPtr window, IntPtr parameter);
    private static int searchProcessId;
    private static string searchTitle;
    private static IntPtr searchResult;

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    private static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);

    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageW")]
    private static extern IntPtr SendMessageText(IntPtr window, uint message, IntPtr wParam, StringBuilder text);

    public static IntPtr MousePosition(int x, int y) {
        return (IntPtr)((y << 16) | (x & 0xffff));
    }

    public static IntPtr MouseWheelDelta(short delta) {
        return (IntPtr)((long)(ushort)delta << 16);
    }

    public static void PressAltA() {
        const uint keyUp = 0x0002;
        keybd_event(0x12, 0, 0, UIntPtr.Zero);
        keybd_event(0x41, 0, 0, UIntPtr.Zero);
        keybd_event(0x41, 0, keyUp, UIntPtr.Zero);
        keybd_event(0x12, 0, keyUp, UIntPtr.Zero);
    }

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr window, StringBuilder text, int maximumCount);

    [DllImport("user32.dll")]
    private static extern bool EnumChildWindows(IntPtr parent, EnumChildProc callback, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr window, out Rect rectangle);

    [DllImport("user32.dll")]
    private static extern bool PrintWindow(IntPtr window, IntPtr deviceContext, uint flags);

    private static bool FindWindow(IntPtr window, IntPtr parameter) {
        uint processId;
        GetWindowThreadProcessId(window, out processId);
        StringBuilder text = new StringBuilder(512);
        GetWindowText(window, text, text.Capacity);
        if (processId == searchProcessId && text.ToString().Contains(searchTitle)) {
            searchResult = window;
            return false;
        }
        return true;
    }

    public static IntPtr FindProcessWindow(int processId, string title) {
        searchProcessId = processId;
        searchTitle = title;
        searchResult = IntPtr.Zero;
        EnumWindows(FindWindow, IntPtr.Zero);
        return searchResult;
    }

    public static string ReadDescendantText(IntPtr parent) {
        StringBuilder result = new StringBuilder();
        EnumChildWindows(parent, delegate(IntPtr window, IntPtr parameter) {
            StringBuilder text = new StringBuilder(32768);
            SendMessageText(window, 0x000D, (IntPtr)text.Capacity, text);
            if (text.Length > 0) result.Append(' ').Append(text);
            return true;
        }, IntPtr.Zero);
        return result.ToString();
    }

    public static bool CaptureWindow(IntPtr window, string path) {
        Rect rectangle;
        if (!GetWindowRect(window, out rectangle)) return false;
        int width = rectangle.Right - rectangle.Left;
        int height = rectangle.Bottom - rectangle.Top;
        using (Bitmap bitmap = new Bitmap(width, height, PixelFormat.Format32bppArgb))
        using (Graphics graphics = Graphics.FromImage(bitmap)) {
            IntPtr context = graphics.GetHdc();
            try {
                if (!PrintWindow(window, context, 2)) return false;
            } finally {
                graphics.ReleaseHdc(context);
            }
            bitmap.Save(path, ImageFormat.Png);
        }
        return true;
    }
}
'@

Assert-True (Test-Path -LiteralPath $ExecutablePath) 'Zommi.exe was not found.'
$process = $null
try {
    $process = Start-Process -FilePath $ExecutablePath -ArgumentList '--acceptance-ui-seeded' -PassThru
    $chat = Find-ProcessWindow $process 'Zommi*floating Codex chat' 20
    Assert-True ($null -ne $chat) 'The seeded Glass-style chat did not open.'

    $bounds = $chat.Current.BoundingRectangle
    Assert-True ($bounds.Width -ge 700 -and $bounds.Height -ge 340) 'The floating response surface did not use the expected wide Glass layout.'
    $allText = ''
    $shortcutElement = $null
    foreach ($descendant in $chat.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)) {
        try {
            $allText += ' ' + $descendant.Current.Name
            if ($descendant.Current.Name -like 'Alt + A*Alt + Shift + A*') {
                $shortcutElement = $descendant
            }
        } catch { }
    }
    Assert-True ($allText -like '*Alt + A*Alt + Shift + A*') 'The required shortcuts were not visible.'
    $shortcutName = if ($null -eq $shortcutElement) { '<missing>' } else { $shortcutElement.Current.Name }
    $shortcutHelp = if ($null -eq $shortcutElement) { '<missing>' } else { $shortcutElement.Current.HelpText }
    $hotkeyRegistration = 'passed'
    if ($null -eq $shortcutElement -or
        $shortcutName -notlike '*Alt+A registered: True*Alt+Shift+A registered: True*') {
        if ($AllowHotkeyUnavailable -and
            $shortcutName -like '*Alt+A registered: False*Alt+Shift+A registered: False*') {
            $hotkeyRegistration = 'occupied-by-existing-instance'
        } else {
            throw "Windows did not register both required global hotkeys. Name: $shortcutName Help: $shortcutHelp"
        }
    }

    $composer = Find-DocumentElement $chat 1
    Assert-True ($null -ne $composer) 'The composer was not exposed through UI Automation.'
    $composerText = (Get-AutomationText $composer).TrimEnd()
    Assert-True ($composerText -eq '[docs.example.com] [shop.example.com] [image]') "Context tokens were not inserted before send: '$composerText'."
    if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
        Assert-True ([ZommiUiNative]::CaptureWindow(
            [IntPtr] $chat.Current.NativeWindowHandle,
            $EvidencePath)) 'Could not capture the seeded Glass UI evidence.'
    }

    $composerBounds = $composer.Current.BoundingRectangle
    [void] [ZommiUiNative]::SetCursorPos(
        [int] ($composerBounds.X + 35),
        [int] ($composerBounds.Y + 18))
    [void] [ZommiUiNative]::SendMessage(
        [IntPtr] $composer.Current.NativeWindowHandle,
        0x0200,
        [IntPtr]::Zero,
        [ZommiUiNative]::MousePosition(35, 18))
    $preview = Find-ProcessWindow $process 'Zommi context preview' 10
    if ($null -eq $preview) {
        $previewHandle = [ZommiUiNative]::FindProcessWindow($process.Id, 'Zommi context preview')
        if ($previewHandle -ne [IntPtr]::Zero) {
            $preview = [System.Windows.Automation.AutomationElement]::FromHandle($previewHandle)
        }
    }
    if ($null -eq $preview) {
        $windowNames = @()
        foreach ($candidate in [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
            [System.Windows.Automation.TreeScope]::Children,
            [System.Windows.Automation.Condition]::TrueCondition)) {
            try {
                if ($candidate.Current.ProcessId -eq $process.Id) { $windowNames += $candidate.Current.Name }
            } catch { }
        }
        throw "Hovering a context token did not open a separate preview window. Process windows: $($windowNames -join ', ')"
    }
    $previewText = ''
    $descendants = $preview.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($descendant in $descendants) {
        try { $previewText += ' ' + (Get-AutomationText $descendant) } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($previewText)) {
        $previewNative = [ZommiUiNative]::FindProcessWindow($process.Id, 'Zommi context preview')
        $previewText = [ZommiUiNative]::ReadDescendantText($previewNative)
    }
    Assert-True ($previewText -like '*SELECTED_TEXT_IS_PRIMARY*') "The hover preview did not expose the actual selected context text. Preview text: $previewText"

    $previewHandle = [IntPtr] $preview.Current.NativeWindowHandle
    $previewDocument = Find-AutomationElementById $preview 'ContextPreviewText'
    Assert-True ($null -ne $previewDocument) 'The context preview text area was not exposed through UI Automation.'
    $previewBounds = $preview.Current.BoundingRectangle
    $previewPointerX = [int] ($previewBounds.X + ($previewBounds.Width / 2))
    $previewPointerY = [int] ($previewBounds.Y + ($previewBounds.Height / 2))
    [void] [ZommiUiNative]::SetCursorPos($previewPointerX, $previewPointerY)
    Start-Sleep -Milliseconds 450
    Assert-True ([ZommiUiNative]::IsWindowVisible($previewHandle)) 'The context preview disappeared while the pointer moved into it.'

    $previewDocumentHandle = [IntPtr] $previewDocument.Current.NativeWindowHandle
    $beforeScrollLine = [int] [ZommiUiNative]::SendMessage(
        $previewDocumentHandle,
        0x00CE,
        [IntPtr]::Zero,
        [IntPtr]::Zero)
    1..4 | ForEach-Object {
        [void] [ZommiUiNative]::SendMessage(
            $previewDocumentHandle,
            0x020A,
            [ZommiUiNative]::MouseWheelDelta(-120),
            [ZommiUiNative]::MousePosition($previewPointerX, $previewPointerY))
    }
    Start-Sleep -Milliseconds 150
    $afterScrollLine = [int] [ZommiUiNative]::SendMessage(
        $previewDocumentHandle,
        0x00CE,
        [IntPtr]::Zero,
        [IntPtr]::Zero)
    Assert-True ($afterScrollLine -gt $beforeScrollLine) "The context preview did not scroll while hovered. First visible line: $beforeScrollLine -> $afterScrollLine"
    Assert-True ([ZommiUiNative]::IsWindowVisible($previewHandle)) 'The context preview disappeared during scrolling.'

    [void] [ZommiUiNative]::SetCursorPos(5, 5)
    Start-Sleep -Milliseconds 450
    Assert-True (-not [ZommiUiNative]::IsWindowVisible($previewHandle)) 'The context preview remained visible after the pointer left it.'
    $chatHandle = [IntPtr] $chat.Current.NativeWindowHandle
    Assert-True ([ZommiUiNative]::PostMessage($chatHandle, 0x0312, [IntPtr] 0x5A4E, [IntPtr]::Zero)) 'Could not invoke image selection through WM_HOTKEY.'
    $selector = Find-ProcessWindow $process 'Zommi image selection' 10
    Assert-True ($null -ne $selector) 'Alt+Shift+A did not open the image-selection overlay.'
    $selectorHandle = [IntPtr] $selector.Current.NativeWindowHandle
    [void] [ZommiUiNative]::SendMessage($selectorHandle, 0x0201, [IntPtr] 1, [ZommiUiNative]::MousePosition(120, 120))
    [void] [ZommiUiNative]::SendMessage($selectorHandle, 0x0200, [IntPtr] 1, [ZommiUiNative]::MousePosition(300, 220))
    [void] [ZommiUiNative]::SendMessage($selectorHandle, 0x0202, [IntPtr]::Zero, [ZommiUiNative]::MousePosition(300, 220))

    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 100
        $chat = Find-ProcessWindow $process 'Zommi*floating Codex chat' 1
        if ($null -ne $chat) {
            $composer = Find-DocumentElement $chat 1
            $composerText = if ($null -eq $composer) { '' } else { (Get-AutomationText $composer).TrimEnd() }
        }
    } while (-not $composerText.Contains('[image 2]') -and [DateTime]::UtcNow -lt $deadline)
    $imageSelectionResult = 'passed'
    if (-not $composerText.Contains('[image 2]')) {
        $selectorAfter = [ZommiUiNative]::FindProcessWindow($process.Id, 'Zommi image selection')
        $status = Find-AutomationElementById $chat 'CodexStatus'
        $statusText = if ($null -eq $status) { '<missing>' } else { $status.Current.Name }
        if ($AllowCaptureUnavailable -and $statusText -like '*Image selection failed:*') {
            $imageSelectionResult = 'capture-unavailable'
        } else {
            throw "The selected screen region was not attached to the composer as image context. Composer: $composerText Status: $statusText Selector: $selectorAfter"
        }
    }

    $beforeMove = $chat.Current.BoundingRectangle
    [void] [ZommiUiNative]::SetCursorPos(80, 80)
    [ZommiUiNative]::PressAltA()
    Start-Sleep -Milliseconds 700
    $chat = Find-ProcessWindow $process 'Zommi*floating Codex chat' 5
    $afterMove = $chat.Current.BoundingRectangle
    $shortcutDispatch = 'physical-alt-a'
    if ($beforeMove.X -eq $afterMove.X -and $beforeMove.Y -eq $afterMove.Y) {
        Assert-True ([ZommiUiNative]::PostMessage(
            [IntPtr] $chat.Current.NativeWindowHandle,
            0x0312,
            [IntPtr] 0x5A4D,
            [IntPtr]::Zero)) 'Could not reinvoke Alt+A while the chat was visible.'
        Start-Sleep -Milliseconds 700
        $chat = Find-ProcessWindow $process 'Zommi*floating Codex chat' 5
        $afterMove = $chat.Current.BoundingRectangle
        $shortcutDispatch = 'wm-hotkey-fallback'
    }
    $reinvocationResult = 'passed'
    if ($beforeMove.X -eq $afterMove.X -and $beforeMove.Y -eq $afterMove.Y) {
        if ($AllowCaptureUnavailable) {
            $reinvocationResult = 'cursor-unavailable'
        } else {
            throw 'Reinvoking Alt+A did not move the existing window beside the pointer.'
        }
    } else {
        $pointerInside = 420 -ge $afterMove.X -and 420 -lt ($afterMove.X + $afterMove.Width) -and 120 -ge $afterMove.Y -and 120 -lt ($afterMove.Y + $afterMove.Height)
        Assert-True (-not $pointerInside) 'Reinvocation moved the window under the pointer.'
    }

    [ordered]@{
        contextTokens = $composerText
        hoverPreview = 'passed'
        hoverPreviewScroll = "$beforeScrollLine->$afterScrollLine"
        imageSelection = $imageSelectionResult
        hotkeyRegistration = $hotkeyRegistration
        shortcutDispatch = $shortcutDispatch
        reinvocationMove = $reinvocationResult
        bounds = "$($afterMove.X),$($afterMove.Y),$($afterMove.Width),$($afterMove.Height)"
    } | ConvertTo-Json
} finally {
    if ($null -ne $process -and -not $process.HasExited) {
        & taskkill.exe /PID $process.Id /T /F 2>&1 | Out-Null
    }
}
