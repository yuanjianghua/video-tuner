# lib/load.ps1 - manifest-driven module loader (same pattern as llama-tuner). ASCII-only.
# Usage: . lib\load.ps1 ; foreach ($mp in Get-VidModulePaths $root) { . $mp }

function Get-VidManifest([string]$root) {
  $mf = Join-Path $root 'lib\modules.json'
  if (-not (Test-Path $mf)) { throw "missing module manifest: $mf" }
  $obj = Get-Content $mf -Raw | ConvertFrom-Json
  return @($obj.modules)
}

function Get-VidModulePaths([string]$root) {
  $loaded = @{}
  $paths = @()
  foreach ($m in (Get-VidManifest $root)) {
    foreach ($d in @($m.deps)) {
      if (-not $loaded.ContainsKey([string]$d)) {
        throw ("module '" + $m.name + "' depends on '" + $d + "' which is not loaded before it (check lib/modules.json order)")
      }
    }
    $p = Join-Path $root ('lib\' + $m.file)
    if (-not (Test-Path $p)) { throw ('manifest lists missing file: ' + $p) }
    $loaded[[string]$m.name] = $true
    $paths += $p
  }
  return $paths
}
