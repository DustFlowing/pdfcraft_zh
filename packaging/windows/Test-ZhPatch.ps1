param([string]$TestRoot)
$ErrorActionPreference='Stop'
if (-not $TestRoot) { $TestRoot=Join-Path $PSScriptRoot ('..\..\dist\qa\installer-'+[Guid]::NewGuid().ToString('N')) }
New-Item -ItemType Directory -Path $TestRoot | Out-Null
$TestRoot=(Resolve-Path -LiteralPath $TestRoot).Path
$Package=New-Item -ItemType Directory -Path (Join-Path $TestRoot '补丁 包')
$Installed=New-Item -ItemType Directory -Path (Join-Path $TestRoot '模拟 安装目录')
$Names=@('printcraft.exe','printcraft-cli.exe')
$Script=Join-Path $Package.FullName 'Apply-ZhPatch.ps1'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Apply-ZhPatch.ps1') -Destination $Script
$Old=[ordered]@{}; $New=[ordered]@{}; $Checks=[Collections.Generic.List[string]]::new()
function Hash([string]$File) { return (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLowerInvariant() }
foreach ($Name in $Names) {
    [IO.File]::WriteAllText((Join-Path $Installed.FullName $Name),"original $Name",[Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $Package.FullName $Name),"patched $Name",[Text.Encoding]::ASCII)
    $Old[$Name]=Hash (Join-Path $Installed.FullName $Name)
    $New[$Name]=Hash (Join-Path $Package.FullName $Name)
}
$Manifest=[ordered]@{schema=1;architecture='x64';original=$Old;payload=$New}
[IO.File]::WriteAllText((Join-Path $Package.FullName 'manifest.json'),($Manifest|ConvertTo-Json -Depth 5))
function Assert-Files($Expected) {
    foreach ($Name in $Names) {
        if ((Hash (Join-Path $Installed.FullName $Name)) -ne $Expected[$Name]) { throw "Unexpected installed bytes: $Name" }
    }
}
function Expect-Failure([scriptblock]$Block) {
    $Failed=$false
    try { & $Block } catch { $Failed=$true }
    if (-not $Failed) { throw 'Expected rejection did not occur.' }
}
& $Script -Action Install -InstallDir $Installed.FullName
Assert-Files $New
$Backup=(Get-ChildItem -LiteralPath $Installed.FullName -Directory -Filter 'backup-zh-*'|Select-Object -First 1).FullName
foreach ($Name in $Names) { if ((Hash (Join-Path $Backup $Name)) -ne $Old[$Name]) { throw 'Bad backup' } }
$Checks.Add('install_and_verified_original_backup')
& $Script -Action Install -InstallDir $Installed.FullName
Assert-Files $New
$Checks.Add('idempotent_install')
& $Script -Action Restore -InstallDir $Installed.FullName
Assert-Files $Old
& $Script -Action Restore -InstallDir $Installed.FullName
Assert-Files $Old
$Checks.Add('restore_and_idempotent_restore')
[IO.File]::WriteAllText((Join-Path $Installed.FullName 'printcraft.exe'),'unknown newer build')
$Unexpected=Hash (Join-Path $Installed.FullName 'printcraft.exe')
Expect-Failure { & $Script -Action Install -InstallDir $Installed.FullName }
if ((Hash (Join-Path $Installed.FullName 'printcraft.exe')) -ne $Unexpected -or (Hash (Join-Path $Installed.FullName 'printcraft-cli.exe')) -ne $Old['printcraft-cli.exe']) { throw 'Wrong-version rejection changed files' }
Copy-Item -LiteralPath (Join-Path $Backup 'printcraft.exe') -Destination (Join-Path $Installed.FullName 'printcraft.exe') -Force
$Checks.Add('unknown_original_rejected_without_changes')
$Lock=[IO.File]::Open((Join-Path $Installed.FullName 'printcraft-cli.exe'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
try { Expect-Failure { & $Script -Action Install -InstallDir $Installed.FullName } }
finally { $Lock.Dispose() }
Assert-Files $Old
$Checks.Add('second_file_lock_rolls_back_first_replacement')
& $Script -Action Install -InstallDir $Installed.FullName
Assert-Files $New
[IO.File]::WriteAllText((Join-Path $Installed.FullName 'printcraft.exe'),'updated after patch')
$Updated=Hash (Join-Path $Installed.FullName 'printcraft.exe')
Expect-Failure { & $Script -Action Restore -InstallDir $Installed.FullName }
if ((Hash (Join-Path $Installed.FullName 'printcraft.exe')) -ne $Updated) { throw 'Restore overwrote newer update' }
$Checks.Add('restore_preserves_later_updates')
Expect-Failure { & $Script -Action Restore -InstallDir $Installed.FullName -BackupDir $Package.FullName }
$Checks.Add('backup_path_cannot_escape_install_directory')
[IO.File]::WriteAllText((Join-Path $Package.FullName 'printcraft-cli.exe'),'tampered payload')
Expect-Failure { & $Script -Action Install -InstallDir $Installed.FullName }
if ((Hash (Join-Path $Installed.FullName 'printcraft.exe')) -ne $Updated) { throw 'Tampered payload changed installation' }
$Checks.Add('tampered_payload_rejected')
$Report=[ordered]@{passed=$Checks.Count;checks=@($Checks);test_root=$TestRoot;timestamp_utc=(Get-Date).ToUniversalTime().ToString('o')}
[IO.File]::WriteAllText((Join-Path $TestRoot 'report.json'),($Report|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
Write-Output ('INSTALLER_TESTS_PASSED='+$Checks.Count)
Write-Output ('REPORT='+ (Join-Path $TestRoot 'report.json'))
