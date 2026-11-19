# Stop the server that .\start.ps1 started and free its GPU memory. The server gets STOP_TIMEOUT seconds
# (default 30) to shut down; requests still running are cut off (it does not drain them), so stop.ps1
# says when there are any. Windows port of ./stop.sh.
# Usage: .\stop.ps1      Env: PORT (see scripts\config.ps1), STOP_TIMEOUT

$ErrorActionPreference = 'Stop'
$LogName = 'stop.ps1'
$global:LASTEXITCODE = 0
. (Join-Path $PSScriptRoot 'scripts\config.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$server = Get-ServerProcess
if (-not $server) {
  if (Test-Path -LiteralPath $PidFile) { Remove-Item -LiteralPath $PidFile -ErrorAction SilentlyContinue }
  log "No server running (no server PID): nothing to stop"
  exit 0
}
$busy = 0
try {
  $health = Invoke-LocalRest -Uri "$(Get-ApiBaseUrl)/health" -TimeoutSec 3 -Method 'Get'
  $count = $health.running
  if ($null -eq $count) { $count = $health.requests_running }
  if ($count -is [int] -and $count -ge 0) { $busy = $count }
} catch { $busy = 0 }
if ("$busy" -notmatch '^[0-9]+$') { $busy = 0 }
if ($busy -gt 0) { warn "$busy request(s) still running will be cut off" }

$TimeoutSeconds = [int](Get-EnvOr 'STOP_TIMEOUT' '30')
log "Stopping tensorfold-native (PID $($server.Id), up to ${TimeoutSeconds}s)"
$stopped = Stop-Server -TimeoutSeconds $TimeoutSeconds
if (-not $stopped) {
  try { taskkill /PID $server.Id /T /F | Out-Null } catch { }
  Remove-Item -LiteralPath $PidFile -ErrorAction SilentlyContinue
}
log 'Stopped the server; its GPU memory is free again'
