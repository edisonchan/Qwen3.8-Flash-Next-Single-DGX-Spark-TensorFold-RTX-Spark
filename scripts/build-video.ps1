# Build the optional Windows ARM64 libtfvideo and install every optional runtime DLL into tensorfold\dist.
# All third-party inputs are vendored under <project>\third_party, so no network or package manager is used.
param(
  [string]$ZigExe = 'D:\building\zig-aarch64-windows-0.17.0\zig.exe',
  [string]$Tensorfold = '',
  [string]$Prefix = '',
  [int]$Jobs = 0
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $Tensorfold) { $Tensorfold = Join-Path $RepoRoot 'tensorfold' }
if (-not $Prefix) { $Prefix = Join-Path $Tensorfold 'dist' }
if ($Jobs -le 0) { $Jobs = [int](${env:NUMBER_OF_PROCESSORS}) ; if ($Jobs -le 0) { $Jobs = 20 } }
$ThirdParty = Join-Path $RepoRoot 'third_party'
$FfmpegPrefix = Join-Path $ThirdParty 'ffmpeg-prefix'
$LibDir = Join-Path $Prefix 'native\lib'
$BinDir = Join-Path $Prefix 'native\bin'

function Say { param([string]$Message) Write-Host "[build-video] $Message" }

foreach ($dir in @($ThirdParty, $FfmpegPrefix, (Join-Path $ThirdParty 'ffmpeg-dlls'), (Join-Path $ThirdParty 'optional-libs'))) {
  if (-not (Test-Path -LiteralPath $dir)) { throw "missing vendored input: $dir" }
}
if (-not (Test-Path -LiteralPath $ZigExe)) { throw "Zig not found: $ZigExe" }
New-Item -ItemType Directory -Force -Path $LibDir, $BinDir | Out-Null

# 1. The five libraries the engine looks for by name. libwebpdecoder.dll is the libwebp 1.6.0
#    decoder build renamed to the file name v1.2.7's env-var path expects on Windows.
Say 'installing optional runtime libraries'
foreach ($name in @('turbojpeg.dll', 'tfgrammar.dll', 'libwebpdecoder.dll', 'libsharpyuv.dll', 'pdfium.dll')) {
  Copy-Item -LiteralPath (Join-Path $ThirdParty "optional-libs\$name") -Destination (Join-Path $LibDir $name) -Force
}
# LoadLibrary resolves a DLL's dependencies through the process PATH; libsharpyuv must also sit
# beside the executable for the WebP decoder loaded by absolute path.
Copy-Item -LiteralPath (Join-Path $ThirdParty 'optional-libs\libsharpyuv.dll') -Destination (Join-Path $BinDir 'libsharpyuv.dll') -Force

# 2. libtfvideo over the FFmpeg 9.0.2 DLLs shipped by PyAV 19.0.1. The import libraries and headers
#    are vendored in third_party\ffmpeg-prefix; patch 0007 switches this step to DLL linking on Windows.
Say "zig build -j$Jobs video -Dffmpeg=$FfmpegPrefix"
$old = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
Push-Location $Tensorfold
try {
  & $ZigExe build "-j$Jobs" video "-Dffmpeg=$FfmpegPrefix" --prefix $Prefix
  $rc = $LASTEXITCODE
} finally {
  Pop-Location
  $ErrorActionPreference = $old
}
if ($rc -ne 0) { throw "zig build video failed (exit $rc)" }

# 3. FFmpeg DLLs must travel with tfvideo.dll; a PDB is not part of the runtime.
foreach ($dll in (Get-ChildItem -LiteralPath (Join-Path $ThirdParty 'ffmpeg-dlls') -Filter '*.dll')) {
  Copy-Item -LiteralPath $dll.FullName -Destination (Join-Path $LibDir $dll.Name) -Force
}
Remove-Item -LiteralPath (Join-Path $LibDir 'tfvideo.pdb') -ErrorAction SilentlyContinue

# 4. Build intermediates from this step only; the main build script cleans its own caches.
$git = (Get-Command git.exe -ErrorAction Stop).Source
foreach ($dir in @('.zig-cache', 'zig-out')) {
  $full = Join-Path $Tensorfold $dir
  if (-not (Test-Path -LiteralPath $full)) { continue }
  & $git -C $Tensorfold clean -fdx -- $dir 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { Remove-Item -LiteralPath $full -Recurse -Force }
}

$exe = Join-Path $LibDir 'tfvideo.dll'
if (-not (Test-Path -LiteralPath $exe)) { throw "build finished but $exe is missing" }
Say "OK: $exe"
Say 'optional DLLs installed in native\lib (and native\bin for libsharpyuv)'
