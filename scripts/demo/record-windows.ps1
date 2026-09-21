#requires -Version 7.0
param(
    [Parameter(Mandatory=$true)][string]$PackageDirectory,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [ValidateSet('compare','error','dashboard','amazon','sheets')][string]$Scene='compare',
    [string]$Workspace='/tmp/zommi-demo-workspace',
    [string]$DashboardUrl='http://127.0.0.1:8765/',
    [string]$RuntimeTargetId,
    [string]$BrowserEndpoint,
    [ValidateRange(60,3600)][int]$MaxDurationSeconds=1200,
    [switch]$Manual,
    [switch]$SendPrompt
)
$ErrorActionPreference='Stop'
if($Scene -in @('amazon','sheets') -and (-not $Manual -or -not $BrowserEndpoint)){throw 'Amazon and Sheets require a prepared browser endpoint and manual recording control.'}
if($BrowserEndpoint -and (-not $Manual -or ([Uri]$BrowserEndpoint).Scheme -notin @('http','ws') -or ([Uri]$BrowserEndpoint).Host -notin @('127.0.0.1','localhost'))){throw 'Manual browser capture requires an authorized loopback HTTP or WebSocket endpoint.'}
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
if(-not [DemoRecorder]::DesktopUpdates()){throw 'Desktop capture is stale or unavailable. Restore an updating, unlocked desktop before recording.'}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path $OutputDirectory){throw 'Use a fresh output directory for each recording.'}
$null=New-Item -ItemType Directory $OutputDirectory
$ownerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
& icacls.exe $OutputDirectory /inheritance:r /grant:r ('*'+$ownerSid+':(OI)(CI)F') '*S-1-5-18:(OI)(CI)F' | Out-Null
if($LASTEXITCODE -ne 0){throw 'Could not restrict local recording evidence.'}
$demoProfile=Join-Path $OutputDirectory 'profile'
$prepareArguments=@((Join-Path $PSScriptRoot 'prepare.py'),'--package',$PackageDirectory,'--profile',$demoProfile,'--workspace',$Workspace)
if($Scene -in @('dashboard','amazon','sheets')){$prepareArguments+='--browser-details'}
if($RuntimeTargetId){$prepareArguments+=@('--runtime-target-id',$RuntimeTargetId)}
& python.exe @prepareArguments
if($LASTEXITCODE -ne 0){throw 'Real-agent preparation failed.'}
$environment=Get-Content (Join-Path $demoProfile 'demo-environment.json') -Raw|ConvertFrom-Json
$previous=@();$app=$null;$browser=$null;$recorder=$null
$markers=[ordered]@{};$clock=$null
function Mark([string]$name){$markers[$name]=$clock.Elapsed.TotalSeconds}
function AssertWorkspace {
 $binding=Get-Content (Join-Path $demoProfile 'binding.json') -Raw|ConvertFrom-Json
 $identity=Get-Content (Join-Path $demoProfile 'demo-identity.json') -Raw|ConvertFrom-Json
 if($binding.cwd -cne $Workspace -or $binding.runtimeTargetId -cne $identity.runtimeTargetId){throw 'The recording app is not connected to the prepared runtime and workspace.'}
}
function AssertNativeSelection($Selection,[int]$Expected) {
 if(-not $Selection -or $Selection.count -ne $Expected -or @($Selection.items).Count -ne $Expected){throw 'Required native attachments were not observed; no prompt was submitted.'}
 if(@($Selection.items|Where-Object {-not $_.hasImage}).Count){throw 'An attachment has no native image; no prompt was submitted.'}
 if($Scene -eq 'dashboard' -and @($Selection.items|Where-Object alignmentStatus -ne 'aligned').Count){throw 'The dashboard capture is not aligned with source context; no prompt was submitted.'}
}
function ReadDemoControl([string]$Path) {
 # Producers should rename a fully written .tmp file to .json. A writer that
 # opens/truncates the final path can briefly expose an empty or partial file.
 # Leave it pending until a complete command is available.
 try {$raw=[IO.File]::ReadAllText($Path)} catch [IO.IOException] {return $null}
 if([string]::IsNullOrWhiteSpace($raw)){return $null}
 try {$command=$raw|ConvertFrom-Json -ErrorAction Stop} catch {return $null}
 return $command
}
function ReadUi {
 $child=[DemoAccess]::FindWindowEx($script:window,[IntPtr]::Zero,[NullString]::Value,[NullString]::Value)
 if($child -eq [IntPtr]::Zero){return @()}
 try{@([DemoAccess]::Read($child))}catch{return @()}
}
function WaitUi([string]$pattern,[int]$seconds=30) {
 $deadline=[DateTime]::UtcNow.AddSeconds($seconds)
 do {
  $entry=ReadUi|Where-Object {$_.Name -match $pattern}|Select-Object -First 1
  if($entry){return $entry}
  Start-Sleep -Milliseconds 100
 }while([DateTime]::UtcNow -lt $deadline)
 throw "Control not ready: $pattern"
}
function Key([byte]$code) {
 [DemoAccess]::keybd_event($code,[byte][DemoAccess]::MapVirtualKey($code,0),0,[UIntPtr]::Zero)
 Start-Sleep -Milliseconds 40
 [DemoAccess]::keybd_event($code,[byte][DemoAccess]::MapVirtualKey($code,0),2,[UIntPtr]::Zero)
}
function Click($entry) {
 if(-not [DemoAccess]::Focus($script:window)){throw 'Demo window is not foreground.'}
 $x=$entry.Bounds[0]+[int]($entry.Bounds[2]/2);$y=$entry.Bounds[1]+[int]($entry.Bounds[3]/2)
 if(-not [DemoAccess]::OwnsPoint($script:window,$x,$y)){throw 'Demo control is covered.'}
 [void][DemoAccess]::SetCursorPos($x,$y)
 [DemoAccess]::mouse_event(2,0,0,0,[UIntPtr]::Zero);Start-Sleep -Milliseconds 45
 [DemoAccess]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
 Start-Sleep -Milliseconds 200
}
function Drag([int]$x1,[int]$y1,[int]$x2,[int]$y2) {
 [void][DemoAccess]::SetCursorPos($x1,$y1)
 Start-Sleep -Milliseconds 250
 [DemoAccess]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
 for($step=1;$step -le 30;$step++){
  [void][DemoAccess]::SetCursorPos($x1+[int](($x2-$x1)*$step/30),$y1+[int](($y2-$y1)*$step/30))
  Start-Sleep -Milliseconds 25
 }
 [DemoAccess]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
 Start-Sleep -Milliseconds 500
}
function Snapshot([string]$name) {
 $bitmap=[Drawing.Bitmap]::new(2352,1323)
 $graphics=[Drawing.Graphics]::FromImage($bitmap)
 try{$graphics.CopyFromScreen(24,24,0,0,$bitmap.Size);$bitmap.Save((Join-Path $OutputDirectory $name))}
 finally{$graphics.Dispose();$bitmap.Dispose()}
}
try {
 $bounds=[Windows.Forms.Screen]::PrimaryScreen.Bounds
 if($bounds.Width -ne 2400 -or $bounds.Height -ne 1600){throw 'This storyboard is calibrated for a 2400x1600 desktop. Recalibrate and inspect before recording.'}
 $previous=@(Suspend-ConflictingZommiApplications -EntryPoint (Join-Path $OutputDirectory 'not-running.exe'))
 if(-not $BrowserEndpoint){
 $browserStart=[Diagnostics.ProcessStartInfo]::new((Join-Path $env:ProgramFiles 'Google/Chrome/Application/chrome.exe'))
 $browserStart.UseShellExecute=$false
 $fixture=[Uri]::new((Join-Path $PSScriptRoot 'fixture.html'))
 $url=if($Scene -eq 'dashboard'){$DashboardUrl}else{$fixture.AbsoluteUri+'?scene='+$Scene}
 if($Scene -eq 'dashboard' -and ([Uri]$url).Host -notin @('127.0.0.1','localhost')){throw 'Dashboard recording requires the local synthetic fixture.'}
 foreach($argument in @(('--user-data-dir='+(Join-Path $OutputDirectory 'browser')),'--no-first-run','--no-default-browser-check','--disable-background-networking','--disable-sync','--disable-gpu','--force-device-scale-factor=1','--remote-debugging-port=0','--window-position=0,0','--window-size=2400,1600',('--app='+$url))){$browserStart.ArgumentList.Add($argument)}
 $browser=[Diagnostics.Process]::Start($browserStart)
 Start-Sleep -Seconds 3
 if($browser.HasExited -or -not (Test-Path (Join-Path $OutputDirectory 'browser'))){throw 'Chrome did not open an isolated profile.'}
 }
 $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PackageDirectory 'Zommi.exe'))
 $start.UseShellExecute=$false;$start.WorkingDirectory=$PackageDirectory
 foreach($entry in $environment.PSObject.Properties){$start.Environment[$entry.Name]=[string]$entry.Value}
 if($BrowserEndpoint){
  $start.Environment['ZOMMI_BROWSER_CDP_ENDPOINT']=$BrowserEndpoint
 }elseif($Scene -eq 'dashboard'){
  $portFile=Join-Path $OutputDirectory 'browser/DevToolsActivePort'
  if(-not (Test-Path $portFile)){throw 'The isolated browser did not expose its authorized debugging endpoint.'}
  $port=(Get-Content $portFile)[0]
  if($port -notmatch '^\d+$'){throw 'Invalid local browser port.'}
  $start.Environment['ZOMMI_BROWSER_CDP_ENDPOINT']='http://127.0.0.1:'+$port
 }
 $start.Environment['ZOMMI_ACCEPTANCE_LOG']=Join-Path $OutputDirectory 'private-desktop.jsonl'
 $app=[Diagnostics.Process]::Start($start)
 $deadline=[DateTime]::UtcNow.AddSeconds(30)
 do{$app.Refresh();Start-Sleep -Milliseconds 100}while($app.MainWindowHandle -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline)
 $script:window=$app.MainWindowHandle
 if($script:window -eq [IntPtr]::Zero){throw 'Demo app did not open.'}
 $null=WaitUi '^Message composer'
 $deadline=[DateTime]::UtcNow.AddSeconds(60)
 do {
  $entries=ReadUi
  $ready=@($entries|Where-Object {$_.Name -eq 'New agent' -and ($_.State -band 1) -eq 0}).Count
  $starting=@($entries|Where-Object Name -match '^Waking Zommi').Count
  if($ready -and -not $starting){break}
  Start-Sleep -Milliseconds 150
 }while([DateTime]::UtcNow -lt $deadline)
 if(-not $ready -or $starting){throw 'The real agent did not become ready for recording.'}
 # A WSL startup can reopen an empty prepared chat in the runtime's home.
 # Set the actual UI workspace and verify the persisted live binding before
 # recording anything or submitting a prompt.
 Click (WaitUi '^Workspace$' 60)
 Click (WaitUi '^Folder path')
 [DemoAccess]::keybd_event(0x11,0x1d,0,[UIntPtr]::Zero);Key 0x41
 [DemoAccess]::keybd_event(0x11,0x1d,2,[UIntPtr]::Zero)
 [DemoAccess]::TypeText($Workspace)
 Key 0x0d
 $deadline=[DateTime]::UtcNow.AddSeconds(30)
 do {
  try{AssertWorkspace;break}catch{if([DateTime]::UtcNow -ge $deadline){throw}}
  Start-Sleep -Milliseconds 150
 }while($true)
 $hide=ReadUi|Where-Object Name -eq 'Hide chat sessions'|Select-Object -First 1
 if($hide){Click $hide}
 # Agent browser-tool initialization can raise another Chrome window. Restore
 # the owned source after runtime/workspace setup, before inspecting the take.
 if($browser){
  $browser.Refresh()
  if(-not [DemoAccess]::Focus($browser.MainWindowHandle)){throw 'The owned source browser could not become foreground.'}
 }
 [void][DemoAccess]::SetWindowPos($script:window,[IntPtr]::Zero,1200,100,1160,1210,0x40)
 if(-not [DemoAccess]::Focus($script:window)){throw 'The recording app could not become foreground.'}
 Start-Sleep -Seconds 2
 Snapshot 'inspection.png'
 Write-Host 'Inspection image is ready. Create record.ready after checking the actual screen and selection coordinates.'
 $deadline=[DateTime]::UtcNow.AddMinutes(15)
 while(-not (Test-Path (Join-Path $OutputDirectory 'record.ready'))){
  if(Test-Path (Join-Path $OutputDirectory 'abort')){throw 'Recording cancelled before capture.'}
  if([DateTime]::UtcNow -gt $deadline){throw 'Recording was not started after inspection.'}
  Start-Sleep -Milliseconds 200
 }
 $recordedAt=[DateTime]::UtcNow
 $recorder=[DemoRecorder]::new((Join-Path $OutputDirectory 'frames'),24,24,2352,1323,$MaxDurationSeconds)
 $clock=[Diagnostics.Stopwatch]::StartNew()
 Mark 'intro'
 if($Manual){
  # Inputs and browser actions happen through the real UI. This channel only
  # timestamps them; it cannot manufacture an attachment or agent response.
  $control=Join-Path $OutputDirectory 'control'
  $null=New-Item -ItemType Directory $control
  $seen=[Collections.Generic.HashSet[string]]::new()
  $allowedMarks=@('selection-start','selection-end','sent','response-ready','refresh','followup-selection-start','followup-selection-end','followup-sent','followup-response-ready','verify-input','verify-restored')
  $finished=$false
  Write-Host 'Recording actual desktop pixels. Add ordered control JSON files to mark actions or finish.'
  while(-not $finished){
   if($recorder.Error){throw $recorder.Error}
   if($clock.Elapsed.TotalSeconds -ge $MaxDurationSeconds){throw 'Manual recording exceeded its configured duration limit.'}
   foreach($file in Get-ChildItem $control -Filter '*.json'|Sort-Object Name){
    if($seen.Contains($file.Name)){continue}
    $command=ReadDemoControl $file.FullName
    if(-not $command){continue}
    switch($command.action){
     'mark' {
      if($command.name -notin $allowedMarks -or $markers.Contains($command.name)){throw 'Unknown or duplicate recording marker.'}
      if($command.name -in @('sent','followup-sent')){AssertWorkspace}
      Mark $command.name
     }
     'finish' {$finished=$true}
     'abort' {throw 'Manual take rejected; do not export.'}
     default {throw 'Unknown recording control action.'}
    }
    [void]$seen.Add($file.Name)
   }
   Start-Sleep -Milliseconds 100
  }
 }else{
 Start-Sleep -Milliseconds 1500
 # The actual Alt+A global shortcut opens the shipped native selector.
 [DemoAccess]::keybd_event(0x12,0x38,0,[UIntPtr]::Zero);Key 0x41
 [DemoAccess]::keybd_event(0x12,0x38,2,[UIntPtr]::Zero)
 Start-Sleep -Milliseconds 1200
 Mark 'selection-start'
 if($Scene -eq 'dashboard'){
  [DemoAccess]::keybd_event(0x11,0x1d,0,[UIntPtr]::Zero)
  Drag 36 240 552 612
  [DemoAccess]::keybd_event(0x11,0x1d,2,[UIntPtr]::Zero)
  Drag 570 240 1085 612
  Drag 36 632 1085 1060
  Key 0x0d
 }elseif($Scene -eq 'compare'){
  [DemoAccess]::keybd_event(0x11,0x1d,0,[UIntPtr]::Zero)
  Drag 55 300 539 760
  [DemoAccess]::keybd_event(0x11,0x1d,2,[UIntPtr]::Zero)
  Drag 560 300 1044 760
  Key 0x0d
 }else{Drag 55 300 891 800}
 # A visible composer does not mean capture succeeded. Wait for the real
 # native acceptance event and refuse image-less submissions after a failure.
 $expected=if($Scene -eq 'dashboard'){3}elseif($Scene -eq 'compare'){2}else{1}
 $deadline=[DateTime]::UtcNow.AddSeconds(45)
 do {
  $failure=ReadUi|Where-Object Name -match 'Selection failed'|Select-Object -First 1
  if($failure){throw 'Native selection failed; no prompt was submitted.'}
  $events=@(Get-Content (Join-Path $OutputDirectory 'private-desktop.jsonl')|ForEach-Object {$_|ConvertFrom-Json})
  $selection=$events|Where-Object event -eq 'selection.content'|Select-Object -Last 1
  if($selection){AssertNativeSelection $selection $expected;break}
  if([DateTime]::UtcNow -ge $deadline){throw 'Required native attachments were not observed; no prompt was submitted.'}
  Start-Sleep -Milliseconds 150
 }while($true)
 $composer=WaitUi '^Message composer' 30
 AssertWorkspace
 Mark 'selection-end'
 Start-Sleep -Milliseconds 1500
 [void][DemoAccess]::SetWindowPos($script:window,[IntPtr]::Zero,1200,100,1160,1210,0x40)
 Click (WaitUi '^Message composer')
 $prompt=if($Scene -eq 'dashboard'){'Why does A jump while B stays flat? Investigate and fix the graph.'}elseif($Scene -eq 'compare'){'Which plan is cheaper for six seats? Include the annual total. Use only A and B.'}else{'Explain this error and the next step. Use only the attached message.'}
 [DemoAccess]::TypeText($prompt)
 Start-Sleep -Seconds 2
 if($SendPrompt){
  Key 0x0d
  Mark 'sent'
  Start-Sleep -Seconds 2
  $deadline=[DateTime]::UtcNow.AddSeconds($(if($Scene -eq 'dashboard'){480}else{60}))
  $sawBusy=$false
  do {
   $busy=@(ReadUi|Where-Object Name -match '^Stop response|^Stop$').Count
   if($busy){$sawBusy=$true}
   if($sawBusy -and -not $busy){break}
   Start-Sleep -Milliseconds 250
  }while([DateTime]::UtcNow -lt $deadline)
  if(-not $sawBusy -or $busy){throw 'No completed real-agent response was observed; do not export this take.'}
  Mark 'response-ready'
  Start-Sleep -Seconds 6
  if($Scene -eq 'dashboard'){
   # Refresh the actual served dashboard after the agent edits the SQL/source.
   $browser.Refresh()
   if(-not [DemoAccess]::Focus($browser.MainWindowHandle)){throw 'Could not focus the real dashboard.'}
   Mark 'refresh'
   Key 0x74
   Start-Sleep -Seconds 4
   [void][DemoAccess]::SetWindowPos($script:window,[IntPtr]::Zero,1200,100,1160,1210,0x40)
   Start-Sleep -Seconds 6
  }
 }
 }
 Mark 'end'
 Snapshot 'end.png'
 $recorder.Dispose()
 if($recorder.Error){throw $recorder.Error}
 $manifest=Get-Content (Join-Path $PackageDirectory 'release-manifest.json') -Raw|ConvertFrom-Json
 @{scene=$Scene;recordedAtUtc=$recordedAt.ToString('o');gitCommit=$manifest.gitCommit;capture='Windows desktop pixels';syntheticSource=($Scene -ne 'amazon');sourceKind=$(if($Scene -eq 'amazon'){'public-product-pages'}else{'synthetic'});realRuntime='Codex';promptSent=$markers.Contains('sent');manual=[bool]$Manual;audio=$false;duration=$recorder.Duration;frameTimes=$recorder.Times.ToArray();markers=$markers}|ConvertTo-Json -Depth 3|Set-Content (Join-Path $OutputDirectory 'recording.json')
 Write-Host 'Raw recording complete; export and inspect every frame before publishing.'
}finally{
 if($recorder){$recorder.Dispose()}
 if($app -and -not $app.HasExited){[void]$app.CloseMainWindow();if(-not $app.WaitForExit(5000)){$app.Kill($true)}}
 if($browser -and -not $browser.HasExited){$browser.Kill($true);$browser.WaitForExit(5000)|Out-Null}
 Restore-SuspendedZommiApplications -ExecutablePaths $previous
}
