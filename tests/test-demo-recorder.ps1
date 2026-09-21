#requires -Version 7.0
param([switch]$CheckNativeRecorder)
# Exercise the recorder's actual pre-submission guards without starting an app,
# sending a model prompt, or requiring an unlocked desktop.
$ErrorActionPreference='Stop'
$source=Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/demo/record-windows.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors){throw ($errors.Message -join '; ')}
foreach($name in @('AssertWorkspace','AssertNativeSelection','ReadDemoControl')){
 $definition=$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
 if(@($definition).Count -ne 1){throw "Recorder guard missing: $name"}
 . ([scriptblock]::Create($definition[0].Extent.Text))
}
function Reject([scriptblock]$Action){
 $rejected=$false
 try{& $Action}catch{$rejected=$true}
 if(-not $rejected){throw 'An invalid recording state was accepted.'}
}
$demoProfile=Join-Path ([IO.Path]::GetTempPath()) ('zommi-recorder-guards-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory $demoProfile
try{
 $controlPath=Join-Path $demoProfile 'control.json'
 foreach($partial in @('', '{"action":', '{"action":"mark","name":')){
  [IO.File]::WriteAllText($controlPath,$partial)
  if($null -ne (ReadDemoControl $controlPath)){throw 'A partial control file was consumed.'}
 }
 [IO.File]::WriteAllText($controlPath,'{"action":"mark","name":"sent"}')
 $writer=[IO.File]::Open($controlPath,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try{if($null -ne (ReadDemoControl $controlPath)){throw 'An unfinished exclusive write was consumed.'}}finally{$writer.Dispose()}
 if((ReadDemoControl $controlPath).name -ne 'sent'){throw 'A completed control file was not read.'}
 $Workspace='/tmp/demo-dashboard'
 @{runtimeTargetId='demo-runtime'}|ConvertTo-Json|Set-Content (Join-Path $demoProfile 'demo-identity.json')
 @{runtimeTargetId='demo-runtime';cwd=$Workspace}|ConvertTo-Json|Set-Content (Join-Path $demoProfile 'binding.json')
 AssertWorkspace
 foreach($cwd in @('/home/example','/tmp/Demo-dashboard')){
  @{runtimeTargetId='demo-runtime';cwd=$cwd}|ConvertTo-Json|Set-Content (Join-Path $demoProfile 'binding.json')
  Reject {AssertWorkspace}
 }
 @{runtimeTargetId='other-runtime';cwd=$Workspace}|ConvertTo-Json|Set-Content (Join-Path $demoProfile 'binding.json')
 Reject {AssertWorkspace}
 $Scene='dashboard'
 $images=@(1..3|ForEach-Object {[pscustomobject]@{hasImage=$true;alignmentStatus='aligned'}})
 AssertNativeSelection ([pscustomobject]@{count=3;items=$images}) 3
 Reject {AssertNativeSelection $null 3}
 Reject {AssertNativeSelection ([pscustomobject]@{count=2;items=$images[0..1]}) 3}
 Reject {AssertNativeSelection ([pscustomobject]@{count=3;items=$images[0..1]}) 3}
 $images[0].hasImage=$false
 Reject {AssertNativeSelection ([pscustomobject]@{count=3;items=$images}) 3}
 $images[0].hasImage=$true;$images[0].alignmentStatus='image-only'
 Reject {AssertNativeSelection ([pscustomobject]@{count=3;items=$images}) 3}
 'Recorder guards passed: exact runtime/workspace, complete images, aligned dashboard context.'
}finally{Remove-Item -LiteralPath $demoProfile -Recurse -Force}
if($CheckNativeRecorder){
 # Optional Windows desktop check: a one-pixel recording must signal timeout,
 # rather than silently stop while the host keeps accepting timing markers.
 Add-Type -AssemblyName System.Drawing
 Add-Type -AssemblyName System.Windows.Forms
 $references=@([Drawing.Bitmap].Assembly.Location,[Windows.Forms.Form].Assembly.Location)
 $references+=Get-ChildItem (Join-Path $PSHOME 'ref') -Filter '*.dll'|ForEach-Object FullName
 $references+=Get-ChildItem $PSHOME -Filter 'System.Private.Windows*.dll'|ForEach-Object FullName
 $references+=Get-ChildItem $PSHOME -Filter 'System.Windows.Forms.Primitives.dll'|ForEach-Object FullName
 Add-Type -CompilerOptions '/nowarn:1701,9191' -ReferencedAssemblies $references -TypeDefinition (Get-Content -Raw (Join-Path (Split-Path $source -Parent) 'windows-recorder.cs'))
 $capture=Join-Path ([IO.Path]::GetTempPath()) ('zommi-recorder-deadline-'+[guid]::NewGuid().ToString('N'))
 $recorder=$null
 try{
  Reject {[DemoRecorder]::new($capture,0,0,1,1,0)}
  $recorder=[DemoRecorder]::new($capture,0,0,1,1,1)
  Start-Sleep -Milliseconds 1600
  if($recorder.Error -isnot [TimeoutException] -or $recorder.Times.Count -lt 1){throw 'The recorder failed to report its actual capture deadline.'}
  $durable=@(Get-Content (Join-Path $capture 'frame-times.jsonl')|ForEach-Object {[double]::Parse($_,[Globalization.CultureInfo]::InvariantCulture)})
  if($durable.Count -ne $recorder.Times.Count -or $durable[-1] -ne $recorder.Times[-1]){throw 'Durable frame timestamps do not match the recorded frames.'}
  'Native recorder deadline passed: timeout is explicit, with actual frames captured.'
 }finally{
  if($recorder){$recorder.Dispose()}
  if(Test-Path $capture){Remove-Item -LiteralPath $capture -Recurse -Force}
 }
}
