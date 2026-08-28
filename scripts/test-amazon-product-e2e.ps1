[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ExecutablePath,

    [Parameter(Mandatory = $true)]
    [string] $EvidenceDirectory,

    [string] $ProductAsin
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

function Invoke-CapturedProcess {
    param(
        [string] $FilePath,
        [string] $Arguments,
        [int] $TimeoutSeconds = 60
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

function Get-AutomationText {
    param([System.Windows.Automation.AutomationElement] $Element)

    $textPatternObject = $null
    if ($Element.TryGetCurrentPattern(
        [System.Windows.Automation.TextPattern]::Pattern,
        [ref] $textPatternObject)) {
        return [string] ([System.Windows.Automation.TextPattern] $textPatternObject).DocumentRange.GetText(30000)
    }
    $valuePatternObject = $null
    if ($Element.TryGetCurrentPattern(
        [System.Windows.Automation.ValuePattern]::Pattern,
        [ref] $valuePatternObject)) {
        return [string] ([System.Windows.Automation.ValuePattern] $valuePatternObject).Current.Value
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
    Assert-True ([ZommiAmazonNative]::SetControlText(
        [IntPtr] $Element.Current.NativeWindowHandle,
        $Value)) 'Could not write the RichEdit composer text.'
}

function Invoke-AutomationElement {
    param([System.Windows.Automation.AutomationElement] $Element)
    $pattern = $Element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    ([System.Windows.Automation.InvokePattern] $pattern).Invoke()
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
                $candidate.Current.Name -like 'Zommi*floating*chat' -and
                -not $candidate.Current.IsOffscreen) {
                return $candidate
            }
        } catch {
            # Top-level windows can disappear during enumeration.
        }
    }
    return $null
}

function Get-ChromeWindows {
    $processIds = @(Get-Process -Name chrome -ErrorAction SilentlyContinue).Id
    if ($processIds.Count -eq 0) { return @() }
    $desktop = [System.Windows.Automation.AutomationElement]::RootElement
    $windows = $desktop.FindAll(
        [System.Windows.Automation.TreeScope]::Children,
        [System.Windows.Automation.Condition]::TrueCondition)
    $result = @()
    foreach ($candidate in $windows) {
        try {
            if ($processIds -contains $candidate.Current.ProcessId -and
                $candidate.Current.NativeWindowHandle -ne 0) {
                $result += [pscustomobject]@{
                    Element = $candidate
                    Handle = [IntPtr] $candidate.Current.NativeWindowHandle
                    ProcessId = $candidate.Current.ProcessId
                    Name = $candidate.Current.Name
                }
            }
        } catch {
            # Chrome windows can disappear during enumeration.
        }
    }
    return $result
}

function Wait-ZommiWindow {
    param(
        [System.Diagnostics.Process] $Process,
        [int] $TimeoutSeconds = 15
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $window = Find-ZommiWindow $Process
        if ($null -ne $window) { return $window }
        Start-Sleep -Milliseconds 100
    }
    return $null
}

function Wait-ProductDocument {
    param(
        [System.Windows.Automation.AutomationElement] $Window,
        [string[]] $ExpectedTerms,
        [int] $TimeoutSeconds = 45
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $document = Find-ControlTypeElement $Window ([System.Windows.Automation.ControlType]::Document)
        if ($null -ne $document) {
            $text = Get-AutomationText $document
            $containsAll = $true
            foreach ($term in $ExpectedTerms) {
                if ($text.IndexOf($term, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
                    $containsAll = $false
                    break
                }
            }
            if ($containsAll) {
                return [pscustomobject]@{ Element = $document; Text = $text }
            }
        }
        Start-Sleep -Milliseconds 400
    }
    return $null
}

function Invoke-DocumentText {
    param(
        [System.Windows.Automation.AutomationElement] $Document,
        [string] $Text
    )

    $patternObject = $null
    if (-not $Document.TryGetCurrentPattern(
        [System.Windows.Automation.TextPattern]::Pattern,
        [ref] $patternObject)) {
        return $false
    }
    $range = ([System.Windows.Automation.TextPattern] $patternObject).DocumentRange.FindText($Text, $false, $true)
    if ($null -eq $range) { return $false }
    $rectangles = $range.GetBoundingRectangles()
    if ($rectangles.Count -lt 4 -or $rectangles[2] -le 0 -or $rectangles[3] -le 0) { return $false }
    [ZommiAmazonNative]::ClickAt(
        [int] ($rectangles[0] + ($rectangles[2] / 2)),
        [int] ($rectangles[1] + ($rectangles[3] / 2)))
    return $true
}

function Save-ScreenEvidence {
    param(
        [System.Drawing.Rectangle] $Bounds,
        [string] $Path
    )

    $bitmap = New-Object System.Drawing.Bitmap($Bounds.Width, $Bounds.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($Bounds.X, $Bounds.Y, 0, 0, $Bounds.Size)
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ZommiAmazonNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct Point { public int X; public int Y; }

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")]
    private static extern bool AttachThreadInput(uint attach, uint attachTo, bool value);
    [DllImport("user32.dll")]
    private static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int command);
    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    private static extern void SwitchToThisWindow(IntPtr hWnd, bool altTab);
    [DllImport("user32.dll")]
    private static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);
    [DllImport("user32.dll")]
    private static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);
    [DllImport("user32.dll")]
    private static extern bool PostMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageW")]
    private static extern IntPtr SendMessageText(IntPtr window, uint message, IntPtr wParam, string text);

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

    public static void PressAltA() {
        const uint KeyUp = 0x0002;
        keybd_event(0x12, 0, 0, UIntPtr.Zero);
        keybd_event(0x41, 0, 0, UIntPtr.Zero);
        keybd_event(0x41, 0, KeyUp, UIntPtr.Zero);
        keybd_event(0x12, 0, KeyUp, UIntPtr.Zero);
    }

    public static bool SetControlText(IntPtr window, string text) {
        return window != IntPtr.Zero && SendMessageText(window, 0x000C, IntPtr.Zero, text) != IntPtr.Zero;
    }

    public static void ClickAt(int x, int y) {
        SetCursorPos(x, y);
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
    }

    public static bool CloseWindow(IntPtr window) {
        return PostMessage(window, 0x0010, IntPtr.Zero, IntPtr.Zero);
    }
}
'@

$catalog = @(
    [pscustomobject]@{ Asin = 'B07FZ8S74R'; Terms = @('Echo Dot', '3rd Gen') },
    [pscustomobject]@{ Asin = 'B09B8V1LZ3'; Terms = @('Echo Dot', '5th Gen') },
    [pscustomobject]@{ Asin = 'B0D1XD1ZV3'; Terms = @('AirPods Pro', '2') }
)
$product = if ([string]::IsNullOrWhiteSpace($ProductAsin)) {
    Get-Random -InputObject $catalog
} else {
    $catalog | Where-Object Asin -eq $ProductAsin | Select-Object -First 1
}
Assert-True ($null -ne $product) "Unknown product ASIN '$ProductAsin'."
Assert-True (Test-Path -LiteralPath $ExecutablePath) 'Zommi.exe was not found.'
$chromeExecutable = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
Assert-True (Test-Path -LiteralPath $chromeExecutable) 'Google Chrome is not installed.'
New-Item -ItemType Directory -Force -Path $EvidenceDirectory | Out-Null
$productUri = "https://www.amazon.com/dp/$($product.Asin)"
$chromeProcess = $null
$zommi = $null
$chromeWindow = $null

try {
    $existingChromeHandles = @(Get-ChromeWindows | ForEach-Object { [int64] $_.Handle })
    $chromeArguments = '--new-window {0}' -f (Quote-Argument $productUri)
    Start-Process -FilePath $chromeExecutable -ArgumentList $chromeArguments | Out-Null

    for ($attempt = 0; $attempt -lt 200 -and $null -eq $chromeWindow; $attempt++) {
        Start-Sleep -Milliseconds 150
        $candidate = Get-ChromeWindows | Where-Object {
            $existingChromeHandles -notcontains [int64] $_.Handle
        } | Select-Object -First 1
        if ($null -ne $candidate) {
            $chromeWindow = $candidate.Handle
            $chromeProcess = Get-Process -Id $candidate.ProcessId -ErrorAction SilentlyContinue
        }
    }
    Assert-True ($null -ne $chromeProcess) 'The isolated Chrome product window did not open.'
    Assert-True ([ZommiAmazonNative]::Activate($chromeWindow)) 'Could not activate the Chrome product window.'
    Start-Sleep -Milliseconds 800

    $chromeRoot = [System.Windows.Automation.AutomationElement]::FromHandle($chromeWindow)
    $productDocument = Wait-ProductDocument $chromeRoot $product.Terms 20
    if ($null -eq $productDocument) {
        $captchaDocument = Find-ControlTypeElement $chromeRoot ([System.Windows.Automation.ControlType]::Document)
        if ($null -ne $captchaDocument -and (Invoke-DocumentText $captchaDocument 'Continue shopping')) {
            Start-Sleep -Seconds 3
            Start-Process -FilePath $chromeExecutable -ArgumentList (Quote-Argument $productUri) | Out-Null
            Start-Sleep -Seconds 2
        }
        $productDocument = Wait-ProductDocument $chromeRoot $product.Terms 45
    }
    if ($null -eq $productDocument) {
        $diagnosticDocument = Find-ControlTypeElement $chromeRoot ([System.Windows.Automation.ControlType]::Document)
        $diagnosticText = if ($null -eq $diagnosticDocument) { '<no document>' } else { Get-AutomationText $diagnosticDocument }
        if ($diagnosticText.Length -gt 2500) { $diagnosticText = $diagnosticText.Substring(0, 2500) }
        throw "Amazon did not expose the expected live product page for $($product.Asin). Window='$($chromeRoot.Current.Name)' Document='$diagnosticText'"
    }

    $documentBounds = $productDocument.Element.Current.BoundingRectangle
    $pointerX = [int] ($documentBounds.X + [Math]::Min(700, [Math]::Max(80, $documentBounds.Width / 2)))
    $pointerY = [int] ($documentBounds.Y + [Math]::Min(320, [Math]::Max(80, $documentBounds.Height / 2)))
    [void] [ZommiAmazonNative]::SetCursorPos($pointerX, $pointerY)

    $capture = Invoke-CapturedProcess $ExecutablePath '--acceptance-capture-once' 45
    Assert-True ($capture.ExitCode -eq 0) "Live Amazon pointer capture failed: $($capture.StandardError)"
    $captureJson = $capture.StandardOutput | ConvertFrom-Json
    $capturedText = [string]::Join(' ', @($captureJson.snapshot.visibleText))
    Assert-True ($captureJson.snapshot.processName -eq 'chrome') 'The shortcut target was not the Chrome window under the pointer.'
    Assert-True ($null -ne $captureJson.snapshot.locator) "Chrome did not expose an Amazon URL. Capture: $($capture.StandardOutput)"
    Assert-True ($captureJson.snapshot.locator.value -like "*$($product.Asin)*") "The captured URL did not identify the selected Amazon product. Capture: $($capture.StandardOutput)"
    foreach ($term in $product.Terms) {
        Assert-True ($capturedText.IndexOf($term, [StringComparison]::OrdinalIgnoreCase) -ge 0) "Captured Amazon context omitted '$term'."
    }

    $zommi = Start-Process -FilePath $ExecutablePath -PassThru
    Start-Sleep -Milliseconds 1200
    $zommi.Refresh()
    Assert-True (-not $zommi.HasExited) 'Zommi exited during tray startup.'
    Assert-True ($null -eq (Find-ZommiWindow $zommi)) 'Zommi showed a window before the shortcut.'

    Assert-True ([ZommiAmazonNative]::Activate($chromeWindow)) 'Could not restore Chrome before invoking Zommi.'
    [void] [ZommiAmazonNative]::SetCursorPos($pointerX, $pointerY)
    Start-Sleep -Milliseconds 300
    [ZommiAmazonNative]::PressAltA()
    $chat = Wait-ZommiWindow $zommi 20
    Assert-True ($null -ne $chat) 'The global shortcut did not open the floating Zommi chat.'

    $chatBounds = $chat.Current.BoundingRectangle
    $pointerInside = $pointerX -ge $chatBounds.X -and $pointerX -lt ($chatBounds.X + $chatBounds.Width) -and $pointerY -ge $chatBounds.Y -and $pointerY -lt ($chatBounds.Y + $chatBounds.Height)
    Assert-True (-not $pointerInside) 'The floating chat covered the indicated point.'
    $composer = Find-ZommiComposer $chat
    Assert-True ($null -ne $composer -and $composer.Current.HasKeyboardFocus) 'The floating composer was not focused.'
    $contextToken = Get-AutomationText $composer
    Assert-True ($contextToken -eq '[amazon.com] ') 'The Amazon URL abbreviation was not inserted in the composer.'
    foreach ($term in $product.Terms) {
        Assert-True ($contextToken.IndexOf($term, [StringComparison]::OrdinalIgnoreCase) -lt 0) 'Raw product text leaked into the visible context token.'
    }

    Set-AutomationValue $composer ($contextToken + "what's this product")
    $browserBounds = $chromeRoot.Current.BoundingRectangle
    $evidenceBounds = New-Object System.Drawing.Rectangle(
        [int] $browserBounds.X,
        [int] $browserBounds.Y,
        [int] $browserBounds.Width,
        [int] $browserBounds.Height)
    $beforePath = Join-Path $EvidenceDirectory "amazon-$($product.Asin)-before.png"
    Save-ScreenEvidence $evidenceBounds $beforePath

    $send = Find-AutomationElementById $chat 'SendMessage'
    Assert-True ($null -ne $send) 'The Send button was not exposed.'
    Invoke-AutomationElement $send

    $deadline = [DateTime]::UtcNow.AddSeconds(150)
    $transcriptText = ''
    $response = ''
    $codexThreadId = ''
    while ([DateTime]::UtcNow -lt $deadline) {
        $latestChat = Find-ZommiWindow $zommi
        if ($null -ne $latestChat) {
            $transcript = Find-ZommiTranscript $latestChat
            $status = Find-AutomationElementById $latestChat 'CodexStatus'
            if ($null -ne $transcript -and $null -ne $status) {
                $transcriptText = Get-AutomationText $transcript
                $answerStart = $transcriptText.LastIndexOf('Codex', [StringComparison]::Ordinal)
                if ($answerStart -ge 0 -and $status.Current.Name -like 'Agent status: ready*') {
                    $response = $transcriptText.Substring($answerStart + 'Codex'.Length).Trim()
                    if ($status.Current.Name -match 'thread ([0-9a-f-]{36})') {
                        $codexThreadId = $Matches[1]
                    }
                    break
                }
            }
        }
        Start-Sleep -Milliseconds 300
    }
    Assert-True (-not [string]::IsNullOrWhiteSpace($response)) "Codex did not answer the live Amazon question. Transcript: $transcriptText"
    Assert-True ($transcriptText.Contains("[amazon.com] what's this product")) 'The visible user turn did not show the Amazon context token with the typed question.'
    foreach ($term in $product.Terms) {
        Assert-True ($response.IndexOf($term, [StringComparison]::OrdinalIgnoreCase) -ge 0) "Codex response did not identify '$term': $response"
    }

    $afterPath = Join-Path $EvidenceDirectory "amazon-$($product.Asin)-answer.png"
    Save-ScreenEvidence $evidenceBounds $afterPath
    [ordered]@{
        asin = $product.Asin
        url = $productUri
        expectedTerms = $product.Terms
        response = $response
        codexThreadId = $codexThreadId
        contextToken = $contextToken
        pointer = "$pointerX,$pointerY"
        floatingWindowBounds = "$($chatBounds.X),$($chatBounds.Y),$($chatBounds.Width),$($chatBounds.Height)"
        beforeScreenshot = $beforePath
        answerScreenshot = $afterPath
        executableSha256 = (Get-FileHash -Algorithm SHA256 $ExecutablePath).Hash.ToLowerInvariant()
        windowsVersion = [Environment]::OSVersion.VersionString
    } | ConvertTo-Json
} finally {
    if ($null -ne $zommi -and -not $zommi.HasExited) {
        & taskkill.exe /PID $zommi.Id /T /F 2>&1 | Out-Null
    }
    if ($null -ne $chromeWindow) {
        [void] [ZommiAmazonNative]::CloseWindow($chromeWindow)
    }
}
