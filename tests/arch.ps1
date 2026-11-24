# tests/arch.ps1 - architecture coupling audit for video-tuner (ported from llama-tuner, same rules):
# discovered cross-module call graph must EQUAL the declared graph in lib/modules.json;
# pure modules touch no side-effect primitives; graph acyclic; manifest topological;
# no duplicate function names; no alias shadowing; size budgets; thin entry. ASCII-only.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$libDir = Join-Path $root 'lib'

$script:pass = 0
$script:failList = @()
function Assert-Ok([bool]$cond, [string]$name) {
  if ($cond) { $script:pass++; Write-Host ('PASS  ' + $name) }
  else { $script:failList += $name; Write-Host ('FAIL  ' + $name) }
}

# ---------- load manifest ----------
$mfPath = Join-Path $libDir 'modules.json'
if (-not (Test-Path $mfPath)) { Write-Host 'FAIL  lib/modules.json missing'; exit 1 }
$obj = Get-Content $mfPath -Raw | ConvertFrom-Json
$manifest = @($obj.modules)

# ---------- parse each module: defined functions + comment-stripped body ----------
$mods = @()
foreach ($m in $manifest) {
  $f = Join-Path $libDir ([string]$m.file)
  $exists = Test-Path $f
  Assert-Ok $exists ('manifest file exists: lib/' + $m.file)
  $raw = ''
  if ($exists) { $raw = Get-Content $f -Raw }
  $text = ($raw -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
  $defs = @([regex]::Matches($raw, '(?im)^[ \t]*function[ \t]+([A-Za-z][A-Za-z0-9_-]*)') | ForEach-Object { $_.Groups[1].Value })
  $mods += [pscustomobject]@{
    Name = [string]$m.name; File = [string]$m.file; Pure = [bool]$m.pure
    Deps = [string[]]@($m.deps); Text = $text; Defs = $defs; Lines = ($raw -split "`r?`n").Count
  }
}

# ---------- coverage: manifest <-> disk, both directions ----------
$disk = @(Get-ChildItem $libDir -Filter *.ps1 | ForEach-Object { $_.Name })
$declaredFiles = @($mods | ForEach-Object { $_.File })
$undoc = @($disk | Where-Object { $declaredFiles -notcontains $_ })
$ghost = @($declaredFiles | Where-Object { $disk -notcontains $_ })
Assert-Ok ($undoc.Count -eq 0) ('every lib/*.ps1 is declared in modules.json' + $(if ($undoc.Count) { ' (missing: ' + ($undoc -join ',') + ')' } else { '' }))
Assert-Ok ($ghost.Count -eq 0) ('modules.json lists no phantom files' + $(if ($ghost.Count) { ' (phantom: ' + ($ghost -join ',') + ')' } else { '' }))

# ---------- function ownership + duplicates ----------
$pairs = @()
foreach ($m in $mods) { foreach ($d in $m.Defs) { $pairs += [pscustomobject]@{ Mod = $m.Name; Fn = [string]$d } } }
$dupes = @($pairs | Group-Object Fn | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
Assert-Ok ($dupes.Count -eq 0) ('no duplicate function names across modules' + $(if ($dupes.Count) { ': ' + ($dupes -join ',') } else { '' }))

# ---------- discovered coupling (word-boundary scan, case-insensitive like PS) ----------
$edges = @()
foreach ($a in $mods) {
  foreach ($p in $pairs) {
    if ($p.Mod -eq $a.Name) { continue }
    $rx = '(?<![\w-])' + [regex]::Escape($p.Fn) + '(?![\w-])'
    $hit = [regex]::Match($a.Text, $rx, 'IgnoreCase')
    if ($hit.Success) { $edges += [pscustomobject]@{ From = $a.Name; To = $p.Mod; Fn = $hit.Value } }
  }
}
foreach ($m in $mods) {
  $mine = @($edges | Where-Object { $_.From -eq $m.Name })
  $disc = @($mine | ForEach-Object { $_.To } | Sort-Object -Unique)
  $decl = @($m.Deps | Sort-Object)
  $undeclared = @($disc | Where-Object { $decl -notcontains $_ })
  $stale = @($decl | Where-Object { $disc -notcontains $_ })
  $uDetail = ''
  if ($undeclared.Count) { $uDetail = ' (e.g. ' + (@($mine | Where-Object { $undeclared -contains $_.To } | ForEach-Object { $_.Fn } | Select-Object -First 3) -join ', ') + ')' }
  Assert-Ok ($undeclared.Count -eq 0) ('no undeclared coupling out of ' + $m.Name + $uDetail)
  Assert-Ok ($stale.Count -eq 0) ('no stale declared dep in ' + $m.Name + $(if ($stale.Count) { ' (no longer used: ' + ($stale -join ',') + ')' } else { '' }))
}

# ---------- pure modules: no side-effect primitives at all ----------
$sideEffectRx = 'Write-Host|Get-Process|Stop-Process|Start-Process|Start-Sleep|Invoke-RestMethod|Invoke-WebRequest|Get-CimInstance|Test-Path|Get-Content|Set-Content|New-Item|Remove-Item|Copy-Item|Get-ChildItem|Get-Item\b|Resolve-Path|Expand-Archive|taskkill|WScript|nvidia-smi|IO\.File|BinaryReader|ComObject'
foreach ($m in @($mods | Where-Object { $_.Pure })) {
  $hit = [regex]::Match($m.Text, $sideEffectRx)
  Assert-Ok (-not $hit.Success) ('pure module ' + $m.Name + ' uses no side-effect primitives' + $(if ($hit.Success) { ' (found: ' + $hit.Value + ')' } else { '' }))
}

# ---------- acyclic + topological manifest order ----------
$depMap = @{}
$idxMap = @{}
for ($i = 0; $i -lt $mods.Count; $i++) { $depMap[$mods[$i].Name] = @($mods[$i].Deps); $idxMap[$mods[$i].Name] = $i }
$script:mark = @{}
$script:cyc = ''
function Visit-Dep([string]$n, [string]$chainTxt) {
  if ($script:mark.ContainsKey($n) -and [int]$script:mark[$n] -eq 2) { return }
  if ($script:mark.ContainsKey($n) -and [int]$script:mark[$n] -eq 1) { $script:cyc = $chainTxt + ' -> ' + $n; return }
  $script:mark[$n] = 1
  foreach ($d in $depMap[$n]) { Visit-Dep ([string]$d) ($chainTxt + ' -> ' + $d) }
  $script:mark[$n] = 2
}
foreach ($n in @($depMap.Keys)) { Visit-Dep $n $n }
Assert-Ok ($script:cyc -eq '') ('dependency graph is acyclic' + $(if ($script:cyc) { ': ' + $script:cyc } else { '' }))
$orderBad = @()
foreach ($m in $mods) { foreach ($d in $m.Deps) {
  if (-not $idxMap.ContainsKey($d)) { $orderBad += ($m.Name + ' -> unknown module ' + $d) }
  elseif ($idxMap[$d] -ge $idxMap[$m.Name]) { $orderBad += ($m.Name + ' listed before its dep ' + $d) }
} }
Assert-Ok ($orderBad.Count -eq 0) ('manifest order is topological' + $(if ($orderBad.Count) { ': ' + ($orderBad -join '; ') } else { '' }))

# ---------- loader self-test + alias shadow guard (needs the modules loaded) ----------
. (Join-Path $libDir 'load.ps1')
$paths = @(Get-VidModulePaths $root)
foreach ($mp in $paths) { . $mp }
Assert-Ok ($paths.Count -eq $mods.Count -and -not @($paths | Where-Object { -not (Test-Path $_) }).Count) 'loader returns every manifest module, in order, all existing'
$anames = @(Get-Alias | ForEach-Object { $_.Name })
$clash = @($pairs | ForEach-Object { $_.Fn } | Where-Object { $anames -contains $_ })
Assert-Ok ($clash.Count -eq 0) ('no function shadowed by a builtin alias' + $(if ($clash.Count) { ': ' + ($clash -join ',') } else { '' }))

# ---------- size budgets (guard against re-bloating back into one big file) ----------
foreach ($m in $mods) { Assert-Ok ($m.Lines -le 250) ('lib/' + $m.File + ' <= 250 lines (is ' + $m.Lines + ')') }
$tune = Get-Content (Join-Path $root 'tune.ps1') -Raw
Assert-Ok ((($tune -split "`r?`n").Count) -le 200) ('tune.ps1 stays thin (' + (($tune -split "`r?`n").Count) + ' lines)')
Assert-Ok (-not ($tune -match '(?im)^[ \t]*function[ \t]+')) 'entry script defines no logic functions'

# ---------- engine API field names (typo here null-indexes during validation) ----------
$vtext = (@($mods | Where-Object { $_.File -eq 'validate.ps1' }))[0].Text
Assert-Ok ($vtext -match 'queue_running' -and $vtext -match 'queue_pending') 'validate reads ComfyUI queue_running/queue_pending fields'

# ---------- graph summary ----------
Write-Host ''
Write-Host 'Dependency graph (discovered == declared):'
foreach ($m in $mods) {
  Write-Host ('  ' + $m.Name + ' -> ' + $(if (@($m.Deps).Count) { $m.Deps -join ', ' } else { '(none)' }) + $(if ($m.Pure) { '   [pure]' } else { '' }))
}
Write-Host ''
Write-Host ('=== arch: ' + $script:pass + ' passed, ' + $script:failList.Count + ' failed ===')
if ($script:failList.Count -gt 0) { $script:failList | ForEach-Object { Write-Host ('  FAILED: ' + $_) }; exit 1 }
exit 0
