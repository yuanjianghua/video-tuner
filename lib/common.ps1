# lib/common.ps1 - logging + engine lifecycle helpers. ASCII-only.
$script:VidLogLines = @()

function Write-VidLog([string]$msg) {
  $line = (Get-Date -Format 'HH:mm:ss') + '  ' + $msg
  Write-Host $line
  $script:VidLogLines += $line
}

function Save-VidLog([string]$path) {
  Set-Content -Path $path -Value $script:VidLogLines -Encoding UTF8
}

# The portable engine runs python_embeded\python.exe main.py -> match by command line, never by
# bare image name (a bare python.exe might be the user's own interpreter).
function Stop-VidEngine {
  foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -match 'ComfyUI[\\/]+main\.py' })) {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
  }
  Start-Sleep -Seconds 2
}
