# lib/sysinfo.ps1 - hardware detection, pure query (adapted from llama-tuner's battle-tested code).
# Driver guard mirrors llama-tuner: an uninstalled NVIDIA driver would silently drop the user into
# CPU generation that takes hours instead of minutes -> detect and say so instead of planning it.
# ASCII-only.

function Get-VidRamMB {
  $os = Get-CimInstance Win32_OperatingSystem
  return [int]($os.TotalVisibleMemorySize / 1KB)
}

function Get-NvidiaGpusVid {
  $smi = @(
    (Get-Command nvidia-smi -ErrorAction SilentlyContinue).Source,
    "$env:SystemRoot\System32\nvidia-smi.exe"
  ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
  if (-not $smi) { return @() }
  $out = @()
  try { $out = & $smi --query-gpu=index,name,memory.total,memory.used --format=csv,noheader,nounits 2>$null } catch { return @() }
  $gpus = @()
  foreach ($line in $out) {
    if ($line -match '^\s*\d+') {
      $p = $line -split ','
      $gpus += [pscustomobject]@{ Id = [int]$p[0].Trim(); Name = $p[1].Trim(); TotalMB = [int]$p[2].Trim(); UsedMB = [int]$p[3].Trim() }
    }
  }
  return $gpus
}

# caller MUST wrap in @() (PS5.1 scalar unroll trap)
function Get-VidGpuSummary {
  $gpus = @(Get-NvidiaGpusVid)
  if ($gpus.Count -eq 0) { return $null }
  return [pscustomobject]@{
    List    = $gpus
    TotalMB = ($gpus | Measure-Object -Property TotalMB -Sum).Sum
    UsedMB  = ($gpus | Measure-Object -Property UsedMB  -Sum).Sum
    Count   = $gpus.Count
    Sig     = (($gpus | ForEach-Object { "$($_.Name)/$($_.TotalMB)" }) -join '+')
  }
}

function Test-VidNvidiaDevicePresent {
  @(Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Display'" -ErrorAction SilentlyContinue |
      Where-Object { $_.DeviceID -match 'VEN_10DE' -or $_.Name -match 'NVIDIA|GeForce|RTX|GTX' }).Count -gt 0
}

# commit budget (WDDM false-OOM lesson carried over verbatim)
function Get-VidMemoryBudget {
  $os = Get-CimInstance Win32_OperatingSystem
  $mounted = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
  $configured = @(Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
  $missing = @($configured | Where-Object { $cf = $_; -not @($mounted | Where-Object { $_.Substring(0, 2) -ieq $cf.Substring(0, 2) }).Count })
  return [pscustomobject]@{
    CommitLimitMB = [int]($os.TotalVirtualMemorySize / 1KB)
    CommitFreeMB  = [int]($os.FreeVirtualMemory / 1KB)
    Mounted       = $mounted
    Missing       = $missing
  }
}
