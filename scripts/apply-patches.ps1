# Apply this recipe's patches to the TensorFold checkout at <project>\tensorfold.
# The patch files in patches\windows are the Linux patches with LF line endings (git apply on Windows
# rejects the original CRLF files) and Windows-specific wording where a library name changed.
# Idempotent: an already applied patch is skipped by looking for its own added lines in each target file.
param(
  [string]$Tensorfold = '',
  [string]$PatchDir = '',
  [switch]$Reset
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $Tensorfold) { $Tensorfold = Join-Path $RepoRoot 'tensorfold' }
if (-not $PatchDir) { $PatchDir = Join-Path $RepoRoot 'patches\windows' }
if (-not (Test-Path -LiteralPath (Join-Path $Tensorfold 'build.zig'))) {
  throw "TensorFold checkout not found at $Tensorfold; clone TF_REF first (see scripts\build.ps1)"
}
if (-not (Test-Path -LiteralPath $PatchDir)) { throw "patch directory not found: $PatchDir" }
$git = (Get-Command git.exe -ErrorAction Stop).Source

function Invoke-Git {
  param([string[]]$Arguments)
  $old = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $text = & $git -C $Tensorfold @Arguments 2>&1
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = (($text | ForEach-Object { "$_" }) -join "`n") }
  } finally { $ErrorActionPreference = $old }
}
function Say { param([string]$Message) Write-Host "[apply-patches] $Message" }

Invoke-Git @('config', 'core.autocrlf', 'false') | Out-Null
if ($Reset) {
  Say 'resetting the checkout to the pinned revision (drops local changes)'
  Invoke-Git @('reset', '--hard', 'HEAD') | Out-Null
  Invoke-Git @('clean', '-fdq') | Out-Null
}
$head = (Invoke-Git @('rev-parse', 'HEAD')).Text.Trim()
Say "TensorFold $head"

function Test-PatchApplied {
  # A later patch can touch the same file, so `git apply -R --check` is not a reliable marker.
  # For every file a patch touches, look for two of its added lines in that file.
  param([System.IO.FileInfo]$Patch)
  $lines = @(Get-Content -LiteralPath $Patch.FullName -Encoding UTF8)
  $markers = @{}
  $target = ''
  foreach ($line in $lines) {
    if ($line -match '^\+\+\+ b/(.+)$') { $target = $Matches[1]; continue }
    if (-not $target -or -not $line.StartsWith('+') -or $line.StartsWith('+++')) { continue }
    $text = $line.Substring(1).TrimEnd()
    if ($text.Length -eq 0) { continue }
    if (-not $markers.ContainsKey($target)) { $markers[$target] = @() }
    if ($markers[$target].Count -lt 2) { $markers[$target] += @($text) }
  }
  if ($markers.Count -eq 0) { return $false }
  foreach ($entry in $markers.GetEnumerator()) {
    $file = Join-Path $Tensorfold ($entry.Key -replace '/', '\')
    if (-not (Test-Path -LiteralPath $file)) { return $false }
    $content = Get-Content -LiteralPath $file -Raw -Encoding UTF8
    foreach ($text in $entry.Value) { if (-not $content.Contains($text)) { return $false } }
  }
  return $true
}

foreach ($patch in (Get-ChildItem -LiteralPath $PatchDir -Filter '*.patch' | Sort-Object Name)) {
  if (Test-PatchApplied $patch) { Say "already applied: $($patch.Name)"; continue }
  $check = Invoke-Git @('apply', '--check', $patch.FullName)
  if ($check.Code -ne 0) {
    throw "patch $($patch.Name) does not apply to $head (run with -Reset to restore the pinned tree).`n$($check.Text)"
  }
  $result = Invoke-Git @('apply', $patch.FullName)
  if ($result.Code -ne 0) { throw "could not apply $($patch.Name):`n$($result.Text)" }
  Say "applied: $($patch.Name)"
}
Say 'all patches applied'
