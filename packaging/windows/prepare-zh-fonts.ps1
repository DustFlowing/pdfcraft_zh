param([Parameter(Mandatory=$true)][string]$FontDir)
$ErrorActionPreference = 'Stop'
$FontDir = [IO.Path]::GetFullPath($FontDir)
$Pinned = 'abb83316d96aa59c1cf64784289e378fe9fa5695'
$ArchiveHash = '2802ac8023aa36a66ea6e7445854e3a078d377ffff42169341bd237871f7213e'
$FontHash = 'e4bca8df123ce01b104780f576ea1a58b9a5ff1662a91124b6d3180cb6c88212'
if (-not (Test-Path -LiteralPath $FontDir)) {
    git init $FontDir
    if ($LASTEXITCODE -ne 0) { throw '字体仓库初始化失败。' }
    git -C $FontDir remote add origin https://github.com/storytold/craft-fonts.git
    if ($LASTEXITCODE -ne 0) { throw '字体仓库配置失败。' }
    git -C $FontDir fetch --depth 1 origin $Pinned
    if ($LASTEXITCODE -ne 0) { throw '字体仓库下载失败。' }
    git -C $FontDir checkout --detach $Pinned
    if ($LASTEXITCODE -ne 0) { throw '字体版本切换失败。' }
}
$Actual = (git -C $FontDir rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $Actual -ne $Pinned) { throw '请选择固定版本的独立 craft-fonts 副本；脚本不会重置已有仓库。' }
$ManifestPath = Join-Path $FontDir 'fonts\manifest.txt'
$Manifest = [IO.File]::ReadAllText($ManifestPath)
if ($Manifest -match 'Noto Sans CJK|Source Han|Adobe') { throw '字体清单包含此项目禁止的资源。' }
$Archive = Join-Path $FontDir 'wqy-microhei-0.2.0-beta.tar.gz'
$Font = Join-Path $FontDir 'fonts\wqy-microhei\wqy-microhei.ttc'
if (-not (Test-Path -LiteralPath $Font)) {
    if (-not (Test-Path -LiteralPath $Archive)) {
        curl.exe -fLsS --retry 2 --connect-timeout 20 --max-time 180 https://downloads.sourceforge.net/project/wqy/wqy-microhei/0.2.0-beta/wqy-microhei-0.2.0-beta.tar.gz -o $Archive
        if ($LASTEXITCODE -ne 0) { throw '中文字体下载失败。' }
    }
    if ((Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash -ine $ArchiveHash) { throw '字体压缩包校验失败。' }
    tar -xzf $Archive -C (Join-Path $FontDir 'fonts') wqy-microhei/wqy-microhei.ttc wqy-microhei/LICENSE_Apache2.txt wqy-microhei/README.txt wqy-microhei/AUTHORS.txt
    if ($LASTEXITCODE -ne 0) { throw '字体解压失败。' }
}
if ((Get-FileHash -LiteralPath $Font -Algorithm SHA256).Hash -ine $FontHash) { throw '中文字体校验失败。' }
$Line = "WenQuanYi Micro Hei | Regular | fonts/wqy-microhei/wqy-microhei.ttc | Hans,Latn | Apache-2.0 | fonts/wqy-microhei/LICENSE_Apache2.txt | $FontHash | https://sourceforge.net/projects/wqy/files/wqy-microhei/0.2.0-beta/"
if ($Manifest -notmatch '(?m)^WenQuanYi Micro Hei \|') {
    [IO.File]::WriteAllText($ManifestPath,($Manifest.TrimEnd() + [Environment]::NewLine + $Line + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
}
foreach ($Row in [IO.File]::ReadAllLines($ManifestPath)) {
    if (-not $Row.Trim() -or $Row.Trim().StartsWith('#')) { continue }
    $Fields = $Row -split ' \| '
    if ($Fields.Count -ne 8) { throw '字体清单格式错误。' }
    if (-not (Test-Path -LiteralPath (Join-Path $FontDir $Fields[5]))) { throw '缺少字体许可。' }
    if ((Get-FileHash -LiteralPath (Join-Path $FontDir $Fields[2]) -Algorithm SHA256).Hash -ine $Fields[6]) { throw "字体校验失败：$($Fields[2])" }
}
Write-Output "字体构建输入已校验：$FontDir"
