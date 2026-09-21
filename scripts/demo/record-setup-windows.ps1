#requires -Version 7.0
param(
    [Parameter(Mandatory=$true)][string]$PackageDirectory,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [ValidateRange(60,1800)][int]$MaxDurationSeconds=900
)
$ErrorActionPreference='Stop'
$repository=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repository 'scripts/accept-windows-capture.ps1') -PackageDirectory $PackageDirectory -HelpersOnly
Add-Type -AssemblyName Accessibility
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
$references=@([Accessibility.IAccessible].Assembly.Location,[Drawing.Bitmap].Assembly.Location,[Windows.Forms.Form].Assembly.Location)
$references+=Get-ChildItem (Join-Path $PSHOME 'ref') -Filter '*.dll'|ForEach-Object FullName
$references+=Get-ChildItem $PSHOME -Filter 'System.Private.Windows*.dll'|ForEach-Object FullName
$references+=Get-ChildItem $PSHOME -Filter 'System.Windows.Forms.Primitives.dll'|ForEach-Object FullName
Add-Type -CompilerOptions '/nowarn:1701,9191' -ReferencedAssemblies $references -TypeDefinition (Get-Content -Raw (Join-Path $PSScriptRoot 'windows-input.cs'))
Add-Type -CompilerOptions '/nowarn:1701,9191' -ReferencedAssemblies $references -TypeDefinition (Get-Content -Raw (Join-Path $PSScriptRoot 'windows-recorder.cs'))
[void][DemoAccess]::SetProcessDPIAware()
if(-not [DemoRecorder]::DesktopUpdates()){throw 'Restore an updating, unlocked desktop before recording.'}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path $OutputDirectory){throw 'Use a fresh recording directory.'}
$null=New-Item -ItemType Directory $OutputDirectory
$ownerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
& icacls.exe $OutputDirectory /inheritance:r /grant:r ('*'+$ownerSid+':(OI)(CI)F') '*S-1-5-18:(OI)(CI)F' | Out-Null
if($LASTEXITCODE -ne 0){throw 'Could not restrict recording evidence.'}
$demoProfile=Join-Path $OutputDirectory 'profile'
$null=New-Item -ItemType Directory (Join-Path $demoProfile 'Zommi')
# Presentation preferences only: no completed setup, runtime binding or fake agent.
@{runtimeSetupCompleted=$false;themeMode='light';themeColor='ocean';chatFontSize=14}|ConvertTo-Json|Set-Content (Join-Path $demoProfile 'Zommi/settings.json')
$previous=@();$app=$null;$recorder=$null
try {
 $previous=@(Suspend-ConflictingZommiApplications -EntryPoint (Join-Path $OutputDirectory 'not-running.exe'))
 $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PackageDirectory 'Zommi.exe'))
 $start.UseShellExecute=$false;$start.WorkingDirectory=$PackageDirectory
 foreach($key in @('APPDATA','LOCALAPPDATA')){$start.Environment[$key]=$demoProfile}
 foreach($entry in @{ZOMMI_CORE_STATE_PATH='binding.json';ZOMMI_RUNTIME_OVERRIDES_PATH='overrides.json';ZOMMI_RUNTIME_DISCOVERY_CACHE_PATH='targets.json';XDG_CONFIG_HOME='config';XDG_STATE_HOME='state';XDG_CACHE_HOME='cache'}.GetEnumerator()){
  $start.Environment[$entry.Key]=Join-Path $demoProfile $entry.Value
 }
 foreach($key in @($start.Environment.Keys)){
  if($key.StartsWith('ZOMMI_FAKE_') -or $key -eq 'ZOMMI_RUNTIME_DISCOVERY_MODE'){$null=$start.Environment.Remove($key)}
 }
 $app=[Diagnostics.Process]::Start($start)
 $deadline=[DateTime]::UtcNow.AddSeconds(60)
 do{$app.Refresh();Start-Sleep -Milliseconds 100}while($app.MainWindowHandle -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline)
 if($app.MainWindowHandle -eq [IntPtr]::Zero){throw 'Setup window did not open.'}
 [void][DemoAccess]::SetWindowPos($app.MainWindowHandle,[IntPtr]::Zero,650,180,1100,1100,0x40)
 if(-not [DemoAccess]::Focus($app.MainWindowHandle)){throw 'Setup window could not become foreground.'}
 Write-Host 'Inspect the real first-run panel, then create record.ready.'
 $deadline=[DateTime]::UtcNow.AddMinutes(10)
 while(-not (Test-Path (Join-Path $OutputDirectory 'record.ready'))){
  if($app.HasExited -or (Test-Path (Join-Path $OutputDirectory 'abort')) -or [DateTime]::UtcNow -gt $deadline){throw 'Setup recording was not started.'}
  Start-Sleep -Milliseconds 200
 }
 $recordedAt=[DateTime]::UtcNow
 $recorder=[DemoRecorder]::new((Join-Path $OutputDirectory 'frames'),650,180,1100,1100,$MaxDurationSeconds)
 $clock=[Diagnostics.Stopwatch]::StartNew();$markers=[ordered]@{intro=0}
 $control=Join-Path $OutputDirectory 'control';$null=New-Item -ItemType Directory $control
 $seen=[Collections.Generic.HashSet[string]]::new();$finished=$false
 while(-not $finished -and $clock.Elapsed.TotalSeconds -lt $MaxDurationSeconds){
  if($app.HasExited){throw 'Setup app exited before completion.'}
  foreach($file in Get-ChildItem $control -Filter '*.json'|Sort-Object Name){
   if($seen.Contains($file.Name)){continue}
   try{$command=Get-Content $file.FullName -Raw|ConvertFrom-Json}catch{continue}
   if($command.action -eq 'finish'){$finished=$true}
   elseif($command.action -eq 'mark' -and $command.name -in @('select-agent','connect','ready') -and -not $markers.Contains($command.name)){$markers[$command.name]=$clock.Elapsed.TotalSeconds}
   else{throw 'Unknown or duplicate setup control command.'}
   [void]$seen.Add($file.Name)
  }
  Start-Sleep -Milliseconds 100
 }
 if(-not $finished){throw 'Setup recording timed out.'}
 $settings=Get-Content (Join-Path $demoProfile 'Zommi/settings.json') -Raw|ConvertFrom-Json
 $binding=Get-Content (Join-Path $demoProfile 'binding.json') -Raw|ConvertFrom-Json
 if(-not $settings.runtimeSetupCompleted -or -not $binding.runtimeTargetId -or -not $binding.sessionId){throw 'First-run setup did not persist a real runtime session.'}
 $markers['end']=$clock.Elapsed.TotalSeconds
 $recorder.Dispose();if($recorder.Error){throw $recorder.Error}
 $manifest=Get-Content (Join-Path $PackageDirectory 'release-manifest.json') -Raw|ConvertFrom-Json
 @{scene='setup';recordedAtUtc=$recordedAt.ToString('o');gitCommit=$manifest.gitCommit;capture='Windows desktop pixels';audio=$false;duration=$recorder.Duration;frameTimes=$recorder.Times.ToArray();markers=$markers;setupCompleted=$true;realSessionBound=$true}|ConvertTo-Json -Depth 3|Set-Content (Join-Path $OutputDirectory 'recording.json')
 Write-Host 'Real first-run setup recorded. Export and privacy review remain required.'
}finally{
 if($recorder){$recorder.Dispose()}
 if($app -and -not $app.HasExited){[void]$app.CloseMainWindow();if(-not $app.WaitForExit(5000)){$app.Kill($true)}}
 Restore-SuspendedZommiApplications -ExecutablePaths $previous
}
