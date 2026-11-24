# lib/fetch.ps1 - byte transport: single-stream and segmented-parallel downloads with resume.
# Deps: common. ASCII-only (PS 5.1 codepage rule).


# PS5.1 Invoke-WebRequest buffers the WHOLE response in RAM before writing - fine for a 200MB
# zip, fatal for a 3.5GB engine (no progress, RAM bloat, restart-from-zero on every stall).
# So: streaming HttpWebRequest -> FileStream, with Range-based resume and progress every 64MB.
function Invoke-VidDownload {
  param([string]$Url, [string]$OutFile, [int]$TimeoutSec = 3600, [int]$Retries = 5)
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
  New-Item -ItemType Directory -Force -Path (Split-Path $OutFile -Parent) | Out-Null
  $name = [IO.Path]::GetFileName($OutFile)
  for ($i = 1; $i -le $Retries; $i++) {
    $req = $null; $resp = $null; $fs = $null; $rs = $null
    try {
      $have = 0
      if (Test-Path $OutFile) { $have = (Get-Item $OutFile).Length }
      Write-VidLog ('  downloading (try ' + $i + $(if ($have) { ', resume from ' + [math]::Round($have / 1MB) + 'MB' } else { '' }) + '): ' + $name)
      $req = [System.Net.HttpWebRequest]::Create($Url)
      $req.Timeout = 30000
      $req.ReadWriteTimeout = 60000
      $req.UserAgent = 'video-tuner'
      if ($have -gt 0) { $req.AddRange($have) }
      $resp = $req.GetResponse()
      $status = [int]$resp.StatusCode
      if ($have -gt 0 -and $status -ne 206) { $have = 0 }   # server ignored Range: restart clean
      $fs = [IO.File]::Open($OutFile, $(if ($status -eq 206) { [IO.FileMode]::Append } else { [IO.FileMode]::Create }))
      $total = -1
      try { if ($resp.ContentLength -ge 0) { $total = $resp.ContentLength + $have } } catch {}
      $rs = $resp.GetResponseStream()
      $buf = New-Object byte[] 262144
      $sinceReport = 0
      while ($true) {
        $n = $rs.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        $fs.Write($buf, 0, $n)
        $have += $n; $sinceReport += $n
        if ($sinceReport -ge 67108864) {
          $msg = '    ... ' + [math]::Round($have / 1MB) + 'MB'
          if ($total -gt 0) { $msg += '/' + [math]::Round($total / 1MB) + 'MB (' + [math]::Round(100.0 * $have / $total) + '%)' }
          Write-VidLog $msg
          $sinceReport = 0
        }
      }
      $rs.Close(); $rs = $null; $fs.Close(); $fs = $null; $resp.Close(); $resp = $null
      $size = (Get-Item $OutFile).Length
      if ($size -gt 0 -and ($total -lt 0 -or $size -ge $total)) { return $true }
      Write-VidLog ('    incomplete (' + [math]::Round($size / 1MB) + '/' + [math]::Round($total / 1MB) + 'MB), will resume')
    } catch {
      Write-VidLog ('    stalled: ' + $_.Exception.Message)
    } finally {
      if ($rs) { $rs.Close() }
      if ($fs) { $fs.Close() }
      if ($resp) { $resp.Close() }
    }
    Start-Sleep -Seconds (5 * $i)
  }
  return $false
}

# Worker body for one range segment. Kept as source text so it can be handed to a fresh
# runspace (runspaces in-process: no extra powershell.exe x8, which matters on 16GB).
function Get-VidPartWorkerSource {
  return @'
param($url, $partPath, $start, $end)
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
$expect = [long]$end - [long]$start + 1
$tries = 0
while ($tries -lt 10) {
  $have = [long]0
  if (Test-Path $partPath) { $have = [long](Get-Item $partPath).Length }
  if ($have -ge $expect) { return $true }
  $tries++
  $req = $null; $resp = $null; $fs = $null; $rs = $null
  try {
    $req = [Net.HttpWebRequest]::Create($url)
    $req.Timeout = 20000
    $req.ReadWriteTimeout = 45000
    $req.UserAgent = 'video-tuner'
    $req.AddRange([long]($start + $have), [long]$end)
    $resp = $req.GetResponse()
    $code = [int]$resp.StatusCode
    if ($code -ne 206) { throw ('server ignored Range (HTTP ' + $code + ')') }
    $fs = [IO.File]::Open($partPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    $rs = $resp.GetResponseStream()
    $buf = New-Object byte[] 262144
    $got = [long]0
    while ($true) {
      $n = $rs.Read($buf, 0, $buf.Length)
      if ($n -le 0) { break }
      $fs.Write($buf, 0, $n)
      $got += $n
      if (($have + $got) -ge $expect) { break }
    }
  } catch {
  } finally {
    if ($rs) { $rs.Close() }
    if ($fs) { $fs.Close() }
    if ($resp) { $resp.Close() }
  }
}
if (-not (Test-Path $partPath)) { return $false }
return ([long](Get-Item $partPath).Length -ge $expect)
'@
}

function Get-VidRemoteSize([string]$Url) {
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.Method = 'HEAD'
    $req.Timeout = 20000
    $req.UserAgent = 'video-tuner'
    $resp = $req.GetResponse()
    $len = $resp.ContentLength
    $resp.Close()
    if ($len -gt 0) { return [long]$len }
  } catch {}
  try {
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.AddRange(0, 0)
    $req.Timeout = 20000
    $req.UserAgent = 'video-tuner'
    $resp = $req.GetResponse()
    $cr = ''
    try { $cr = [string]$resp.Headers['Content-Range'] } catch {}
    $resp.Close()
    if ($cr -match '/(\d+)\s*$') { return [long]$Matches[1] }
  } catch {}
  return [long]0
}

# Segmented parallel download with per-part resume. Falls back to the single stream on any
# doubt (unknown size, server ignoring Range, part mismatch) so we never assemble garbage.
function Invoke-VidDownloadParallel {
  param([string]$Url, [string]$OutFile, [int]$Conns = 8, [int]$MinParallelMB = 32)
  New-Item -ItemType Directory -Force -Path (Split-Path $OutFile -Parent) | Out-Null
  $size = Get-VidRemoteSize $Url
  if ($size -le 0) {
    Write-VidLog '    (size unknown - single stream)'
    return (Invoke-VidDownload $Url $OutFile)
  }
  if ((Test-Path $OutFile) -and ((Get-Item $OutFile).Length -ge $size)) { return $true }
  if ($size -lt ($MinParallelMB * 1MB)) {
    Write-VidLog ('    ' + [math]::Round($size / 1MB) + 'MB - single stream')
    return (Invoke-VidDownload $Url $OutFile)
  }
  $chunk = [long][math]::Ceiling($size / $Conns)
  $parts = @()
  for ($k = 0; $k -lt $Conns; $k++) {
    $s = [long]($k * $chunk)
    if ($s -ge $size) { break }
    $e = [long][math]::Min($s + $chunk - 1, $size - 1)
    $p = Join-Path (Split-Path $OutFile -Parent) ([IO.Path]::GetFileName($OutFile) + '.part' + $k)
    $parts += @{ path = $p; start = $s; end = $e; ps = $null; rs = $null; ar = $null }
  }
  Write-VidLog ('    ' + $parts.Count + ' connections, ' + [math]::Round($size / 1MB) + 'MB total')
  $src = Get-VidPartWorkerSource
  foreach ($p in $parts) {
    $ps = [powershell]::Create()
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps.Runspace = $rs
    [void]$ps.AddScript($src)
    [void]$ps.AddParameter('url', $Url)
    [void]$ps.AddParameter('partPath', $p.path)
    [void]$ps.AddParameter('start', $p.start)
    [void]$ps.AddParameter('end', $p.end)
    $p.ps = $ps; $p.rs = $rs
    $p.ar = $ps.BeginInvoke()
  }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $lastBytes = [long]0
  $lastT = 0.0
  while ($true) {
    $bytes = [long]0
    foreach ($p in $parts) { if (Test-Path $p.path) { $bytes += [long](Get-Item $p.path).Length } }
    $running = @($parts | Where-Object { -not $_.ar.IsCompleted }).Count
    $el = $sw.Elapsed.TotalSeconds
    if ((($el - $lastT) -ge 20) -or ($running -eq 0)) {
      $avg = $bytes / 1MB / [math]::Max($el, 0.001)
      $eta = if ($avg -gt 0.01) { [int](($size - $bytes) / 1MB / $avg) } else { -1 }
      Write-VidLog ('    ' + [math]::Round($bytes / 1MB) + '/' + [math]::Round($size / 1MB) + 'MB ' + [int](100.0 * $bytes / $size) + '%  ' + [math]::Round($avg, 2) + ' MB/s  ETA ' + $eta + 's')
      $lastBytes = $bytes
      $lastT = $el
    }
    if ($running -eq 0) { break }
    Start-Sleep -Seconds 3
  }
  $allOk = $true
  foreach ($p in $parts) {
    $want = [long]$p.end - [long]$p.start + 1
    $got = [long]0
    if (Test-Path $p.path) { $got = [long](Get-Item $p.path).Length }
    if ($got -lt $want) { $allOk = $false }
    if ($p.ps) { try { [void]$p.ps.EndInvoke($p.ar) } catch {}; $p.ps.Dispose() }
    if ($p.rs) { try { $p.rs.Close() } catch {} }
  }
  if (-not $allOk) {
    Write-VidLog ('    parallel attempt incomplete (' + [math]::Round($bytes / 1MB) + '/' + [math]::Round($size / 1MB) + 'MB) - parts kept for resume')
    return $false
  }
  Write-VidLog ('    assembling from ' + $parts.Count + ' parts...')
  $out = [IO.File]::Create($OutFile)
  try {
    foreach ($p in $parts) {
      $in = [IO.File]::OpenRead($p.path)
      try { $in.CopyTo($out, 1048576) } finally { $in.Close() }
    }
  } finally { $out.Close() }
  $final = (Get-Item $OutFile).Length
  if ($final -ne $size) {
    Write-VidLog ('    assembled size mismatch: ' + $final + ' vs ' + $size)
    return $false
  }
  foreach ($p in $parts) { Remove-Item $p.path -Force -ErrorAction SilentlyContinue }
  return $true
}
