# lib/state.ps1 - config.json read/write + history of validated runs. ASCII-only.
# Same shape as llama-tuner's state: plan cache keyed by hardware signature + model, so a
# re-run on the same machine with the same model reuses the validated tier without re-testing.

function Get-VidStatePath([string]$root) { return (Join-Path $root 'config.json') }

function Read-VidState([string]$root) {
  $p = Get-VidStatePath $root
  if (-not (Test-Path $p)) { return $null }
  try { return (Get-Content $p -Raw | ConvertFrom-Json) } catch { return $null }
}

function Write-VidState([string]$root, [object]$state) {
  $json = $state | ConvertTo-Json -Depth 8
  Set-Content -Path (Get-VidStatePath $root) -Value $json -Encoding UTF8
}

# Cache is only reusable when hardware AND model AND resolution all match (same rule as K-cache).
function Test-VidPlanFresh {
  param([object]$State, [string]$GpuSig, [string]$Model, [string]$Res)
  if (-not $State) { return $false }
  if (-not $State.Plan) { return $false }
  return ([string]$State.Plan.GpuSig -eq $GpuSig -and
          [string]$State.Plan.Model -eq $Model -and
          [string]$State.Plan.Res -eq $Res -and
          [string]$State.Plan.Validated -eq 'true')
}

function Set-VidPlanState {
  param([string]$root, [object]$Plan, [bool]$Validated, [string]$Note = '')
  $state = Read-VidState $root
  if (-not $state) { $state = [pscustomobject]@{} }
  $state | Add-Member -Force NoteProperty Plan ([pscustomobject]@{
    Tier      = [string]$Plan.Pick.Id
    Model     = [string]$Plan.Pick.Model
    Res       = [string]$Plan.Pick.Res
    GpuSig    = [string]$Plan.GpuSig
    VramMB    = [int]$Plan.VramMB
    RamMB     = [int]$Plan.RamMB
    Validated = ([string]$Validated).ToLower()
    Note      = $Note
    At        = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  })
  Write-VidState $root $state
}
