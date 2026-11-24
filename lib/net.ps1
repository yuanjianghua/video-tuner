# lib/net.ps1 - which URL to ask: model mirrors, GitHub accelerator routing, cache file.
# Deps: common, fetch. ASCII-only (PS 5.1 codepage rule).
# Measured here 2026-11-24: huggingface.co BLOCKED, hf-mirror flaky, modelscope.cn ~10 MB/s,
# github.com direct 0.03-0.1 MB/s vs 0.7+ MB/s through front proxies.

# Model hosts, in order. Measured here 2026-11-24: model scope = 10.4 MB/s, huggingface.co
# blocked, hf-mirror timed out that hour. ModelScope serves the SAME repo ids with a
# different path shape (/resolve/master/), so it is first and the HF-family hosts are fallbacks.
function Get-VidDownloadHosts {
  return @(
    @{ base = 'https://modelscope.cn/models/'; rev = 'master' },
    @{ base = 'https://hf-mirror.com/'; rev = 'main' },
    @{ base = 'https://huggingface.co/'; rev = 'main' }
  )
}

function Get-VidRepoFileUrls([string]$Repo, [string]$Path) {
  $urls = @()
  foreach ($h in @(Get-VidDownloadHosts)) {
    $urls += ($h.base + $Repo + '/resolve/' + $h.rev + '/' + $Path)
  }
  return $urls
}

function Invoke-VidDownloadRepoFile {
  param([string]$Repo, [string]$Path, [string]$OutFile)
  foreach ($u in @(Get-VidRepoFileUrls $Repo $Path)) {
    Write-VidLog ('    source: ' + ([Uri]$u).Host)
    if (Invoke-VidDownloadParallel $u $OutFile) { return $true }
  }
  return $false
}

# GitHub is the only source for the engine, and direct github.com gives ~0.03-0.1 MB/s here
# while a 6-connection pull through a proxy gave 0.74 MB/s. So: sample each route for a few
# seconds, keep the winner, and remember it in ghroute.txt next to the download.
function Get-VidGithubProxies { return @('https://gh-proxy.com/', 'https://gh-proxy.net/', 'https://ghfast.top/') }

function Measure-VidRoute([string]$Url, [int]$Seconds = 5) {
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.Timeout = 12000
    $req.ReadWriteTimeout = 10000
    $req.UserAgent = 'video-tuner'
    $resp = $req.GetResponse()
    $rs = $resp.GetResponseStream()
    $buf = New-Object byte[] 262144
    $total = [long]0
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
      $n = $rs.Read($buf, 0, $buf.Length)
      if ($n -le 0) { break }
      $total += $n
    }
    $rs.Close(); $resp.Close()
    if ($sw.Elapsed.TotalSeconds -le 0) { return 0 }
    return ($total / 1MB / $sw.Elapsed.TotalSeconds)
  } catch { return 0 }
}

function Select-VidGithubRoute([string]$CanonicalUrl, [string]$CacheFile) {
  $cands = @(@{ label = 'direct'; url = $CanonicalUrl })
  foreach ($p in @(Get-VidGithubProxies)) { $cands += @{ label = $p.Split('/')[2]; url = ($p + $CanonicalUrl) } }
  $ordered = @()
  if (Test-Path $CacheFile) {
    $cached = ([IO.File]::ReadAllText($CacheFile)).Trim()
    if ($cached) {
      $hit = @($cands | Where-Object { $_.url -eq $cached })
      if ($hit.Count -gt 0) { $ordered += $hit[0] }
    }
  }
  foreach ($c in $cands) {
    $dup = $false
    foreach ($o in $ordered) { if ($o.url -eq $c.url) { $dup = $true } }
    if (-not $dup) { $ordered += $c }
  }
  $best = $null
  $bestRate = 0
  foreach ($c in $ordered) {
    $r = Measure-VidRoute $c.url 5
    Write-VidLog ('    route ' + $c.label + ' = ' + [math]::Round($r, 2) + ' MB/s')
    if ($r -gt $bestRate) { $bestRate = $r; $best = $c }
    if ($bestRate -ge 3) { break }
  }
  if (-not $best) { return $null }
  New-Item -ItemType Directory -Force -Path (Split-Path $CacheFile -Parent) | Out-Null
  try { [IO.File]::WriteAllText($CacheFile, $best.url) } catch {}
  return $best
}

function Invoke-VidDownloadGithub {
  param([string]$Url, [string]$OutFile, [string]$Canonical = '')
  $canon = if ($Canonical) { $Canonical } else { $Url }
  $cacheFile = Join-Path (Split-Path $OutFile -Parent) 'ghroute.txt'
  $route = Select-VidGithubRoute $canon $cacheFile
  if (-not $route) { Write-VidLog '    no GitHub route answered'; return $false }
  Write-VidLog ('    using ' + $route.label)
  if (Invoke-VidDownloadParallel $route.url $OutFile) { return $true }
  foreach ($p in @('') + @(Get-VidGithubProxies)) {
    $u = $p + $canon
    if ($u -ne $route.url) {
      Write-VidLog ('    retry via ' + $(if ($p) { $p.Split('/')[2] } else { 'direct' }))
      if (Invoke-VidDownloadParallel $u $OutFile) { return $true }
    }
  }
  return $false
}
