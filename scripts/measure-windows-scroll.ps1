[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PackageDirectory,
    [Parameter(Mandatory=$true)][string]$ResultDirectory,
    [string]$PythonExecutable = 'python',
    [int]$Samples = 3,
    [int]$WheelEvents = 240,
    [ValidateSet('standard','folded')][string]$Workload = 'standard',
    [ValidateSet('default','impeller','skia')][string]$Renderer = 'default',
    [string]$HistoryFile,
    [switch]$Maximized
)
$ErrorActionPreference='Stop'
$package=(Resolve-Path $PackageDirectory).Path
$null=New-Item -ItemType Directory -Force -Path $ResultDirectory
$results=(Resolve-Path $ResultDirectory).Path
$python=(& $PythonExecutable -c 'import sys; print(sys.executable)').Trim()
if($LASTEXITCODE -ne 0 -or -not (Test-Path $python)){throw 'A Windows Python interpreter is required for the local agent fixture.'}
. (Join-Path $PSScriptRoot 'accept-windows-capture.ps1') -PackageDirectory $package -HelpersOnly
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ZommiScrollInput {
    [DllImport("user32.dll")] private static extern void mouse_event(uint flags,uint x,uint y,uint data,UIntPtr extra);
    [DllImport("user32.dll")] private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int x,int y);
    public static void Wheel(int x,int y,int delta) {
        var old=SetThreadDpiAwarenessContext(new IntPtr(-4));
        try { if(!SetCursorPos(x,y))throw new InvalidOperationException("Pointer input unavailable"); mouse_event(0x800,0,0,unchecked((uint)delta),UIntPtr.Zero); }
        finally {SetThreadDpiAwarenessContext(old);}
    }
}
'@
function Read-Trace([string]$Path){
    if(-not (Test-Path $Path)){return @()}
    return @(Get-Content $Path | ForEach-Object { if($_.Trim()){$_|ConvertFrom-Json} })
}
function Screenshot([IntPtr]$Window,[string]$Path){
    $bounds=[ZommiWindowsAcceptanceNative]::PhysicalBounds($Window)
    $bitmap=[Drawing.Bitmap]::new($bounds[2],$bounds[3])
    $graphics=[Drawing.Graphics]::FromImage($bitmap)
    try{$graphics.CopyFromScreen($bounds[0],$bounds[1],0,0,$bitmap.Size);$bitmap.Save($Path)}
    finally{$graphics.Dispose();$bitmap.Dispose()}
}
Assert-DesktopCaptureSurface
$executable=Join-Path $package 'Zommi.exe'
$suspended=@(Suspend-ConflictingZommiApplications -EntryPoint $executable)
$runProfile=Join-Path $results 'profile'
$null=New-Item -ItemType Directory -Force -Path $runProfile
$expectedHistoryTurns=120
if($HistoryFile){$HistoryFile=(Resolve-Path $HistoryFile).Path;$expectedHistoryTurns=(Get-Content $HistoryFile -Raw|ConvertFrom-Json).thread.turns.Count}
$trace=Join-Path $results 'frames.jsonl'
if(Test-Path $trace){throw 'Use a new result directory for each benchmark run.'}
$streamSignal=Join-Path $runProfile 'stream.signal'
$identity="native:windows$([char]0)codex-app-server$([char]0)$python$([char]0)default"
$hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity))).ToLowerInvariant()
$binding=Join-Path $runProfile 'binding.json'
@{runtimeTargetId="runtime-$($hash.Substring(0,20))";sessionId='scroll-benchmark';cwd=$runProfile}|ConvertTo-Json|Set-Content $binding
$start=[Diagnostics.ProcessStartInfo]::new($executable)
$start.WorkingDirectory=$package
$start.UseShellExecute=$false
$start.RedirectStandardOutput=$true
$start.RedirectStandardError=$true
$start.Environment['APPDATA']=$runProfile
$start.Environment['LOCALAPPDATA']=$runProfile
$start.Environment['ZOMMI_SCROLL_TRACE']=$trace
$start.Environment['ZOMMI_CODEX_COMMAND']=$python
$start.Environment['ZOMMI_CODEX_ARGS_JSON']=ConvertTo-Json -Compress -InputObject @((Join-Path $PSScriptRoot 'scroll-runtime-fixture.py'))
$start.Environment['ZOMMI_CORE_STATE_PATH']=$binding
$start.Environment['ZOMMI_RUNTIME_OVERRIDES_PATH']=Join-Path $runProfile 'overrides.json'
$start.Environment['ZOMMI_RUNTIME_DISCOVERY_CACHE_PATH']=Join-Path $runProfile 'discovery.json'
$start.Environment['ZOMMI_SCROLL_STREAM_SIGNAL']=$streamSignal
$start.Environment['ZOMMI_SCROLL_WORKLOAD']=$Workload
if($HistoryFile){$start.Environment['ZOMMI_SCROLL_HISTORY']=$HistoryFile}
if($Renderer -ne 'default'){$start.Environment['ZOMMI_WINDOWS_RENDERER']=$Renderer}
$start.Environment['ZOMMI_ACCEPTANCE_LOG']=Join-Path $results 'desktop.jsonl'
$application=$null
try{
    $application=[Diagnostics.Process]::Start($start)
    $stdout=$application.StandardOutput.ReadToEndAsync()
    $stderr=$application.StandardError.ReadToEndAsync()
    $deadline=[DateTime]::UtcNow.AddSeconds(60)
    do{
        if($application.HasExited){throw "Benchmark app exited: $($stderr.GetAwaiter().GetResult())"}
        $ready=@(Read-Trace $trace|Where-Object event -eq 'ready')
        if($ready.Count){break}
        Start-Sleep -Milliseconds 100
    }while([DateTime]::UtcNow -lt $deadline)
    if(-not $ready.Count -or $ready[0].turns -ne $expectedHistoryTurns -or $ready[0].mode -ne 'release'){throw 'The release app did not load the expected agent history.'}
    $window=Wait-ForVisibleProcessWindow -ProcessId $application.Id
    [ZommiWindowsAcceptanceNative]::Restore($window)
    if($Maximized){Start-Sleep -Milliseconds 400;[ZommiWindowsAcceptanceNative]::Maximize($window)}
    Start-Sleep -Seconds 2
    $bounds=[ZommiWindowsAcceptanceNative]::PhysicalBounds($window)
    $x=$bounds[0]+[int]($bounds[2]*0.60)
    $y=$bounds[1]+[int]($bounds[3]*0.45)
    if(-not [ZommiWindowsAcceptanceNative]::IsOwnedWindowAtPoint($window,$x,$y)){throw 'The benchmark transcript is covered.'}
    Screenshot $window (Join-Path $results 'before.png')
    $measurements=@()
    foreach($scenario in @('static','streaming')){
        if($scenario -eq 'streaming'){Set-Content $streamSignal 'start';Start-Sleep -Milliseconds 400}
        foreach($sample in 1..$Samples){
            $watch=[Diagnostics.Stopwatch]::StartNew()
            foreach($index in 0..($WheelEvents-1)){
                # Travel up then back down through the same text, at 60 Hz.
                $delta=if($index -lt $WheelEvents/2){120}else{-120}
                [ZommiScrollInput]::Wheel($x,$y,$delta)
                $remaining=($index+1)*16-$watch.ElapsedMilliseconds
                if($remaining -gt 0){Start-Sleep -Milliseconds $remaining}
            }
            $elapsed=$watch.ElapsedMilliseconds
            $flushDeadline=[DateTime]::UtcNow.AddSeconds(5)
            do{
                Start-Sleep -Milliseconds 100
                $recordedSamples=@(Read-Trace $trace|Where-Object event -eq 'scroll')
                if($recordedSamples.Count -gt $measurements.Count){break}
            }while([DateTime]::UtcNow -lt $flushDeadline)
            if($recordedSamples.Count -ne $measurements.Count+1){throw 'The app did not record exactly one sample for the injected wheel sequence.'}
            $last=$recordedSamples[-1]
            # Windows coalesces wheel messages when the UI is busy. Check the
            # delivered distance as well as rendered movement, not a 1:1 count.
            if($last.inputCount -lt [Math]::Min(30,$WheelEvents/2) -or $last.pointerDistance -lt $WheelEvents*10 -or $last.frameCount -lt 5 -or $last.travel -lt 1000){throw 'The benchmark did not exercise a moving, rendered transcript.'}
            $expectedTurns=if($scenario -eq 'static' -or $Workload -eq 'folded'){$expectedHistoryTurns}else{$expectedHistoryTurns+1}
            if($last.turns -ne $expectedTurns){throw 'The expected static or streaming conversation was not rendered.'}
            if(@($last.receiptToRasterUs).Count -lt $last.inputCount*0.98){throw 'Frame timings did not cover the end of the wheel sequence.'}
            $measurements+=@{scenario=$scenario;sample=$sample;inputElapsedMs=$elapsed;data=$last}
            Write-Host "scroll-$scenario-$sample`: $($last.frameCount) frames, $($last.inputCount) wheel events, $([int]$last.travel) px"
        }
    }
    Screenshot $window (Join-Path $results 'after.png')
    $manifest=Get-Content (Join-Path $package 'release-manifest.json') -Raw|ConvertFrom-Json
    $harnessHash=(Get-FileHash $PSCommandPath).Hash.ToLowerInvariant()
    $fixtureHash=(Get-FileHash (Join-Path $PSScriptRoot 'scroll-runtime-fixture.py')).Hash.ToLowerInvariant()
    $historyHash=if($HistoryFile){(Get-FileHash $HistoryFile).Hash.ToLowerInvariant()}else{$null}
    @{package=$package;packageCommit=$manifest.gitCommit;workload=$Workload;renderer=$Renderer;maximized=[bool]$Maximized;measuredBounds=$bounds;historySha256=$historyHash;harnessSha256=$harnessHash;fixtureSha256=$fixtureHash;wheelEvents=$WheelEvents;ready=$ready[0];samples=$measurements;testedAtUtc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json -Depth 12|Set-Content (Join-Path $results 'result.json')
}finally{
    if($application -and -not $application.HasExited){$application.Kill($true);$application.WaitForExit()}
    if($stderr){$stderr.GetAwaiter().GetResult()|Set-Content (Join-Path $results 'stderr.log')}
    Restore-SuspendedZommiApplications -ExecutablePaths $suspended
}
