# lib/install.ps1 - engine + model installers. Deps: common, discover, net. ASCII-only.
# Every file name below was pulled from repo listings on 2026-11-24, never from memory.

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

# GitHub's API is intermittent here (actual DNS resolution failure seen 2026-11-24), so a
# successful, verified reply is cached and reused during outages. Never a made-up file name:
# the cache is only ever written from a real API response.
function Get-VidEngineRelease([string]$root) {
  $cache = Join-Path $root 'runtime\engine_release.json'
  try {
    $r = Invoke-RestMethod 'https://api.github.com/repos/Comfy-Org/ComfyUI/releases/latest' -TimeoutSec 20
    if (-not $r.tag_name -or -not @($r.assets).Count) { throw 'unexpected release reply' }
    New-Item -ItemType Directory -Force -Path (Split-Path $cache -Parent) | Out-Null
    [IO.File]::WriteAllText($cache, ($r | ConvertTo-Json -Depth 6 -Compress))
    return $r
  } catch {
    Write-VidLog ('  GitHub API unavailable: ' + $_.Exception.Message)
  }
  if (Test-Path $cache) {
    Write-VidLog '  using cached verified release metadata'
    try {
      $r = ([IO.File]::ReadAllText($cache) | ConvertFrom-Json)
      if ($r.tag_name -and @($r.assets).Count) { return $r }
    } catch {}
  }
  throw 'Cannot reach GitHub API and no cached release metadata. Re-run later or download the portable manually.'
}

function Install-VidEngine([string]$root) {
  Write-VidLog 'ComfyUI portable not found - downloading official Windows portable from GitHub...'
  $dest = Join-Path $root 'ComfyUI'
  if (Test-VidEngineRoot $dest) { return $dest }
  $free = Get-VidFreeDiskGB $root
  if ($free -ge 0 -and $free -lt 25) {
    Write-VidLog ('WARNING: only ' + $free + ' GB free on this volume; engine is ~15 GB after extraction.')
  }
  $rel = Get-VidEngineRelease $root
  $asset = @($rel.assets | Where-Object { $_.name -match 'windows_portable.*nvidia.*\.7z$' } | Select-Object -First 1)
  if (-not $asset) { $asset = @($rel.assets | Where-Object { $_.name -match 'windows_portable.*\.7z$' } | Select-Object -First 1) }
  if (-not $asset) { throw 'No portable asset in latest release. Download manually: https://github.com/Comfy-Org/ComfyUI/releases' }
  $asset = $asset[0]
  $tmp = Join-Path $root 'runtime\dl'
  $z = Join-Path $tmp $asset.name
  # canonical github.com URL for the accelerators (browser_download_url is objects.githubusercontent,
  # which most prefix proxies do NOT relay)
  $canon = 'https://github.com/Comfy-Org/ComfyUI/releases/download/' + $rel.tag_name + '/' + $asset.name
  $dl = if ($asset.browser_download_url) { $asset.browser_download_url } else { $canon }
  if (-not (Invoke-VidDownloadGithub $dl $z $canon)) {
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
