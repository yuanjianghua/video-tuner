# video-tuner: auto-tune text-to-video (Wan family) on ComfyUI for THIS machine.
# Entry point / orchestration ONLY (defines no logic functions; tests/arch.ps1 enforces this).
# Modules in lib/, load order + allowed deps in lib/modules.json. Offline tests: tests\all.cmd.
# Same philosophy as llama-tuner: detect hardware -> plan -> PROVE by a real (reduced) generation
# -> write one-click launchers. ASCII-only source; CN labels via \u escapes.
#
# Usage:  tune.cmd                                   full flow: detect, install if needed, validate, launchers
#         tune.ps1 -SkipValidate                     plan only, never touch a running engine
#         tune.ps1 -Generate -Prompt "..."           generate a clip at the validated tier (HOURS, see report)
#         tune.ps1 -Force                            revalidate even if the cache matches hardware+model
param(
  [string]$EngineDir = '',
  [string]$Prompt = '',
  [int]$Port = 8188,
  [switch]$SkipValidate,
  [switch]$NoShortcut,
  [switch]$NoDownload,
  [switch]$Force,
  [switch]$Generate,
  [switch]$CpuOnly
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = $PSScriptRoot
. (Join-Path $root 'lib\load.ps1')
foreach ($mp in Get-VidModulePaths $root) { . $mp }
$reportPath = Join-Path $root 'tuning_report.txt'

try {
  Write-VidLog "=== video-tuner $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="

  # 1. machine. Reading hardware never stops a running engine (dry-run rule from llama-tuner).
  $ramMB = Get-VidRamMB
  Write-VidLog ('RAM total: ' + [Math]::Round($ramMB / 1024, 1) + ' GB')
  $gpu = Get-VidGpuSummary
  if ($gpu) {
    Write-VidLog ('GPU x' + $gpu.Count + ': ' + (($gpu.List | ForEach-Object { "$($_.Name) $($_.TotalMB)MB (used $($_.UsedMB)MB)" }) -join '; '))
  } else {
    if (-not $CpuOnly -and (Test-VidNvidiaDevicePresent)) {
      Write-VidLog 'ERROR: NVIDIA GPU present at device level but nvidia-smi does not work - driver missing/broken.'
      Write-VidLog '       Install it (Windows Update optional updates, or nvidia.com/drivers), then re-run.'
      throw 'NVIDIA driver missing (GPU present, nvidia-smi unusable)'
    }
    Write-VidLog 'ERROR: no NVIDIA GPU. CPU-only Wan generation is not practical (hours per SECOND of video).'
    Write-VidLog '       This tool intentionally does not plan CPU video runs. AMD users: run ComfyUI manually.'
    throw 'no usable NVIDIA GPU for video generation'
  }
  $mem = Get-VidMemoryBudget
  Write-VidLog ('Commit budget: ' + [Math]::Round($mem.CommitLimitMB / 1024, 1) + ' GB limit / ' + [Math]::Round($mem.CommitFreeMB / 1024, 1) + ' GB free')

  # 2. engine (ComfyUI portable). Dry runs must never kill it; Start-VidEngine reuses if alive.
  $engineRoot = $EngineDir
  if ($engineRoot -and -not (Test-VidEngineRoot $engineRoot)) { throw ('-EngineDir is not a ComfyUI portable root: ' + $engineRoot) }
  if (-not $engineRoot) { $engineRoot = Get-VidEngineRoots $root }
  if (-not $engineRoot) {
    if ($NoDownload) { throw 'ComfyUI portable not found and -NoDownload set. Install it or pass -EngineDir.' }
    $engineRoot = Install-VidEngine $root
  }
  Write-VidLog ('engine: ' + $engineRoot)

  # 3. plan by hardware (pure), then intersect with what is actually on disk
  $plan = Get-VidPlan -VramMB ([int]$gpu.TotalMB) -RamMB ([int]$ramMB) -CommitFreeMB ([int]$mem.CommitFreeMB)
  if (-not $plan) {
    Write-VidLog 'ERROR: machine below every tier. Video generation needs at least 6 GB VRAM + 8 GB RAM.'
    Write-VidLog '       (Wan 2.1 1.3B at 480p is the floor; see README "hardware floor".)'
    throw 'hardware below all tiers'
  }
  Write-VidLog ('hardware plan: ' + $plan.Reason)

  $inv = Get-VidModelInventory $engineRoot
  Write-VidLog ('models on disk: ckpt=' + @($inv.Checkpts).Count + ' clip=' + @($inv.Clips).Count + ' vae=' + @($inv.Vaes).Count +
                '  ready=[' + ($inv.Ready -join ', ') + ']')
  $ready = Select-VidReadyTier $plan $inv
  if (-not $ready -and -not $NoDownload) {
    Write-VidLog ('downloading model set for ' + $plan.Pick.Model + ' (this is tens of GB, hours on slow links)...')
    Install-VidModels $engineRoot $plan.Pick.Model
    $inv = Get-VidModelInventory $engineRoot
    $ready = Select-VidReadyTier $plan $inv
  }
  if (-not $ready) {
    Write-VidLog 'ERROR: no runnable model set (need diffusion weights + umt5 text encoder + wan vae).'
    foreach ($m in @(Get-VidModelManifest $plan.Pick.Model)) { Write-VidLog ('  manual: ' + $m.url) }
    throw 'no runnable model set; place files under ComfyUI\models and re-run'
  }
  if ($ready.Id -ne $plan.Pick.Id) {
    Write-VidLog ('  plan downgraded to what is on disk: ' + $plan.Pick.Id + ' -> ' + $ready.Id + ' (' + $ready.Model + ')')
    $plan | Add-Member -Force NoteProperty Pick $ready
  }
  Write-VidLog ('working tier: ' + $ready.Id + ' ' + $ready.Model + ' ' + $ready.Res + '  ' + (Get-VidExpectation $ready))

  # 4. validate by ONE REAL reduced generation (unless cached or -SkipValidate)
  $gpuSig = $gpu.Sig
  $state = Read-VidState $root
  $cached = Test-VidPlanFresh $state $gpuSig $ready.Model $ready.Res
  if ($Generate) {
    Start-VidEngine -EngineRoot $engineRoot -Port $Port -VramMB ([int]$gpu.TotalMB) | Out-Null
    if (-not $cached -and -not $SkipValidate) {
      Write-VidLog 'no validated plan for this hardware+model: validating first (a real generation is cheaper to lose than hours)...'
      $vr = Invoke-VidValidatePlan -Plan $plan -Inv $inv -EngineRoot $engineRoot -Port $Port
      if (-not $vr.Ok) { foreach ($a in $vr.Attempts) { Write-VidLog ('  attempt ' + $a.Tier + ': ' + $(if ($a.Ok) { 'ok' } else { $a.Error })) }
        throw 'validation failed on every tier - see README hardware floor and manual fallback' }
      $plan | Add-Member -Force NoteProperty Pick $vr.Tier
      Set-VidPlanState $root $plan $true ('validated ' + $vr.Tier.Id)
    }
    if (-not $Prompt) { throw '-Generate needs -Prompt "..."' }
    Start-VidFullGeneration -Plan $plan -Inv $inv -Prompt $Prompt -Port $Port | Out-Null
  } elseif ($cached -and -not $Force) {
    Write-VidLog 'reusing validated plan (hardware and model unchanged; -Force to revalidate)'
  } elseif ($SkipValidate) {
    Write-VidLog 'DRY RUN: plan written, nothing was booted. Engine (if running) was NOT touched.'
    Set-VidPlanState $root $plan $false 'dry-run, not validated'
  } else {
    Start-VidEngine -EngineRoot $engineRoot -Port $Port -VramMB ([int]$gpu.TotalMB) | Out-Null
    $wfProbe = New-VidValidationWorkflow -Tier $plan.Pick -Inv $inv
    $nodes = Get-VidEngineNodes (Get-VidEngineBaseUrl $Port)
    $run = Test-VidWorkflowRunnable $wfProbe $nodes
    if (-not $run.Ok) {
      Write-VidLog ('ERROR: engine is missing nodes: ' + ($run.Missing -join ', '))
      Write-VidLog '       GGUF checkpoints need the ComfyUI-GGUF custom node pack: install ComfyUI-Manager then "Install (GGUF)".'
      throw 'missing custom nodes'
    }
    $vr = Invoke-VidValidatePlan -Plan $plan -Inv $inv -EngineRoot $engineRoot -Port $Port
    if (-not $vr.Ok) { foreach ($a in $vr.Attempts) { Write-VidLog ('  attempt ' + $a.Tier + ': ' + $(if ($a.Ok) { 'ok' } else { $a.Error })) }
      Write-VidLog 'HINT: repeated CUDA OOM on the 17-frame proof run usually means pagefile/RAM pressure - close big apps or enlarge the pagefile.'
      throw 'validation failed on every tier' }
    $plan | Add-Member -Force NoteProperty Pick $vr.Tier
    Set-VidPlanState $root $plan $true ('validated ' + $vr.Tier.Id + ' in ' + $vr.Seconds + 's')
  }

  # 5. artifacts
  Write-VidLaunchers $root $engineRoot $Port ([int]$gpu.TotalMB) ([bool]$NoShortcut)
  Write-VidLog ('expectation: ' + (Get-VidExpectation $plan.Pick))
  Write-VidLog '=== DONE. start_video_engine.cmd opens the UI; tune.ps1 -Generate -Prompt "..." renders a clip. ==='
  Save-VidLog $reportPath
} catch {
  Write-VidLog ('ERROR: ' + $_.Exception.Message)
  Write-VidLog 'Fix the issue and re-run tune.cmd'
  Save-VidLog $reportPath
  exit 1
}
