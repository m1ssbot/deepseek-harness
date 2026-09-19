$ErrorActionPreference = 'SilentlyContinue'
Start-Sleep -Seconds 8
$c = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue
$pids = @($c | Select-Object -ExpandProperty OwningProcess -Unique)
foreach ($p in $pids) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 3
$dir = 'D:/Project/deepseek-harness'
$out = Join-Path $dir '.local/dsh-web.out.log'
$err = Join-Path $dir '.local/dsh-web.err.log'
Start-Process -FilePath 'C:/nvm4w/nodejs/node.exe' -ArgumentList @('--import','tsx/esm','apps/cli/src/bin.ts','web') -WorkingDirectory $dir -RedirectStandardOutput $out -RedirectStandardError $err -WindowStyle Hidden
Start-Sleep -Seconds 10
$ok = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue
$status = if ($ok) { 'RESTART_OK: 3080 listening' } else { 'RESTART_FAIL: 3080 not listening' }
Add-Content -Path (Join-Path $dir '.local/dsh-web.restart-status.log') -Value ("[$(Get-Date -Format o)] " + $status)
