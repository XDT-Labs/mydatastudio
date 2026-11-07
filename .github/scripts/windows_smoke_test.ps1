# Checks an installed Windows build: its aiserver starts, enforces auth and
# stops on POST /shutdown (Windows has no SIGTERM, so that's how the app stops
# it), and the app itself starts and creates its support directory. The app
# only spawns its aiserver after onboarding, which a headless run can't reach,
# so the two are started separately, as in linux_smoke_test.sh.
#
# Every wait is bounded so a hang fails the job.
#
# Usage: windows_smoke_test.ps1 <install-dir> <realm>
param(
  [Parameter(Mandatory = $true)][string]$InstallDir,
  [Parameter(Mandatory = $true)][string]$Realm
)
$ErrorActionPreference = 'Stop'

function Fail([string]$message, [string]$log) {
  Write-Host "Error: $message"
  if ($log -and (Test-Path $log)) { Get-Content $log -Tail 40 }
  exit 1
}

function Status([string]$method, [string]$url, [string]$token) {
  $curlArgs = @('-s', '-m', '20', '-o', 'NUL', '-w', '%{http_code}', '-X', $method)
  if ($token) { $curlArgs += @('-H', "Authorization: Bearer $token") }
  return (& curl.exe @curlArgs $url)
}

$work = Join-Path $env:RUNNER_TEMP "smoke-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $work | Out-Null

Write-Host '--- aiserver'
$zip = Join-Path $InstallDir 'data\flutter_assets\app\aiserver-windows.zip'
if (-not (Test-Path $zip)) { Fail "$zip is not in the install" }
# The same extractor PythonManager uses on Windows.
Expand-Archive -Path $zip -DestinationPath "$work\aiserver" -Force
$exe = "$work\aiserver\aiserver.exe"
if (-not (Test-Path $exe)) { Fail 'aiserver.exe is not at the root of the zip' }

$env:AISERVER_TOKEN = 'smoke'
$env:APP_SUPPORT_DIR = $work
$env:AICHAT_MODELS_DIR = "$work\models"
$log = "$work\aiserver.log"
$server = Start-Process -FilePath $exe -PassThru -NoNewWindow `
  -RedirectStandardOutput $log -RedirectStandardError "$work\aiserver.err.log"

$url = $null
for ($i = 0; $i -lt 180 -and -not $url; $i++) {
  Start-Sleep -Seconds 1
  $text = (Get-Content $log, "$work\aiserver.err.log" -Raw -ErrorAction SilentlyContinue) -join "`n"
  if ($text -match 'http://(127\.0\.0\.1|localhost):\d+') { $url = $Matches[0] }
  elseif ($server.HasExited) { break }
}
if (-not $url) { Fail 'aiserver printed no URL' $log }
Write-Host "aiserver at $url"

$status = Status 'GET' "$url/skills" $null
if ($status -ne '401') { Fail "/skills without a token returned $status, expected 401" $log }
$status = Status 'GET' "$url/skills" 'smoke'
if ($status -ne '200') { Fail "/skills with the token returned $status, expected 200" $log }
$status = Status 'POST' "$url/shutdown" $null
if ($status -ne '401') { Fail "/shutdown without a token returned $status, expected 401" $log }
$status = Status 'POST' "$url/shutdown" 'smoke'
if ($status -ne '200') { Fail "/shutdown returned $status, expected 200" $log }
if (-not $server.WaitForExit(15000)) {
  Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
  Fail 'aiserver kept running after /shutdown' $log
}

Write-Host '--- app'
$support = Join-Path ([Environment]::GetFolderPath('ApplicationData')) $Realm
if (Test-Path $support) { Fail "$support exists before the app ran" }
$appLog = "$work\app.log"
$app = Start-Process -FilePath (Join-Path $InstallDir 'mydatastudio.exe') -PassThru `
  -RedirectStandardOutput $appLog -RedirectStandardError "$work\app.err.log"
Start-Sleep -Seconds 20
if ($app.HasExited) { Fail "the app exited during startup (code $($app.ExitCode))" "$work\app.err.log" }
$created = Test-Path $support
# The app may exit on its own between the check above and here; that mustn't
# fail the run.
Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
if (-not $created) { Fail "the app created no support directory at $support" "$work\app.err.log" }
Write-Host 'Smoke test passed'
