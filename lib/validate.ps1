# lib/validate.ps1 - REAL end-to-end proof: start engine, run a reduced generation, measure.
# Philosophy copied from llama-tuner: never trust a plan we have not booted. A validation run is
# a REAL Wan generation at reduced cost (17 frames / few steps) - it proves the whole chain
# (weights load -> text encode -> denoise -> VAE decode -> save image) and exposes OOM within
# minutes instead of hours. Dry-run mode (-SkipValidate) must NEVER stop a running engine.

# Get-VidTiers() rebuilds objects per call; match a plan's tier by stable Id, not reference.
function Get-VidTierIndexById([string]$Id) {
  $tiers = Get-VidTiers
  for ($i = 0; $i -lt $tiers.Count; $i++) { if ($tiers[$i].Id -eq $Id) { return $i } }
  return -1
}
function Get-VidEngineBaseUrl([int]$Port) { return ('http://127.0.0.1:' + $Port) }

function Test-VidEngineHealth([int]$Port) {
  try {
    $r = Invoke-RestMethod (Get-VidEngineBaseUrl $Port + '/system_stats') -TimeoutSec 5
    return ($null -ne $r)
  } catch { return $false }
}

# Reuse a healthy engine; only (re)start when none answers. Same rule as llama-tuner cache hits.
function Start-VidEngine {
  param([string]$EngineRoot, [int]$Port = 8188, [int]$VramMB = 0)
  if (Test-VidEngineHealth $Port) {
    Write-VidLog ('engine already listening on ' + $Port + ' - reusing it (not restarting)')
    return $false
  }
  $py = Join-Path $EngineRoot 'python_embeded\python.exe'
  $mainPy = Join-Path $EngineRoot 'ComfyUI\main.py'
  $argl = @($mainPy, '--port', [string]$Port, '--windows-standalone-build')
  if ($VramMB -gt 0 -and $VramMB -lt 10000) { $argl += '--lowvram' }
  if ($VramMB -ge 10000 -and $VramMB -lt 14000) { $argl += '--normalvram' }
  Write-VidLog ('starting engine: port ' + $Port + $(if ($argl -contains '--lowvram') { ' --lowvram' } else { '' }))
  Start-Process -FilePath $py -ArgumentList $argl -WorkingDirectory (Split-Path $mainPy) -WindowStyle Minimized
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Seconds 2
    if (Test-VidEngineHealth $Port) { Write-VidLog 'engine is up'; return $true }
  }
  throw ('engine did not answer /system_stats within 120s - check the ComfyUI console window')
}

# Distill loras are OPTIONAL speed hardware for the 14B dual graph. Both-or-nothing:
# returns empty pair when tier is not 14B or files missing (caller falls back to native 20-step).
function Select-VidLoraForTier([object]$Tier, [object]$Inv) {
  if ($Tier.Kind -ne 'wan22-t2v') { return @{ High = ''; Low = '' } }
  if (-not $Inv.PSObject.Properties['Loras'] -or -not @($Inv.Loras).Count) { return @{ High = ''; Low = '' } }
  $pool = @($Inv.Loras | Where-Object { $_.Name -imatch 'lightx2v|turbo|distill' })
  $h = @($pool | Where-Object { $_.Name -imatch 'high' }) | Select-Object -First 1
  $l = @($pool | Where-Object { $_.Name -imatch 'low' }) | Select-Object -First 1
  if ($h -and $l) { return @{ High = $h.Name; Low = $l.Name } }
  return @{ High = ''; Low = '' }
}

# The reduced proof-run: same pipeline, deliberately tiny so failure is cheap (~1-3 min on 8GB).
function New-VidValidationWorkflow {
  param([object]$Tier, [object]$Inv)
  $ck = @(Select-VidCkptForTier $Tier $Inv)
  if (-not $ck) { throw ('no checkpoint on disk for tier ' + $Tier.Id + ' (' + $Tier.Model + ')') }
  if (-not $Inv.Clips.Count) { throw 'no umt5/t5 text encoder found under models/text_encoders' }
  $vae = Select-VidVaeForTier $Tier $Inv
  if (-not $vae) {
    throw ('no compatible vae on disk for tier ' + $Tier.Id + ' (place the matching wan vae under models/vae)')
  }
  # ckpt string: single model = 1 name; 14B dual = 'high;low' (builder delegates to dual graph).
  # If the low-noise weight is missing we still PROVE the chain via the equivalent single-sampler
  # graph (same loaders/encoder/decode path) - and say so out loud.
  $useKind = $Tier.Kind
  $ckStr = $ck[0].Name
  $lora = @{ High = ''; Low = '' }
  if ($Tier.Kind -eq 'wan22-t2v') {
    if (@($ck).Count -ge 2) {
      $ckStr = (($ck | Select-Object -First 2 | ForEach-Object { $_.Name }) -join ';')
      $lora = Select-VidLoraForTier $Tier $Inv
    } else {
      Write-VidLog '  NOTE: 14B low-noise weight missing - proving with single-sampler equivalent chain'
      $useKind = 'wan21'
    }
  }
  # proof size: small area, 17 frames ((17-1) % 4 == 0), 4 steps. Real chain end to end.
  return (New-VidWorkflowT2V -CkptName $ckStr -ClipName $Inv.Clips[0].Name -VaeName $vae.Name -Kind $useKind `
    -Prompt 'A small orange cat walking on a wooden table, cinematic lighting' `
    -Width 480 -Height 272 -Frames 17 -Steps 4 -Cfg $Tier.Cfg -Shift $Tier.Shift -Fps $Tier.Fps -Sampler $Tier.Sampler `
    -LoraHigh $lora.High -LoraLow $lora.Low)
}

# Tier -> checkpoint list, by tier.Kind. 14B tiers need BOTH high+low noise (high first).
function Select-VidCkptForTier([object]$Tier, [object]$Inv) {
  $pool = @($Inv.Checkpts)
  switch ([string]$Tier.Kind) {
    'wan21'     { $pool = @($pool | Where-Object { $_.Name -imatch '1[\.,]3' }) }
    'wan22-5b'  { $pool = @($pool | Where-Object { $_.Name -imatch 'ti2v|ti_2v|5B|5b' }) }
    'wan22-t2v' {
      $pool = @($pool | Where-Object { $_.Name -imatch '14B|A14B' })
      $q = @($pool | Where-Object { $_.Name -imatch 'Q4' })
      if ($q.Count) { $pool = $q }
      # deterministic order: high noise first (dual-model pass order)
      $pool = @($pool | Sort-Object @{e = { if ($_.Name -imatch 'high') { 0 } else { 1 } }})
    }
    'hunyuan'   { $pool = @($pool | Where-Object { $_.Name -imatch 'hunyuan' }) }
    default     { $pool = @() }
  }
  return $pool
}

# Wan 2.2 5B needs the 2.2 vae; 1.3B/14B use 2.1. WRONG VAE = garbage: hard pairing, no match -> null.
function Select-VidVaeForTier([object]$Tier, [object]$Inv) {
  $want = '2\.1'
  if ($Tier.Kind -eq 'wan22-5b') { $want = '2\.2' }
  if ($Tier.Kind -eq 'hunyuan') { $want = 'hunyuan' }
  $hit = @($Inv.Vaes | Where-Object { $_.Name -imatch $want }) | Select-Object -First 1
  return $hit
}

# Best hardware-fitting tier that ALSO has every file on disk; best-first, null if none runnable.
function Select-VidReadyTier([object]$Plan, [object]$Inv) {
  $cands = @($Plan.All | Sort-Object @{e = { Get-VidTierIndexById $_.Tier.Id } } -Descending | ForEach-Object { $_.Tier })
  foreach ($t in $cands) {
    if (-not $Inv.Clips.Count -or -not $Inv.Vaes.Count) { continue }
    if (@(Select-VidCkptForTier $t $Inv).Count) { return $t }
  }
  return $null
}

# One validation attempt -> @{ Ok; Seconds; Error }; never throws, OOM comes back as data to downgrade.
function Invoke-VidValidationRun {
  param([object]$Workflow, [int]$Port = 8188, [int]$TimeoutSec = 1800)
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $base = Get-VidEngineBaseUrl $Port
  $clientId = [guid]::NewGuid().ToString()
  $body = @{ prompt = $Workflow; client_id = $clientId } | ConvertTo-Json -Depth 20
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    $r = Invoke-RestMethod -Uri ($base + '/prompt') -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 30
  } catch {
    $msg = $_.ErrorDetails.Message
    if (-not $msg) { $msg = $_.Exception.Message }
    return @{ Ok = $false; Seconds = [int]$sw.Elapsed.TotalSeconds; Error = ('prompt rejected: ' + $msg) }
  }
  $pid_ = [string]$r.prompt_id
  $lastErr = ''
  while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
    Start-Sleep -Seconds 5
    $q = $null
    try { $q = Invoke-RestMethod ($base + '/queue') -TimeoutSec 10 } catch { continue }
    $running = @($q.running | ForEach-Object { $_ })
    $runningIds = @($running | ForEach-Object { [string]$_[0] })
    if ($runningIds -notcontains $pid_) {
      try {
        $h = Invoke-RestMethod ($base + '/history/' + $pid_) -TimeoutSec 10
      } catch { $lastErr = $_.Exception.Message; continue }
      $entry = $h.$pid_
      if ($null -eq $entry) {
        # gone from queue AND history with nothing posted back -> most likely killed mid-run (OOM)
        return @{ Ok = $false; Seconds = [int]$sw.Elapsed.TotalSeconds; Error = ('job vanished without history. ' + $lastErr) }
      }
      $st = $entry.status
      if ($st -and $st.status_str -and $st.status_str -ne 'success') {
        $det = ''
        foreach ($m in @($st.messages)) { $det += ($m | ConvertTo-Json -Depth 8 -Compress) + ' ' }
        return @{ Ok = $false; Seconds = [int]$sw.Elapsed.TotalSeconds; Error = ('status=' + $st.status_str + ' ' + $det) }
      }
      # success requires at least one saved output (SaveImage images / SaveVideo video)
      $sawSave = $false
      foreach ($np in $entry.PSObject.Properties) {
        if ($np.Value.outputs -and (@($np.Value.outputs.images).Count -or @($np.Value.outputs.video).Count)) { $sawSave = $true }
      }
      if ($sawSave) { return @{ Ok = $true; Seconds = [int]$sw.Elapsed.TotalSeconds; Error = '' } }
      return @{ Ok = $false; Seconds = [int]$sw.Elapsed.TotalSeconds; Error = 'finished but no image output (workflow wiring broken?)' }
    }
  }
  return @{ Ok = $false; Seconds = [int]$sw.Elapsed.TotalSeconds; Error = 'timeout waiting for generation' }
}

function Test-VidErrorIsMemory([string]$Err) {
  return ($Err -imatch 'out of memory|OOM|CUDA|allocat|page file|commit')
}

# Full loop: try planned tier; on memory failure walk the downgrade ladder.
# Returns @{ Ok; Tier; Attempts; Seconds }. Caller owns engine lifecycle.
function Invoke-VidValidatePlan {
  param([object]$Plan, [object]$Inv, [string]$EngineRoot, [int]$Port = 8188,
        [bool]$StopEngineAfter = $false, [int]$TimeoutSec = 1800)
  $idx = Get-VidTierIndexById $plan.Pick.Id
  if ($idx -lt 0) { throw 'plan tier missing from ladder' }
  $candidates = @($idx) + @(Get-VidDowngradeOrder $idx)
  $attempts = @()
  foreach ($i in $candidates) {
    $t = $tiers[$i]
    Write-VidLog ('validating tier ' + $t.Id + ' (' + $t.Model + ' ' + $t.Res + ')')
    try { $wf = New-VidValidationWorkflow -Tier $t -Inv $Inv }
    catch {
      Write-VidLog ('  cannot build: ' + $_.Exception.Message)
      $attempts += @{ Tier = $t.Id; Ok = $false; Error = 'build: ' + $_.Exception.Message }
      continue
    }
    $res = Invoke-VidValidationRun -Workflow $wf -Port $Port -TimeoutSec $TimeoutSec
    $attempts += @{ Tier = $t.Id; Ok = $res.Ok; Seconds = $res.Seconds; Error = $res.Error }
    if ($res.Ok) {
      Write-VidLog ('  OK in ' + $res.Seconds + 's (reduced proof run; full clip scales ~frames x steps)')
      return @{ Ok = $true; Tier = $t; Attempts = $attempts; Seconds = $res.Seconds }
    }
    Write-VidLog ('  failed: ' + $res.Error)
    if (-not (Test-VidErrorIsMemory $res.Error)) {
      # not a memory problem: downgrading tiers will not fix a wiring/missing-node bug
      if ($StopEngineAfter) { Stop-VidEngine }
      return @{ Ok = $false; Tier = $t; Attempts = $attempts; Seconds = $res.Seconds }
    }
  }
  if ($StopEngineAfter) { Stop-VidEngine }
  return @{ Ok = $false; Tier = $null; Attempts = $attempts; Seconds = 0 }
}

# Real generation at the validated tier's full settings. Reuses the same runner; timeout is
# hours because on an 8GB card a 14B clip honestly takes hours (we say so, we do not hide it).
function Start-VidFullGeneration {
  param([object]$Plan, [object]$Inv, [string]$Prompt, [int]$Port = 8188, [int]$TimeoutSec = 21600)
  $t = $Plan.Pick
  $ck = @(Select-VidCkptForTier $t $Inv)
  if (-not $ck) { throw ('no checkpoint for tier ' + $t.Id) }
  if (-not $Inv.Clips.Count) { throw 'text encoder missing' }
  $vae = Select-VidVaeForTier $t $Inv
  if (-not $vae) { throw ('matching wan vae missing for tier ' + $t.Id) }
  $wh = Get-VidResolution $t.Res
  $ckStr = $ck[0].Name
  $steps = $t.Steps; $cfg = $t.Cfg
  $lora = @{ High = ''; Low = '' }
  if ($t.Kind -eq 'wan22-t2v') {
    if (@($ck).Count -lt 2) { throw '14B full run needs BOTH high+low noise weights (run tune.cmd again to download the missing one)' }
    $ckStr = (($ck | Select-Object -First 2 | ForEach-Object { $_.Name }) -join ';')
    $lora = Select-VidLoraForTier $t $Inv
    if (-not $lora.High) {
      Write-VidLog '  NOTE: lightx2v 4-step loras missing -> official NATIVE sampling (20 steps, cfg 3.5), much slower'
      $steps = 20; $cfg = 3.5
    }
  }
  $wf = New-VidWorkflowT2V -CkptName $ckStr -ClipName $Inv.Clips[0].Name -VaeName $vae.Name -Kind $t.Kind `
    -Prompt $Prompt -Width $wh[0] -Height $wh[1] -Frames $t.Frames -Steps $steps -Cfg $cfg `
    -Shift $t.Shift -Fps $t.Fps -Sampler $t.Sampler -LoraHigh $lora.High -LoraLow $lora.Low
  Write-VidLog ('full run: ' + $t.Model + ' ' + $t.Res + ' ' + $t.Frames + ' frames x ' + $steps + ' steps cfg ' + $cfg)
  Write-VidLog ('  expectation: ' + (Get-VidExpectation $t))
  $res = Invoke-VidValidationRun -Workflow $wf -Port $Port -TimeoutSec $TimeoutSec
  if ($res.Ok) {
    Write-VidLog ('  done in ' + [int]($res.Seconds / 60) + ' min. Output: ComfyUI\output\vidtuner_*.mp4')
  } else {
    Write-VidLog ('  FAILED: ' + $res.Error)
  }
  return $res
}
