# lib/compose.ps1 - multi-clip story: N short 720p clips -> ffmpeg concat -> Chinese voiceover.
# Core tool stays zero-dependency PowerShell; this stage reuses ffmpeg from PATH and Windows SAPI.
# ASCII-only source (Chinese default narration via \u escapes).

function Get-VidDefaultNarration {
  return [regex]::Unescape('\u4e00\u53ea\u6a58\u732b\u5728\u6728\u684c\u4e0a\u6563\u6b65\uff0c\u9633\u5149\u6e29\u6696\uff0c\u50cf\u4e00\u6bb5\u5b89\u9759\u7684\u7eaa\u5f55\u7247\u3002')
}

# A fresh base seed per run prevents ComfyUI from caching a prior identical prompt and
# silently skipping SaveVideo (history says success, but no new mp4 is written).
function Get-VidRunSeed([datetime]$When) { return [int]($When.Ticks % 1000003) }

# Fixed 3-second clip: 49 frames at 16fps ((49-1)%4==0), 12 steps, 1280x720 (both %16==0).
function New-VidComposeTimeline {
  param([int]$ClipCount = 3, [string]$Prompt, [int]$BaseSeed = 42)
  if ($ClipCount -lt 2 -or $ClipCount -gt 12) { throw 'compose needs 2-12 clips' }
  if (-not $Prompt) { throw 'compose needs a prompt' }
  $specs = @()
  for ($i = 0; $i -lt $ClipCount; $i++) {
    $specs += [pscustomobject]@{
      Index = $i + 1; Prompt = $Prompt; Seed = $BaseSeed + ($i * 101)
      Width = 1280; Height = 720; Frames = 49; Steps = 12
    }
  }
  return $specs
}

function New-VidConcatList {
  param([string[]]$Paths)
  $lines = @()
  foreach ($p in @($Paths)) {
    if (-not $p) { throw 'empty clip path in concat list' }
    $esc = $p.Replace("'", "'\''")
    $lines += "file '" + $esc + "'"
  }
  return ($lines -join "`n")
}

function Invoke-VidClipBatch {
  param([object[]]$Timeline, [object]$Tier, [object]$Inv, [string]$OutputDir,
        [int]$Port = 8188, [int]$TimeoutSec = 7200)
  $ck = @(Select-VidCkptForTier $Tier $Inv)
  if (-not $ck.Count) { throw ('no checkpoint for tier ' + $Tier.Id) }
  if (-not $Inv.Clips.Count) { throw 'text encoder missing' }
  $vae = Select-VidVaeForTier $Tier $Inv
  if (-not $vae) { throw ('matching vae missing for tier ' + $Tier.Id) }
  if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }
  $made = @()
  foreach ($spec in $Timeline) {
    Write-VidLog ('compose: clip ' + $spec.Index + '/' + $Timeline.Count + ' seed=' + $spec.Seed + ' (3s 720p)')
    $before = @(Get-ChildItem $OutputDir -Filter 'vidtuner*.mp4' | ForEach-Object { $_.FullName })
    $wf = New-VidWorkflowT2V -CkptName $ck[0].Name -ClipName $Inv.Clips[0].Name -VaeName $vae.Name `
      -Kind $Tier.Kind -Prompt $spec.Prompt -Width $spec.Width -Height $spec.Height `
      -Frames $spec.Frames -Steps $spec.Steps -Cfg $Tier.Cfg -Shift $Tier.Shift -Fps $Tier.Fps `
      -Seed $spec.Seed -Sampler $Tier.Sampler
    $res = Invoke-VidValidationRun -Workflow $wf -Port $Port -TimeoutSec $TimeoutSec
    if (-not $res.Ok) { throw ('clip ' + $spec.Index + ' failed: ' + $res.Error) }
    $after = @(Get-ChildItem $OutputDir -Filter 'vidtuner*.mp4' | ForEach-Object { $_.FullName })
    $fresh = @($after | Where-Object { $before -notcontains $_ })
    if (-not $fresh.Count) { throw ('clip ' + $spec.Index + ' succeeded but wrote no mp4') }
    $made += @($fresh | Sort-Object)[0]
  }
  return $made
}

function New-VidVoiceoverWav {
  param([string]$Text, [string]$WavPath)
  if (-not $Text) { throw 'voiceover text is empty' }
  Add-Type -AssemblyName System.Speech
  $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
  $zh = @($synth.GetInstalledVoices() | Where-Object { $_.Enabled -and $_.VoiceInfo.Culture -like 'zh-*' } | Select-Object -First 1)
  if (-not $zh.Count) { throw 'no Chinese SAPI voice found; install a zh-CN speech voice in Windows settings' }
  $synth.SelectVoice($zh[0].VoiceInfo.Name)
  $dir = Split-Path $WavPath -Parent
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $synth.SetOutputToWaveFile($WavPath)
  try { $synth.Speak($Text) } finally { $synth.SetOutputToNull() }
  $synth.Dispose()
  if (-not (Test-Path $WavPath) -or (Get-Item $WavPath).Length -lt 1000) { throw 'TTS produced no audio' }
  return $WavPath
}

function Join-VidFinalVideo {
  param([string[]]$Clips, [string]$WavPath, [string]$OutPath)
  $ff = Get-Command ffmpeg -ErrorAction SilentlyContinue
  if (-not $ff) { throw 'ffmpeg not found in PATH; install it (winget install Gyan.FFmpeg) and re-run' }
  if (@($Clips).Count -lt 2) { throw 'compose merge needs at least 2 clips' }
  if (-not (Test-Path $WavPath)) { throw 'voiceover wav missing' }
  $dir = Split-Path $OutPath -Parent
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $listPath = Join-Path $dir 'compose_list.txt'
  $utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
  [IO.File]::WriteAllText($listPath, (New-VidConcatList $Clips), $utf8)
  $ffargs = @('-hide_banner', '-loglevel', 'error', '-y', '-f', 'concat', '-safe', '0',
              '-i', $listPath, '-i', $WavPath, '-c:v', 'copy', '-c:a', 'aac', '-b:a', '128k',
              '-shortest', $OutPath)
  & $ff.Source @ffargs
  if ($LASTEXITCODE -ne 0) { throw ('ffmpeg merge failed with exit ' + $LASTEXITCODE) }
  if (-not (Test-Path $OutPath) -or (Get-Item $OutPath).Length -lt 10000) { throw 'merged video missing or too small' }
  return $OutPath
}

function Invoke-VidCompose {
  param([string]$Root, [string]$EngineRoot, [object]$Inv, [object]$Tier, [string]$Prompt,
        [string]$Narration, [int]$ClipCount = 3, [int]$Port = 8188, [int]$TimeoutSec = 7200)
  $timeline = @(New-VidComposeTimeline -ClipCount $ClipCount -Prompt $Prompt -BaseSeed (Get-VidRunSeed (Get-Date)))
  $outDir = Join-Path $EngineRoot 'ComfyUI\output'
  $pieces = @(Invoke-VidClipBatch -Timeline $timeline -Tier $Tier -Inv $Inv -OutputDir $outDir `
      -Port $Port -TimeoutSec $TimeoutSec)
  $wav = New-VidVoiceoverWav -Text $Narration -WavPath (Join-Path $Root 'runtime\voiceover.wav')
  $out = Join-Path $outDir ('vidtuner_story_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.mp4')
  $final = Join-VidFinalVideo -Clips $pieces -WavPath $wav -OutPath $out
  Write-VidLog ('compose done: ' + @($pieces).Count + ' clips + voiceover -> ' + $final)
  return [pscustomobject]@{ Clips = @($pieces).Count; VoiceOver = $wav; Output = $final }
}
