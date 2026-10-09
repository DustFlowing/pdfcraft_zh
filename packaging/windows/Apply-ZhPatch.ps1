param(
    [ValidateSet('Install','Restore')][string]$Action = 'Install',
    [string]$InstallDir = 'C:\Program Files\PrintCraft',
    [string]$BackupDir
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Names = @('printcraft.exe','printcraft-cli.exe')
$InstallDir = (Resolve-Path -LiteralPath $InstallDir).Path.TrimEnd('\')
$Prefix = $InstallDir + '\'
function Read-Json([string]$File) { return ([IO.File]::ReadAllText($File) | ConvertFrom-Json) }
function Hash([string]$File) { return (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLowerInvariant() }
function Same-Hash([string]$File,[string]$Expected) {
    return ((Test-Path -LiteralPath $File -PathType Leaf) -and (Hash $File) -eq $Expected.ToLowerInvariant())
}
function Assert-Child([string]$File) {
    $Absolute = [IO.Path]::GetFullPath($File)
    if (-not $Absolute.StartsWith($Prefix,[StringComparison]::OrdinalIgnoreCase)) { throw '拒绝访问安装目录以外的路径。' }
    return $Absolute
}
foreach ($Process in Get-Process -Name printcraft,printcraft-cli,pdfcraft,pdfcraft-cli -ErrorAction SilentlyContinue) {
    if ($Process.Path -and $Process.Path.StartsWith($Prefix,[StringComparison]::OrdinalIgnoreCase)) {
        throw '请先保存文档并关闭此目录中的 PrintCraft 和 CLI。'
    }
}
if ($Action -eq 'Install') {
    $Manifest = Read-Json (Join-Path $PSScriptRoot 'manifest.json')
    if ($Manifest.schema -ne 1 -or $Manifest.architecture -ne 'x64') { throw '不支持的补丁清单。' }
    $Already = $true
    foreach ($Name in $Names) {
        if (-not (Same-Hash (Join-Path $PSScriptRoot $Name) $Manifest.payload.$Name)) { throw "补丁文件校验失败：$Name" }
        if (-not (Same-Hash (Join-Path $InstallDir $Name) $Manifest.payload.$Name)) { $Already = $false }
    }
    if ($Already) { Write-Output '该补丁已经安装，无需重复操作。'; return }
    foreach ($Name in $Names) {
        if (-not (Same-Hash (Join-Path $InstallDir $Name) $Manifest.original.$Name)) {
            throw "原程序校验值不匹配：$Name。补丁未作修改；可使用包内的便携中文版。"
        }
    }
    $BackupDir = Assert-Child (Join-Path $InstallDir ('backup-zh-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8)))
    New-Item -ItemType Directory -Path $BackupDir | Out-Null
    foreach ($Name in $Names) {
        Copy-Item -LiteralPath (Join-Path $InstallDir $Name) -Destination (Join-Path $BackupDir $Name)
        if (-not (Same-Hash (Join-Path $BackupDir $Name) $Manifest.original.$Name)) { throw "备份校验失败：$Name" }
    }
    $Record = [ordered]@{schema=1;original=$Manifest.original;patched=$Manifest.payload;created_utc=(Get-Date).ToUniversalTime().ToString('o')}
    [IO.File]::WriteAllText((Join-Path $BackupDir 'backup.json'),($Record | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    $SourceDir=$PSScriptRoot; $Wanted=$Manifest.payload; $Before=$Manifest.original
} else {
    if (-not $BackupDir) {
        $Candidates = @(Get-ChildItem -LiteralPath $InstallDir -Directory -Filter 'backup-zh-*' | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'backup.json') } | Sort-Object Name -Descending)
        if (-not $Candidates.Count) { throw '找不到汉化补丁的原文件备份。' }
        $BackupDir = $Candidates[0].FullName
    }
    $BackupDir = Assert-Child ((Resolve-Path -LiteralPath $BackupDir).Path)
    $Record = Read-Json (Join-Path $BackupDir 'backup.json')
    if ($Record.schema -ne 1) { throw '不支持的备份清单。' }
    $Already=$true
    foreach ($Name in $Names) {
        if (-not (Same-Hash (Join-Path $BackupDir $Name) $Record.original.$Name)) { throw "备份校验失败：$Name" }
        if (-not (Same-Hash (Join-Path $InstallDir $Name) $Record.original.$Name)) { $Already=$false }
    }
    if ($Already) { Write-Output '原版程序已恢复，无需重复操作。'; return }
    foreach ($Name in $Names) {
        if (-not (Same-Hash (Join-Path $InstallDir $Name) $Record.patched.$Name)) { throw "程序已被其他更新修改，回滚已取消：$Name" }
    }
    $SourceDir=$BackupDir; $Wanted=$Record.original; $Before=$Record.patched
}
$Staged=@{}; $Replaced=@()
$TransactionDir=Assert-Child (Join-Path $InstallDir ('.zh-transaction-' + [Guid]::NewGuid().ToString('N')))
try {
    New-Item -ItemType Directory -Path $TransactionDir | Out-Null
    foreach ($Name in $Names) {
        Copy-Item -LiteralPath (Join-Path $InstallDir $Name) -Destination (Join-Path $TransactionDir $Name)
        if (-not (Same-Hash (Join-Path $TransactionDir $Name) $Before.$Name)) { throw "事务备份校验失败：$Name" }
        $New=Assert-Child (Join-Path $InstallDir ('.zh-new-' + [Guid]::NewGuid().ToString('N') + '.tmp'))
        Copy-Item -LiteralPath (Join-Path $SourceDir $Name) -Destination $New
        $Staged[$Name]=$New
        if (-not (Same-Hash $New $Wanted.$Name)) { throw "新文件校验失败：$Name" }
    }
    foreach ($Name in $Names) {
        [IO.File]::Replace($Staged[$Name],(Join-Path $InstallDir $Name),[NullString]::Value)
        $Replaced+=$Name
        if (-not (Same-Hash (Join-Path $InstallDir $Name) $Wanted.$Name)) { throw "替换后校验失败：$Name" }
    }
} catch {
    $Failure=$_
    foreach ($Name in $Replaced) {
        $Rollback=Assert-Child (Join-Path $InstallDir ('.zh-rollback-' + [Guid]::NewGuid().ToString('N') + '.tmp'))
        Copy-Item -LiteralPath (Join-Path $TransactionDir $Name) -Destination $Rollback
        [IO.File]::Replace($Rollback,(Join-Path $InstallDir $Name),[NullString]::Value)
        if (-not (Same-Hash (Join-Path $InstallDir $Name) $Before.$Name)) { throw "恢复失败，请从 $TransactionDir 手动恢复 $Name" }
    }
    throw "操作失败，已恢复操作前的程序。若拒绝访问，请以管理员身份运行。原因：$Failure"
} finally {
    foreach ($File in $Staged.Values) { if (Test-Path -LiteralPath $File) { Remove-Item -LiteralPath (Assert-Child $File) -Force } }
}
# Only remove the two verified temporary copies created by this transaction; keep permanent backups.
foreach ($Name in $Names) { Remove-Item -LiteralPath (Assert-Child (Join-Path $TransactionDir $Name)) -Force }
Remove-Item -LiteralPath (Assert-Child $TransactionDir) -Force
if ($Action -eq 'Install') { Write-Output "简体中文补丁安装完成。原文件备份：$BackupDir" }
else { Write-Output '原版程序已恢复，备份仍保留。' }
