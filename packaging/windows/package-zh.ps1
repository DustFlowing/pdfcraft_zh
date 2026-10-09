param(
    [Parameter(Mandatory=$true)][string]$BinDir,
    [Parameter(Mandatory=$true)][string]$FontDir,
    [string]$OriginalDir='C:\Program Files\PrintCraft',
    [string]$CargoHome=$env:CARGO_HOME,
    [string]$OutputDir
)
$ErrorActionPreference='Stop'
$Root=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $OutputDir) { $OutputDir=Join-Path $Root 'dist\PrintCraft-0.2.1-zh-CN-windows-x64' }
if (Test-Path -LiteralPath $OutputDir) { throw '输出目录已存在，请选择新目录。' }
& (Join-Path $PSScriptRoot 'prepare-zh-fonts.ps1') -FontDir $FontDir
$BinDir=(Resolve-Path -LiteralPath $BinDir).Path
if ((Get-Item -LiteralPath (Join-Path $OriginalDir 'printcraft.exe')).VersionInfo.ProductVersion -ne '0.2.1') { throw '此包针对 PrintCraft 0.2.1，原程序版本不符。' }
New-Item -ItemType Directory -Path $OutputDir | Out-Null
$Names=[ordered]@{'printcraft.exe'='pdfcraft.exe';'printcraft-cli.exe'='pdfcraft-cli.exe'}
$Payload=[ordered]@{}; $Original=[ordered]@{}
foreach ($Name in $Names.Keys) {
    $Source=Join-Path $BinDir $Names[$Name]
    $Bytes=[IO.File]::ReadAllBytes($Source)
    $Pe=[BitConverter]::ToInt32($Bytes,0x3c)
    $Expected=if ($Name -eq 'printcraft.exe') { 2 } else { 3 }
    if ([BitConverter]::ToUInt16($Bytes,$Pe+4) -ne 0x8664 -or [BitConverter]::ToUInt16($Bytes,$Pe+0x5c) -ne $Expected) { throw "二进制架构或子系统错误：$Name" }
    Copy-Item -LiteralPath $Source -Destination (Join-Path $OutputDir $Name)
    $Payload[$Name]=(Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash.ToLowerInvariant()
    $Original[$Name]=(Get-FileHash -LiteralPath (Join-Path $OriginalDir $Name) -Algorithm SHA256).Hash.ToLowerInvariant()
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Apply-ZhPatch.ps1') -Destination $OutputDir
foreach ($Name in @('NOTICE','LICENSE-MIT','LICENSE-APACHE','ATTRIBUTION.md','ATTRIBUTION.toml')) { Copy-Item -LiteralPath (Join-Path $Root $Name) -Destination $OutputDir }
$Licenses=New-Item -ItemType Directory -Path (Join-Path $OutputDir 'licenses')
Copy-Item -LiteralPath (Join-Path $Root 'assets\icons\LICENSE-lucide.txt') -Destination $Licenses.FullName
Get-ChildItem -LiteralPath (Join-Path $Root 'assets\fonts') -Filter 'OFL-*.txt' | Copy-Item -Destination $Licenses.FullName
foreach ($Family in @('biz-ud-pgothic','biz-ud-mincho','shippori-mincho','wqy-microhei')) {
    $Dest=New-Item -ItemType Directory -Path (Join-Path $Licenses.FullName $Family)
    foreach ($Name in @('OFL.txt','LICENSE_Apache2.txt','README.txt','AUTHORS.txt')) {
        $From=Join-Path $FontDir "fonts\$Family\$Name"
        if (Test-Path -LiteralPath $From) { Copy-Item -LiteralPath $From -Destination $Dest.FullName }
    }
}
# Include licence texts for every embedded fallback font and rendering asset.
if (-not $CargoHome) { $CargoHome=Join-Path $env:USERPROFILE '.cargo' }
function Find-Crate([string]$Name) {
    $Registry=Join-Path $CargoHome 'registry\src'
    foreach ($Index in Get-ChildItem -LiteralPath $Registry -Directory) {
        $Candidate=Join-Path $Index.FullName $Name
        if (Test-Path -LiteralPath $Candidate -PathType Container) { return $Candidate }
    }
    throw "Missing source licences for $Name; use the CargoHome used to build this release."
}
$Fallback=New-Item -ItemType Directory -Path (Join-Path $Licenses.FullName 'egui-default-fonts')
$Epaint=Find-Crate 'epaint_default_fonts-0.36.2'
foreach ($Name in @('OFL.txt','UFL.txt','Hack-Regular.txt','emoji-icon-font-mit-license.txt')) { Copy-Item -LiteralPath (Join-Path $Epaint "fonts\$Name") -Destination $Fallback.FullName }
$CMap=New-Item -ItemType Directory -Path (Join-Path $Licenses.FullName 'hayro-cmap')
Copy-Item -LiteralPath (Join-Path (Find-Crate 'hayro-cmap-0.1.0') 'assets\LICENSE.txt') -Destination $CMap.FullName
foreach ($Component in @('hayro','hayro-interpret','hayro-syntax','hayro-jbig2','lopdf')) {
    $Dest=New-Item -ItemType Directory -Path (Join-Path $Licenses.FullName $Component)
    Get-ChildItem -LiteralPath (Join-Path $Root "vendor\$Component") -File -Filter 'LICENSE*' | Copy-Item -Destination $Dest.FullName
}
foreach ($Name in @('LICENSE_FOXIT','CGATS_LICENSE.txt')) { Copy-Item -LiteralPath (Join-Path $Root "vendor\hayro-interpret\assets\$Name") -Destination (Join-Path $Licenses.FullName 'hayro-interpret') }
Copy-Item -LiteralPath (Join-Path $FontDir 'fonts\manifest.txt') -Destination (Join-Path $Licenses.FullName 'embedded-craft-fonts-manifest.txt')
Copy-Item -LiteralPath (Join-Path $FontDir 'ATTRIBUTION.md') -Destination (Join-Path $Licenses.FullName 'craft-fonts-ATTRIBUTION.md')
$Manifest=[ordered]@{
    schema=1;name='PrintCraft Simplified Chinese Patch';version='0.2.1-zh.1';architecture='x64'
    source_repository='https://github.com/DustFlowing/pdfcraft_zh'
    source_commit=(git -C $Root rev-parse HEAD).Trim()
    source_modified=$true
    build_feature='pdfcraft/zh-hans'
    chinese_font_sha256='e4bca8df123ce01b104780f576ea1a58b9a5ff1662a91124b6d3180cb6c88212'
    built_utc=(Get-Date).ToUniversalTime().ToString('o')
    payload=$Payload;original=$Original
}
[IO.File]::WriteAllText((Join-Path $OutputDir 'manifest.json'),($Manifest | ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
$NL=[Environment]::NewLine
$Launch='@echo off'+$NL+'start "" "%~dp0printcraft.exe" --language zh-hans %*'+$NL
[IO.File]::WriteAllText((Join-Path $OutputDir 'Start-Chinese.cmd'),$Launch,[Text.Encoding]::ASCII)
foreach ($Action in @('Install','Restore')) {
    $Wrapper='@echo off'+$NL+'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Apply-ZhPatch.ps1" -Action '+$Action+' %*'+$NL+'pause'+$NL
    [IO.File]::WriteAllText((Join-Path $OutputDir "$Action.cmd"),$Wrapper,[Text.Encoding]::ASCII)
}
$Images=New-Item -ItemType Directory -Path (Join-Path $OutputDir 'images')
Get-ChildItem -LiteralPath (Join-Path $Root 'docs\images') -Filter 'zh-*.png' | Copy-Item -Destination $Images.FullName
Copy-Item -LiteralPath (Join-Path $Root 'docs\zh-patch.md') -Destination (Join-Path $OutputDir 'README-zh-CN.md')
Write-Output "已生成待验证发布包：$OutputDir"
