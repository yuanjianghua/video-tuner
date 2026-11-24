# lib/discover.ps1 - locate the ComfyUI portable engine and Wan model files on disk. ASCII-only.
# Deps: common (logging). No downloads here: discover only reports what EXISTS; install fills gaps.

function Get-VidEngineRoots([string]$root) {
  # candidate engine locations, first hit wins
  return @(
    'D:\Apps\ComfyUI',                                  # house rules: third-party apps live in D:\Apps
    (Join-Path $root 'ComfyUI'),                        # self-contained: engine next to the tuner
    (Join-Path $env:LOCALAPPDATA 'Programs\ComfyUI'),   # ComfyUI Desktop installs here
    (Join-Path $env:USERPROFILE 'Desktop\ComfyUI')
  ) | Where-Object { Test-VidEngineRoot $_ } | Select-Object -First 1
}

function Test-VidEngineRoot([string]$dir) {
  return ((Test-Path $dir) -and (Test-Path (Join-Path $dir 'python_embeded\python.exe')) -and (Test-Path (Join-Path $dir 'ComfyUI\main.py')))
}

# Given an engine root, return standard subdirs (created lazily by ComfyUI itself).
function Get-VidModelDirs([string]$engineRoot) {
  $c = Join-Path $engineRoot 'ComfyUI\models'
  return [pscustomobject]@{
    Root   = $c
    Unet   = @((Join-Path $c 'diffusion_models'), (Join-Path $c 'unet')) | Where-Object { Test-Path $_ }
    Clip   = @((Join-Path $c 'text_encoders'), (Join-Path $c 'clip')) | Where-Object { Test-Path $_ }
    Vae    = Join-Path $c 'vae'
    Loras  = Join-Path $c 'loras'
  }
}

function Find-VidFiles([string[]]$dirs, [string]$pattern) {
  $out = @()
  foreach ($d in $dirs) {
    if (-not $d -or -not (Test-Path $d)) { continue }
    $out += @(Get-ChildItem $d -Recurse -Filter '*.gguf' -ErrorAction SilentlyContinue)
    $out += @(Get-ChildItem $d -Recurse -Filter '*.safetensors' -ErrorAction SilentlyContinue)
  }
  return @($out | Where-Object { $_.Name -match $pattern } | Sort-Object Length -Descending)
}

# Wan pipeline = diffusion weights + umt5 text encoder + wan vae (+ optional lightx2v loras).
function Get-VidModelInventory([string]$engineRoot) {
  $dirs = Get-VidModelDirs $engineRoot
  $ckpts = @(Find-VidFiles $dirs.Unet 'wan|hunyuan')
  $clips = @(Find-VidFiles $dirs.Clip 'umt5|t5|clip')
  $vaes  = @(Find-VidFiles @($dirs.Vae) 'wan|hunyuan|vae')
  $loras = @(Find-VidFiles @($dirs.Loras) 'wan|lightx|turbo')
  $byModel = [ordered]@{}
  foreach ($f in $ckpts) {
    $n = $f.Name
    $key = 'other'
    if ($n -imatch 'hunyuan') { $key = 'hunyuan1.5-t2v-480p' }
    elseif ($n -imatch 'ti2v|ti_2v') { $key = 'wan2.2-ti2v-5b-gguf' }
    elseif ($n -imatch '1[\.,]3') { $key = 'wan2.1-t2v-1.3b' }
    elseif ($n -imatch '14B|A14B') { $key = 'wan2.2-t2v-14b-gguf' }
    if (-not $byModel.Contains($key)) { $byModel[$key] = @() }
    $byModel[$key] += $f
  }
  return [pscustomobject]@{
    Dirs     = $dirs
    Checkpts = $ckpts
    Clips    = $clips
    Vaes     = $vaes
    Loras    = $loras
    ByModel  = $byModel
    # a model key is runnable only when weights + encoder + vae all exist
    Ready    = @($byModel.Keys | Where-Object { $clips.Count -and $vaes.Count -and $byModel[$_].Count })
  }
}

# Query a running engine for installed node class types (core + custom nodes).
function Get-VidEngineNodes([string]$baseUrl) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $info = Invoke-RestMethod -Uri ($baseUrl.TrimEnd('/') + '/object_info') -TimeoutSec 20
  return @($info.PSObject.Properties.Name)
}

function Test-VidWorkflowRunnable {
  param([object]$Workflow, [string[]]$EngineNodes)
  $missing = @()
  foreach ($n in @(Get-VidRequiredNodes $Workflow)) {
    if ($EngineNodes -notcontains $n) { $missing += $n }
  }
  return [pscustomobject]@{ Ok = ($missing.Count -eq 0); Missing = $missing }
}

# Free disk on the volume holding a path (GB). Downloads are 5-30 GB; warn before starting.
function Get-VidFreeDiskGB([string]$path) {
  $q = Resolve-Path ($path + '\..') -ErrorAction SilentlyContinue
  if (-not $q) { $q = $path }
  $drive = ([string]$q).Substring(0, 1)
  $d = @(Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='" + $drive + ":'")) | Select-Object -First 1
  if (-not $d) { return -1 }
  return [math]::Round($d.FreeSpace / 1GB, 1)
}
