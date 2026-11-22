# Download the FP4 checkpoint to a plain directory - no Hub cache, no .git, no symlinks.
#
# Model: nvidia/Qwen3.8-Flash-Next-FP4-Local (NVIDIA's QAD NVFP4/MXFP8 checkpoint, ~96 GiB).
# Two public sources are supported, both serving the same config/tensors layout:
#   * Hugging Face  nvidia/Qwen3.8-Flash-Next-FP4-Local   (public repo, no token needed)
#   * ModelScope    nv-community/Qwen3.8-Flash-Next-FP4-Local (community mirror)
#
# Source selection: -Source auto (default) probes both, lists files through whichever API
# answers, and picks the faster one; if the chosen source fails mid-download the script
# switches to the other and continues (complete files are skipped, partial ones resume).
# -Source hf / -Source modelscope force one source.
#
# The script uses only curl + PowerShell (no modelscope/HF package to install; nothing is
# installed on your behalf). It lists the repo files, then downloads each blob straight
# into -TargetDir, preserving paths (tensors/*.safetensors). Because files land directly
# in the target folder:
#   - there is no ~/.cache/... snapshot tree and no symlink farm;
#   - there is no .git directory (this is an HTTP file download, not a git clone);
#   - interrupted downloads resume with curl -C -; re-running is safe: files whose size
#     matches the manifest are skipped, wrong-sized ones are re-fetched.
#
# USAGE
#   powershell -ExecutionPolicy Bypass -File .\scripts\download-model.ps1
#   powershell -ExecutionPolicy Bypass -File .\scripts\download-model.ps1 -TargetDir E:\models\Qwen3.8-Flash-Next-FP4-Local
#     (default landing directory is D:\llm\models\Qwen3.8-Flash-Next-FP4-Local; -TargetDir overrides it)
#   powershell ... -Source modelscope      # force one source
#   Add -ListOnly to print the file list + total size without downloading.

[CmdletBinding()]
param(
  [ValidateSet('auto', 'hf', 'modelscope')]
  [string]$Source = 'auto',
  [string]$HfRepo = 'nvidia/Qwen3.8-Flash-Next-FP4-Local',
  [string]$HfRevision = 'main',
  [string]$MsRepo = 'nv-community/Qwen3.8-Flash-Next-FP4-Local',
  [string]$MsRevision = 'master',
  [string]$TargetDir = 'D:\llm\models\Qwen3.8-Flash-Next-FP4-Local',
  [switch]$ListOnly,
  [int]$Retries = 5
)

$ErrorActionPreference = 'Stop'

function Say { param([string]$m) Write-Host "[download-model] $m" }
function HumanGiB { param([double]$b) '{0:F1} GiB' -f ($b / 1GB) }

# ---------------------------------------------------------------- dependencies
# curl is a built-in component of Windows 10 1803+ / Windows 11. If it is missing we say so
# and stop - this script never installs anything on your behalf.
$curl = (Get-Command curl.exe -ErrorAction SilentlyContinue)
if (-not $curl) {
  Write-Host '[download-model] curl.exe not found on PATH.' -ForegroundColor Red
  Write-Host '[download-model] It ships with Windows 10 1803+ (Settings -> Apps -> Optional features,' -ForegroundColor Red
  Write-Host '[download-model]   or "curl" via winget). Install it yourself and re-run; nothing here installs software.' -ForegroundColor Red
  exit 1
}
$curl = $curl.Source

# ---------------------------------------------------------------- source adapters
# Each source exposes: List -> normalized @{Path;Size} array, Url(path) -> download URL.
function Get-SourceBlobs {
  param([string]$Name)
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  if ($Name -eq 'hf') {
    $url = "https://huggingface.co/api/models/$HfRepo/tree/$HfRevision`?recursive=true"
    $raw = & $curl -sSfL $url | Out-String
    if ($LASTEXITCODE -ne 0) { throw "HF list failed: $url" }
    # Windows PowerShell 5.1's ConvertFrom-Json wraps an array input in a single object:
    # assign first, then expand through the pipeline (5.1 and 7.x both behave correctly).
    $json = $raw | ConvertFrom-Json
    $items = @($json | Where-Object { $_.type -eq 'file' })
    $blobs = @($items | ForEach-Object { [pscustomobject]@{ Path = $_.path; Size = $_.size } } | Sort-Object Path)
  } else {
    $url = "https://www.modelscope.cn/api/v1/models/$MsRepo/repo/files?Revision=$([uri]::EscapeDataString($MsRevision))&Recursive=True"
    $raw = & $curl -sSfL $url | Out-String
    if ($LASTEXITCODE -ne 0) { throw "ModelScope list failed: $url" }
    $json = $raw | ConvertFrom-Json
    $blobs = @($json.Data.Files | Where-Object { $_.Type -eq 'blob' } | ForEach-Object { [pscustomobject]@{ Path = $_.Path; Size = $_.Size } } | Sort-Object Path)
  }
  $sw.Stop()
  if ($blobs.Count -eq 0) { throw "$Name returned no files" }
  if (-not ($blobs.Path -contains 'config.json')) { throw "$Name manifest has no config.json - refusing to trust it" }
  [pscustomobject]@{ Source = $Name; Blobs = $blobs; Seconds = $sw.Elapsed.TotalSeconds }
}

function Get-SourceUrl {
  param([string]$Name, [string]$Path)
  $enc = [uri]::EscapeDataString($Path)
  if ($Name -eq 'hf') { return "https://huggingface.co/$HfRepo/resolve/$HfRevision/$Path" }
  return "https://www.modelscope.cn/api/v1/models/$MsRepo/repo?Revision=$([uri]::EscapeDataString($MsRevision))&FilePath=$enc"
}

# ---------------------------------------------------------------- latency probe
# The model host is chosen by ICMP round-trip time via ping.exe: 1 packet, 4 s timeout.
# (.NET's System.Net.NetworkInformation.Ping is blocked by some local network stacks /
# proxies on Windows, while ping.exe still gets replies — so we use ping.exe and parse it.)
# Output is localized ("time=12ms" / "时间=12ms"), and "<1ms" appears for LAN-level hosts;
# any non-reply (timeout / unreachable) yields $null and ranks that source last. If every
# probe returns $null we fall back to list-API response time so the script still picks one.
function Measure-HostLatencyMs {
  param([string]$HostName, [int]$TimeoutMs = 4000)
  try {
    $out = & ping.exe -n 1 -w $TimeoutMs $HostName 2>$null | Out-String
    # reply lines look like  time=12ms / 时间=12ms  and  time<1ms / 时间<1ms (no '=' in the '<' form)
    if ($out -match '(?:time|时间)[=<]\s*(\d+)\s*ms') { return [double]$Matches[1] }
    return $null
  } catch { return $null }
}

# ---------------------------------------------------------------- source selection
$candidates = if ($Source -eq 'auto') { @('hf', 'modelscope') } else { @($Source) }
Say "probing source(s): $($candidates -join ', ')"
$probes = @()
foreach ($c in $candidates) {
  try {
    $p = Get-SourceBlobs -Name $c
    $host_ = if ($c -eq 'hf') { 'huggingface.co' } else { 'www.modelscope.cn' }
    $lat = Measure-HostLatencyMs -HostName $host_ -TimeoutMs 4000
    $latText = if ($null -eq $lat) { 'n/a' } else { '{0:N1} ms' -f $lat }
    Say ("  {0}: OK, {1} files, ping {2} (list {3:N1}s)" -f $c, $p.Blobs.Count, $latText, $p.Seconds)
    $probes += [pscustomobject]@{ Source = $p.Source; Blobs = $p.Blobs; Seconds = $p.Seconds; LatencyMs = $lat }
  } catch {
    Say "  ${c}: unavailable ($($_.Exception.Message))"
  }
}
if ($probes.Count -eq 0) {
  Write-Host '[download-model] no source reachable. Check network/proxy, or force one: -Source hf | -Source modelscope' -ForegroundColor Red
  exit 1
}
# sanity: sources must agree on the file manifest (ignoring metadata files that legitimately
# differ between hubs), otherwise one mirror is stale.
if ($probes.Count -gt 1) {
  $cmpBlobs = { param($p) ($p.Blobs | Where-Object { $_.Path -notmatch '^(\.gitattributes|configuration\.json)$' } | ForEach-Object { "$($_.Path):$($_.Size)" }) -join '|' }
  $sig = & $cmpBlobs $probes[0]; $sig2 = & $cmpBlobs $probes[1]
  if ($sig -ne $sig2) { Say 'WARNING: mirrors disagree on file sizes - if in doubt use -Source hf (the official NVIDIA repo)' }
}
# rank: lower ping wins; $null (unreachable/slow >4s) ranks last; all-null falls back to list time
$anyLatency = @($probes | Where-Object { $null -ne $_.LatencyMs }).Count -gt 0
if ($anyLatency) {
  $order = @($probes | Sort-Object { if ($null -eq $_.LatencyMs) { [double]::MaxValue } else { $_.LatencyMs } } | ForEach-Object { $_.Source })
  $first = $probes | Sort-Object { if ($null -eq $_.LatencyMs) { [double]::MaxValue } else { $_.LatencyMs } } | Select-Object -First 1
} else {
  Say 'both ping results unavailable; ranking by API list time instead'
  $order = @($probes | Sort-Object Seconds | ForEach-Object { $_.Source })
  $first = $probes | Sort-Object Seconds | Select-Object -First 1
}
Say ("download order: {0}" -f ($order -join ' -> '))
$blobs = $first.Blobs
$total = ($blobs | Measure-Object -Property Size -Sum).Sum
Say "$($blobs.Count) files, total $(HumanGiB $total)"

if ($ListOnly) {
  foreach ($f in $blobs) { '{0,12}  {1}' -f $f.Size, $f.Path }
  return
}

# ---------------------------------------------------------------- download
New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
$i = 0
foreach ($f in $blobs) {
  $i++
  $dest = Join-Path $TargetDir ($f.Path -replace '/', '\')
  $parent = Split-Path -Parent $dest
  if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  $have = 0
  if (Test-Path -LiteralPath $dest) { $have = (Get-Item -LiteralPath $dest).Length }

  if ($have -eq [long]$f.Size) {
    Say "[$i/$($blobs.Count)] skip (complete): $($f.Path)"
    continue
  }
  if ($have -gt [long]$f.Size) {
    Say "[$i/$($blobs.Count)] size mismatch, re-downloading: $($f.Path)"
    Remove-Item -LiteralPath $dest -Force
    $have = 0
  }

  $ok = $false
  foreach ($srcName in $order) {
    $url = Get-SourceUrl -Name $srcName -Path $f.Path
    for ($attempt = 1; $attempt -le $Retries -and -not $ok; $attempt++) {
      Say "[$i/$($blobs.Count)] $(if ($have) {'resume'} else {'download'}) via $srcName $(HumanGiB $f.Size): $($f.Path) (try $attempt)"
      if ($have -gt 0) { & $curl -sSfL -C - --retry 3 -o $dest $url } else { & $curl -sSfL --retry 3 -o $dest $url }
      $rc = $LASTEXITCODE
      $now = if (Test-Path -LiteralPath $dest) { (Get-Item -LiteralPath $dest).Length } else { 0 }
      if ($rc -eq 0 -and $now -eq [long]$f.Size) { $ok = $true } else { $have = $now; Start-Sleep -Seconds 2 }
    }
    if ($ok) { break }
    if ($order.Count -gt 1) { Say "  [$srcName] exhausted for $($f.Path), switching source" }
  }
  if (-not $ok) { throw "failed to download $($f.Path) from $($order -join '+') after $Retries attempts each" }
}

# ---------------------------------------------------------------- sanity check
if (-not (Test-Path -LiteralPath (Join-Path $TargetDir 'config.json'))) { throw "config.json missing in $TargetDir" }
$shards = @(Get-ChildItem -LiteralPath (Join-Path $TargetDir 'tensors') -Filter '*.safetensors' -ErrorAction SilentlyContinue)
if ($shards.Count -lt 1) { throw "no tensor shards in $TargetDir\tensors" }
Say "OK: checkpoint ready at $TargetDir ($($shards.Count) shards, $(HumanGiB $total))"
Say "set MODEL_DIR to this path (config.ps1 defaults here) and run .\start.ps1"
