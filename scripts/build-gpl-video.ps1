# Rebuild the FFmpeg video stack for Windows 11 ARM64 natively - no MSYS2, no conda.
#
# WHAT IT PRODUCES (all under <project>\third_party, then tfvideo.dll in dist)
#   ffmpeg-dlls\    the FFmpeg 9.0.2 ARM64 DLLs (avcodec/avformat/avutil/swscale + companions)
#                   from the pinned PyAV 19.0.1 win_arm64 wheel.
#   ffmpeg-prefix\  the FFmpeg 9.0.2 public headers from the official source tarball plus the
#                   import libraries avcodec.lib / avformat.lib / avutil.lib / swscale.lib,
#                   generated from those DLLs with scripts\make_ffmpeg_defs.py + `zig dlltool`.
#   tensorfold\dist\native\lib\tfvideo.dll  built natively by `zig build video` against the
#                   prefix above (patch 0007 links the Windows import libraries).
#
# TOOLCHAIN - the same native toolchain as the engine build, nothing else:
#   - Zig 0.17.0 (aarch64-windows)   : `zig dlltool` for the import libs, `zig build video`
#   - python, curl, tar on PATH      : fetch/verify/extract
# No cross toolchain, no package manager, no shell environment beyond PowerShell.
#
# USAGE
#   powershell -ExecutionPolicy Bypass -File .\scripts\build-gpl-video.ps1
#   powershell -ExecutionPolicy Bypass -File .\scripts\build-gpl-video.ps1 -PreflightOnly
#   powershell -ExecutionPolicy Bypass -File .\scripts\build-gpl-video.ps1 -Force   # re-fetch

[CmdletBinding()]
param(
  [string]$ProjectRoot = '',
  [string]$ZigExe = 'D:\building\zig-aarch64-windows-0.17.0\zig.exe',
  [int]$Jobs = 0,
  [switch]$PreflightOnly,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
$ThirdParty = Join-Path $ProjectRoot 'third_party'
$DllOut     = Join-Path $ThirdParty 'ffmpeg-dlls'
$PrefixOut  = Join-Path $ThirdParty 'ffmpeg-prefix'
$Work       = Join-Path $ProjectRoot '.work\video-src'
$Defs       = Join-Path $ProjectRoot '.work\video-defs'
$Tensorfold = Join-Path $ProjectRoot 'tensorfold'
$Prefix     = Join-Path $Tensorfold 'dist'
if ($Jobs -le 0) { $Jobs = [int]${env:NUMBER_OF_PROCESSORS}; if ($Jobs -le 0) { $Jobs = 20 } }

# Pinned sources (exact URLs and SHA-256, verified on 2026-11-19).
$PyAvWheelUrl = 'https://files.pythonhosted.org/packages/a5/78/16864f1aa2c3ac5017f15132b85c6d3c74bb85caca8c45ce836ad30dfe20/av-19.0.1-cp312-abi3-win_arm64.whl'
$PyAvWheelSha = 'e9e1b0cae6cebd2adc2c5c6691fc890112f8f6c846b76a9135307617db1e32e9'
$FfSrcUrl     = 'https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz'
$FfSrcSha     = '8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e'

function Say  { param([string]$m) Write-Host "[video] $m" }
function Ok   { param([string]$m) Write-Host "  [ OK ] $m" -ForegroundColor Green }
function Miss { param([string]$m) Write-Host "  [MISS] $m" -ForegroundColor Red }
function Get-Sha256 { param([string]$p) (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() }

# ---------------------------------------------------------------- 1. PREFLIGHT (detect, never install)
Say 'PREFLIGHT - native video toolchain (Zig + python + curl + tar)'
$fail = $false
if (Test-Path -LiteralPath $ZigExe) { Ok "Zig: $ZigExe" } else { Miss "Zig not found: $ZigExe"; $fail = $true }
foreach ($t in @('python', 'curl', 'tar')) {
  if (Get-Command $t -ErrorAction SilentlyContinue) { Ok "$t on PATH" } else { Miss "$t not on PATH"; $fail = $true }
}
if ($fail -and -not $PreflightOnly) { throw 'Preflight failed: install the missing tool and re-run.' }
if ($PreflightOnly) { Say 'PreflightOnly: detection complete.'; if ($fail) { exit 1 } else { exit 0 } }

New-Item -ItemType Directory -Force -Path $DllOut, $Work, $Defs | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $PrefixOut 'lib'), (Join-Path $PrefixOut 'include') | Out-Null

# ---------------------------------------------------------------- 2. FETCH pinned archives + verify SHA-256
$wheel = Join-Path $Work 'av-19.0.1-cp312-abi3-win_arm64.whl'
$ffTar = Join-Path $Work 'ffmpeg-9.0.2.tar.xz'
foreach ($pair in @(@($wheel, $PyAvWheelUrl, $PyAvWheelSha), @($ffTar, $FfSrcUrl, $FfSrcSha))) {
  $dest = $pair[0]
  if ((-not (Test-Path -LiteralPath $dest)) -or $Force) {
    Say "downloading $([System.IO.Path]::GetFileName($dest)) ..."
    & curl -sSfL -o $dest $pair[1]
    if ($LASTEXITCODE -ne 0) { throw "download failed: $($pair[1])" }
  }
  $got = Get-Sha256 $dest
  if ($got -ne $pair[2]) { throw "SHA-256 mismatch for $([System.IO.Path]::GetFileName($dest)): got $got" }
  Ok "$([System.IO.Path]::GetFileName($dest)) sha256 verified"
}

# ---------------------------------------------------------------- 3. EXTRACT DLLs (from the PyAV wheel)
$python = (Get-Command python.exe -ErrorAction Stop).Source
$haveDlls = @(Get-ChildItem -LiteralPath $DllOut -Filter 'avcodec-*.dll' -ErrorAction SilentlyContinue).Count
if (($haveDlls -eq 0) -or $Force) {
  Say 'extracting FFmpeg DLLs from the PyAV wheel into third_party\ffmpeg-dlls'
  $pyExtract = Join-Path $Work 'extract_dlls.py'
  @'
import sys, zipfile, os, shutil
whl, dest = sys.argv[1], sys.argv[2]
n = 0
with zipfile.ZipFile(whl) as z:
    for m in z.namelist():
        if m.startswith("av.libs/") and m.endswith(".dll"):
            with z.open(m) as src, open(os.path.join(dest, os.path.basename(m)), "wb") as out:
                shutil.copyfileobj(src, out)
            n += 1
print("extracted", n, "DLLs")
'@ | Set-Content -LiteralPath $pyExtract -Encoding ascii
  & $python $pyExtract $wheel $DllOut
  if ($LASTEXITCODE -ne 0) { throw 'wheel extraction failed' }
}
foreach ($pat in @('avcodec-*.dll','avformat-*.dll','avutil-*.dll','swscale-*.dll')) {
  if (-not @(Get-ChildItem -LiteralPath $DllOut -Filter $pat).Count) { throw "missing $pat in $DllOut" }
}
Ok "FFmpeg DLLs present: $((Get-ChildItem -LiteralPath $DllOut -Filter '*.dll').Count)"

# ---------------------------------------------------------------- 4. EXTRACT headers (from the FFmpeg source tarball)
$incDir = Join-Path $PrefixOut 'include'
foreach ($d in @('libavcodec','libavformat','libavutil','libswscale')) {
  if ((-not (Test-Path -LiteralPath (Join-Path $incDir $d))) -or $Force) {
    Say "extracting $d headers from ffmpeg-9.0.2.tar.xz"
    & tar -xf $ffTar --strip-components=1 -C $incDir "ffmpeg-9.0.2/$d"
    if ($LASTEXITCODE -ne 0) { throw "tar extract failed for $d" }
  }
}
# Configure-generated headers, written with the exact content the validated build used.
$genHeaders = @{
  'libavutil\avconfig.h' = "#define AV_HAVE_BIGENDIAN 0`r`n#define AV_HAVE_FAST_UNALIGNED 1`r`n"
  'libavutil\ffversion.h' = "#define FFMPEG_VERSION ""9.0.2""`r`n"
}
foreach ($h in $genHeaders.Keys) {
  $p = Join-Path $incDir $h
  if ((-not (Test-Path -LiteralPath $p)) -or $Force) {
    [System.IO.File]::WriteAllText($p, $genHeaders[$h], (New-Object System.Text.UTF8Encoding($false)))
    Ok "generated $h"
  }
}
Ok "headers: $((Get-ChildItem -LiteralPath $incDir -Recurse -Filter '*.h').Count) files"

# ---------------------------------------------------------------- 5. IMPORT LIBRARIES (.def + zig dlltool)
$libDir = Join-Path $PrefixOut 'lib'
$libsOk = $true
foreach ($name in @('avcodec','avformat','avutil','swscale')) {
  if ((-not (Test-Path -LiteralPath (Join-Path $libDir "$name.lib"))) -or $Force) { $libsOk = $false }
}
if (-not $libsOk) {
  Say 'generating .def files from the DLL exports'
  & $python (Join-Path $PSScriptRoot 'make_ffmpeg_defs.py') $DllOut $Defs
  if ($LASTEXITCODE -ne 0) { throw 'make_ffmpeg_defs.py failed' }
  foreach ($name in @('avcodec','avformat','avutil','swscale')) {
    $def = Join-Path $Defs "$name.def"
    $dllName = (Select-String -LiteralPath $def -Pattern '^LIBRARY "(.*)"').Matches[0].Groups[1].Value
    Say "zig dlltool: $name.def -> $name.lib (target arm64, DLL $dllName)"
    & $ZigExe dlltool -d $def -l (Join-Path $libDir "$name.lib") -m arm64 -D $dllName
    if ($LASTEXITCODE -ne 0) { throw "zig dlltool failed for $name" }
  }
}
foreach ($name in @('avcodec','avformat','avutil','swscale')) {
  if (-not (Test-Path -LiteralPath (Join-Path $libDir "$name.lib"))) { throw "import lib missing: $name.lib" }
  Ok "$name.lib"
}

# ---------------------------------------------------------------- 6. BUILD tfvideo.dll (native zig)
if (Test-Path -LiteralPath (Join-Path $Tensorfold 'build.zig')) {
  Say "zig build -j$Jobs video -Dffmpeg=$PrefixOut"
  Push-Location $Tensorfold
  try {
    & $ZigExe build "-j$Jobs" video "-Dffmpeg=$PrefixOut" --prefix $Prefix
    $rc = $LASTEXITCODE
  } finally { Pop-Location }
  if ($rc -ne 0) { throw "zig build video failed (exit $rc)" }
  $tfvideo = Join-Path $Prefix 'native\lib\tfvideo.dll'
  if (-not (Test-Path -LiteralPath $tfvideo)) { throw "tfvideo.dll missing: $tfvideo" }
  Remove-Item -LiteralPath (Join-Path $Prefix 'native\lib\tfvideo.pdb') -ErrorAction SilentlyContinue
  Ok "tfvideo.dll: $tfvideo"
} else {
  Say "tensorfold checkout not present yet - tfvideo.dll is built by the engine stage (build.ps1)"
}

# ---------------------------------------------------------------- 7. VERIFY (PE architecture)
foreach ($pat in @('avcodec-*.dll','avformat-*.dll','avutil-*.dll','swscale-*.dll')) {
  $dll = Get-ChildItem -LiteralPath $DllOut -Filter $pat | Select-Object -First 1
  $bytes = [System.IO.File]::ReadAllBytes($dll.FullName)
  $pe = [BitConverter]::ToInt32($bytes, 0x3c)
  $machine = [BitConverter]::ToUInt16($bytes, $pe + 4)
  if ($machine -ne 0xaa64) { throw "$($dll.Name) is not ARM64 (machine=0x$($machine.ToString('x4')))" }
  Ok "$($dll.Name): ARM64"
}
Say 'OK - FFmpeg video stack rebuilt natively (wheel DLLs + source headers + import libs + tfvideo.dll)'
