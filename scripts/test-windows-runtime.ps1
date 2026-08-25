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
        [int] $TimeoutSeconds = 180
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    Assert-True ($process.Start()) "Could not start $FilePath."
    $standardOutput = $process.StandardOutput.ReadToEndAsync()
    $standardError = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        & taskkill.exe /PID $process.Id /T /F 2>&1 | Out-Null
        throw "$FilePath timed out after $TimeoutSeconds seconds."
    }
    $process.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StandardOutput = $standardOutput.Result
        StandardError = $standardError.Result
    }
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

function Find-ControlTypeElement {
    param(
        [System.Windows.Automation.AutomationElement] $Root,
        [System.Windows.Automation.ControlType] $ControlType
    )

    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        $ControlType)
    return $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Find-ZommiDocument {
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

function Find-ZommiTranscript {
    param([System.Windows.Automation.AutomationElement] $Root)
    $element = Find-AutomationElementById $Root 'CodexTranscript'
    if ($null -ne $element) { return $element }
    return Find-ZommiDocument $Root 0
}

function Find-ZommiComposer {
    param([System.Windows.Automation.AutomationElement] $Root)
    $element = Find-AutomationElementById $Root 'ZommiComposer'
    if ($null -ne $element) { return $element }
    return Find-ZommiDocument $Root 1
}

function Find-ZommiWindow {
    param([System.Diagnostics.Process] $Process)

    $desktop = [System.Windows.Automation.AutomationElement]::RootElement
    $windows = $desktop.FindAll(
        [System.Windows.Automation.TreeScope]::Children,
        [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($candidate in $windows) {
        try {
            if ($candidate.Current.ProcessId -eq $Process.Id -and
                $candidate.Current.Name -like 'Zommi*floating Codex chat' -and
                -not $candidate.Current.IsOffscreen) {
                return $candidate
            }
        } catch {
            # The desktop window list can change while it is enumerated.
        }
    }
    return $null
}

function Wait-ZommiWindow {
    param(
        [System.Diagnostics.Process] $Process,
        [int] $TimeoutSeconds = 15
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $window = Find-ZommiWindow $Process
        if ($null -ne $window) {
            return $window
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
    if ($Element.Current.NativeWindowHandle -ne 0) {
        return [ZommiNativeWindow]::ReadWindowText([IntPtr] $Element.Current.NativeWindowHandle)
    }
    return [string] $Element.Current.Name
}

function Set-AutomationValue {
    param(
        [System.Windows.Automation.AutomationElement] $Element,
        [string] $Value
    )

    $pattern = $null
    if ($Element.TryGetCurrentPattern(
        [System.Windows.Automation.ValuePattern]::Pattern,
        [ref] $pattern)) {
        ([System.Windows.Automation.ValuePattern] $pattern).SetValue($Value)
        return
    }
    Assert-True ([ZommiNativeWindow]::SetControlText(
        [IntPtr] $Element.Current.NativeWindowHandle,
        $Value)) 'Could not write the RichEdit composer text.'
}

function Invoke-AutomationElement {
    param([System.Windows.Automation.AutomationElement] $Element)
    $pattern = $Element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    ([System.Windows.Automation.InvokePattern] $pattern).Invoke()
}

function Wait-TranscriptText {
    param(
        [System.Diagnostics.Process] $Process,
        [string] $Expected,
        [int] $TimeoutSeconds = 120
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $window = Find-ZommiWindow $Process
        if ($null -ne $window) {
            $transcript = Find-ZommiTranscript $window
            if ($null -ne $transcript) {
                $text = Get-AutomationText $transcript
                if ($text -like "*$Expected*") {
                    return $text
                }
            }
        }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Wait-ThreadId {
    param(
        [System.Diagnostics.Process] $Process,
        [int] $TimeoutSeconds = 60
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $window = Find-ZommiWindow $Process
        if ($null -ne $window) {
            $status = Find-AutomationElementById $window 'CodexStatus'
            if ($null -ne $status) {
                $statusText = [string] $status.Current.Name
                if ($statusText -match 'thread ([0-9a-f-]{36})') {
                    return $Matches[1]
                }
            }
        }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Assert-ComposerFocused {
    param([System.Windows.Automation.AutomationElement] $Window)
    $composer = Find-ZommiComposer $Window
    Assert-True ($null -ne $composer) 'The floating composer was not exposed through UI Automation.'
    Assert-True $composer.Current.HasKeyboardFocus 'The floating composer did not receive keyboard focus.'
    return $composer
}

function Invoke-ZommiShortcut {
    param([System.Diagnostics.Process] $Process)

    [ZommiNativeWindow]::PressAltA()
    $window = Wait-ZommiWindow $Process 3
    $dispatch = 'synthetic-keyboard'
    if ($null -eq $window) {
        Assert-True ([ZommiNativeWindow]::SendZommiHotkey([uint32] $Process.Id)) 'Could not deliver WM_HOTKEY to the hidden Zommi form.'
        $window = Wait-ZommiWindow $Process 15
        $dispatch = 'wm-hotkey-fallback'
    }
    return [pscustomobject]@{
        Window = $window
        Dispatch = $dispatch
    }
}

function Activate-Window {
    param(
        [IntPtr] $WindowHandle,
        [int] $ProcessId,
        [string] $Title = ''
    )

    $shell = New-Object -ComObject WScript.Shell
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        try {
            [System.Windows.Automation.AutomationElement]::FromHandle($WindowHandle).SetFocus()
        } catch {
            # Continue with native activation when the UIA provider is transient.
        }
        [void] [ZommiNativeWindow]::Activate($WindowHandle)
        [void] $shell.AppActivate($ProcessId)
        if (-not [string]::IsNullOrWhiteSpace($Title)) {
            [void] $shell.AppActivate($Title)
        }
        Start-Sleep -Milliseconds 150
        $foreground = [ZommiNativeWindow]::GetForegroundWindow()
        $foregroundProcessId = [ZommiNativeWindow]::GetWindowProcessId($foreground)
        $foregroundTitle = [ZommiNativeWindow]::ReadWindowText($foreground)
        if ($foreground -eq $WindowHandle -or
            $foregroundProcessId -eq $ProcessId -or
            (-not [string]::IsNullOrWhiteSpace($Title) -and $foregroundTitle -like "*$Title*")) {
            return $true
        }
    }
    return $false
}

function Send-ChatTurn {
    param(
        [System.Diagnostics.Process] $Process,
        [System.Windows.Automation.AutomationElement] $Window,
        [string] $Prompt,
        [string] $Expected
    )

    $composer = Assert-ComposerFocused $Window
    $attached = Get-AutomationText $composer
    Set-AutomationValue $composer ($attached + $Prompt)
    $send = Find-AutomationElementById $Window 'SendMessage'
    Assert-True ($null -ne $send) 'The Send button was not exposed through UI Automation.'
    Invoke-AutomationElement $send
    $transcript = Wait-TranscriptText $Process $Expected
    if ($null -eq $transcript) {
        $latestWindow = Find-ZommiWindow $Process
        $latestTranscript = Find-ZommiTranscript $latestWindow
        $latestStatus = Find-AutomationElementById $latestWindow 'CodexStatus'
        $latestComposer = Find-ZommiComposer $latestWindow
        $transcriptText = if ($null -eq $latestTranscript) { '<missing>' } else { Get-AutomationText $latestTranscript }
        $statusText = if ($null -eq $latestStatus) { '<missing>' } else { [string] $latestStatus.Current.Name }
        $composerText = if ($null -eq $latestComposer) { '<missing>' } else { Get-AutomationText $latestComposer }
        throw "Codex did not stream '$Expected' into the floating chat. Transcript: $transcriptText Status: $statusText Composer: $composerText"
    }
    return $transcript
}

if (-not [Environment]::Is64BitOperatingSystem -or
    [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This acceptance script requires 64-bit Windows.'
}

Add-Type -AssemblyName UIAutomationClient
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class ZommiNativeWindow {
    [StructLayout(LayoutKind.Sequential)]
    public struct Point {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
    [DllImport("user32.dll")]
    private static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder value, int maximumCount);
    [DllImport("user32.dll")]
    private static extern bool PostMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    private static extern bool AttachThreadInput(uint attach, uint attachTo, bool value);
    [DllImport("user32.dll")]
    private static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int command);
    [DllImport("user32.dll")]
    private static extern void SwitchToThisWindow(IntPtr hWnd, bool altTab);
    [DllImport("user32.dll")]
    private static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageW")]
    private static extern IntPtr SendMessageText(IntPtr window, uint message, IntPtr wParam, string text);

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr parameter);
    private static uint searchProcessId;
    private static IntPtr searchResult;

    private static bool FindProcessWindow(IntPtr hWnd, IntPtr parameter) {
        uint processId;
        GetWindowThreadProcessId(hWnd, out processId);
        if (processId == searchProcessId && GetWindowTextLength(hWnd) > 0) {
            searchResult = hWnd;
            return false;
        }
        return true;
    }

    public static Point CursorPosition() {
        Point point;
        GetCursorPos(out point);
        return point;
    }

    public static void PressAltA() {
        const uint KeyUp = 0x0002;
        keybd_event(0x12, 0, 0, UIntPtr.Zero);
        keybd_event(0x41, 0, 0, UIntPtr.Zero);
        keybd_event(0x41, 0, KeyUp, UIntPtr.Zero);
        keybd_event(0x12, 0, KeyUp, UIntPtr.Zero);
    }

    public static void PressEscape() {
        const uint KeyUp = 0x0002;
        keybd_event(0x1B, 0, 0, UIntPtr.Zero);
        keybd_event(0x1B, 0, KeyUp, UIntPtr.Zero);
    }

    public static bool SendZommiHotkey(uint processId) {
        searchProcessId = processId;
        searchResult = IntPtr.Zero;
        EnumWindows(FindProcessWindow, IntPtr.Zero);
        return searchResult != IntPtr.Zero && PostMessage(searchResult, 0x0312, (IntPtr)0x5A4D, IntPtr.Zero);
    }

    public static bool SetControlText(IntPtr window, string text) {
        return window != IntPtr.Zero && SendMessageText(window, 0x000C, IntPtr.Zero, text) != IntPtr.Zero;
    }

    public static int GetWindowProcessId(IntPtr window) {
        uint processId;
        GetWindowThreadProcessId(window, out processId);
        return (int)processId;
    }

    public static string ReadWindowText(IntPtr window) {
        int length = GetWindowTextLength(window);
        StringBuilder value = new StringBuilder(length + 1);
        GetWindowText(window, value, value.Capacity);
        return value.ToString();
    }

    public static bool Activate(IntPtr target) {
        const uint KeyUp = 0x0002;
        IntPtr foreground = GetForegroundWindow();
        uint ignored;
        uint foregroundThread = GetWindowThreadProcessId(foreground, out ignored);
        uint targetThread = GetWindowThreadProcessId(target, out ignored);
        bool attached = foregroundThread != targetThread && AttachThreadInput(foregroundThread, targetThread, true);
        try {
            keybd_event(0x12, 0, 0, UIntPtr.Zero);
            ShowWindow(target, 9);
            BringWindowToTop(target);
            SwitchToThisWindow(target, true);
            return SetForegroundWindow(target);
        } finally {
            keybd_event(0x12, 0, KeyUp, UIntPtr.Zero);
            if (attached) AttachThreadInput(foregroundThread, targetThread, false);
        }
    }
}
'@

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('zommi-floating-chat-' + [Guid]::NewGuid().ToString('N'))
$executable = Join-Path $temporaryRoot 'Zommi.exe'
$gui = $null
$edgeWindow = $null
$edgeProfile = $null
$explorerWindow = $null
$notepadWindow = $null
$results = [ordered]@{}

try {
    New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null
    Copy-Item -LiteralPath $ExecutablePath -Destination $executable

    $handshake = Invoke-CapturedProcess $executable '--acceptance-app-server-handshake' 90
    Assert-True ($handshake.ExitCode -eq 0) "Windows to WSL app-server handshake failed: $($handshake.StandardError)"
    $handshakeJson = $handshake.StandardOutput | ConvertFrom-Json
    Assert-True $handshakeJson.ready 'The app-server handshake did not create a Codex thread.'
    $results.appServerHandshake = 'passed'

    $relay = Invoke-CapturedProcess $executable '--acceptance-app-server-turn' 180
    Assert-True ($relay.ExitCode -eq 0) "Windows to WSL Codex turn failed: $($relay.StandardError)"
    $relayJson = $relay.StandardOutput | ConvertFrom-Json
    Assert-True ($relayJson.status -eq 'completed') "The relay turn ended as '$($relayJson.status)'."
    Assert-True ($relayJson.response -eq 'ZOMMI_RELAY_READY') "Unexpected relay response: '$($relayJson.response)'."
    $results.appServerTurn = 'passed'

    $activity = Invoke-CapturedProcess $executable '--acceptance-app-server-activity' 180
    Assert-True ($activity.ExitCode -eq 0) "Codex activity streaming probe failed: $($activity.StandardError) $($activity.StandardOutput)"
    $activityJson = $activity.StandardOutput | ConvertFrom-Json
    Assert-True ($activityJson.sawThinking) 'Codex thinking/commentary was not streamed through Zommi.'
    Assert-True ($activityJson.sawTool) 'Codex tool lifecycle was not streamed through Zommi.'
    Assert-True ($activityJson.sawToolOutput) 'Codex tool output was not streamed through Zommi.'
    $results.appServerActivity = 'passed'

    $image = Invoke-CapturedProcess $executable '--acceptance-app-server-image' 180
    Assert-True ($image.ExitCode -eq 0) "Codex image-context probe failed: $($image.StandardError) $($image.StandardOutput)"
    $imageJson = $image.StandardOutput | ConvertFrom-Json
    Assert-True ($imageJson.response -like '*ZOMMI_IMAGE_4827*') 'Codex did not receive the selected-image input.'
    $results.appServerImage = 'passed'

    $selection = Invoke-CapturedProcess $executable '--acceptance-selected-text' 30
    Assert-True ($selection.ExitCode -eq 0) "Selected-text capture probe failed: $($selection.StandardError) $($selection.StandardOutput)"
    $selectionJson = $selection.StandardOutput | ConvertFrom-Json
    Assert-True (@($selectionJson.selection) -contains 'SELECTED_TEXT_CAPTURE_7391') 'Windows UI Automation did not return the selected text.'
    $results.selectedTextCapture = 'passed'

    $gui = Start-Process -FilePath $executable -PassThru
    Start-Sleep -Milliseconds 1500
    $gui.Refresh()
    Assert-True (-not $gui.HasExited) 'Zommi exited during hidden tray startup.'
    Assert-True ($null -eq (Find-ZommiWindow $gui)) 'Zommi showed its chat before the shortcut was pressed.'
    $results.hiddenTrayStartup = 'passed'

    if ($SkipBrowser) {
        throw '-SkipBrowser is diagnostic only; full floating-chat acceptance requires Edge.'
    }

    $edgeCandidates = @(
        @(
            (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
            (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
        ) | Where-Object { Test-Path $_ }
    )
    Assert-True ($edgeCandidates.Count -gt 0) 'Microsoft Edge is not installed.'
    $edgeExecutable = $edgeCandidates[0]
    $browserMarker = 'ZOMMI_PAGE_' + [Guid]::NewGuid().ToString('N')
    $buttonName = 'Hover target ' + $browserMarker
    $bodyMarker = 'Visible page text ' + $browserMarker
    $tableMarker = 'Account usage grid ' + $browserMarker
    $tableCellMarker = 'Account row ' + $browserMarker
    $longPageTailMarker = 'LONG_PAGE_TAIL_' + [Guid]::NewGuid().ToString('N')
    $browserTitle = 'Zommi Acceptance ' + $browserMarker
    $htmlPath = Join-Path $temporaryRoot 'zommi-browser-acceptance.html'
    $longPageParagraphs = [string]::Join('', @(1..80 | ForEach-Object {
        '<p>Long webpage paragraph {0}: {1}</p>' -f $_, ('x' * 180)
    }))
    $html = "<!doctype html><title>$browserTitle</title><main><button style='position:fixed;top:80px;right:80px;font-size:30px'>$buttonName</button><h1>$bodyMarker</h1><table aria-label='$tableMarker'><thead><tr><th>Alias</th><th>Ecosystem</th></tr></thead><tbody><tr><td>$tableCellMarker</td><td>github</td></tr></tbody></table>$longPageParagraphs<p>$longPageTailMarker</p></main>"
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
    $edgeActivated = Activate-Window ([IntPtr] $edgeWindow.MainWindowHandle) $edgeWindow.Id $browserTitle
    if (-not $edgeActivated) {
        $actualForeground = [ZommiNativeWindow]::GetForegroundWindow()
        $actualProcessId = [ZommiNativeWindow]::GetWindowProcessId($actualForeground)
        $actualProcess = Get-Process -Id $actualProcessId -ErrorAction SilentlyContinue
        throw "Could not activate the isolated Edge window. Expected hwnd=$($edgeWindow.MainWindowHandle) pid=$($edgeWindow.Id); actual hwnd=$actualForeground pid=$actualProcessId process=$($actualProcess.ProcessName)."
    }
    Start-Sleep -Milliseconds 500

    $edgeRoot = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr] $edgeWindow.MainWindowHandle)
    $button = Find-AutomationElement $edgeRoot $buttonName
    Assert-True ($null -ne $button) 'Edge did not expose the hovered acceptance button.'
    $buttonBounds = $button.Current.BoundingRectangle
    [void] [ZommiNativeWindow]::SetCursorPos(
        [int] ($buttonBounds.X + ($buttonBounds.Width / 2)),
        [int] ($buttonBounds.Y + ($buttonBounds.Height / 2)))
    Start-Sleep -Milliseconds 250
    $foregroundBeforeShortcut = [ZommiNativeWindow]::GetForegroundWindow()
    $foregroundProcessId = [ZommiNativeWindow]::GetWindowProcessId($foregroundBeforeShortcut)
    $foregroundProcess = Get-Process -Id $foregroundProcessId -ErrorAction SilentlyContinue
    $foregroundTitle = [ZommiNativeWindow]::ReadWindowText($foregroundBeforeShortcut)
    Assert-True ($null -ne $foregroundProcess -and $foregroundProcess.ProcessName -eq 'msedge' -and $foregroundTitle -like "*$browserTitle*") "The controlled Edge page was not foreground immediately before the shortcut. Actual process=$($foregroundProcess.ProcessName) title=$foregroundTitle."
    $pageCapture = Invoke-CapturedProcess $executable '--acceptance-capture-once' 30
    Assert-True ($pageCapture.ExitCode -eq 0) "The pointer page capture probe failed: $($pageCapture.StandardError)"
    $pageCaptureJson = $pageCapture.StandardOutput | ConvertFrom-Json
    $pageCaptureText = [string]::Join(' ', @($pageCaptureJson.snapshot.visibleText))
    Assert-True ($pageCaptureJson.snapshot.locator.value -eq $browserUri) 'The pointer page capture probe omitted the browser URL.'
    Assert-True ($null -ne $pageCaptureJson.snapshot.indicatedTarget) "The pointer page capture probe omitted the hovered accessibility target. Capture: $($pageCapture.StandardOutput)"
    $accessibilityTree = $pageCaptureJson.snapshot.accessibilityTree
    Assert-True ($null -ne $accessibilityTree) 'The pointer page capture probe omitted the post-render browser accessibility tree.'
    Assert-True ($accessibilityTree.source -eq 'windows-uia-control-view') "The accessibility tree reported an unexpected source: $($accessibilityTree.source)"
    Assert-True ($accessibilityTree.nodeCount -gt 0) 'The browser accessibility tree did not contain any nodes.'
    Assert-True (@($accessibilityTree.roots).Count -gt 0) 'The browser accessibility tree did not contain a root.'
    Assert-True (@($accessibilityTree.roots[0].children).Count -gt 0) 'The browser accessibility tree did not preserve nested provider relationships.'
    $accessibilityTreeJson = $accessibilityTree | ConvertTo-Json -Depth 100 -Compress
    Assert-True ($accessibilityTreeJson -like "*$bodyMarker*") 'The browser accessibility tree omitted rendered page content.'
    Assert-True ($accessibilityTreeJson -like "*$tableMarker*" -or $accessibilityTreeJson -like "*$tableCellMarker*") 'The browser accessibility tree omitted the semantic table fixture.'
    Assert-True ($pageCaptureJson.viewportImageBytes -gt 0) 'The deliberate browser capture did not include an automatic viewport PNG.'
    Assert-True ($pageCaptureText -like "*$browserMarker*") 'The pointer page capture probe omitted the page text.'
    Assert-True ($pageCaptureText -like "*$longPageTailMarker*") 'The pointer page capture probe truncated the long webpage before its tail marker.'
    $pointerBefore = [ZommiNativeWindow]::CursorPosition()
    $shortcut = Invoke-ZommiShortcut $gui
    $chat = $shortcut.Window
    $results.shortcutDispatch = $shortcut.Dispatch
    Assert-True ($null -ne $chat) 'Alt+A did not open the floating chat.'
    $pointerAfter = [ZommiNativeWindow]::CursorPosition()
    Assert-True ($pointerBefore.X -eq $pointerAfter.X -and $pointerBefore.Y -eq $pointerAfter.Y) "Opening Zommi moved the mouse pointer from $($pointerBefore.X),$($pointerBefore.Y) to $($pointerAfter.X),$($pointerAfter.Y)."
    $chatBounds = $chat.Current.BoundingRectangle
    $pointerInsideChat = $pointerAfter.X -ge $chatBounds.X -and
        $pointerAfter.X -lt ($chatBounds.X + $chatBounds.Width) -and
        $pointerAfter.Y -ge $chatBounds.Y -and
        $pointerAfter.Y -lt ($chatBounds.Y + $chatBounds.Height)
    Assert-True (-not $pointerInsideChat) 'The floating chat opened under the pointer.'
    Assert-True ($null -ne (Find-AutomationElementById $chat 'ZommiShortcuts')) 'Zommi did not expose its Alt+A shortcuts.'

    $composer = Assert-ComposerFocused $chat
    $contextText = Get-AutomationText $composer
    Assert-True ($contextText -eq '[context] ') "The attached page context was not inserted in the composer. Visible text: $contextText"
    Assert-True ($contextText -notlike "*$browserMarker*" -and $contextText -notlike "*$browserUri*") 'Raw page context leaked into the visible composer token.'
    $threadId = Wait-ThreadId $gui
    Assert-True (-not [string]::IsNullOrWhiteSpace($threadId)) 'The floating chat did not expose its Codex thread id.'
    $pagePrompt = 'Reply with the exact token from the attached page context that starts with ZOMMI_PAGE_ and nothing else.'
    $transcript = Send-ChatTurn $gui $chat $pagePrompt $browserMarker
    Assert-True ($transcript -like "*$pagePrompt*") 'The typed page prompt did not appear in the chat transcript.'
    $visiblePageTurn = [string] $transcript
    Assert-True ($visiblePageTurn.Contains("[context] $pagePrompt")) 'The page turn did not preserve its composer context token.'
    Assert-True ((Wait-ThreadId $gui) -eq $threadId) 'The page turn switched Codex threads.'
    $results.webpageHoverShortcutFocusStream = 'passed'

    [ZommiNativeWindow]::PressEscape()
    Start-Sleep -Milliseconds 300
    Assert-True ($null -eq (Find-ZommiWindow $gui)) 'Escape did not hide the floating chat.'

    $folderMarker = 'zommi-folder-' + [Guid]::NewGuid().ToString('N')
    $explorerFolder = Join-Path $temporaryRoot $folderMarker
    $selectedFile = Join-Path $explorerFolder 'selected-zommi-file.txt'
    New-Item -ItemType Directory -Path $explorerFolder | Out-Null
    [IO.File]::WriteAllText($selectedFile, 'zommi folder acceptance')
    Start-Process -FilePath explorer.exe -ArgumentList (Quote-Argument $explorerFolder) | Out-Null
    $shell = New-Object -ComObject Shell.Application
    for ($attempt = 0; $attempt -lt 120 -and $null -eq $explorerWindow; $attempt++) {
        Start-Sleep -Milliseconds 100
        foreach ($candidate in @($shell.Windows())) {
            try {
                if ([string]::Equals([string] $candidate.Document.Folder.Self.Path, $explorerFolder, [StringComparison]::OrdinalIgnoreCase)) {
                    $explorerWindow = $candidate
                    break
                }
            } catch {
                # A shell surface without a Folder view is not the target.
            }
        }
    }
    Assert-True ($null -ne $explorerWindow) 'The acceptance Explorer window did not open.'
    $explorerWindow.Document.SelectItem($selectedFile, 29)
    $explorerProcessId = [ZommiNativeWindow]::GetWindowProcessId([IntPtr] ([int64] $explorerWindow.HWND))
    Assert-True (Activate-Window ([IntPtr] ([int64] $explorerWindow.HWND)) $explorerProcessId $folderMarker) 'Could not activate the acceptance Explorer window.'
    Start-Sleep -Milliseconds 500
    $explorerRoot = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr] ([int64] $explorerWindow.HWND))
    $fileElement = Find-AutomationElement $explorerRoot 'selected-zommi-file.txt'
    if ($null -ne $fileElement) {
        $fileBounds = $fileElement.Current.BoundingRectangle
        [void] [ZommiNativeWindow]::SetCursorPos(
            [int] ($fileBounds.X + ($fileBounds.Width / 2)),
            [int] ($fileBounds.Y + ($fileBounds.Height / 2)))
    }
    $folderCapture = Invoke-CapturedProcess $executable '--acceptance-capture-once' 30
    Assert-True ($folderCapture.ExitCode -eq 0) "The pointer Explorer capture probe failed: $($folderCapture.StandardError)"
    $folderCaptureJson = $folderCapture.StandardOutput | ConvertFrom-Json
    Assert-True ($folderCaptureJson.snapshot.locator.value -eq $explorerFolder) 'The pointer Explorer capture probe omitted the folder path.'
    Assert-True (@($folderCaptureJson.snapshot.selection) -contains $selectedFile) 'The pointer Explorer capture probe omitted the selected file.'
    $folderPointerBefore = [ZommiNativeWindow]::CursorPosition()
    $shortcut = Invoke-ZommiShortcut $gui
    $chat = $shortcut.Window
    Assert-True ($null -ne $chat) 'Alt+A did not reopen Zommi over File Explorer.'
    $folderPointerAfter = [ZommiNativeWindow]::CursorPosition()
    Assert-True ($folderPointerBefore.X -eq $folderPointerAfter.X -and $folderPointerBefore.Y -eq $folderPointerAfter.Y) 'The Explorer invocation moved the mouse pointer.'
    $composer = Assert-ComposerFocused $chat
    $contextText = Get-AutomationText $composer
    Assert-True ($contextText -eq '[file-explorer] ') 'The Explorer context token was not inserted in the composer.'
    Assert-True ((Wait-ThreadId $gui) -eq $threadId) 'Reinvoking Zommi over Explorer created a new Codex thread.'
    $folderPrompt = 'Reply with only the selected file name from the attached folder context.'
    $transcript = Send-ChatTurn $gui $chat $folderPrompt 'selected-zommi-file.txt'
    Assert-True ($transcript -like "*$browserMarker*" -and $transcript -like '*selected-zommi-file.txt*') 'The same floating transcript did not preserve both turns.'
    Assert-True ((Wait-ThreadId $gui) -eq $threadId) 'The Explorer turn switched Codex threads.'
    $results.folderHoverReinvokeSameThread = 'passed'

    [ZommiNativeWindow]::PressEscape()
    Start-Sleep -Milliseconds 300
    Assert-True ($null -eq (Find-ZommiWindow $gui)) 'Escape did not hide Zommi after the Explorer turn.'

    $windowMarker = 'ZOMMI_WINDOW_' + [Guid]::NewGuid().ToString('N')
    $notepadPath = Join-Path $temporaryRoot ($windowMarker + '.txt')
    [IO.File]::WriteAllText($notepadPath, "Visible arbitrary window text: $windowMarker")
    Start-Process -FilePath notepad.exe -ArgumentList (Quote-Argument $notepadPath) | Out-Null
    for ($attempt = 0; $attempt -lt 120 -and $null -eq $notepadWindow; $attempt++) {
        Start-Sleep -Milliseconds 100
        $notepadWindow = Get-Process notepad -ErrorAction SilentlyContinue | Where-Object {
            $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -like "*$windowMarker*"
        } | Select-Object -First 1
    }
    Assert-True ($null -ne $notepadWindow) 'The acceptance Notepad window did not open.'
    Assert-True (Activate-Window ([IntPtr] $notepadWindow.MainWindowHandle) $notepadWindow.Id $windowMarker) 'Could not activate the acceptance Notepad window.'
    Start-Sleep -Milliseconds 500
    $notepadRoot = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr] $notepadWindow.MainWindowHandle)
    $document = Find-ControlTypeElement $notepadRoot ([System.Windows.Automation.ControlType]::Document)
    Assert-True ($null -ne $document) 'Notepad did not expose its document through UI Automation.'
    $documentBounds = $document.Current.BoundingRectangle
    [void] [ZommiNativeWindow]::SetCursorPos(
        [int] ($documentBounds.X + [Math]::Min(80, $documentBounds.Width / 2)),
        [int] ($documentBounds.Y + [Math]::Min(30, $documentBounds.Height / 2)))
    $windowCapture = Invoke-CapturedProcess $executable '--acceptance-capture-once' 30
    Assert-True ($windowCapture.ExitCode -eq 0) "The pointer arbitrary-window capture probe failed: $($windowCapture.StandardError)"
    $windowCaptureJson = $windowCapture.StandardOutput | ConvertFrom-Json
    $windowCaptureText = [string]::Join(' ', @($windowCaptureJson.snapshot.visibleText))
    Assert-True ($windowCaptureText -like "*$windowMarker*") 'The pointer arbitrary-window capture probe omitted visible text.'
    $windowPointerBefore = [ZommiNativeWindow]::CursorPosition()
    $shortcut = Invoke-ZommiShortcut $gui
    $chat = $shortcut.Window
    Assert-True ($null -ne $chat) 'Alt+A did not reopen Zommi over an arbitrary window.'
    $windowPointerAfter = [ZommiNativeWindow]::CursorPosition()
    Assert-True ($windowPointerBefore.X -eq $windowPointerAfter.X -and $windowPointerBefore.Y -eq $windowPointerAfter.Y) 'The arbitrary-window invocation moved the pointer.'
    $composer = Assert-ComposerFocused $chat
    $contextText = Get-AutomationText $composer
    Assert-True ($contextText -eq '[notepad] ') 'The arbitrary-window context token was not inserted in the composer.'
    Assert-True ((Wait-ThreadId $gui) -eq $threadId) 'Reinvoking Zommi over an arbitrary window created a new Codex thread.'
    $windowPrompt = 'Reply with the exact token from the attached window context that starts with ZOMMI_WINDOW_ and nothing else.'
    $transcript = Send-ChatTurn $gui $chat $windowPrompt $windowMarker
    Assert-True ($transcript -like "*$browserMarker*" -and $transcript -like '*selected-zommi-file.txt*' -and $transcript -like "*$windowMarker*") 'The floating transcript did not preserve all three turns.'
    Assert-True ((Wait-ThreadId $gui) -eq $threadId) 'The arbitrary-window turn switched Codex threads.'
    $results.windowHoverReinvokeSameThread = 'passed'

    $results.codexThreadId = $threadId
    $results.windowsVersion = [Environment]::OSVersion.VersionString
    $results.executableSha256 = (Get-FileHash -Algorithm SHA256 $executable).Hash.ToLowerInvariant()
    $results | ConvertTo-Json
} finally {
    if ($null -ne $gui -and -not $gui.HasExited) {
        & taskkill.exe /PID $gui.Id /T /F 2>&1 | Out-Null
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
    if ($null -ne $notepadWindow -and -not $notepadWindow.HasExited) {
        Stop-Process -Id $notepadWindow.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 250
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}
