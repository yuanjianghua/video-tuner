# lib/workflows.ps1 - PURE ComfyUI workflow-JSON builders (API format). No I/O. ASCII-only.
#
# Node classes/wiring are GROUNDED against official ComfyUI templates pulled 2026-11-24
# (video_wan2_2_5B_ti2v.json et al.), not from memory:
#   single-model wan: UNETLoader|UnetLoaderGGUF -> ModelSamplingSD3(shift) -> KSampler
#                     -> VAEDecode -> CreateVideo(fps) -> SaveVideo   (mp4 out, all core nodes)
#   latent node differs by model gen: wan2.1/14B -> EmptyHunyuanLatentVideo (16ch)
#                                      wan2.2 5B -> Wan22ImageToVideoLatent (48ch, image optional)
#   text encoder: CLIPLoader(type='wan') / CLIPLoaderGGUF for GGUF umt5
#   GGUF loaders come from the ComfyUI-GGUF custom pack; everything else is core.
# Negative prompt = the official Chinese quality-negatives string (same one the templates ship).

function New-VidWorkflowT2V {
  param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$CkptName,
    [Parameter(Mandatory)][AllowEmptyString()][string]$ClipName,
    [Parameter(Mandatory)][AllowEmptyString()][string]$VaeName,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Prompt,
    [string]$Kind = 'wan21',
    [int]$Width = 832, [int]$Height = 480, [int]$Frames = 81,
    [int]$Steps = 20, [int]$Seed = 42, [double]$Cfg = 5.0, [double]$Shift = 8.0,
    [int]$Fps = 16, [string]$Sampler = 'uni_pc', [string]$Scheduler = 'simple',
    [string]$LoraHigh = '', [string]$LoraLow = '', [string]$ShiftArg = ''
  )
  if ($Kind -eq 'wan22-t2v') {
    # dual high/low-noise graph needs TWO ckpt names separated by ';'
    $parts = @($CkptName -split ';')
    if ($parts.Count -lt 2) { throw 'wan22-t2v (14B) needs "high.gguf;low.gguf" in -CkptName' }
    $sh = if ($ShiftArg -ne '') { [double]$ShiftArg } else { $Shift }
    return (New-VidWorkflowWan22Dual -CkptHigh $parts[0].Trim() -CkptLow $parts[1].Trim() -ClipName $ClipName -VaeName $VaeName `
        -Prompt $Prompt -Width $Width -Height $Height -Frames $Frames -Steps $Steps -Seed $Seed -Cfg $Cfg -Fps $Fps `
        -LoraHigh $LoraHigh -LoraLow $LoraLow -Shift $sh -Sampler $Sampler -Scheduler $Scheduler)
  }
  $sh2 = if ($ShiftArg -ne '') { [double]$ShiftArg } else { $Shift }
  if (-not $CkptName -or -not $ClipName -or -not $VaeName -or -not $Prompt) { throw 'workflow needs ckpt, clip, vae and prompt' }
  if ($Frames -lt 5 -or (($Frames - 1) % 4) -ne 0) { throw ("frames must be >= 5 and (n-1) % 4 == 0 for Wan temporal VAE, got $Frames") }
  if ($Width % 16 -ne 0 -or $Height % 16 -ne 0) { throw 'width/height must be multiples of 16' }

  # CN quality-negatives via \u escapes (source stays ASCII, PS5.1 codepage-safe)
  $neg = [regex]::Unescape('\u8272\u8c03\u8273\u4e3d\uff0c\u8fc7\u66dd\uff0c\u9759\u6001\uff0c\u7ec6\u8282\u6a21\u7cca\u4e0d\u6e05\uff0c\u5b57\u5e55\uff0c\u98ce\u683c\uff0c\u4f5c\u54c1\uff0c\u753b\u4f5c\uff0c\u753b\u9762\uff0c\u9759\u6b62\uff0c\u6574\u4f53\u53d1\u7070\uff0c\u6700\u5dee\u8d28\u91cf\uff0c\u4f4e\u8d28\u91cf\uff0cJPEG\u538b\u7f29\u6b8b\u7559\uff0c\u4e11\u964b\u7684\uff0c\u6b8b\u7f3a\u7684\uff0c\u591a\u4f59\u7684\u624b\u6307\uff0c\u753b\u5f97\u4e0d\u597d\u7684\u624b\u90e8\uff0c\u753b\u5f97\u4e0d\u597d\u7684\u8138\u90e8\uff0c\u7578\u5f62\u7684\uff0c\u6bc1\u5bb9\u7684\uff0c\u5f62\u6001\u7578\u5f62\u7684\u80a2\u4f53\uff0c\u624b\u6307\u878d\u5408\uff0c\u9759\u6b62\u4e0d\u52a8\u7684\u753b\u9762\uff0c\u6742\u4e71\u7684\u80cc\u666f\uff0c\u4e09\u6761\u817f\uff0c\u80cc\u666f\u4eba\u5f88\u591a\uff0c\u5012\u7740\u8d70')
  $g = [ordered]@{}
  if ($CkptName -match '\.gguf$') {
    $g['1'] = @{ class_type = 'UnetLoaderGGUF'; inputs = @{ unet_name = $CkptName } }
  } else {
    $g['1'] = @{ class_type = 'UNETLoader'; inputs = @{ unet_name = $CkptName; weight_dtype = 'default' } }
  }
  if ($ClipName -match '\.gguf$') {
    $g['2'] = @{ class_type = 'CLIPLoaderGGUF'; inputs = @{ clip_name = $ClipName; type = 'wan' } }
  } else {
    $g['2'] = @{ class_type = 'CLIPLoader'; inputs = @{ clip_name = $ClipName; type = 'wan' } }
  }
  $g['3'] = @{ class_type = 'VAELoader'; inputs = @{ vae_name = $VaeName } }
  $g['4'] = @{ class_type = 'CLIPTextEncode'; inputs = @{ text = $Prompt; clip = @('2', 0) } }
  $g['5'] = @{ class_type = 'CLIPTextEncode'; inputs = @{ text = $neg; clip = @('2', 0) } }
  if ($Kind -eq 'wan22-5b') {
    # 48-channel wan2.2 latent; image input deliberately unwired = pure text-to-video
    $g['6'] = @{ class_type = 'Wan22ImageToVideoLatent'; inputs = @{ width = $Width; height = $Height; length = $Frames; batch_size = 1 } }
  } else {
    $g['6'] = @{ class_type = 'EmptyHunyuanLatentVideo'; inputs = @{ width = $Width; height = $Height; length = $Frames; batch_size = 1 } }
  }
  $g['7'] = @{ class_type = 'ModelSamplingSD3'; inputs = @{ model = @('1', 0); shift = $sh2 } }
  $g['8'] = @{ class_type = 'KSampler'; inputs = @{
    model = @('7', 0); positive = @('4', 0); negative = @('5', 0); latent_image = @('6', 0)
    seed = $Seed; steps = $Steps; cfg = $Cfg; sampler_name = $Sampler; scheduler = $Scheduler; denoise = 1.0
  } }
  $g['9']  = @{ class_type = 'VAEDecode'; inputs = @{ samples = @('8', 0); vae = @('3', 0) } }
  $g['10'] = @{ class_type = 'CreateVideo'; inputs = @{ images = @('9', 0); fps = $Fps } }
  $g['11'] = @{ class_type = 'SaveVideo'; inputs = @{ video = @('10', 0); filename_prefix = 'vidtuner' } }
  return $g
}

# 14B T2V dual-noise-expert graph, GROUNDED against official template
# video_wan2_2_14B_t2v.json (2026-11-24): two UNETLoaders -> optional LoraLoaderModelOnly(hi/lo)
# -> ModelSamplingSD3(shift) x2 -> KSamplerAdvanced pass1 (add_noise enable, 0..steps/2, leftover
# enable) -> KSamplerAdvanced pass2 (add_noise disable, steps/2..steps) -> VAEDecode -> video out.
# Turbo mode = lightx2v 4-step loras, cfg 1; native fallback = no loras, steps 20, cfg 3.5
# (both parameter sets are the template's own two switch positions).
function New-VidWorkflowWan22Dual {
  param(
    [string]$CkptHigh, [string]$CkptLow, [string]$ClipName, [string]$VaeName, [string]$Prompt,
    [int]$Width = 832, [int]$Height = 480, [int]$Frames = 81,
    [int]$Steps = 4, [int]$Seed = 42, [double]$Cfg = 1.0, [int]$Fps = 16,
    [string]$LoraHigh = '', [string]$LoraLow = '', [double]$Shift = 5.0,
    [string]$Sampler = 'euler', [string]$Scheduler = 'simple'
  )
  if (-not $CkptHigh -or -not $CkptLow -or -not $ClipName -or -not $VaeName -or -not $Prompt) { throw 'dual workflow needs high+low ckpt, clip, vae, prompt' }
  if ($Frames -lt 5 -or (($Frames - 1) % 4) -ne 0) { throw ("frames must satisfy (n-1) % 4 == 0, got $Frames") }
  if ($Width % 16 -ne 0 -or $Height % 16 -ne 0) { throw 'width/height must be multiples of 16' }
  if ($Steps -lt 2) { throw 'dual pass needs >= 2 steps to split' }
  if ((-not $LoraHigh -and $LoraLow) -or ($LoraHigh -and -not $LoraLow)) { throw 'lora: give BOTH high+low or neither' }
  # CN quality-negatives via \u escapes (source stays ASCII, PS5.1 codepage-safe)
  $neg = [regex]::Unescape('\u8272\u8c03\u8273\u4e3d\uff0c\u8fc7\u66dd\uff0c\u9759\u6001\uff0c\u7ec6\u8282\u6a21\u7cca\u4e0d\u6e05\uff0c\u5b57\u5e55\uff0c\u98ce\u683c\uff0c\u4f5c\u54c1\uff0c\u753b\u4f5c\uff0c\u753b\u9762\uff0c\u9759\u6b62\uff0c\u6574\u4f53\u53d1\u7070\uff0c\u6700\u5dee\u8d28\u91cf\uff0c\u4f4e\u8d28\u91cf\uff0cJPEG\u538b\u7f29\u6b8b\u7559\uff0c\u4e11\u964b\u7684\uff0c\u6b8b\u7f3a\u7684\uff0c\u591a\u4f59\u7684\u624b\u6307\uff0c\u753b\u5f97\u4e0d\u597d\u7684\u624b\u90e8\uff0c\u753b\u5f97\u4e0d\u597d\u7684\u8138\u90e8\uff0c\u7578\u5f62\u7684\uff0c\u6bc1\u5bb9\u7684\uff0c\u5f62\u6001\u7578\u5f62\u7684\u80a2\u4f53\uff0c\u624b\u6307\u878d\u5408\uff0c\u9759\u6b62\u4e0d\u52a8\u7684\u753b\u9762\uff0c\u6742\u4e71\u7684\u80cc\u666f\uff0c\u4e09\u6761\u817f\uff0c\u80cc\u666f\u4eba\u5f88\u591a\uff0c\u5012\u7740\u8d70')
  $g = [ordered]@{}
  foreach ($pair in @(@('1', $CkptHigh), @('2', $CkptLow))) {
    if ($pair[1] -match '\.gguf$') {
      $g[$pair[0]] = @{ class_type = 'UnetLoaderGGUF'; inputs = @{ unet_name = $pair[1] } }
    } else {
      $g[$pair[0]] = @{ class_type = 'UNETLoader'; inputs = @{ unet_name = $pair[1]; weight_dtype = 'default' } }
    }
  }
  # model chain per expert: loader -> [lora] -> shift
  if ($LoraHigh) {
    $g['3'] = @{ class_type = 'LoraLoaderModelOnly'; inputs = @{ model = @('1', 0); lora_name = $LoraHigh; strength_model = 1.0 } }
    $g['4'] = @{ class_type = 'LoraLoaderModelOnly'; inputs = @{ model = @('2', 0); lora_name = $LoraLow; strength_model = 1.0 } }
    $g['5'] = @{ class_type = 'ModelSamplingSD3'; inputs = @{ model = @('3', 0); shift = $Shift } }
    $g['6'] = @{ class_type = 'ModelSamplingSD3'; inputs = @{ model = @('4', 0); shift = $Shift } }
  } else {
    $g['5'] = @{ class_type = 'ModelSamplingSD3'; inputs = @{ model = @('1', 0); shift = $Shift } }
    $g['6'] = @{ class_type = 'ModelSamplingSD3'; inputs = @{ model = @('2', 0); shift = $Shift } }
  }
  if ($ClipName -match '\.gguf$') {
    $g['7'] = @{ class_type = 'CLIPLoaderGGUF'; inputs = @{ clip_name = $ClipName; type = 'wan' } }
  } else {
    $g['7'] = @{ class_type = 'CLIPLoader'; inputs = @{ clip_name = $ClipName; type = 'wan' } }
  }
  $g['8']  = @{ class_type = 'VAELoader'; inputs = @{ vae_name = $VaeName } }
  $g['9']  = @{ class_type = 'CLIPTextEncode'; inputs = @{ text = $Prompt; clip = @('7', 0) } }
  $g['10'] = @{ class_type = 'CLIPTextEncode'; inputs = @{ text = $neg; clip = @('7', 0) } }
  $g['11'] = @{ class_type = 'EmptyHunyuanLatentVideo'; inputs = @{ width = $Width; height = $Height; length = $Frames; batch_size = 1 } }
  $split = [int][math]::Ceiling($Steps / 2)
  $g['12'] = @{ class_type = 'KSamplerAdvanced'; inputs = @{
    model = @('5', 0); positive = @('9', 0); negative = @('10', 0); latent_image = @('11', 0)
    add_noise = 'enable'; noise_seed = $Seed; steps = $Steps; cfg = $Cfg
    sampler_name = $Sampler; scheduler = $Scheduler; start_at_step = 0; end_at_step = $split
    return_with_leftover_noise = 'enable'
  } }
  $g['13'] = @{ class_type = 'KSamplerAdvanced'; inputs = @{
    model = @('6', 0); positive = @('9', 0); negative = @('10', 0); latent_image = @('12', 0)
    add_noise = 'disable'; noise_seed = 0; steps = $Steps; cfg = $Cfg
    sampler_name = $Sampler; scheduler = $Scheduler; start_at_step = $split; end_at_step = $Steps
    return_with_leftover_noise = 'disable'
  } }
  $g['14'] = @{ class_type = 'VAEDecode'; inputs = @{ samples = @('13', 0); vae = @('8', 0) } }
  $g['15'] = @{ class_type = 'CreateVideo'; inputs = @{ images = @('14', 0); fps = $Fps } }
  $g['16'] = @{ class_type = 'SaveVideo'; inputs = @{ video = @('15', 0); filename_prefix = 'vidtuner' } }
  return $g
}

function Get-VidRequiredNodes([object]$Workflow) {
  $need = New-Object System.Collections.Generic.HashSet[string]
  foreach ($k in $Workflow.Keys) { [void]$need.Add([string]$Workflow[$k].class_type) }
  return @($need)
}

# Core (custom-node-free) class types our builders may emit.
function Get-VidCoreNodes {
  return @('UNETLoader', 'CLIPLoader', 'VAELoader', 'CLIPTextEncode', 'EmptyHunyuanLatentVideo',
           'Wan22ImageToVideoLatent', 'ModelSamplingSD3', 'KSampler', 'KSamplerAdvanced',
           'LoraLoaderModelOnly', 'VAEDecode', 'CreateVideo', 'SaveVideo', 'CheckpointLoaderSimple')
}
# Class types that require the ComfyUI-GGUF custom node pack.
function Get-VidGgufNodes { return @('UnetLoaderGGUF', 'CLIPLoaderGGUF') }

function Get-VidWorkflowKinds { return @('t2v') }
