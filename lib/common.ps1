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

# Persist the exact API-format prompt we POST to ComfyUI, so a run can be reproduced later.
function Save-VidWorkflowJson {
  param([object]$Workflow, [string]$Dir, [string]$Tag = 'api', [string]$ClientId = '')
  if (-not $Dir) { return '' }
  if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Force -Path $Dir | Out-Null }
  $cid = if ($ClientId) { $ClientId } else { [guid]::NewGuid().ToString() }
  $body = @{ prompt = $Workflow; client_id = $cid } | ConvertTo-Json -Depth 20
  $path = Join-Path $Dir ('vidtuner_' + $Tag + '_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '.json')
  $utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
  [IO.File]::WriteAllText($path, $body, $utf8)
  return $path
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
