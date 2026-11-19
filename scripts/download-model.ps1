# Download the FP4 checkpoint to a plain directory - no Hub cache, no .git, no symlinks.
#
# Model: nvidia/Qwen3.8-Flash-Next-FP4-Local (NVIDIA's QAD NVFP4/MXFP8 checkpoint, ~96 GiB).
# ModelScope mirror: nv-community/Qwen3.8-Flash-Next-FP4-Local (verified on ModelScope; the
#   nvidia/... id itself is not mirrored there). The engine reads the same config/tensors layout
#   either way, so the local directory is identical to an Hugging Face snapshot of that model.
#
# The script uses only curl + PowerShell (no modelscope/HF package to install). It lists the
# repo files through the ModelScope HTTP API and downloads each blob straight into -TargetDir,
# preserving paths (tensors/*.safetensors). Because files land directly in the target folder:
#   - there is no ~/.cache/... snapshot tree and no symlink farm;
#   - there is no .git directory (this is an HTTP file download, not a git clone);
#   - interrupted downloads resume with curl -C -; re-running is safe and skips complete files.
#
# USAGE
#   powershell -ExecutionPolicy Bypass -File .\scripts\download-model.ps1
#   powershell -ExecutionPolicy Bypass -File .\scripts\download-model.ps1 -TargetDir E:\models\Qwen3.8-Flash-Next-FP4-Local
#     (default landing directory is D:\llm\models\Qwen3.8-Flash-Next-FP4-Local; -TargetDir overrides it)
#   Add -ListOnly to print the file list + total size without downloading.

[CmdletBinding()]
param(
  [string]$ModelId = 'nv-community/Qwen3.8-Flash-Next-FP4-Local',
  [string]$Revision = 'master',
  [string]$TargetDir = 'D:\llm\models\Qwen3.8-Flash-Next-FP4-Local',
  [switch]$ListOnly,
  [int]$Retries = 5
)

$ErrorActionPreference = 'Stop'
$ApiBase = 'https://www.modelscope.cn/api/v1/models'
$curl = (Get-Command curl.exe -ErrorAction Stop).Source

function Say { param([string]$m) Write-Host "[download-model] $m" }
function HumanGiB { param([double]$b) '{0:F1} GiB' -f ($b / 1GB) }

# 1. list repo files through the ModelScope API
$listUrl = "$ApiBase/$ModelId/repo/files?Revision=$([uri]::EscapeDataString($Revision))&Recursive=True"
Say "listing files: $ModelId @ $Revision"
$raw = & $curl -sSfL $listUrl
if ($LASTEXITCODE -ne 0) { throw "cannot list model files: $listUrl" }
$parsed = $raw | ConvertFrom-Json
$blobs = @($parsed.Data.Files | Where-Object { $_.Type -eq 'blob' } | Sort-Object Path)
if ($blobs.Count -eq 0) { throw "no files returned for $ModelId @ $Revision" }
$total = ($blobs | Measure-Object -Property Size -Sum).Sum
Say "$($blobs.Count) files, total $(HumanGiB $total)"

if ($ListOnly) {
  foreach ($f in $blobs) { '{0,12}  {1}' -f $f.Size, $f.Path }
  return
}

# 2. download each blob straight into TargetDir (flat, no cache, no .git)
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

  $url = "$ApiBase/$ModelId/repo?Revision=$([uri]::EscapeDataString($Revision))&FilePath=$([uri]::EscapeDataString($f.Path))"
  Say "[$i/$($blobs.Count)] $(if ($have) {'resume'} else {'download'}) $(HumanGiB $f.Size): $($f.Path)"
  $ok = $false
  for ($attempt = 1; $attempt -le $Retries -and -not $ok; $attempt++) {
    if ($have -gt 0) { & $curl -sSfL -C - --retry 3 -o $dest $url } else { & $curl -sSfL --retry 3 -o $dest $url }
    $rc = $LASTEXITCODE
    $now = if (Test-Path -LiteralPath $dest) { (Get-Item -LiteralPath $dest).Length } else { 0 }
    if ($rc -eq 0 -and $now -eq [long]$f.Size) { $ok = $true } else { $have = $now; Start-Sleep -Seconds 2 }
  }
  if (-not $ok) { throw "failed to download $($f.Path) after $Retries attempts" }
}

# 3. sanity check: config.json + at least one weight shard must exist
if (-not (Test-Path -LiteralPath (Join-Path $TargetDir 'config.json'))) { throw "config.json missing in $TargetDir" }
$shards = @(Get-ChildItem -LiteralPath (Join-Path $TargetDir 'tensors') -Filter '*.safetensors' -ErrorAction SilentlyContinue)
if ($shards.Count -lt 1) { throw "no tensor shards in $TargetDir\tensors" }
Say "OK: checkpoint ready at $TargetDir ($($shards.Count) shards, $(HumanGiB $total))"
Say "set MODEL_DIR to this path (config.ps1 defaults here) and run .\start.ps1"
