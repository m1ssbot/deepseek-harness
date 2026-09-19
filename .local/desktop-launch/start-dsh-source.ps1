$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Url = 'http://127.0.0.1:3080'
$OfficialRemoteName = 'upstream'
$OfficialRemoteUrl = 'https://github.com/deepseek-ai/deepseek-harness.git'
# Writable home: your GitHub fork. Official is fetch-only; never push there.
$ForkRemoteName = 'origin'
$AppExecutable = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$AppArguments = @(
  '--profile-directory=Default'
)
$ReadyTimeout = [TimeSpan]::FromMinutes(3)
$PollSeconds = 1
$BuiltRevFile = Join-Path $PSScriptRoot 'built-at.rev'
$StartLogFile = Join-Path $PSScriptRoot 'last-start.log'
$BuildLogFile = Join-Path $PSScriptRoot 'last-build.log'
# Representative host + client artifacts required by `dsh web`.
$ArtifactProbes = @(
  (Join-Path $Repo 'packages\client\ui-renderer\lib\client.js')
  (Join-Path $Repo 'packages\llm\llm\lib\typert.host.js')
  (Join-Path $Repo 'packages\api\session-controller\lib\client.js')
  # BFF Client bundle inlines each selected package's ./remote wire names.
  # Stale remotes/lib/client.js is what made the permission chip silently fail.
  (Join-Path $Repo 'packages\api\remotes\lib\client.js')
)

function Show-Error([string]$Message) {
  Write-Host $Message -ForegroundColor Red
  if ($env:DSH_LAUNCH_NO_UI -eq '1') { return }
  Add-Type -AssemblyName PresentationFramework
  [System.Windows.MessageBox]::Show($Message, 'DeepSeek Harness') | Out-Null
}

function Wait-ForClose([string]$Prompt = 'Press Enter to close') {
  if ($env:DSH_LAUNCH_NO_UI -eq '1') { return }
  Read-Host $Prompt
}

function Test-DshReady([string]$TargetUrl) {
  try {
    $resp = Invoke-WebRequest -Uri $TargetUrl -UseBasicParsing -TimeoutSec 2
    return ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 500)
  } catch {
    return $false
  }
}

function Invoke-Git {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$GitArgs,
    [switch]$AllowFail
  )
  # git writes progress to stderr; with $ErrorActionPreference=Stop that becomes a
  # terminating error under Windows PowerShell 5.x when stderr is redirected.
  $previousEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & git -C $Repo @GitArgs 2>&1
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousEap
  }
  if ($code -ne 0 -and -not $AllowFail) {
    $text = ($output | ForEach-Object { "$_" } | Out-String).Trim()
    throw "git $($GitArgs -join ' ') failed (exit $code)`n$text"
  }
  return @{
    ExitCode = $code
    Output   = $output
  }
}

function Get-GitText {
  param([hashtable]$Result)
  return (($Result.Output | ForEach-Object { "$_" }) -join "`n").Trim()
}

function Ensure-OfficialAndForkRemotes {
  $remoteNames = @(
    (Invoke-Git -GitArgs @('remote')).Output |
      ForEach-Object { "$_".Trim() } |
      Where-Object { $_ }
  )

  if ($remoteNames -notcontains $OfficialRemoteName) {
    Write-Host "Adding official remote '$OfficialRemoteName' -> $OfficialRemoteUrl"
    Invoke-Git -GitArgs @('remote', 'add', $OfficialRemoteName, $OfficialRemoteUrl) | Out-Null
  } else {
    $currentUrl = Get-GitText (Invoke-Git -GitArgs @('remote', 'get-url', $OfficialRemoteName))
    if ($currentUrl -ne $OfficialRemoteUrl) {
      Write-Host "Updating '$OfficialRemoteName' URL: $currentUrl -> $OfficialRemoteUrl"
      Invoke-Git -GitArgs @('remote', 'set-url', $OfficialRemoteName, $OfficialRemoteUrl) | Out-Null
    }
  }

  # Refuse accidental pushes to the official remote (no write access anyway).
  $officialPush = Get-GitText (Invoke-Git -GitArgs @('remote', 'get-url', '--push', $OfficialRemoteName) -AllowFail)
  if ($officialPush -ne 'no_push') {
    Invoke-Git -GitArgs @('remote', 'set-url', '--push', $OfficialRemoteName, 'no_push') | Out-Null
  }

  if ($remoteNames -notcontains $ForkRemoteName) {
    throw @"
Missing fork remote '$ForkRemoteName'.
Add your GitHub fork, e.g.:
  git remote add origin https://github.com/<you>/deepseek-harness.git
Then re-run this launcher.
"@
  }

  $forkUrl = Get-GitText (Invoke-Git -GitArgs @('remote', 'get-url', $ForkRemoteName))
  if ($forkUrl -match 'github\.com[/:]deepseek-ai/deepseek-harness(\.git)?$') {
    throw @"
Remote '$ForkRemoteName' points at the official repo:
  $forkUrl
Point origin at YOUR fork (you have no write access to deepseek-ai), e.g.:
  git remote set-url origin https://github.com/<you>/deepseek-harness.git
"@
  }

  return $forkUrl
}

function Get-OfficialDefaultBranchInfo {
  $headResult = Invoke-Git -GitArgs @('symbolic-ref', "refs/remotes/$OfficialRemoteName/HEAD") -AllowFail
  $defaultRef = Get-GitText $headResult
  if ($headResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($defaultRef)) {
    Write-Host "Remote HEAD not set; resolving default branch for '$OfficialRemoteName'..."
    Invoke-Git -GitArgs @('remote', 'set-head', $OfficialRemoteName, '-a') | Out-Null
    $defaultRef = Get-GitText (Invoke-Git -GitArgs @('symbolic-ref', "refs/remotes/$OfficialRemoteName/HEAD"))
  }

  if ($defaultRef -notmatch "refs/remotes/$([regex]::Escape($OfficialRemoteName))/(?<branch>.+)$") {
    throw "Could not resolve official default branch from $defaultRef"
  }

  $defaultBranch = $Matches['branch']
  $officialRef = "$OfficialRemoteName/$defaultBranch"
  $officialHead = Get-GitText (Invoke-Git -GitArgs @('rev-parse', $officialRef))
  $officialShort = Get-GitText (Invoke-Git -GitArgs @('rev-parse', '--short', $officialRef))
  return @{
    DefaultBranch = $defaultBranch
    OfficialRef   = $officialRef
    OfficialHead  = $officialHead
    OfficialShort = $officialShort
  }
}

function Copy-LocalDir {
  param(
    [Parameter(Mandatory = $true)][string]$From,
    [Parameter(Mandatory = $true)][string]$To
  )
  if (-not (Test-Path -LiteralPath $From)) { return }
  New-Item -ItemType Directory -Path $To -Force | Out-Null
  $previousEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    # /E copies subdirs including empty; /NFL /NDL /NJH /NJS keep the console quiet.
    & robocopy $From $To /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousEap
  }
  # robocopy: 0-7 are success; 8+ is failure.
  if ($code -ge 8) {
    throw "Failed to copy .local ($From -> $To); robocopy exit $code"
  }
}

function Save-LocalDir {
  $localDir = Join-Path $Repo '.local'
  $backup = Join-Path $env:TEMP ('dsh-local-preserve-' + [guid]::NewGuid().ToString('N'))
  if (Test-Path -LiteralPath $localDir) {
    Write-Host 'Preserving .local/ across official sync...'
    Copy-LocalDir -From $localDir -To $backup
  }
  return $backup
}

function Restore-LocalDir {
  param([string]$Backup)
  $localDir = Join-Path $Repo '.local'
  if (-not $Backup -or -not (Test-Path -LiteralPath $Backup)) { return }
  Write-Host 'Restoring .local/ after official sync...'
  Copy-LocalDir -From $Backup -To $localDir
  Remove-Item -LiteralPath $Backup -Recurse -Force -ErrorAction SilentlyContinue
}

function Ensure-LaunchForkMaster {
  # Checkout fork master, merge official, keep tracked .local/.
  param([hashtable]$OfficialInfo)

  $defaultBranch = $OfficialInfo.DefaultBranch
  $officialRef = $OfficialInfo.OfficialRef
  $officialShort = $OfficialInfo.OfficialShort
  $forkMasterRef = "$ForkRemoteName/$defaultBranch"

  $localBackup = Save-LocalDir
  try {
    $current = Get-GitText (Invoke-Git -GitArgs @('branch', '--show-current') -AllowFail)
    $localMaster = Invoke-Git -GitArgs @('show-ref', '--verify', '--quiet', "refs/heads/$defaultBranch") -AllowFail

    if ($current -eq $defaultBranch) {
      Write-Host "Already on launch branch '$defaultBranch'."
    } elseif ($localMaster.ExitCode -eq 0) {
      Write-Host "Checking out launch branch '$defaultBranch' (leaving other branches untouched)..."
      Invoke-Git -GitArgs @('switch', $defaultBranch) | Out-Null
    } else {
      Write-Host "Creating local '$defaultBranch' from $officialRef..."
      Invoke-Git -GitArgs @('switch', '-c', $defaultBranch, $officialRef) | Out-Null
    }

    $workBranch = Get-GitText (Invoke-Git -GitArgs @('branch', '--show-current'))
    if ($workBranch -ne $defaultBranch) {
      throw "Expected to be on '$defaultBranch' but current branch is '$workBranch'."
    }

    Invoke-Git -GitArgs @('branch', '--set-upstream-to', $forkMasterRef, $defaultBranch) -AllowFail | Out-Null

    $behindText = Get-GitText (Invoke-Git -GitArgs @('rev-list', '--count', "HEAD..$officialRef") -AllowFail)
    $behind = 0
    if ($behindText -match '^\d+$') { $behind = [int]$behindText }

    if ($behind -gt 0) {
      Write-Host "Merging official $officialRef @ $officialShort into '$defaultBranch' ($behind commit(s))..."
      Invoke-Git -GitArgs @('merge', '--no-edit', $officialRef) | Out-Null
    } else {
      Write-Host "Launch branch already contains official @ $officialShort"
    }

    $workShort = Get-GitText (Invoke-Git -GitArgs @('rev-parse', '--short', 'HEAD'))
    Write-Host "Launch: $workBranch @ $workShort (fork $ForkRemoteName/$defaultBranch + official $officialShort)"

    Write-Host "Pushing '$defaultBranch' to fork '$ForkRemoteName' (no force; keeps .local/)..."
    Invoke-Git -GitArgs @('push', '-u', $ForkRemoteName, "HEAD:refs/heads/$defaultBranch") | Out-Null
  } finally {
    Restore-LocalDir -Backup $localBackup
  }
}

function Sync-OfficialToForkAndPrepareWorkBranch {
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'git not found. Install Git for Windows first.'
  }

  $inside = Get-GitText (Invoke-Git -GitArgs @('rev-parse', '--is-inside-work-tree'))
  if ($inside -ne 'true') {
    throw "Not a git repository:`n$Repo"
  }

  $forkUrl = Ensure-OfficialAndForkRemotes
  Write-Host "Official: $OfficialRemoteName ($OfficialRemoteUrl) [fetch-only]"
  Write-Host "Fork:     $ForkRemoteName ($forkUrl) [master sync + launch]"
  Write-Host 'Launch:   fork master (not local/dev)'

  Write-Host "Fetching official '$OfficialRemoteName' and fork '$ForkRemoteName'..."
  Invoke-Git -GitArgs @('fetch', $OfficialRemoteName, '--prune') | Out-Null
  Invoke-Git -GitArgs @('fetch', $ForkRemoteName, '--prune') -AllowFail | Out-Null

  $officialInfo = Get-OfficialDefaultBranchInfo
  Ensure-LaunchForkMaster -OfficialInfo $officialInfo
}

function Test-ArtifactProbes {
  foreach ($probe in $ArtifactProbes) {
    if (-not (Test-Path -LiteralPath $probe)) { return $false }
  }
  return $true
}

function Invoke-Pnpm {
  param(
    [Parameter(Mandatory = $true)]$PnpmCommand,
    [Parameter(Mandatory = $true)][string[]]$PnpmArgs,
    [string]$LogFile
  )
  # pnpm/npm write progress and warnings to stderr; with $ErrorActionPreference=Stop
  # that becomes a terminating NativeCommandError under Windows PowerShell 5.x.
  # Also: piping native output through ForEach-Object can clobber $LASTEXITCODE,
  # so capture the stream into a variable first, then read the exit code.
  $previousEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & $PnpmCommand.Source @PnpmArgs 2>&1
    $code = $LASTEXITCODE
    foreach ($item in @($output)) {
      $line = "$item"
      Write-Host $line
      if ($LogFile) {
        Add-Content -LiteralPath $LogFile -Value $line
      }
    }
    return $code
  } finally {
    $ErrorActionPreference = $previousEap
  }
}

function Ensure-BuiltArtifacts {
  param($PnpmCommand)

  $head = Get-GitText (Invoke-Git -GitArgs @('rev-parse', 'HEAD'))
  $short = Get-GitText (Invoke-Git -GitArgs @('rev-parse', '--short', 'HEAD'))
  $recorded = ''
  if (Test-Path -LiteralPath $BuiltRevFile) {
    $recorded = (Get-Content -LiteralPath $BuiltRevFile -Raw).Trim()
  }

  $bundleOk = Test-ArtifactProbes
  if (-not ($bundleOk -and $recorded -eq $head)) {
    Write-Host ''
    if (-not $bundleOk) {
      Write-Host 'Required build artifacts missing; running pnpm run build once...'
    } else {
      Write-Host "HEAD moved ($short); running pnpm run build once..."
    }
    Write-Host 'This can take several minutes the first time after a sync.'
    Write-Host "Build log: $BuildLogFile"
    Set-Content -LiteralPath $BuildLogFile -Value ("=== pnpm build @ $(Get-Date -Format o) HEAD $short ===") -Encoding utf8
    $code = Invoke-Pnpm -PnpmCommand $PnpmCommand -PnpmArgs @('run', '--dir', $Repo, 'build') -LogFile $BuildLogFile
    if ($code -ne 0) {
      throw "pnpm run build failed with exit code $code.`nSee $BuildLogFile"
    }
    if (-not (Test-ArtifactProbes)) {
      throw "pnpm run build finished but required artifacts are still missing.`nSee $BuildLogFile"
    }
    Set-Content -LiteralPath $BuiltRevFile -Value $head -Encoding ascii
    Write-Host "Recorded build stamp for $short"
  } else {
    Write-Host "Build artifacts already match HEAD $short; skipping full build."
  }

  # HEAD stamp alone is not enough: a Host Typert regenerate can refresh
  # packages/*/lib/typert.remote-client.js without rebuilding the remotes
  # Client bundle that inlines those wires. Fail closed and repair.
  Ensure-RemotesClientWire -PnpmCommand $PnpmCommand
}

function Ensure-RemotesClientWire {
  param($PnpmCommand)

  # Official master may not ship this gate yet (it lives on local/dev adaptations).
  $pkgJson = Get-Content -LiteralPath (Join-Path $Repo 'package.json') -Raw -ErrorAction SilentlyContinue
  if ($pkgJson -notmatch '"verify-remotes-client-wire"\s*:') {
    Write-Host 'Skipping remotes Client wire check (script not in package.json on this branch).'
    return
  }

  Write-Host 'Checking remotes Client wire sync against mounted ./remote artifacts...'
  $check = Invoke-Pnpm -PnpmCommand $PnpmCommand -PnpmArgs @('run', '--dir', $Repo, 'verify-remotes-client-wire')
  if ($check -eq 0) {
    Write-Host 'Remotes Client wire sync ok.'
    return
  }

  Write-Host 'Remotes Client wire drift detected; rebuilding @deepseek-ai/dsh-api-remotes...' -ForegroundColor Yellow
  $bundleCode = Invoke-Pnpm -PnpmCommand $PnpmCommand -PnpmArgs @(
    '--filter', '@deepseek-ai/dsh-api-remotes', 'run', 'bundle'
  )
  if ($bundleCode -ne 0) {
    throw "pnpm --filter @deepseek-ai/dsh-api-remotes run bundle failed with exit code $bundleCode"
  }

  $recheck = Invoke-Pnpm -PnpmCommand $PnpmCommand -PnpmArgs @('run', '--dir', $Repo, 'verify-remotes-client-wire')
  if ($recheck -ne 0) {
    throw @"
Remotes Client wire sync still failing after rebuild.
The browser would send stale RPC field names (permission chip switches silently fail).
Run: pnpm run verify-remotes-client-wire
Then: pnpm --filter @deepseek-ai/dsh-api-remotes run bundle
"@
  }
  Write-Host 'Remotes Client rebuilt and wire sync ok.'
}

if (-not (Test-Path (Join-Path $Repo 'package.json'))) {
  Show-Error "Source repo not found:`n$Repo"
  exit 1
}

$pnpm = Get-Command pnpm.cmd -ErrorAction SilentlyContinue
if (-not $pnpm) { $pnpm = Get-Command pnpm -ErrorAction SilentlyContinue }
if (-not $pnpm) {
  Show-Error 'pnpm not found. Enable corepack or install pnpm first.'
  exit 1
}
if (-not (Test-Path $AppExecutable)) {
  Show-Error "DeepSeek Harness desktop app not found:`n$AppExecutable"
  exit 1
}

Write-Host 'Starting DeepSeek Harness from source...'
Write-Host "Repo: $Repo"
Write-Host "UI:   $Url"
Write-Host 'Sync: merge official into fork master (no force-push, no reset --hard). Launch that master.'
Write-Host '.local/ is git-tracked on the fork and copied back after checkout so launch files survive.'
Write-Host ''

# Machine/user OPENSSL_CONF may point at a missing file (e.g. Postgres etc
# without openssl.cnf). Git for Windows (OpenSSL backend) then fails TLS.
# Prefer fixing the file on disk; only clear the process env as a last resort.
if ($env:OPENSSL_CONF -and -not (Test-Path -LiteralPath $env:OPENSSL_CONF)) {
  Write-Host "Clearing invalid OPENSSL_CONF (missing file): $($env:OPENSSL_CONF)" -ForegroundColor Yellow
  Remove-Item Env:OPENSSL_CONF
}

try {
  Sync-OfficialToForkAndPrepareWorkBranch
} catch {
  Write-Host ''
  Write-Host $_.Exception.Message -ForegroundColor Red
  Show-Error $_.Exception.Message
  Write-Host ''
  Wait-ForClose
  exit 1
}

Write-Host ''
Write-Host 'Installing / refreshing dependencies (pnpm install)...'
$installCode = Invoke-Pnpm -PnpmCommand $pnpm -PnpmArgs @('install', '--dir', $Repo)
if ($installCode -ne 0) {
  $msg = "pnpm install failed with exit code $installCode."
  Write-Host $msg -ForegroundColor Red
  Show-Error $msg
  Write-Host ''
  Wait-ForClose
  exit $installCode
}

try {
  Ensure-BuiltArtifacts -PnpmCommand $pnpm
} catch {
  Write-Host $_.Exception.Message -ForegroundColor Red
  Show-Error $_.Exception.Message
  Write-Host ''
  Wait-ForClose
  exit 1
}

Write-Host ''
Write-Host 'Waiting until the server is ready before opening the desktop app...'
Write-Host 'Close this window or press Ctrl+C to stop.'
Write-Host ''

$stdoutFile = Join-Path $env:TEMP ('dsh-web-' + [guid]::NewGuid().ToString('N') + '.log')
$stderrFile = Join-Path $env:TEMP ('dsh-web-' + [guid]::NewGuid().ToString('N') + '.err.log')
Set-Content -LiteralPath $StartLogFile -Value ("=== dsh launch @ $(Get-Date -Format o) ===") -Encoding utf8
# Prefer pnpm.cmd so Start-Process is not handed a PowerShell script wrapper.
$pnpmExe = $pnpm.Source
if ($pnpm.Name -notmatch '\.cmd$') {
  $cmd = Get-Command pnpm.cmd -ErrorAction SilentlyContinue
  if ($cmd) { $pnpmExe = $cmd.Source }
}
$proc = Start-Process -FilePath $pnpmExe -ArgumentList @('dsh', 'web', '--no-open') -WorkingDirectory $Repo -PassThru -NoNewWindow -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
if (-not $proc) {
  Show-Error 'Failed to start pnpm dsh web.'
  exit 1
}

function Get-LaunchLogText {
  $chunks = @()
  foreach ($f in @($stdoutFile, $stderrFile)) {
    if (Test-Path -LiteralPath $f) {
      $chunks += (Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue)
    }
  }
  return (($chunks | Where-Object { $_ }) -join "`n")
}

$deadline = (Get-Date) + $ReadyTimeout
$opened = $false
$webUrl = $null
while ((Get-Date) -lt $deadline) {
  if ($proc.HasExited) {
    $logText = Get-LaunchLogText
    Add-Content -LiteralPath $StartLogFile -Value $logText
    Write-Host "dsh exited early with code $($proc.ExitCode)."
    if ($logText) {
      Write-Host $logText
    }
    Show-Error "dsh exited early with code $($proc.ExitCode).`nSee $StartLogFile"
    exit ($proc.ExitCode)
  }

  $logText = Get-LaunchLogText
  if ($null -eq $webUrl -and $logText) {
    if ($logText -match 'dsh web: (\S+)') { $webUrl = $Matches[1] }
  }

  if ($null -ne $webUrl -and (Test-DshReady $webUrl)) {
    Write-Host 'Server is ready. Opening DeepSeek Harness in a Chrome app window.'
    Add-Content -LiteralPath $StartLogFile -Value "ready: $webUrl"
    Start-Process -FilePath $AppExecutable -ArgumentList ($AppArguments + "--app=$webUrl")
    $opened = $true
    break
  }

  Start-Sleep -Seconds $PollSeconds
}

if (-not $opened) {
  Write-Host "Timed out waiting for $Url after $($ReadyTimeout.TotalSeconds)s."
  Write-Host "Launch URL: $(if ($webUrl) { $webUrl } else { $Url })"
  Write-Host 'Open that URL in Chrome with --app= to get a standalone window (token is session-fresh).'
}

try {
  Wait-Process -Id $proc.Id
} catch {
  # Process already gone.
}

if (-not $proc.HasExited) {
  # Defensive: ensure we don't leave a dangling wait.
  exit 0
}

exit ($proc.ExitCode)
