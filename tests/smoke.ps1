# tests/smoke.ps1 - behavior regressions for video-tuner, offline (no network, no engine). ASCII-only.
# Run: tests\all.cmd  (arch.ps1 first, then this).
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'lib\load.ps1')
foreach ($mp in @(Get-VidModulePaths $root)) { . $mp }

$script:pass = 0
$script:failList = @()
function Assert-Ok([bool]$cond, [string]$name) {
  if ($cond) { $script:pass++; Write-Host ('PASS  ' + $name) }
  else { $script:failList += $name; Write-Host ('FAIL  ' + $name) }
}
function Assert-Throws([scriptblock]$block, [string]$name) {
  $threw = $false
  try { & $block | Out-Null } catch { $threw = $true }
  Assert-Ok $threw $name
}

$tmp = Join-Path $env:TEMP ('vidtuner_smoke_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
  # ---------- plan: ladder + gates ----------
  $tiers = Get-VidTiers
  Assert-Ok ($tiers.Count -eq 6) 'ladder has 6 tiers'
  Assert-Ok (($tiers | ForEach-Object { $_.Id }) -join ',' -eq 'T0,T1,T2,T3,T4,T5') 'tier ids sequential T0..T5'

  # the user's machine: 8192 vram / 16384 ram -> best runnable is T2 (5B 720p, 4-step)
  $p = Get-VidPlan -VramMB 8192 -RamMB 16384
  Assert-Ok ($p.Pick.Id -eq 'T2') ('8GB vram + 16GB ram picks T2 (got ' + $p.Pick.Id + ')')
  Assert-Ok (@($p.Blocked | Where-Object { $_ -imatch '^T3' }).Count -eq 1) '14B T3 is RAM-locked at 16GB and REPORTED as blocked'
  $p12 = Get-VidPlan -VramMB 12288 -RamMB 16384
  Assert-Ok ((@($p12.Blocked | ForEach-Object { $_.Substring(0, 2) }) -join ',') -eq 'T3,T4') 'at 12GB vram the two 32GB-RAM 14B tiers are both reported blocked'

  $p0 = Get-VidPlan -VramMB 6144 -RamMB 8192
  Assert-Ok ($p0.Pick.Id -eq 'T0') '6GB vram floor picks T0'
  Assert-Ok ($null -eq (Get-VidPlan -VramMB 4096 -RamMB 8192)) 'below 6GB vram: no plan (honest refusal)'
  $p3 = Get-VidPlan -VramMB 8192 -RamMB 32768
  Assert-Ok ($p3.Pick.Id -eq 'T3') ('32GB RAM unlocks T3 (got ' + $p3.Pick.Id + ')')
  $p5 = Get-VidPlan -VramMB 16384 -RamMB 32768
  Assert-Ok ($p5.Pick.Id -eq 'T5') '16GB vram + 32GB ram picks T5'

  # commit budget veto: free commit under 0.8x a tier's vram rejects THAT tier (T0 needs 4800)
  $pc = Get-VidPlan -VramMB 8192 -RamMB 32768 -CommitFreeMB 5000
  Assert-Ok ($pc.Pick.Id -eq 'T0') 'low commit budget downgrades 14B pick to T0'

  # every tier: expectation non-empty + resolution legal + frames rule legal
  foreach ($t in $tiers) {
    Assert-Ok ((Get-VidExpectation $t).Length -gt 20) ('expectation text for ' + $t.Id)
    $wh = Get-VidResolution $t.Res
    Assert-Ok ($wh[0] % 16 -eq 0 -and $wh[1] % 16 -eq 0) ('resolution of ' + $t.Id + ' is 16px multiple')
    Assert-Ok ((($t.Frames - 1) % 4) -eq 0) ('frames of ' + $t.Id + ' satisfies (n-1)%4==0')
  }

  $dg = Get-VidDowngradeOrder 3
  Assert-Ok (($dg -join ',') -eq '2,1,0') 'downgrade ladder from index 3 is 2,1,0'
  Assert-Throws { Get-VidDowngradeOrder 9 } 'bad tier index rejected'

  # Get-VidTiers() rebuilds its objects on every call; a plan holds tiers from an older call.
  Assert-Ok ((Get-VidTierIndexById 'T0') -eq 0) 'tier index by Id: T0 = 0'
  Assert-Ok ((Get-VidTierIndexById 'T2') -eq 2) 'tier index by Id works across Get-VidTiers calls'
  Assert-Ok ((Get-VidTierIndexById 'NOPE') -eq -1) 'unknown tier Id = -1'

  # missing model = a failed attempt, not a crash on a null tier array
  $emptyInv = [pscustomobject]@{ Checkpts=@(); Clips=@(); Vaes=@(); Ready=@() }
  $fakePlan = [pscustomobject]@{ Pick = ([pscustomobject]@{ Id = 'T0' }) }
  $vr0 = Invoke-VidValidatePlan -Plan $fakePlan -Inv $emptyInv
  Assert-Ok ((-not $vr0.Ok) -and ($vr0.Attempts.Count -eq 1)) 'validate with no models reports failed attempt, no null-index crash'

  # ComfyUI /queue items are [number, prompt_id, ...]; reading index 0 made long jobs look vanished.
  $runJob = [object[]]@(7, 'pid-running', @{}, @{})
  $pendJob = [object[]]@(8, 'pid-pending', @{}, @{})
  $runArr = [object[]]::new(1); $runArr[0] = $runJob
  $pendArr = [object[]]::new(1); $pendArr[0] = $pendJob
  $fakeQueue = [pscustomobject]@{ queue_running = $runArr; queue_pending = $pendArr }
  Assert-Ok ((@(Get-VidBusyPromptIds $fakeQueue) -join ',') -eq 'pid-running,pid-pending') 'queue prompt id read from index 1, not queue number'

  # ---------- workflows: structural rules ----------
  Assert-Throws { New-VidWorkflowT2V -CkptName '' -ClipName c -VaeName v -Prompt p } 'empty ckpt name rejected'
  Assert-Throws { New-VidWorkflowT2V -CkptName a.gguf -ClipName c -VaeName v -Prompt p -Frames 80 } 'frames 80 rejected ((n-1)%4 rule)'
  Assert-Throws { New-VidWorkflowT2V -CkptName a.gguf -ClipName c -VaeName v -Prompt p -Width 830 } 'width 830 rejected (%16 rule)'
  $wf = New-VidWorkflowT2V -CkptName 'wan2.1_t2v_1.3B_fp16.safetensors' -ClipName 'umt5.safetensors' -VaeName 'wan_2.1_vae.safetensors' -Prompt 'cat'
  $nodes = @(Get-VidRequiredNodes $wf)
  Assert-Ok ($nodes -contains 'UNETLoader') 'safetensors ckpt uses core UNETLoader'
  Assert-Ok ($nodes -notcontains 'UnetLoaderGGUF') 'safetensors does NOT pull GGUF node'
  $wfG = New-VidWorkflowT2V -CkptName 'x_Q4_K_S.gguf' -ClipName 'umt5.safetensors' -VaeName 'v.safetensors' -Prompt 'cat'
  $nodesG = @(Get-VidRequiredNodes $wfG)
  Assert-Ok ($nodesG -contains 'UnetLoaderGGUF') 'gguf ckpt uses UnetLoaderGGUF'
  $gg = @(Get-VidGgufNodes)
  Assert-Ok (@((Get-VidCoreNodes) | Where-Object { $gg -contains $_ }).Count -eq 0) 'core and gguf node sets are disjoint'

  # ComfyUI v0.46 SaveVideo has a REQUIRED format input; missing it kills a real run at the last node.
  foreach ($svk in @($wf.Keys | Where-Object { $wf[$_].class_type -eq 'SaveVideo' })) {
    Assert-Ok ($wf[$svk].inputs['format'] -eq 'auto' -and $wf[$svk].inputs['codec'].codec -eq 'auto') 'single workflow SaveVideo has format+codec from official template'
  }
  $wfD = New-VidWorkflowWan22Dual -CkptHigh 'h.gguf' -CkptLow 'l.gguf' -ClipName 'c' -VaeName 'v' -Prompt 'cat'
  foreach ($svk in @($wfD.Keys | Where-Object { $wfD[$_].class_type -eq 'SaveVideo' })) {
    Assert-Ok ($wfD[$svk].inputs['format'] -eq 'auto' -and $wfD[$svk].inputs['codec'].codec -eq 'auto') 'dual workflow SaveVideo has format+codec from official template'
  }

  # ---------- compose: storyboard + concat list ----------
  $tl = @(New-VidComposeTimeline -ClipCount 3 -Prompt 'cat')
  Assert-Ok ($tl.Count -eq 3) 'compose timeline makes 3 clips'
  Assert-Ok ((@($tl | ForEach-Object { $_.Seed }) -join ',') -eq '42,143,244') 'compose clips use distinct seeds'
  Assert-Ok ($tl[0].Frames -eq 49 -and $tl[0].Width -eq 1280 -and $tl[0].Height -eq 720 -and $tl[0].Steps -eq 12) 'compose clip is 3s 720p / 12 steps'
  Assert-Throws { New-VidComposeTimeline -ClipCount 1 -Prompt 'cat' } 'compose rejects a 1-clip story'
  Assert-Ok ((Get-VidDefaultNarration).Length -gt 10) 'default zh narration is present'
  $seedA = Get-VidRunSeed ([datetime]'2026-11-25 05:00:00')
  $seedB = Get-VidRunSeed ([datetime]'2026-11-25 05:00:01')
  Assert-Ok ($seedA -ne $seedB -and $seedA -ge 0 -and $seedB -ge 0) 'compose run seed changes with time (defeats ComfyUI cache)'
  $concat = New-VidConcatList @('C:\a.mp4', 'C:\b.mp4')
  Assert-Ok ($concat -match "file 'C:\\a\.mp4'" -and $concat -match "file 'C:\\b\.mp4'") 'ffmpeg concat list quotes each clip'

  # ---------- workflow JSON is persisted for reproduction ----------
  $wfDir = Join-Path $env:TEMP ('vidtuner_wf_' + [guid]::NewGuid().ToString('N'))
  $wfOne = @{ '1' = @{ class_type = 'UNETLoader'; inputs = @{ unet_name = 'unit.gguf' } } }
  $savedWf = Save-VidWorkflowJson -Workflow $wfOne -Dir $wfDir -Tag 'unittest' -ClientId 'fixed-client'
  Assert-Ok (Test-Path $savedWf) 'workflow json is saved to disk'
  $wfJson = Get-Content $savedWf -Raw | ConvertFrom-Json
  Assert-Ok ($wfJson.client_id -eq 'fixed-client' -and $wfJson.prompt.'1'.class_type -eq 'UNETLoader') 'saved workflow keeps API prompt + client id'
  Remove-Item $wfDir -Recurse -Force

  # ---------- checkpoint selection by tier.Kind ----------
  $fakeInv = [pscustomobject]@{
    Checkpts = @(
      @{ Name = 'wan2.1_t2v_1.3B_fp16.safetensors'; Length = 3GB },
      @{ Name = 'wan2.2_ti2v_5B_Q4_K_S.gguf';       Length = 5GB },
      @{ Name = 'wan2.2_t2v_high_noise_14B_Q4_K_S.gguf'; Length = 9GB },
      @{ Name = 'wan2.2_t2v_low_noise_14B_Q4_K_S.gguf';  Length = 9GB },
      @{ Name = 'hunyuan15_i2v_fp8_e4m3fn.safetensors';  Length = 14GB }
    )
    Clips = @(@{ Name = 'umt5_xxl_fp8_e4m3fn_scaled.safetensors' })
    Vaes  = @(@{ Name = 'wan_2.1_vae.safetensors' }, @{ Name = 'wan2.2_vae.safetensors' })
  }
  $t1 = $tiers | Where-Object { $_.Id -eq 'T1' }
  $sel1 = @(Select-VidCkptForTier $t1 $fakeInv)
  Assert-Ok ($sel1.Count -eq 1 -and $sel1[0].Name -imatch '5B') 'T1 selects the 5B ti2v gguf'
  $t3 = $tiers | Where-Object { $_.Id -eq 'T3' }
  $sel3 = @(Select-VidCkptForTier $t3 $fakeInv)
  Assert-Ok ($sel3.Count -eq 2 -and (@($sel3 | Where-Object { $_.Name -imatch 'Q4' }).Count -eq 2)) 'T3 selects BOTH 14B quants (dual-model)'
  $t0 = $tiers | Where-Object { $_.Id -eq 'T0' }
  $sel0 = @(Select-VidCkptForTier $t0 $fakeInv)
  Assert-Ok ($sel0.Count -eq 1 -and $sel0[0].Name -imatch '1.3B') 'T0 selects 1.3B only'

  # vae pairing: wan2.2 latents need the wan2.2 vae; wan2.1 needs the 2.1 vae
  $v22 = Select-VidVaeForTier $t1 $fakeInv
  Assert-Ok ($v22.Name -imatch '2\.2') 'T1 pairs wan2.2 vae'
  $v21 = Select-VidVaeForTier $t0 $fakeInv
  Assert-Ok ($v21.Name -imatch '2\.1') 'T0 pairs wan2.1 vae'

  # ---------- error classification (memory vs wiring) ----------
  Assert-Ok (Test-VidErrorIsMemory 'CUDA out of memory. Tried to allocate 2.00 GiB') 'CUDA OOM classified as memory'
  Assert-Ok (Test-VidErrorIsMemory 'Failed to commit page file region') 'pagefile failure = memory'
  Assert-Ok (-not (Test-VidErrorIsMemory 'value not in list: sampler')) 'bad enum = wiring, not memory'

  # ---------- state: cache matrix ----------
  $stRoot = Join-Path $tmp 'st'
  New-Item -ItemType Directory -Force -Path $stRoot | Out-Null
  $planObj = [pscustomobject]@{ Pick = $t1; VramMB = 8192; RamMB = 16384; GpuSig = 'sigA' }
  Set-VidPlanState $stRoot $planObj $true 'smoke'
  $st = Read-VidState $stRoot
  Assert-Ok (Test-VidPlanFresh $st 'sigA' 'wan2.2-ti2v-5b-gguf' '480p') 'fresh cache matches sig+model+res'
  Assert-Ok (-not (Test-VidPlanFresh $st 'sigB' 'wan2.2-ti2v-5b-gguf' '480p')) 'different GPU sig invalidates'
  Assert-Ok (-not (Test-VidPlanFresh $st 'sigA' 'wan2.1-t2v-1.3b' '480p')) 'different model invalidates'
  Assert-Ok (-not (Test-VidPlanFresh $st 'sigA' 'wan2.2-ti2v-5b-gguf' '720p')) 'different resolution invalidates'
  Assert-Ok (-not (Test-VidPlanFresh $null 'sigA' 'x' 'y')) 'null state never fresh'
  # dry-run (validated=false) must NEVER be reused as validated
  Set-VidPlanState $stRoot $planObj $false 'dry'
  Assert-Ok (-not (Test-VidPlanFresh (Read-VidState $stRoot) 'sigA' 'wan2.2-ti2v-5b-gguf' '480p')) 'dry-run state never counts as fresh'

  # ---------- common: log ----------
  Write-VidLog 'smoke line'
  $logP = Join-Path $tmp 'log.txt'
  Save-VidLog $logP
  Assert-Ok ((Get-Content $logP -Raw) -imatch 'smoke line') 'log saved to disk'
  Assert-Ok (-not (Test-VidEngineHealth 1)) 'health probe: closed port is not healthy (no engine needed)'

  # ---------- discover: pure-ish helpers ----------
  Assert-Ok (-not (Test-VidEngineRoot (Join-Path $tmp 'nope'))) 'fake engine root rejected'
  $free = Get-VidFreeDiskGB $tmp
  Assert-Ok ($free -gt 0) ('free disk probe returns GB (got ' + $free + ')')
  Assert-Ok (@(Find-VidFiles @((Join-Path $tmp 'nodir')) 'x').Count -eq 0) 'Find-VidFiles on missing dir = empty, no throw'
  $req = [pscustomobject]@{ class_type = 'KSampler' }
  $check = Test-VidWorkflowRunnable @{ a = $req } @('KSampler', 'SaveImage')
  Assert-Ok ($check.Ok) 'workflow with present nodes passes runnable check'
  $check2 = Test-VidWorkflowRunnable @{ a = $req } @('SaveImage')
  Assert-Ok (-not $check2.Ok -and $check2.Missing -contains 'KSampler') 'missing node reported by name'

  # ---------- launcher bodies ----------
  $b8 = New-VidLauncherBodies 'D:\Apps\ComfyUI' 8188 8192
  Assert-Ok ($b8.Start -imatch '--lowvram') '8GB vram gets --lowvram flag'
  Assert-Ok ($b8.Start -imatch '--port 8188') 'port embedded in start body'
  Assert-Ok ($b8.Stop -imatch 'Stop-Process' -and $b8.Stop -imatch 'ComfyUI') 'stop kills by ComfyUI main.py command line'
  Assert-Ok ($b8.Stop -imatch [regex]::Escape('$_.CommandLine')) 'kill filter survives build-time interpolation verbatim'
  Assert-Ok ($b8.Stop -notmatch 'taskkill /im python') 'never taskkills bare python.exe'
  $b16 = New-VidLauncherBodies 'D:\Apps\ComfyUI' 8188 16384
  Assert-Ok ($b16.Start -notmatch '--lowvram') '16GB vram card NOT forced to --lowvram'

  # ---------- grounded release snapshot (API-outage fallback) ----------
  $snapPath = Join-Path $root 'data\engine_release.json'
  Assert-Ok (Test-Path $snapPath) 'verified engine release snapshot is bundled'
  $snap = $null
  try { $snap = ([IO.File]::ReadAllText($snapPath) | ConvertFrom-Json) } catch {}
  Assert-Ok ($snap -and $snap.tag_name -match '^v\d+\.\d+\.\d+$') 'snapshot has a real release tag'
  Assert-Ok ($snap -and @($snap.assets).Count -gt 0 -and $snap.assets[0].name -match '\.7z$') 'snapshot has a real portable asset name'
  Assert-Ok (-not (Select-String -Path $snapPath -Pattern '^\s*#').Count) 'snapshot is pure JSON (no comment lines to break ConvertFrom-Json)'
} finally {
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ('=== smoke: ' + $script:pass + ' passed, ' + $script:failList.Count + ' failed ===')
if ($script:failList.Count -gt 0) { $script:failList | ForEach-Object { Write-Host ('  FAILED: ' + $_) }; exit 1 }
exit 0
