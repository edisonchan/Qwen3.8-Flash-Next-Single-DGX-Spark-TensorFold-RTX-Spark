# package-release.ps1 — assemble a redistributable Windows ARM64 binary release.
#
# What goes in the zip:
#   * the prebuilt native engine (tensorfold\dist\native\bin\tensorfold-native.exe)
#   * the non-GPL runtime DLLs (turbojpeg / libwebpdecoder / libsharpyuv / pdfium / tfgrammar)
#   * the PowerShell runtime (start.ps1, stop.ps1, scripts\config.ps1, scripts\banner.ps1)
#   * scripts\download-model.ps1 (curl-only ModelScope downloader)
#   * scripts\build-gpl-video.ps1 + scripts\make_ffmpeg_defs.py (fetch GPL parts from
#     the official upstream sources ON THE USER'S MACHINE)
#   * README(s), LICENSE / NOTICE / CREDITS.md, THIRD-PARTY-NOTICES-RELEASE.md, .env.example
#   * SHA256SUMS.txt for every file in the package
#
# What never goes in the zip (and why):
#   * GPL video stack (FFmpeg av*/sw* DLLs, x264/x265, vmaf, dav1d, vpx, svt-av1, tfvideo.dll).
#     This repository does not redistribute them; build-gpl-video.ps1 downloads them from
#     pythonhosted.org (PyAV) and ffmpeg.org on the user's machine, so the distribution
#     always happens under the upstream projects' own terms.
#   * model weights (~95 GiB): download with scripts\download-model.ps1.
#   * CUDA runtime DLLs: users install CUDA Toolkit 13.4.3 GA themselves (NVIDIA EULA).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\scripts\package-release.ps1
#   options: -Version 'v1.2.7-win1'  -OutDir 'D:\tmp\release'

[CmdletBinding()]
param(
  [string]$ProjectRoot = '',
  [string]$OutDir = '',
  [string]$Version = 'v1.2.7-win1'
)
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 can hand an empty $PSScriptRoot to a param default; in the script
# body it is always set, so resolve the repo root (scripts' parent) here.
if (-not $ProjectRoot) {
  $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }
  $ProjectRoot = Split-Path -Parent $scriptDir
}

function Say([string]$m) { Write-Host "[package] $m" }
function Ok([string]$m)  { Write-Host "[package]   OK  $m" }
function Die([string]$m) { Write-Host "[package]   FAIL  $m" -ForegroundColor Red; exit 1 }

$Native   = Join-Path $ProjectRoot 'tensorfold\dist\native'
$Exe      = Join-Path $Native 'bin\tensorfold-native.exe'
$BinDir   = Join-Path $Native 'bin'
$LibDir   = Join-Path $Native 'lib'
$OptLibs  = Join-Path $ProjectRoot 'third_party\optional-libs'
if (-not $OutDir) { $OutDir = Join-Path $ProjectRoot 'dist-release' }
$Name     = "Qwen3.8-Flash-Next-Windows-ARM64-$Version"
$Staging  = Join-Path $OutDir $Name
$Zip      = Join-Path $OutDir "$Name.zip"

# The only DLL names allowed into the package besides the engine itself. Every one of
# these is fetched from a pinned upstream source by build.ps1 / build-gpl-video.ps1 and
# carries a non-GPL license (see THIRD-PARTY-NOTICES-RELEASE.md below).
$AllowedDlls = @(
  'turbojpeg.dll', 'pdfium.dll', 'tfgrammar.dll',
  'libwebpdecoder.dll', 'libsharpyuv.dll'
)
# Guard list: if any of these ever slips into the package, the build fails.
$GplPatterns = @(
  '^av', '^sw', '^libx264', '^libx265', '^libvmaf', '^libdav1d', '^libvpx',
  '^libSvtAv1', '^tfvideo', '^avicap32', '^msvfw32', '^libopus', '^libiconv',
  '^zlib1', '^libc\+\+', '^libwinpthread'
)

# ---------------------------------------------------------------- 1. preflight
Say "PREFLIGHT - $ProjectRoot  ($Version)"
if (-not (Test-Path -LiteralPath $Exe)) { Die "engine not built: $Exe — run .\build.ps1 first" }
$exeBytes = (Get-Item -LiteralPath $Exe).Length
Ok "engine $Exe ($exeBytes bytes)"
foreach ($n in $AllowedDlls) {
  $src = Join-Path $OptLibs $n
  if (-not (Test-Path -LiteralPath $src)) { Die "required non-GPL runtime DLL missing: $src (run .\build.ps1 to fetch it)" }
}
Ok "all $($AllowedDlls.Count) non-GPL runtime DLLs present in $OptLibs"

# ---------------------------------------------------------------- 2. staging
Say "STAGE - $Staging"
if (Test-Path -LiteralPath $Staging) { Remove-Item -LiteralPath $Staging -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $Staging 'tensorfold\dist\native\bin') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Staging 'tensorfold\dist\native\lib') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Staging 'scripts') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Staging 'docs\images') | Out-Null

# engine + its own bin-side DLL (libsharpyuv, needed next to the exe)
Copy-Item -LiteralPath $Exe -Destination (Join-Path $Staging 'tensorfold\dist\native\bin\tensorfold-native.exe')
$binSharpyuv = Join-Path $BinDir 'libsharpyuv.dll'
if (Test-Path -LiteralPath $binSharpyuv) { Copy-Item -LiteralPath $binSharpyuv -Destination (Join-Path $Staging 'tensorfold\dist\native\bin\libsharpyuv.dll') }

# runtime libs: allowlist only — never enumerate $LibDir itself, so GPL DLLs cannot leak in
foreach ($n in $AllowedDlls) {
  Copy-Item -LiteralPath (Join-Path $OptLibs $n) -Destination (Join-Path $Staging "tensorfold\dist\native\lib\$n")
}
Ok 'engine and non-GPL runtime DLLs staged (allowlist)'

# runtime scripts (byte-identical copies from the working tree)
foreach ($f in @('start.ps1', 'stop.ps1', 'menu.ps1', 'menu.bat')) {
  Copy-Item -LiteralPath (Join-Path $ProjectRoot $f) -Destination (Join-Path $Staging $f)
}
foreach ($f in @('config.ps1', 'banner.ps1', 'download-model.ps1', 'build-gpl-video.ps1', 'make_ffmpeg_defs.py')) {
  Copy-Item -LiteralPath (Join-Path $ProjectRoot "scripts\$f") -Destination (Join-Path $Staging "scripts\$f")
}
Ok 'runtime scripts staged (start/stop + scripts/)'

# docs
foreach ($f in @('README.md', 'README.en.md', 'README.upstream.md', 'build_skill.md', 'LICENSE', 'NOTICE', 'CREDITS.md')) {
  $p = Join-Path $ProjectRoot $f
  if (-not (Test-Path -LiteralPath $p)) { Die "missing $f in the repository root" }
  Copy-Item -LiteralPath $p -Destination (Join-Path $Staging $f)
}
foreach ($img in (Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'docs\images') -Filter '*.png' -ErrorAction SilentlyContinue)) {
  Copy-Item -LiteralPath $img.FullName -Destination (Join-Path $Staging "docs\images\$($img.Name)")
}
Ok 'docs and screenshots staged'

# ---------------------------------------------------------------- 3. generated files
$envExample = @(
  '# Copy this file to .env and adjust as needed. Environment variables set in the shell win over these lines.'
  'MODEL_DIR=D:\llm\models\Qwen3.8-Flash-Next-FP4-Local'
  'TENSORFOLD_IGNORE_STREAM_BUDGET=1'
  '# Optional absolute paths; by default the engine finds the DLLs under tensorfold\dist\native\lib by name.'
  '# TENSORFOLD_LIBTURBOJPEG='
  '# TENSORFOLD_LIBWEBP='
  '# TENSORFOLD_LIBPDFIUM='
) -join "`n"
[System.IO.File]::WriteAllText((Join-Path $Staging '.env.example'), $envExample + "`n", (New-Object System.Text.UTF8Encoding($false)))

$notices = @'
# Third-party notices — Windows ARM64 binary release

Binaries shipped in this package, with their upstream source and license:

| File | Upstream | Version | License | Obtained from |
| --- | --- | --- | --- | --- |
| `tensorfold-native.exe` | TensorFold (Ash Hart & contributors) | v1.2.7 (`93a2e93ecebff8aa52b88e58c5dd222516e69c5f`) + this repository's `patches/windows/0001..0008` | Apache-2.0 / early MIT | built from source locally by `build.ps1` (Zig 0.17.0 + VS2022 ARM64 + CUDA 13.4.3) |
| `turbojpeg.dll` | libjpeg-turbo | 3.1.1 (vc-arm64 release) | BSD-3-Clause (IJG) | https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.1.1/libjpeg-turbo-3.1.1-vc-arm64.exe |
| `pdfium.dll` | PDFium (pdfium-binaries) | chromium/7725 | BSD-3-Clause + sub-licenses | https://github.com/bblanchon/pdfium-binaries/releases/download/chromium/7725/pdfium-win-arm64.tgz |
| `tfgrammar.dll` | xgrammar (MLC-AI), bundles dlpack | 0.2.8 | Apache-2.0 | https://pypi.org/project/xgrammar/ (win_arm64 wheel) |
| `libwebpdecoder.dll`, `libsharpyuv.dll` | libwebp (webmproject) | 1.6.0 | BSD-3-Clause | win_arm64 wheel of PyAV 19.0.1 (files.pythonhosted.org) |

Engine source code: the engine is built from the pinned TensorFold checkout plus the
patches in this repository; `build.ps1` reproduces `tensorfold-native.exe` bit-for-bit
from those sources. See `NOTICE` and `CREDITS.md` for full attributions.

Deliberately NOT shipped in this package:

* **FFmpeg / x264 / x265 / vmaf DLLs and `tfvideo.dll` (GPLv2+)** — this repository does
  not redistribute GPL binaries. Run `scripts\build-gpl-video.ps1` on your machine: it
  downloads the DLLs from the official PyAV wheel on pythonhosted.org and the headers
  from ffmpeg.org, and assembles the video stack locally.
* **Model weights** — download with `scripts\download-model.ps1` (curl only). Weights are
  governed by the NVIDIA Open Model Agreement and the Qwen Community License 1.0.
* **CUDA runtime DLLs** — install CUDA Toolkit 13.4.3 GA yourself per the README
  (NVIDIA EULA).
'@
[System.IO.File]::WriteAllText((Join-Path $Staging 'THIRD-PARTY-NOTICES-RELEASE.md'), $notices + "`n", (New-Object System.Text.UTF8Encoding($false)))
Ok 'generated .env.example and THIRD-PARTY-NOTICES-RELEASE.md'

# ---------------------------------------------------------------- 4. GPL guard + checksums
Say "GUARD - scanning staged file set against the GPL blocklist"
$staged = Get-ChildItem -LiteralPath $Staging -Recurse -File
foreach ($f in $staged) {
  foreach ($pat in $GplPatterns) {
    if ($f.Name -match $pat) { Die "GPL component would ship in the release: $($f.FullName)" }
  }
}
Ok "no GPL artifacts among $($staged.Count) staged files"

Say 'SHA256SUMS'
$sums = foreach ($f in ($staged | Sort-Object FullName)) {
  $rel = $f.FullName.Substring($Staging.Length + 1).Replace('\', '/')
  (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $rel
}
[System.IO.File]::WriteAllLines((Join-Path $Staging 'SHA256SUMS.txt'), $sums, (New-Object System.Text.UTF8Encoding($false)))
Ok "SHA256SUMS.txt ($($sums.Count) entries)"

# ---------------------------------------------------------------- 5. zip
Say "ZIP - $Zip"
if (Test-Path -LiteralPath $Zip) { Remove-Item -LiteralPath $Zip -Force }
Compress-Archive -LiteralPath $Staging -DestinationPath $Zip
$zipItem = Get-Item -LiteralPath $Zip
Ok ("zip ready: {0}  ({1:N1} MB)" -f $zipItem.Name, ($zipItem.Length / 1MB))

Say 'NEXT STEPS'
Write-Host @"
  1. locally verify the package (no server start needed):
       cd $Staging
       .\tensorfold\dist\native\bin\tensorfold-native.exe capabilities --json
  2. publish on GitHub (after you approve):
       git tag -a $Version -m '$Version' && git push origin $Version
       GitHub -> Releases -> Draft new release -> tag $Version
       attach $Zip and paste SHA256SUMS.txt into the release notes
"@
