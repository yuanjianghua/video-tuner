# lib/plan.ps1 - PURE tier planner: hardware numbers in, plan out. No I/O, no WMI. ASCII-only.
#
# Budget is not just VRAM: a diffusion pipeline holds text encoder + weights + latents at once,
# and on small-RAM machines OS commit limit is what actually kills you (WDDM spills to pagefile).
# Each tier declares BOTH minimums; the planner refuses tiers the machine cannot honor.
#
# Ladder (decided 2026-11-24 with user; RAM prices at 6x make 14B a "post-upgrade" tier):
#   T0 wan2.1-t2v-1.3b      480p          6GB vram  /  8GB ram   entry, native 20 steps
#   T1 wan2.2-ti2v-5b Q4    480p  24fps  121f       8GB vram  / 16GB ram   + lightx2v 4-step
#   T2 wan2.2-ti2v-5b Q4    720p  24fps  121f       8GB vram  / 16GB ram   + lightx2v 4-step
#   T3 wan2.2-t2v-14b Q4    480p  16fps   81f       8GB vram  / 32GB ram   dual-model + 4-step x2
#   T4 wan2.2-t2v-14b Q4    720p  16fps   81f      12GB vram  / 32GB ram
#   T5 hunyuan1.5-t2v       480p  24fps  121f      16GB vram  / 32GB ram
# 14B tiers are gated at 32GB RAM ON PURPOSE: they do boot on 16GB but thrash the pagefile so
# hard that hour-long runs die mid-way. Locked until a (cheap-again) RAM upgrade, by design.

function Get-VidTiers {
  return @(
    [pscustomobject]@{ Id='T0'; Model='wan2.1-t2v-1.3b';     Kind='wan21';    Res='480p'; Fps=16; Frames=81;  VramMB=6000;  RamMB=8000;  Q='fp16';   Steps=20; Cfg=5.0; Shift=5; Sampler='uni_pc' }
    # 5B numbers = official ComfyUI template defaults (uni_pc/simple, shift 8 for 24fps). No 4-step
    # lightning lora exists for 5B in Comfy-ready form (verified 2026-11-24), so we do NOT fake one.
    [pscustomobject]@{ Id='T1'; Model='wan2.2-ti2v-5b-gguf'; Kind='wan22-5b'; Res='480p'; Fps=24; Frames=121; VramMB=8000;  RamMB=16000; Q='q4_k_s'; Steps=20; Cfg=5.0; Shift=8; Sampler='uni_pc' }
    [pscustomobject]@{ Id='T2'; Model='wan2.2-ti2v-5b-gguf'; Kind='wan22-5b'; Res='720p'; Fps=24; Frames=121; VramMB=8000;  RamMB=16000; Q='q4_k_s'; Steps=20; Cfg=5.0; Shift=8; Sampler='uni_pc' }
    # 14B: dual high/low noise + official lightx2v 4-step loras (v1.1, hi+lo, Comfy-Org repo).
    [pscustomobject]@{ Id='T3'; Model='wan2.2-t2v-14b-gguf'; Kind='wan22-t2v'; Res='480p'; Fps=16; Frames=81;  VramMB=8000;  RamMB=32000; Q='q4_k_s'; Steps=4;  Cfg=1.0; Shift=5; Sampler='euler' }
    [pscustomobject]@{ Id='T4'; Model='wan2.2-t2v-14b-gguf'; Kind='wan22-t2v'; Res='720p'; Fps=16; Frames=81;  VramMB=12000; RamMB=32000; Q='q4_k_s'; Steps=4;  Cfg=1.0; Shift=5; Sampler='euler' }
    [pscustomobject]@{ Id='T5'; Model='hunyuan1.5-t2v-480p'; Kind='hunyuan';  Res='480p'; Fps=24; Frames=121; VramMB=16000; RamMB=32000; Q='fp8';    Steps=50; Cfg=6.0; Shift=7; Sampler='uni_pc' }
  )
}

# Input: vramMB total, ramMB visible, commitFreeMB (0 = skip commit check). Output: best fit + list.
function Get-VidPlan {
  param([int]$VramMB, [int]$RamMB, [int]$CommitFreeMB = 0)
  $tiers = Get-VidTiers
  $fits = @()
  foreach ($t in $tiers) {
    $okVram = $VramMB -ge $t.VramMB
    $okRam  = $RamMB -ge $t.RamMB
    $okCom  = (-not $CommitFreeMB) -or ($CommitFreeMB -ge [int]($t.VramMB * 0.8))
    if ($okVram -and $okRam -and $okCom) {
      $fits += [pscustomobject]@{ Tier = $t; HeadroomMB = ($VramMB - $t.VramMB) }
    }
  }
  if ($fits.Count -eq 0) { return $null }
  $best = $fits | Sort-Object @{e = { $tiers.IndexOf($_.Tier) }}, @{e = { $_.HeadroomMB } } -Descending | Select-Object -First 1
  $blocked = @()
  foreach ($t in $tiers) {
    if ($RamMB -lt $t.RamMB -and $VramMB -ge $t.VramMB) { $blocked += ($t.Id + ' (needs ' + [math]::Round($t.RamMB / 1024) + ' GB RAM)') }
  }
  return [pscustomobject]@{
    Pick    = $best.Tier
    All     = $fits
    Blocked = $blocked
    VramMB  = $VramMB
    RamMB   = $RamMB
    Reason  = ('tier ' + $best.Tier.Id + ' (' + $best.Tier.Model + ' ' + $best.Tier.Res + ') vram>=' + $best.Tier.VramMB + 'MB ram>=' + $best.Tier.RamMB + 'MB')
  }
}

# Honest expectation text per tier (8GB laptop GPU anchors T0-T2; bigger cards scale down).
function Get-VidExpectation([object]$Tier) {
  switch ($Tier.Id) {
    'T0' { return 'T0 1.3B 480p: ~20-45 min per 5s clip. Entry tier; simple motion, soft detail. Close the browser anyway.' }
    'T1' { return 'T1 5B 480p 24fps (official 20-step): ~25-45 min per 5s clip on an 8GB laptop GPU. Best quality-per-GB on this box.' }
    'T2' { return 'T2 5B 720p 24fps: ~50-90 min per 5s clip. Fine at 16GB RAM; expect pagefile activity during encoder load.' }
    'T3' { return 'T3 14B 480p dual-model 4-step (lightx2v): ~15-30 min per clip WITH 32GB RAM. At 16GB RAM this tier is LOCKED (pagefile thrash kills long runs).' }
    'T4' { return 'T4 14B 720p 4-step: ~40-90 min per clip, wants 12GB+ VRAM and 32GB RAM.' }
    'T5' { return 'T5 Hunyuan 1.5 480p native sampling: ~1.5-3 h per clip, 16GB+ VRAM. Quality tier, not a speed tier.' }
    default { return 'No estimate for this tier.' }
  }
}

# Downgrade ladder for validate: after failing tier index i, try i-1, i-2 ...
function Get-VidDowngradeOrder([int]$TierIndex) {
  $n = (Get-VidTiers).Count
  if ($TierIndex -lt 0 -or $TierIndex -ge $n) { throw ('bad tier index ' + $TierIndex) }
  $order = @()
  for ($i = $TierIndex - 1; $i -ge 0; $i--) { $order += $i }
  return $order
}

# Resolution -> (width,height), Wan-friendly 16px multiples (16:9-ish).
function Get-VidResolution([string]$Res) {
  switch ($Res) {
    '480p'  { return @(832, 480) }
    '720p'  { return @(1280, 704) }
    '1080p' { return @(1920, 1088) }
    default { throw ('unknown resolution ' + $Res) }
  }
}
