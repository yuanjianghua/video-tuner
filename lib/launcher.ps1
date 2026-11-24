# lib/launcher.ps1 - start/stop .cmd bodies + desktop shortcuts for the engine. ASCII-only source.
# String traps inherited from llama-tuner (see its launcher header):
#   1) never use -f formatting on strings containing literal { }
#   2) never embed $$ inside double-quoted strings (expands to empty)

function New-VidLauncherBodies([string]$engineRoot, [int]$port, [int]$vramMB) {
  $py = Join-Path $engineRoot 'python_embeded\python.exe'
  $mainPy = Join-Path $engineRoot 'ComfyUI\main.py'
  $vramFlag = ''
  if ($vramMB -gt 0 -and $vramMB -lt 10000) { $vramFlag = ' --lowvram' }
  $health = 'try{$r=Invoke-RestMethod http://127.0.0.1:' + $port + '/system_stats -TimeoutSec 2; if($r){exit 10}}catch{}; exit 0'
  $waith  = 'try{$r=Invoke-RestMethod http://127.0.0.1:' + $port + '/system_stats -TimeoutSec 3; if($r){exit 0}}catch{}; exit 1'
  # kill by command line so a bare python.exe that is NOT ours is never touched.
  # NOTE the backticks: $_ must survive into the .cmd VERBATIM (double-quoted build string trap).
  $kill = "Get-CimInstance Win32_Process | Where-Object { `$_.CommandLine -match 'ComfyUI.+main[.]py' } | ForEach-Object { Stop-Process -Id `$_.ProcessId -Force -ErrorAction SilentlyContinue }"
  $startBody = @"
@echo off
title Start Video Engine
powershell -NoProfile -Command "$health"
if %errorlevel%==10 goto open
echo Starting ComfyUI engine (auto-tuned flags), this window can be minimized...
start "ComfyUI" /min "$py" "$mainPy" --port $port --windows-standalone-build$vramFlag
:waitloop
ping -n 6 127.0.0.1 >nul
tasklist /fi "imagename eq python.exe" | find /i "python.exe" >nul
if errorlevel 1 (echo ERROR: engine exited during startup - re-run in a console window to see the error. & exit /b 1)
powershell -NoProfile -Command "$waith"
if errorlevel 1 goto waitloop
:open
start http://localhost:$port/
"@
  $stopBody = @"
@echo off
title Stop Video Engine
powershell -NoProfile -Command "$kill"
echo ComfyUI engine stopped.
ping -n 3 127.0.0.1 >nul
"@
  return @{ Start = $startBody; Stop = $stopBody }
}

function Write-VidLaunchers {
  param([string]$outDir, [string]$engineRoot, [int]$port, [int]$vramMB, [bool]$noShortcut = $false)
  $bodies = New-VidLauncherBodies $engineRoot $port $vramMB
  $startPath = Join-Path $outDir 'start_video_engine.cmd'
  $stopPath  = Join-Path $outDir 'stop_video_engine.cmd'
  Set-Content -Path $startPath -Value $bodies.Start -Encoding ASCII
  Set-Content -Path $stopPath  -Value $bodies.Stop  -Encoding ASCII
  Write-VidLog ('wrote ' + $startPath)
  Write-VidLog ('wrote ' + $stopPath)
  if ($noShortcut) { return }
  $desktop = [Environment]::GetFolderPath('Desktop')
  $ws = New-Object -ComObject WScript.Shell
  # CN labels via unicode escapes (source must stay ASCII): start / stop
  $lnkStart = Join-Path $desktop (([regex]::Unescape('\u542f\u52a8')) + 'VideoEngine.lnk')
  $lnkStop  = Join-Path $desktop (([regex]::Unescape('\u505c\u6b62'))  + 'VideoEngine.lnk')
  $sc = $ws.CreateShortcut($lnkStart)
  $sc.TargetPath = $startPath; $sc.WorkingDirectory = $outDir
  $sc.IconLocation = "$env:SystemRoot\System32\shell32.dll,137"
  $sc.Description = 'Start auto-tuned ComfyUI video engine'; $sc.Save()
  $sc2 = $ws.CreateShortcut($lnkStop)
  $sc2.TargetPath = $stopPath; $sc2.WorkingDirectory = $outDir
  $sc2.IconLocation = "$env:SystemRoot\System32\shell32.dll,132"
  $sc2.Description = 'Stop ComfyUI video engine'; $sc2.Save()
  Write-VidLog ('desktop shortcuts: ' + $lnkStart + ' ; ' + $lnkStop)
}
