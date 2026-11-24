# lib/install.ps1 - fetch the ComfyUI portable engine and Wan model files. ASCII-only.
# Deps: common, discover.
# Network reality on this machine (verified 2026-11-24): huggingface.co API/download is BLOCKED,
# hf-mirror.com works, api/raw.githubusercontent works. So every model file is tried against a
# host list in order. All file names below were pulled from repo listings, not from memory.

# PS5.1 Invoke-WebRequest buffers the WHOLE response in RAM before writing - fine for a 200MB
# zip, fatal for a 3.5GB engine (no progress, RAM bloat, restart-from-zero on every stall).
# So: streaming HttpWebRequest -> FileStream, with Range-based resume and progress every 64MB.
function Invoke-VidDownload {
  param([string]$Url, [string]$OutFile, [int]$TimeoutSec = 3600, [int]$Retries = 5)
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
  New-Item -ItemType Directory -Force -Path (Split-Path $OutFile -Parent) | Out-Null
  $name = [IO.Path]::GetFileName($OutFile)
  for ($i = 1; $i -le $Retries; $i++) {
    $req = $null; $resp = $null; $fs = $null; $rs = $null
    try {
      $have = 0
      if (Test-Path $OutFile) { $have = (Get-Item $OutFile).Length }
      Write-VidLog ('  downloading (try ' + $i + $(if ($have) { ', resume from ' + [math]::Round($have / 1MB) + 'MB' } else { '' }) + '): ' + $name)
      $req = [System.Net.HttpWebRequest]::Create($Url)
      $req.Timeout = 30000
      $req.ReadWriteTimeout = 60000
      $req.UserAgent = 'video-tuner'
      if ($have -gt 0) { $req.AddRange($have) }
      $resp = $req.GetResponse()
      $status = [int]$resp.StatusCode
      if ($have -gt 0 -and $status -ne 206) { $have = 0 }   # server ignored Range: restart clean
      $fs = [IO.File]::Open($OutFile, $(if ($status -eq 206) { [IO.FileMode]::Append } else { [IO.FileMode]::Create }))
      $total = -1
      try { if ($resp.ContentLength -ge 0) { $total = $resp.ContentLength + $have } } catch {}
      $rs = $resp.GetResponseStream()
      $buf = New-Object byte[] 262144
      $sinceReport = 0
      while ($true) {
        $n = $rs.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        $fs.Write($buf, 0, $n)
        $have += $n; $sinceReport += $n
        if ($sinceReport -ge 67108864) {
          $msg = '    ... ' + [math]::Round($have / 1MB) + 'MB'
          if ($total -gt 0) { $msg += '/' + [math]::Round($total / 1MB) + 'MB (' + [math]::Round(100.0 * $have / $total) + '%)' }
          Write-VidLog $msg
          $sinceReport = 0
        }
      }
      $rs.Close(); $rs = $null; $fs.Close(); $fs = $null; $resp.Close(); $resp = $null
      $size = (Get-Item $OutFile).Length
      if ($size -gt 0 -and ($total -lt 0 -or $size -ge $total)) { return $true }
      Write-VidLog ('    incomplete (' + [math]::Round($size / 1MB) + '/' + [math]::Round($total / 1MB) + 'MB), will resume')
    } catch {
      Write-VidLog ('    stalled: ' + $_.Exception.Message)
    } finally {
      if ($rs) { $rs.Close() }
      if ($fs) { $fs.Close() }
      if ($resp) { $resp.Close() }
    }
    Start-Sleep -Seconds (5 * $i)
  }
  return $false
}

# resolve-first across mirrors; $relPaths entries: @{repo; path; dir}
function Get-VidDownloadHosts { return @('https://hf-mirror.com', 'https://huggingface.co') }

# GitHub release/zip downloads are intermittently throttled HERE (verified 2026-11-24: direct
# timed out at 15s while gh-proxy.com/ghfast.top both answered instantly). A third-party
# accelerator could tamper with bytes, so we still TRY direct first - but with a short probe
# timeout so a blocked direct route costs 15 seconds, not an hour.
function Get-VidGithubProxies { return @('https://gh-proxy.com/', 'https://ghfast.top/') }

function Test-VidUrlAlive([string]$Url) {
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.Method = 'GET'
    $req.AddRange(0, 63)
    $req.Timeout = 15000
    $req.UserAgent = 'video-tuner'
    $resp = $req.GetResponse()
    $resp.Close()
    return $true
  } catch { return $false }
}

function Invoke-VidDownloadGithub {
  param([string]$Url, [string]$OutFile, [string]$Canonical = '')
  $alt = if ($Canonical) { $Canonical } else { $Url }
  if ((Test-VidUrlAlive $Url) -and (Invoke-VidDownload $Url $OutFile)) { return $true }
  foreach ($p in @(Get-VidGithubProxies)) {
    Write-VidLog ('  using accelerator ' + $p.Split('/')[2])
    if (Invoke-VidDownload ($p + $alt) $OutFile) { return $true }
  }
  return $false
}

function Invoke-VidDownloadRepoFile {
  param([string]$Repo, [string]$Path, [string]$OutFile)
  foreach ($h in @(Get-VidDownloadHosts)) {
    if (Invoke-VidDownload ($h + '/' + $Repo + '/resolve/main/' + $Path) $OutFile) { return $true }
  }
  return $false
}

# The portable release is a .7z; Windows ships bsdtar which can read 7z. If a future build
# cannot, we say so plainly instead of half-extracting.
function Expand-VidArchive7z {
  param([string]$Archive, [string]$Destination)
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  $prev = Get-Location
  try {
    Set-Location $Destination
    & tar.exe -xf $Archive
    if ($LASTEXITCODE -ne 0) { throw ('tar cannot extract this 7z (exit ' + $LASTEXITCODE + '). Extract with 7-Zip to ' + $Destination) }
  } finally { Set-Location $prev }
}

function Install-VidEngine([string]$root) {
  Write-VidLog 'ComfyUI portable not found - downloading official Windows portable from GitHub...'
  $dest = Join-Path $root 'ComfyUI'
  if (Test-VidEngineRoot $dest) { return $dest }
  $free = Get-VidFreeDiskGB $root
  if ($free -ge 0 -and $free -lt 25) {
    Write-VidLog ('WARNING: only ' + $free + ' GB free on this volume; engine is ~15 GB after extraction.')
  }
  $rel = Invoke-RestMethod 'https://api.github.com/repos/Comfy-Org/ComfyUI/releases/latest' -TimeoutSec 30
  $asset = @($rel.assets | Where-Object { $_.name -match 'windows_portable.*nvidia.*\.7z$' } | Select-Object -First 1)
  if (-not $asset) { $asset = @($rel.assets | Where-Object { $_.name -match 'windows_portable.*\.7z$' } | Select-Object -First 1) }
  if (-not $asset) { throw 'No portable asset in latest release. Download manually: https://github.com/Comfy-Org/ComfyUI/releases' }
  $asset = $asset[0]
  $tmp = Join-Path $root 'runtime\dl'
  $z = Join-Path $tmp $asset.name
  # canonical github.com URL for the accelerators (browser_download_url is objects.githubusercontent,
  # which most prefix proxies do NOT relay)
  $canon = 'https://github.com/Comfy-Org/ComfyUI/releases/download/' + $rel.tag_name + '/' + $asset.name
  if (-not (Invoke-VidDownloadGithub $asset.browser_download_url $z $canon)) {
    throw ('Download failed. Get "' + $asset.name + '" manually, unpack, and re-run with -EngineDir <folder>.')
  }
  Write-VidLog '  extracting (a few minutes)...'
  $ex = Join-Path $tmp 'engine'
  Expand-VidArchive7z $z $ex
  $inner = @(Get-ChildItem $ex -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'python_embeded\python.exe') }) | Select-Object -First 1
  if (-not $inner) { throw 'extracted tree has no python_embeded - unexpected archive layout' }
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  Copy-Item (Join-Path $inner.FullName '*') $dest -Recurse -Force
  if (-not (Test-VidEngineRoot $dest)) { throw 'engine tree incomplete after copy' }
  Remove-Item $z -Force -ErrorAction SilentlyContinue
  return $dest
}

# ComfyUI-GGUF custom node pack: REQUIRED whenever we load GGUF weights. Idempotent.
# Installed as plain zip (bare machines have no git); needs no pip deps on recent portables
# (they bundle the 'gguf' python package). If nodes still fail to load, the probe in tune.ps1
# says exactly which class is missing instead of pretending.
function Install-VidGgufPack([string]$engineRoot) {
  $cn = Join-Path $engineRoot 'ComfyUI\custom_nodes\ComfyUI-GGUF'
  if (Test-Path (Join-Path $cn '__init__.py')) { return $cn }
  Write-VidLog 'installing ComfyUI-GGUF custom node pack (needed for GGUF weights)...'
  $tmp = Join-Path $engineRoot 'runtime\dl'
  $z = Join-Path $tmp 'ComfyUI-GGUF.zip'
  if (-not (Invoke-VidDownloadGithub 'https://codeload.github.com/city96/ComfyUI-GGUF/zip/refs/heads/main' $z `
      'https://github.com/city96/ComfyUI-GGUF/archive/refs/heads/main.zip')) {
    throw 'cannot fetch ComfyUI-GGUF. Manual: download zip from github.com/city96/ComfyUI-GGUF, unpack into ComfyUI\custom_nodes\ComfyUI-GGUF'
  }
  $ex = Join-Path $tmp 'ggufpack'
  if (Test-Path $ex) { Remove-Item $ex -Recurse -Force }
  Expand-Archive $z -DestinationPath $ex -Force
  $inner = @(Get-ChildItem $ex -Directory | Where-Object { Test-Path (Join-Path $_.FullName '__init__.py') }) | Select-Object -First 1
  if (-not $inner) { throw 'ComfyUI-GGUF zip layout unexpected' }
  New-Item -ItemType Directory -Force -Path (Split-Path $cn -Parent) | Out-Null
  Copy-Item (Join-Path $inner.FullName '*') $cn -Recurse -Force
  Write-VidLog ('  installed to ' + $cn)
  return $cn
}

# Grounded manifests (repo+path verified against repo listings 2026-11-24).
# VAE pairing is NOT interchangeable: 5B/ti2v uses wan2.2 vae; 14B and 1.3B use wan_2.1 vae.
function Get-VidModelManifest([string]$modelKey) {
  switch ($modelKey) {
    'wan2.1-t2v-1.3b' { return @(
      @{ repo = 'Comfy-Org/Wan_2.1_ComfyUI_repackaged'; path = 'split_files/diffusion_models/wan2.1_t2v_1.3B_fp16.safetensors'; dir = 'diffusion_models' }
      @{ repo = 'Comfy-Org/Wan_2.1_ComfyUI_repackaged'; path = 'split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors'; dir = 'text_encoders' }
      @{ repo = 'Comfy-Org/Wan_2.1_ComfyUI_repackaged'; path = 'split_files/vae/wan_2.1_vae.safetensors'; dir = 'vae' }
    ) }
    'wan2.2-ti2v-5b-gguf' { return @(
      @{ repo = 'QuantStack/Wan2.2-TI2V-5B-GGUF'; path = 'Wan2.2-TI2V-5B-Q4_K_S.gguf'; dir = 'diffusion_models' }
      @{ repo = 'Comfy-Org/Wan_2.2_ComfyUI_Repackaged'; path = 'split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors'; dir = 'text_encoders' }
      @{ repo = 'Comfy-Org/Wan_2.2_ComfyUI_Repackaged'; path = 'split_files/vae/wan2.2_vae.safetensors'; dir = 'vae' }
    ) }
    'wan2.2-t2v-14b-gguf' { return @(
      @{ repo = 'QuantStack/Wan2.2-T2V-A14B-GGUF'; path = 'HighNoise/Wan2.2-T2V-A14B-HighNoise-Q4_K_S.gguf'; dir = 'diffusion_models' }
      @{ repo = 'QuantStack/Wan2.2-T2V-A14B-GGUF'; path = 'LowNoise/Wan2.2-T2V-A14B-LowNoise-Q4_K_S.gguf'; dir = 'diffusion_models' }
      @{ repo = 'Comfy-Org/Wan_2.2_ComfyUI_Repackaged'; path = 'split_files/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_high_noise.safetensors'; dir = 'loras' }
      @{ repo = 'Comfy-Org/Wan_2.2_ComfyUI_Repackaged'; path = 'split_files/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors'; dir = 'loras' }
      @{ repo = 'Comfy-Org/Wan_2.2_ComfyUI_Repackaged'; path = 'split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors'; dir = 'text_encoders' }
      @{ repo = 'Comfy-Org/Wan_2.1_ComfyUI_repackaged'; path = 'split_files/vae/wan_2.1_vae.safetensors'; dir = 'vae' }
    ) }
    default { return @() }
  }
}

function Install-VidModels {
  param([string]$engineRoot, [string]$modelKey)
  $dirs = Get-VidModelDirs $engineRoot
  $mani = @(Get-VidModelManifest $modelKey)
  if ($mani.Count -eq 0) {
    Write-VidLog ('no auto-manifest for ' + $modelKey + '. Place files manually under ' + $dirs.Root + ' (subdirs: diffusion_models, text_encoders, vae, loras) and re-run.')
    throw ('no manifest for ' + $modelKey)
  }
  $free = Get-VidFreeDiskGB $engineRoot
  if ($free -ge 0 -and $free -lt 40) {
    Write-VidLog ('WARNING: only ' + $free + ' GB free; this model set needs ~10-25 GB. Free space first.')
  }
  foreach ($m in $mani) {
    $name = [IO.Path]::GetFileName($m.path)
    $target = Join-Path (Join-Path $dirs.Root $m.dir) $name
    if (Test-Path $target) { Write-VidLog ('  have ' + $name); continue }
    if (-not (Invoke-VidDownloadRepoFile $m.repo $m.path $target)) {
      Write-VidLog ('  MANUAL: ' + $m.repo + ' / ' + $m.path + '  ->  ' + $target)
      throw ('model download failed: ' + $name)
    }
  }
}
