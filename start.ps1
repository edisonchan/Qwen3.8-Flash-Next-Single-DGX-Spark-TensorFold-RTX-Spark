# Serve Qwen3.8 Flash Next (NVIDIA's QAD FP4 checkpoint by default) with TensorFold v1.2.7's Zig engine on one
# Windows 11 ARM machine: checks that the engine binary and the checkpoint are in place, launches tensorfold-native
# serve out of tensorfold\dist on port 8888, waits until the OpenAI API answers, then runs a smoke test.
# Stop it with .\stop.ps1. This is the 1:1 Windows port of ./start.sh.
#
# Usage: .\start.ps1 [restart] [extra tensorfold-native serve args]
#   .\start.ps1                         # up to 5 requests at once, a 262,144-token window, fp8 KV, images, MTP drafts
#   .\start.ps1 restart                 # stop, then start again; the new arguments are checked before stopping
#   .\start.ps1 restart --parallel 2 --context 131072
#   $env:CONTEXT=131072; .\start.ps1 restart  # a shorter window leaves more of the KV pool to the other streams
#   $env:DRAFTS=0; .\start.ps1 restart        # no MTP drafts (--no-drafts)
#   $env:DRY_RUN=1; .\start.ps1               # print the engine command and exit
# Extra arguments go to tensorfold-native serve after the defaults, so they win.
# Settings, from the environment or .\.env (scripts\config.ps1):
#   serving  CONTEXT, PARALLEL, MAX_TOKENS, THINKING, DRAFTS, TEMPERATURE, TOP_P, TOP_K, SERVED_NAME, HOST, PORT
#   files    CHECKPOINT, MODEL_ID, MODEL_REVISION, MODEL_DIR, HF_CACHE, STATE_DIR, DIST_DIR
#   vision   VISION (0|1), VISION_URLS (0|1), PDF (0|1), VIDEO (0|1)
#   setup    FOREGROUND=1, WAIT_TIMEOUT, DRY_RUN=1, MEM_NEED_GIB, MEM_CHECK=0,
#            CUDA_BUDGET_GIB, COMMIT_CHECK=0, FORCE_LOCK=1
#   engine   every TENSORFOLD_* and TF_FLASHNEXT_* variable reaches the child; KV_DTYPE is fp8 or bf16.

$ErrorActionPreference = 'Stop'
$LogName = 'start.ps1'
$global:LASTEXITCODE = 0
. (Join-Path $PSScriptRoot 'scripts\config.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
. (Join-Path $PSScriptRoot 'scripts\banner.ps1')

function Show-Usage {
  foreach ($line in (Get-Content -LiteralPath $PSCommandPath -Encoding UTF8)) {
    if ($line -match '^#') { Write-Host ($line -replace '^# ?', '') }
  }
}

$WaitTimeout = [int](Get-EnvOr 'WAIT_TIMEOUT' '1800')
$Mode = 'start'
$Passthrough = @()
if ($args.Count -gt 0) { $Passthrough = @($args) }
if ($Passthrough.Count -gt 0 -and $Passthrough[0] -eq 'restart') {
  $Mode = 'restart'
  if ($Passthrough.Count -gt 1) { $Passthrough = @($Passthrough[1..($Passthrough.Count - 1)]) } else { $Passthrough = @() }
}
if ($Passthrough.Count -gt 0 -and $Passthrough[0] -eq 'help') { Show-Usage; exit 0 }
foreach ($argument in $Passthrough) {
  if ($argument -eq '-h' -or $argument -eq '--help') { Show-Usage; exit 0 }
}

# ---------------------------------------------------------------- validation (start.sh's lines 37-53)
if ("$Context" -notmatch '^[1-9][0-9]*$' -or $Context -gt 1048576) { die "CONTEXT is a token count up to 1048576, not $Context" }
if ($Parallel -lt 1 -or $Parallel -gt 16) { die "PARALLEL is 1 to 16, not $Parallel" }
if ("$MaxTokens" -notmatch '^[1-9][0-9]*$') { die "MAX_TOKENS is a token count, not $MaxTokens" }
foreach ($pair in @(@('THINKING', $Thinking), @('DRAFTS', $Drafts), @('VISION', $Vision),
                     @('VISION_URLS', $VisionUrls), @('PDF', $Pdf), @('VIDEO', $Video))) {
  if ($pair[1] -notmatch '^[01]$') { die "$($pair[0]) is 0 or 1, not $($pair[1])" }
}
if ($Pdf -eq '1' -and $Vision -ne '1') { die 'PDF=1 renders pages through the vision path: start it with VISION=1 (the default)' }
if ($Video -eq '1' -and $Vision -ne '1') { die 'VIDEO=1 decodes through the vision path: start it with VISION=1 (the default)' }
if ($Context -gt 262144) { die "CONTEXT=$Context is past 262,144: TensorFold 1.2.7's Flash Next engine has no YaRN extension" }
$DryRun = 0
if ((Get-EnvOr 'DRY_RUN' '0') -eq '1') { $DryRun = 1 }

# ---------------------------------------------------------------- SERVE_ARGS (same order as start.sh)
$ServeArgs = New-Object System.Collections.Generic.List[string]
$ServeArgs.Add('--context'); $ServeArgs.Add("$Context")
$ServeArgs.Add('--parallel'); $ServeArgs.Add("$Parallel")
$ServeArgs.Add('--max-tokens'); $ServeArgs.Add("$MaxTokens")
$ServeArgs.Add('--temperature'); $ServeArgs.Add("$Temperature")
$ServeArgs.Add('--top-p'); $ServeArgs.Add("$TopP")
$ServeArgs.Add('--top-k'); $ServeArgs.Add("$TopK")
if ($Thinking -eq '1') { $ServeArgs.Add('--thinking') } else { $ServeArgs.Add('--no-thinking') }
if ($Drafts -ne '1') { $ServeArgs.Add('--no-drafts') }
if ($KvDtype -notmatch '^(bf16|fp8)$') { die "KV_DTYPE is bf16 or fp8, not $KvDtype" }
$ServeArgs.Add('--kv-cache'); $ServeArgs.Add($KvDtype)
if ("$MaxVideos" -notmatch '^[0-9]+$') { die "MAX_VIDEOS is a count, not $MaxVideos" }
$videoTokens = "$($env:TENSORFOLD_VIDEO_TOKENS)"
if ($videoTokens -notmatch '^[0-9]+$') { die "TENSORFOLD_VIDEO_TOKENS is a token count, not $videoTokens" }
if ($Vision -eq '1') {
  $ServeArgs.Add('--vision')
  $ServeArgs.Add('--vision-max-images'); $ServeArgs.Add("$($env:TENSORFOLD_MAX_IMAGES)")
  $ServeArgs.Add('--vision-max-videos'); $ServeArgs.Add("$MaxVideos")
  $ServeArgs.Add('--vision-image-tokens'); $ServeArgs.Add("$($env:TENSORFOLD_IMAGE_TOKENS)")
  if ($VisionUrls -eq '1') { $ServeArgs.Add('--vision-urls') }
  if ($Pdf -eq '1') { $ServeArgs.Add('--vision-pdf') }
  if ([int]$videoTokens -lt 64 -or [int]$videoTokens -gt 262144) {
    die "TENSORFOLD_VIDEO_TOKENS is 64 to 262144 (the engine's range for --vision-video-tokens), not $videoTokens"
  }
  if ($Video -eq '1') { $ServeArgs.Add('--vision-video-tokens'); $ServeArgs.Add($videoTokens) }
}
foreach ($extra in $Passthrough) { $ServeArgs.Add($extra) }

function Get-ArgValue {
  param([string]$Flag, $List)
  $value = ''
  for ($i = 0; $i -lt $List.Count; $i++) {
    if ($List[$i] -eq $Flag) { if ($i + 1 -lt $List.Count) { $value = "$($List[$i + 1])" } }
    elseif ("$($List[$i])".StartsWith("$Flag=")) { $value = "$($List[$i])".Substring($Flag.Length + 1) }
  }
  return $value
}
function Format-Argument {
  param([string]$Value)
  if ($Value -match '\s' -and $Value -notmatch '^"') { return '"' + $Value + '"' }
  return $Value
}

$ApiUrl = Get-ApiBaseUrl
$CheckpointDir = Get-CheckpointDir
$NeedGiB = 0
if ($MemNeedGiB) { $NeedGiB = [int]$MemNeedGiB } else { $NeedGiB = Get-MemNeedGiB ([int](Get-ArgValue '--context' $ServeArgs)) }

# ---------------------------------------------------------------- banner and progress
$Bold = ''; $Magenta = ''; $Green = ''; $Dim = ''; $Reset = ''
if ($OnConsole) {
  $Bold = "$([char]27)[1m"; $Magenta = "$([char]27)[1;35m"; $Green = "$([char]27)[1;32m"
  $Dim = "$([char]27)[2m"; $Reset = "$([char]27)[0m"
}
Write-Host ''
Show-Banner
Write-Host "  $Magenta  Mia's TensorFold Start Script$Reset"
$visionTag = 'off'; if ($Vision -eq '1') { $visionTag = 'on' }
$draftTag = 'off'; if ($Drafts -eq '1') { $draftTag = 'MTP' }
$ablitTag = ''; if ($Ablit -eq '1') { $ablitTag = ' + ablit' }
Write-Host "  $Dim  $ModelId$ablitTag | $(Get-ArgValue '--parallel' $ServeArgs) at once | $(Get-ArgValue '--context' $ServeArgs)-token window | $KvDtype KV | vision $visionTag | drafts $draftTag | port $Port$Reset"
Write-Host ''
$Steps = 5
function step {
  param([int]$Index, [string]$Text)
  Write-Host "$Magenta[$Index/$Steps]$Reset $Bold$Text$Reset"
}

New-Item -ItemType Directory -Force -Path $KernelCache, $StateDir, $LogDir, $env:CUDA_CACHE_PATH | Out-Null
$startLock = $null
$startLockHeld = $false
foreach ($candidate in (Get-StartLockNames)) {
  try { $startLock = New-Object System.Threading.Mutex($false, $candidate); break } catch { $startLock = $null }
}
if (-not $startLock) { die 'could not open the start lock (see scripts\config.ps1)' }
try { $startLockHeld = $startLock.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $startLockHeld = $true }
if (-not $startLockHeld) {
  $startLock.Dispose()
  $detail = ''
  $owner = Get-StartLockOwner
  if ($owner -match '^([0-9]+)\|(.+)$') {
    $ownerPid = [int]$Matches[1]; $since = $Matches[2]
    $proc = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
    $alive = 'no longer running'; if ($proc) { $alive = "still alive ($($proc.ProcessName))" }
    $detail = " | holder PID $ownerPid ($alive), since $since"
  }
  die "another start.ps1 is already running; wait for it to finish$detail | if that run is gone, start with a fresh lock: `$env:FORCE_LOCK=1; .\start.ps1"
}
Set-StartLockOwner "$PID|$((Get-Date).ToUniversalTime().ToString('o'))"

try {
if ($DryRun -eq 1) { log 'DRY_RUN=1: printing the engine command; nothing is stopped or started' }
if ($DryRun -eq 0 -and $Mode -eq 'start' -and (Test-ServerRunning)) {
  $current = Get-ServedName; if (-not $current) { $current = 'not answering yet' }
  log "$ServedName is already running (PID $((Get-ServerProcess).Id), model: $current, port $Port): nothing to do."
  log 'Use .\start.ps1 restart to restart it, or .\stop.ps1 to stop it.'
  exit 0
}

# ---------------------------------------------------------------- step 1
step 1 'Setup: engine binary and checkpoint'
function missing {
  param([string]$Message)
  if ($DryRun -eq 1) { warn $Message } else { die $Message }
}
$haveEngine = 1
if (-not (Test-Path -LiteralPath $EngineExe)) {
  $haveEngine = 0
  missing "$EngineExe is missing: run .\scripts\build.ps1 (or point DIST_DIR at an existing build)"
}
if (-not (Test-Path -LiteralPath (Join-Path $CheckpointDir 'config.json'))) {
  missing "$ModelId is not in ${CheckpointDir}: put the FP4 checkpoint there (or set MODEL_DIR)"
}
if ($haveEngine -eq 1) { log "Ready: $EngineExe and $ModelId" }
if ($Video -eq '1' -and -not (Test-Path -LiteralPath (Join-Path $EngineLibDir 'tfvideo.dll'))) {
  warn "VIDEO=1 but $EngineLibDir\tfvideo.dll is missing: video parts will be refused until the library is built"
}

# ---------------------------------------------------------------- step 2
step 2 'Checks: arguments, previous server, port, memory'
if ($haveEngine -eq 1) {
  $checkArgs = @('serve', (Join-Path $StateDir 'argument-check'), '--name', $ServedName, '--host', $BindHost,
                 '--port', "$Port") + $ServeArgs.ToArray()
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $EngineExe
  $psi.Arguments = (($checkArgs | ForEach-Object { Format-Argument "$_" }) -join ' ')
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $errText = ''
  try {
    $checkProc = [System.Diagnostics.Process]::Start($psi)
    $checkErr = $checkProc.StandardError.ReadToEndAsync()
    $checkOut = $checkProc.StandardOutput.ReadToEndAsync()
    if (-not $checkProc.WaitForExit(60000)) { $checkProc.Kill() }
    $errText = "$($checkErr.Result)$($checkOut.Result)"
  } catch {
    if ($DryRun -eq 1) { warn "DRY_RUN: could not run $EngineExe to check the arguments" }
    else { die "could not run $EngineExe to check the arguments: $($_.Exception.Message)" }
  }
  if ($errText -notmatch 'neither a\s+directory') {
    $tail = ($errText -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '^usage:' } | Select-Object -Last 1)
    if ($DryRun -eq 1) { warn "DRY_RUN: tensorfold-native rejects these arguments: $tail" }
    else { Write-Host $errText; die 'tensorfold-native serve rejects these arguments; nothing was changed' }
  }
}
if ($DryRun -eq 1) {
  if (Test-ServerRunning) { log 'DRY_RUN: a server is running; a real start would stop it first' }
} elseif (($Mode -eq 'restart' -or $Mode -eq 'start') -and (Test-ServerRunning)) {
  if ($Mode -eq 'start') { log 'A server was left running: stopping it, then starting' }
  & (Join-Path $PSScriptRoot 'stop.ps1')
  if ($LASTEXITCODE -ne 0) { die '.\stop.ps1 failed; the previous server may still hold the port' }
}
if ((Test-Path -LiteralPath $PidFile) -and -not (Test-ServerRunning)) {
  log 'Removing the stale PID file of a previous server'
  Remove-Item -LiteralPath $PidFile -ErrorAction SilentlyContinue
}
if ($DryRun -eq 1) {
  if (Test-PortListening $Port) { log "DRY_RUN: port $Port is in use" }
} elseif (Test-PortListening $Port) {
  die "port $Port is already in use: $(Get-PortOwner $Port)"
}
$availGb = Get-EffectiveGiB
$usedGb = [double](Get-GpuUsedGiB)
$freeGb = Get-GpuFreeGiB
if ($availGb -ge $NeedGiB) {
  log "Arguments OK, port $Port free, $availGb GiB CUDA allocation budget (cuMemGetInfo); $usedGb GiB of the WDDM GPU pool committed, $freeGb GiB free (this window needs ~$NeedGiB at start)"
} else {
  $message = "only $availGb GiB of CUDA allocation budget; a $(Get-ArgValue '--context' $ServeArgs)-token window needs ~$NeedGiB"
  if ($availGb -lt $WeightsGiB) { $message += " | the checkpoint alone loads $WeightsGiB GiB, so this machine cannot serve it here" }
  if ($MemCheck -eq '0') { log "$message (MEM_CHECK=0)" } else { warn $message }
}
$commitGb = Get-CommitFreeGiB
if ($CommitCheck -eq '1' -and $commitGb -ge 0 -and $commitGb -lt $NeedGiB) {
  warn "Windows system commit has only $commitGb GiB free (commit limit minus committed); WDDM backs CUDA allocations with commit, so loading ~$WeightsGiB GiB can fail even with $availGb GiB of CUDA memory"
  warn 'Raise the page file (initial 98304 MB, maximum 131072 MB) and reboot, or set COMMIT_CHECK=0 to silence this'
}
$fullWindow = Get-KvGiB ([int](Get-ArgValue '--context' $ServeArgs))
$reserveGiB = [int]$env:TENSORFOLD_MEMORY_RESERVE_GIB
$visionGiB = 0
if ($Vision -eq '1') { $visionGiB = [int][math]::Ceiling([int]$env:TENSORFOLD_VISION_WORKSPACE_MIB / 1024.0) }
$cacheRoom = $availGb - $WeightsGiB - $reserveGiB - $visionGiB
$windowsFit = [int][math]::Floor($cacheRoom / [double]$fullWindow)
$effectiveParallel = [int](Get-ArgValue '--parallel' $ServeArgs)
if ($effectiveParallel * $fullWindow + $WeightsGiB + $reserveGiB + $visionGiB -gt $availGb) {
  $hint = "--parallel $([math]::Max(1, $windowsFit)) for this start, or PARALLEL=$([math]::Max(1, $windowsFit)) in .env to make it stick"
  if ($windowsFit -lt 1) { $hint = 'a smaller CONTEXT or VISION=0' }
  warn "$effectiveParallel full windows are ~$($effectiveParallel * $fullWindow) GiB of $KvDtype cache beside ~$WeightsGiB GiB of weights, a $reserveGiB GiB reserve and $visionGiB GiB of vision workspace, past the ~$availGb GiB CUDA budget: $cacheRoom GiB are left for the caches, which fits $windowsFit full window(s). Start with $hint; streams share the pool and the engine refuses a request that would not fit"
}

# ---------------------------------------------------------------- step 3
step 3 "Launch: tensorfold-native (native process, no container)"
$launchArgs = @('serve') + @((Format-Argument $CheckpointDir)) +
              @('--name', $ServedName, '--host', $BindHost, '--port', "$Port") +
              ($ServeArgs | ForEach-Object { Format-Argument "$_" })
$launchLine = (($launchArgs | ForEach-Object { '"' + $_ + '"' }) -join ' ')
log "tensorfold-native serve $CheckpointDir --name $ServedName --host $BindHost --port $Port $($ServeArgs.ToArray() -join ' ')"
if ($DryRun -eq 1) { Write-Host "[dry-run]`n  $EngineExe $launchLine"; exit 0 }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outLog = Join-Path $LogDir "server-$stamp.out.log"
$errLog = Join-Path $LogDir "server-$stamp.err.log"
Set-Content -LiteralPath $LogPointer -Value ("$outLog`n$errLog") -Encoding UTF8
foreach ($pair in @(@('TENSORFOLD_LIBTURBOJPEG', 'turbojpeg.dll'), @('TENSORFOLD_LIBWEBP', 'libwebp.dll'))) {
  $candidate = Join-Path $EngineLibDir $pair[1]
  if (Test-Path -LiteralPath $candidate) {
    [Environment]::SetEnvironmentVariable($pair[0], $candidate, 'Process')
    log "Decoder: $($pair[0]) = $candidate"
  }
}
$server = Start-Process -FilePath $EngineExe -ArgumentList $launchLine -PassThru -WindowStyle Hidden `
  -RedirectStandardOutput $outLog -RedirectStandardError $errLog -WorkingDirectory $RepoRoot
Set-Content -LiteralPath $PidFile -Value $server.Id -NoNewline
log "Server started (PID $($server.Id)); its output goes to $outLog"

# ---------------------------------------------------------------- log tailing
$Noise = '^\s*$|^=+$|^NVIDIA Release|Copyright|All rights reserved|' +
         '^\[tensorfold\] [^ ]+ "GET /(health|v1/models|models|metrics|stats|slots)[ ?]'
$script:logOffsets = @{}
function Show-NewLog {
  foreach ($file in @($outLog, $errLog)) {
    if (-not (Test-Path -LiteralPath $file)) { continue }
    $offset = 0
    if ($script:logOffsets.ContainsKey($file)) { $offset = $script:logOffsets[$file] }
    $stream = $null
    try {
      $stream = [System.IO.File]::Open($file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
      $length = $stream.Length
      if ($length -gt $offset) {
        [void]$stream.Seek($offset, [System.IO.SeekOrigin]::Begin)
        $buffer = New-Object byte[] ($length - $offset)
        $read = $stream.Read($buffer, 0, $buffer.Length)
        $script:logOffsets[$file] = $offset + $read
        $chunk = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
        foreach ($line in ($chunk -split "`r?`n")) {
          if ($line -match $Noise) { continue }
          if ($line.Trim().Length -gt 0) { Write-Host "  $Dim|$Reset $line" }
        }
      }
    } catch { } finally { if ($stream) { $stream.Dispose() } }
  }
}
function Show-CurrentLog {
  foreach ($file in @($outLog, $errLog)) {
    if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file -Tail 40 | ForEach-Object { Write-Host "  | $_" } }
  }
}
function fail {
  param([string]$Message)
  Write-Host ''
  Write-Host "$Dim-- last server log lines --$Reset"
  Show-CurrentLog
  die $Message
}

if ((Get-EnvOr 'FOREGROUND' '0') -eq '1') {
  try {
    while (-not $server.HasExited) { Show-NewLog; Start-Sleep -Milliseconds 500 }
    Show-NewLog
  } finally { Remove-Item -LiteralPath $PidFile -ErrorAction SilentlyContinue }
  exit $server.ExitCode
}

# ---------------------------------------------------------------- step 4
step 4 "Loading: ~$WeightsGiB GiB of weights (the FP8 n-gram table included)"
$started = Get-Date
$nextBeat = 15
$script:floorWarned = $false
while (-not (Test-ApiReady)) {
  if ($server.HasExited) {
    $crash = ''
    foreach ($file in @($errLog, $outLog)) { if (Test-Path -LiteralPath $file) { $crash += (Get-Content -LiteralPath $file -Raw -ErrorAction SilentlyContinue) } }
    $blockers = @()
    if ($crash -match 'nvcuda|CUDA driver|cudaErrorNoDevice') { $blockers += 'the CUDA driver did not answer: check that nvcuda.dll is present (nvidia-smi -L)' }
    if ($crash -match 'sm_121|no kernel image') { $blockers += 'the binary was built for another SASS target: rebuild for sm_121' }
    if ($crash -match 'neither a directory|no such file') { $blockers += "the checkpoint is not where the engine looks: $CheckpointDir" }
    if ($blockers.Count -gt 0) { foreach ($blocker in $blockers) { warn "  - $blocker" } }
    fail "the server exited (code $($server.ExitCode)) before it was ready"
  }
  $elapsed = ((Get-Date) - $started).TotalSeconds
  if ($elapsed -ge $WaitTimeout) { fail "not ready after ${WaitTimeout}s; it is still running: see $outLog" }
  $free = Get-GpuFreeGiB
  if ($free -lt $MemFloorGiB -and -not $script:floorWarned) {
    $script:floorWarned = $true
    warn "only $free GiB of the WDDM GPU pool left while loading (MEM_FLOOR_GIB $MemFloorGiB): the engine reserves its own headroom, leaving it alone"
  }
  if ($elapsed -ge $nextBeat) {
    $used = [double](Get-GpuUsedGiB)
    $rate = 0.0; if ($elapsed -gt 0) { $rate = $used / $elapsed }
    Write-Host ("  {0}... {1}s elapsed, {2} GiB committed ({3:F2} GiB/s), {4} GiB free of the WDDM pool{5}" -f $Dim, [int]$elapsed, $used, $rate, $free, $Reset)
    $nextBeat += 15
  }
  Show-NewLog
  Start-Sleep -Seconds 3
}
Show-NewLog
$loadedSeconds = [int]((Get-Date) - $started).TotalSeconds
$loadedRate = 0.0
if ($loadedSeconds -gt 0) { $loadedRate = [double](Get-GpuUsedGiB) / $loadedSeconds }
log "Server answered after ${loadedSeconds}s"

# ---------------------------------------------------------------- step 5
step 5 'Smoke test: one chat completion'
$served = Get-ServedName
if (-not $served) { $served = $ServedName }
$body = @{
  model = $served
  max_tokens = 32
  temperature = 0
  chat_template_kwargs = @{ enable_thinking = $false }
  messages = @(@{ role = 'user'; content = 'Reply with OK.' })
} | ConvertTo-Json -Depth 6
try {
  $reply = Invoke-LocalRest -Uri "$ApiUrl/v1/chat/completions" -Method 'Post' -Body $body -TimeoutSec 180
  $content = "$($reply.choices[0].message.content)".Trim()
  if (-not $content) { throw 'the reply had empty content' }
  log "OK: '$($content.Substring(0, [math]::Min(40, $content.Length)))', $($reply.usage.completion_tokens) tokens"
} catch { fail "the smoke test request failed ($($_.Exception.Message)); the server is still running" }

$address = Get-LanAddress
$draftText = 'off'; if ($Drafts -eq '1') { $draftText = 'MTP' }
Write-Host ''
Write-Host "  $Green  ✔ $served is now LIVE! on port $Port$Reset"
Write-Host ''
Write-Host "    API      http://${address}:$Port/v1   (model: $served)"
Write-Host "    Loaded   in ${loadedSeconds}s | $('{0:F2}' -f $loadedRate) GiB/s average while loading"
Write-Host "    Model    $ModelId @ $($ModelRevision.Substring(0, [math]::Min(8, $ModelRevision.Length))) ($QuantLabel)"
Write-Host "    Window   $(Get-ArgValue '--context' $ServeArgs) tokens · $(Get-ArgValue '--parallel' $ServeArgs) at once · $KvDtype KV · drafts $draftText"
Write-Host "    Logs     Get-Content -LiteralPath '$outLog' -Tail 50 -Wait"
Write-Host '    Restart  .\start.ps1 restart'
Write-Host '    Stop     .\stop.ps1'
Write-Host ''
} finally {
  if ($startLock) {
    if ($startLockHeld) { try { $startLock.ReleaseMutex() } catch { } }
    $startLock.Dispose()
  }
  Clear-StartLockOwner
}
