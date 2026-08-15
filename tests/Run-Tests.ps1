$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'TTSModInstaller.ps1')

$script:Passed = 0
$script:Failed = 0

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Expected -ne $Actual) {
        $script:Failed++
        Write-Host ("FAIL: {0}`n  Expected: {1}`n  Actual:   {2}" -f $Name, $Expected, $Actual) -ForegroundColor Red
        return
    }

    $script:Passed++
    Write-Host ("PASS: {0}" -f $Name) -ForegroundColor Green
}

function Assert-ThrowsExitCode {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [Parameter(Mandatory = $true)][string]$Name
    )

    try {
        & $Action
        $script:Failed++
        Write-Host ("FAIL: {0}（预期抛出退出码 {1}）" -f $Name, $ExitCode) -ForegroundColor Red
    }
    catch {
        $actualExitCode = $_.Exception.Data['ExitCode']
        if ($actualExitCode -eq $ExitCode) {
            $script:Passed++
            Write-Host ("PASS: {0}" -f $Name) -ForegroundColor Green
        }
        else {
            $script:Failed++
            Write-Host ("FAIL: {0}`n  Expected exit: {1}`n  Actual exit:   {2}" -f $Name, $ExitCode, $actualExitCode) -ForegroundColor Red
        }
    }
}

$jsonDocuments = '{"ConfigMods":{"Caching":true,"Location":0}}'
$jsonGameData = '{"ConfigMods":{"Caching":true,"Location":1}}'

Assert-Equal `
    -Expected ([version]'0.6.1') `
    -Actual (ConvertTo-InstallerVersion -VersionText 'v0.6.1') `
    -Name '解析带 v 前缀的更新版本号'
Assert-Equal `
    -Expected $true `
    -Actual ($null -eq (ConvertTo-InstallerVersion -VersionText 'v0.5-beta')) `
    -Name '拒绝非正式三段版本号'

$mockRelease = [pscustomobject]@{
    tag_name = 'v0.6.1'
    assets = @(
        [pscustomobject]@{
            name = 'TTSModInstaller-v0.6.1.zip'
            browser_download_url = 'https://example.invalid/TTSModInstaller-v0.6.1.zip'
            digest = ('sha256:' + ('a' * 64))
        },
        [pscustomobject]@{
            name = 'TTSModInstaller-v0.6.1.zip.sha256'
            browser_download_url = 'https://example.invalid/TTSModInstaller-v0.6.1.zip.sha256'
        }
    )
}
$mockZipAsset = Get-InstallerReleaseAsset `
    -Release $mockRelease `
    -AssetName 'TTSModInstaller-v0.6.1.zip'
Assert-Equal `
    -Expected 'TTSModInstaller-v0.6.1.zip' `
    -Actual $mockZipAsset.name `
    -Name '按完整文件名选择 GitHub Release 更新资产'
$mockSourceCodeAsset = Get-InstallerReleaseAsset `
    -Release $mockRelease `
    -AssetName 'Source code.zip'
Assert-Equal `
    -Expected $true `
    -Actual ($null -eq $mockSourceCodeAsset) `
    -Name '不把 GitHub Source code ZIP 当作更新包'
Assert-Equal `
    -Expected 'https://gh-proxy.com/https://api.github.com/repos/Nina-17/TTS-Mod-Installer/releases/latest' `
    -Actual (ConvertTo-InstallerProxyUrl -Url $script:UpdateApiUrl) `
    -Name '生成 gh-proxy.com API 备用地址'
Assert-Equal `
    -Expected 'https://gh-proxy.com/https://github.com/Nina-17/TTS-Mod-Installer/releases/download/v0.6.1/package.zip' `
    -Actual (ConvertTo-InstallerProxyUrl -Url 'https://github.com/Nina-17/TTS-Mod-Installer/releases/download/v0.6.1/package.zip') `
    -Name '生成 gh-proxy.com Release 资产备用地址'
Assert-Equal `
    -Expected $true `
    -Actual ($null -eq (ConvertTo-InstallerProxyUrl -Url 'file:///C:/package.zip')) `
    -Name '代理地址只接受 HTTPS 原始链接'

Assert-Equal `
    -Expected 'Documents' `
    -Actual (Get-ConfigModeFromRawValue -RawValue $jsonDocuments) `
    -Name '解析字符串形式的 Documents 配置'

Assert-Equal `
    -Expected 'GameData' `
    -Actual (Get-ConfigModeFromRawValue -RawValue ([Text.Encoding]::UTF8.GetBytes($jsonGameData))) `
    -Name '解析 UTF-8 REG_BINARY 形式的 Game Data 配置'

$base64Config = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($jsonGameData))
Assert-Equal `
    -Expected 'GameData' `
    -Actual (Get-ConfigModeFromRawValue -RawValue $base64Config) `
    -Name '解析 Base64 包装的配置'

$unanimousConfig = Resolve-TTSConfigModeCandidates -ParsedSettings @(
    [pscustomobject]@{ Mode = 'Documents'; ValueName = 'ConfigGame_h1' },
    [pscustomobject]@{ Mode = 'Documents'; ValueName = 'ConfigGame_h2' }
)
Assert-Equal -Expected 'Documents' -Actual $unanimousConfig.Mode -Name '多个一致配置自动采用'
Assert-Equal -Expected $false -Actual $unanimousConfig.Ambiguous -Name '多个一致配置不标记为歧义'

$conflictingConfig = Resolve-TTSConfigModeCandidates -ParsedSettings @(
    [pscustomobject]@{ Mode = 'Documents'; ValueName = 'ConfigGame_h1' },
    [pscustomobject]@{ Mode = 'GameData'; ValueName = 'ConfigGame_h2' }
)
Assert-Equal -Expected $true -Actual $conflictingConfig.Ambiguous -Name '冲突配置标记为歧义'
Assert-Equal -Expected $true -Actual ($null -eq $conflictingConfig.Mode) -Name '冲突配置不任意选择目标'

$vdf = @'
"libraryfolders"
{
    "0"
    {
        "path"        "C:\\Program Files (x86)\\Steam"
    }
    "1"
    {
        "path"        "D:\\SteamLibrary"
    }
}
'@
$libraries = @(Get-SteamLibrariesFromVdf -Content $vdf)
Assert-Equal -Expected 2 -Actual $libraries.Count -Name '解析 Steam 新版 libraryfolders.vdf 数量'
Assert-Equal -Expected 'D:\SteamLibrary' -Actual $libraries[1] -Name '反转义 Steam 库路径'

foreach ($code in @(0, 1, 3, 7)) {
    Assert-Equal -Expected $true -Actual (Test-RobocopyExitCode -ExitCode $code) -Name ("Robocopy {0} 视为成功" -f $code)
}
foreach ($code in @(8, 16)) {
    Assert-Equal -Expected $false -Actual (Test-RobocopyExitCode -ExitCode $code) -Name ("Robocopy {0} 视为失败" -f $code)
}

$quietCopyArguments = @(
    Get-ModCopyRobocopyArguments `
        -SourceRoot 'D:\Package\Mods' `
        -TargetRoot 'D:\TTS\Mods' `
        -LogPath 'D:\Installer\运行数据\Logs\robocopy.log'
)
Assert-Equal `
    -Expected $false `
    -Actual ($quietCopyArguments -contains '/TEE') `
    -Name '复制过程不再镜像到控制台'
Assert-Equal `
    -Expected $true `
    -Actual ($quietCopyArguments -contains '/NP') `
    -Name '复制过程关闭百分比输出'
Assert-Equal `
    -Expected $true `
    -Actual (@($quietCopyArguments | Where-Object { $_ -like '/UNILOG:*' }).Count -eq 1) `
    -Name '复制过程仍保留 Unicode 详细日志'
$firstAnimationFrame = Get-CopyAnimationFrame -Step 0 -Width 12
$returnAnimationFrame = Get-CopyAnimationFrame -Step 12 -Width 12
Assert-Equal `
    -Expected '●···········' `
    -Actual $firstAnimationFrame.Track `
    -Name '复制动画从进度轨道起点出发'
Assert-Equal `
    -Expected '··········●·' `
    -Actual $returnAnimationFrame.Track `
    -Name '复制动画抵达终点后开始折返'
Assert-Equal `
    -Expected $false `
    -Actual ([string]::IsNullOrWhiteSpace($firstAnimationFrame.Face)) `
    -Name '复制动画包含可爱颜文字'

$okAppearance = Get-InstallerStatusAppearance -Level 'OK'
$warningAppearance = Get-InstallerStatusAppearance -Level 'WARN'
$errorAppearance = Get-InstallerStatusAppearance -Level 'ERROR'
Assert-Equal -Expected '✅' -Actual $okAppearance.Icon -Name '成功状态使用可爱图标'
Assert-Equal -Expected 'Success' -Actual $okAppearance.Color -Name '成功状态使用柔和薄荷色角色'
Assert-Equal -Expected 'Warning' -Actual $warningAppearance.Color -Name '警告状态使用柔和沙金色角色'
Assert-Equal -Expected '❌' -Actual $errorAppearance.Icon -Name '失败状态使用醒目图标'
$primaryThemeColor = Get-InstallerThemeColor -Role 'Primary'
$errorThemeColor = Get-InstallerThemeColor -Role 'Error'
Assert-Equal -Expected '242;182;198' -Actual $primaryThemeColor.Rgb -Name '主色使用浅粉 RGB'
Assert-Equal -Expected '220;146;151' -Actual $errorThemeColor.Rgb -Name '错误色使用低饱和珊瑚红'
Assert-Equal -Expected 'Red' -Actual $errorThemeColor.Fallback -Name '不支持真彩色时错误提示仍清晰可辨'

Assert-Equal `
    -Expected 'x64' `
    -Actual (Get-InstallerNativeArchitecture -ProcessorArchitecture 'x86' -ProcessorArchitectureW6432 'AMD64') `
    -Name '32 位 PowerShell 正确识别 x64 Windows'
Assert-Equal `
    -Expected 'arm64' `
    -Actual (Get-InstallerNativeArchitecture -ProcessorArchitecture 'ARM64' -ProcessorArchitectureW6432 '') `
    -Name '识别 Windows ARM64'
Assert-Equal `
    -Expected 'x86' `
    -Actual (Get-InstallerNativeArchitecture -ProcessorArchitecture 'x86' -ProcessorArchitectureW6432 '') `
    -Name '识别 Windows x86'

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('TTSModInstallerTests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$previousInstallerDataRoot = $script:InstallerDataRoot
$script:InstallerDataRoot = Join-Path $testRoot '运行数据'

try {
    Assert-Equal `
        -Expected (Join-Path $testRoot '运行数据') `
        -Actual (Get-InstallerDataRoot) `
        -Name '运行数据根目录跟随安装器文件夹'
    Assert-Equal `
        -Expected (Join-Path (Join-Path (Join-Path $testRoot '运行数据') 'Temp') 'Extract') `
        -Actual (Get-InstallerExtractionRoot) `
        -Name '解压临时目录位于便携运行数据内'
    Assert-Equal `
        -Expected $true `
        -Actual (Test-Path -LiteralPath (Join-Path $projectRoot '点我启动.cmd') -PathType Leaf) `
        -Name '发布目录提供醒目的中文启动器'

    $mockChecksumPath = Join-Path $testRoot 'mock-update.zip.sha256'
    (('b' * 64) + '  mock-update.zip') |
        Set-Content -LiteralPath $mockChecksumPath -Encoding ASCII
    Assert-Equal `
        -Expected ('b' * 64) `
        -Actual (Get-InstallerChecksumHash -ChecksumPath $mockChecksumPath) `
        -Name '解析裸文件名 SHA-256 更新清单'

    $mockBundledRoot = Join-Path $testRoot 'Bundled7Zip'
    $mockX64Directory = Join-Path $mockBundledRoot 'x64'
    $mockX86Directory = Join-Path $mockBundledRoot 'x86'
    New-Item -ItemType Directory -Path $mockX64Directory -Force | Out-Null
    New-Item -ItemType Directory -Path $mockX86Directory -Force | Out-Null
    'mock-x64-exe' | Set-Content -LiteralPath (Join-Path $mockX64Directory '7z.exe') -Encoding ASCII
    'mock-x64-dll' | Set-Content -LiteralPath (Join-Path $mockX64Directory '7z.dll') -Encoding ASCII
    'mock-x86-exe' | Set-Content -LiteralPath (Join-Path $mockX86Directory '7z.exe') -Encoding ASCII
    'mock-x86-dll' | Set-Content -LiteralPath (Join-Path $mockX86Directory '7z.dll') -Encoding ASCII
    Assert-Equal `
        -Expected (Join-Path $mockX64Directory '7z.exe') `
        -Actual (Find-Bundled7ZipExecutable -BundledRoot $mockBundledRoot -Architecture 'x64' -SkipHashValidation) `
        -Name '内置 7-Zip 优先选择匹配架构'
    Remove-Item -LiteralPath $mockX64Directory -Recurse -Force
    Assert-Equal `
        -Expected (Join-Path $mockX86Directory '7z.exe') `
        -Actual (Find-Bundled7ZipExecutable -BundledRoot $mockBundledRoot -Architecture 'x64' -SkipHashValidation) `
        -Name '缺少原生架构时回退 x86 组件'
    Assert-ThrowsExitCode `
        -Action {
            Find-Bundled7ZipExecutable -BundledRoot $mockBundledRoot -Architecture 'x86' | Out-Null
        } `
        -ExitCode 4 `
        -Name '拒绝哈希不匹配的内置 7-Zip'

    $sevenZipListOutput = @(
        'Path = Mods'
        'Size = 0'
        'Packed Size = 0'
        'Folder = +'
        ''
        'Path = Mods\Images\asset.png'
        'Size = 120'
        'Packed Size = 45'
        'Folder = -'
        ''
    )
    $sevenZipInfo = ConvertFrom-SevenZipListOutput `
        -ListOutput $sevenZipListOutput `
        -ArchivePath (Join-Path $testRoot 'package.7z') `
        -ExitCode 0 `
        -SevenZipPath 'mock-7z'
    Assert-Equal -Expected '7Z' -Actual $sevenZipInfo.Format -Name '解析 7Z 技术列表格式'
    Assert-Equal -Expected 1 -Actual $sevenZipInfo.FileCount -Name '7Z 技术列表只统计文件'
    Assert-Equal -Expected 120 -Actual $sevenZipInfo.UncompressedBytes -Name '7Z 技术列表统计解压大小'
    Assert-Equal -Expected 45 -Actual $sevenZipInfo.CompressedBytes -Name '7Z 技术列表统计压缩大小'
    Assert-Equal -Expected $false -Actual $sevenZipInfo.HadWarnings -Name '7-Zip 退出码 0 不标记警告'

    $rarListOutput = @(
        'Path = Mods\Models\asset.obj'
        'Size = 256'
        'Packed Size = 128'
        'Attributes = A'
        ''
    )
    $rarInfo = ConvertFrom-SevenZipListOutput `
        -ListOutput $rarListOutput `
        -ArchivePath (Join-Path $testRoot 'package.rar') `
        -ExitCode 1 `
        -SevenZipPath 'mock-7z'
    Assert-Equal -Expected 'RAR' -Actual $rarInfo.Format -Name '解析 RAR 技术列表格式'
    Assert-Equal -Expected 1 -Actual $rarInfo.FileCount -Name 'RAR 技术列表统计文件'
    Assert-Equal -Expected $true -Actual $rarInfo.HadWarnings -Name '7-Zip 退出码 1 保留为警告'
    Assert-ThrowsExitCode `
        -Action {
            ConvertFrom-SevenZipListOutput `
                -ListOutput $rarListOutput `
                -ArchivePath (Join-Path $testRoot 'broken.rar') `
                -ExitCode 2 `
                -SevenZipPath 'mock-7z' | Out-Null
        } `
        -ExitCode 4 `
        -Name '7-Zip 致命退出码仍判定为解压失败'

    $warningCompletion = Get-InstallCompletionStatus -HadArchiveWarnings $true
    Assert-Equal -Expected 'WARN' -Actual $warningCompletion.Level -Name '压缩包警告映射为黄色完成状态'
    Assert-Equal `
        -Expected $true `
        -Actual $warningCompletion.ResultMessage.Contains('警告') `
        -Name '压缩包警告写入最终安装结果'

    $directMods = Join-Path $testRoot 'Mods'
    New-Item -ItemType Directory -Path (Join-Path $directMods 'Images') -Force | Out-Null
    Assert-Equal `
        -Expected (Get-Item -LiteralPath $directMods).FullName `
        -Actual (Resolve-SourceModsRoot -RootPath $directMods) `
        -Name '输入本身就是 Mods'

    $wrapped = Join-Path $testRoot 'Wrapped'
    $wrappedMods = Join-Path (Join-Path $wrapped '图包名称') 'Mods'
    New-Item -ItemType Directory -Path (Join-Path $wrappedMods 'Workshop') -Force | Out-Null
    Assert-Equal `
        -Expected (Get-Item -LiteralPath $wrappedMods).FullName `
        -Actual (Resolve-SourceModsRoot -RootPath $wrapped) `
        -Name '识别单层包装目录中的 Mods'

    $contentRoot = Join-Path $testRoot 'ContentRoot'
    New-Item -ItemType Directory -Path (Join-Path $contentRoot 'Models') -Force | Out-Null
    Assert-Equal `
        -Expected (Get-Item -LiteralPath $contentRoot).FullName `
        -Actual (Resolve-SourceModsRoot -RootPath $contentRoot) `
        -Name '识别直接包含 Models 的 Mods 内容'

    $zipBuildRoot = Join-Path $testRoot 'ZipBuild'
    $zipWrappedMods = Join-Path (Join-Path $zipBuildRoot 'ZipWrapper') 'Mods'
    New-Item -ItemType Directory -Path (Join-Path $zipWrappedMods 'Images') -Force | Out-Null
    'zip-content' | Set-Content -LiteralPath (Join-Path (Join-Path $zipWrappedMods 'Images') 'zip-asset.txt') -Encoding UTF8
    $zipPath = Join-Path $testRoot 'package.zip'
    Compress-Archive -Path (Join-Path $zipBuildRoot 'ZipWrapper') -DestinationPath $zipPath

    $expandedZip = Expand-ModPackage -InputPath $zipPath
    try {
        $resolvedZipMods = Resolve-SourceModsRoot -RootPath $expandedZip.Root
        Assert-Equal `
            -Expected $true `
            -Actual (Test-Path -LiteralPath (Join-Path (Join-Path $resolvedZipMods 'Images') 'zip-asset.txt') -PathType Leaf) `
            -Name 'ZIP 解压后识别包装目录中的 Mods'
    }
    finally {
        $expandedZipTemporaryRoot = $expandedZip.TemporaryRoot
        Remove-OwnedTemporaryRoot -TemporaryRoot $expandedZipTemporaryRoot
    }
    Assert-Equal `
        -Expected $false `
        -Actual (Test-Path -LiteralPath $expandedZipTemporaryRoot) `
        -Name 'ZIP 临时目录已清理'

    $ttsmodPath = Join-Path $testRoot 'package.ttsmod'
    Copy-Item -LiteralPath $zipPath -Destination $ttsmodPath
    $expandedTtsmod = Expand-ModPackage -InputPath $ttsmodPath
    try {
        $resolvedTtsmodMods = Resolve-SourceModsRoot -RootPath $expandedTtsmod.Root
        Assert-Equal `
            -Expected $true `
            -Actual (Test-Path -LiteralPath (Join-Path (Join-Path $resolvedTtsmodMods 'Images') 'zip-asset.txt') -PathType Leaf) `
            -Name 'TTSMOD 按 ZIP 解压后识别 Mods'
        Assert-Equal `
            -Expected 'System.IO.Compression.ZipFile' `
            -Actual $expandedTtsmod.Tool `
            -Name 'TTSMOD 使用不受扩展名限制的 ZIP 解压路径'
    }
    finally {
        $expandedTtsmodTemporaryRoot = $expandedTtsmod.TemporaryRoot
        Remove-OwnedTemporaryRoot -TemporaryRoot $expandedTtsmodTemporaryRoot
    }
    Assert-Equal `
        -Expected $false `
        -Actual (Test-Path -LiteralPath $expandedTtsmodTemporaryRoot) `
        -Name 'TTSMOD 临时目录已清理'

    $zipInfo = Get-ZipPackageInfo -ArchivePath $zipPath
    Assert-Equal -Expected 1 -Actual $zipInfo.FileCount -Name 'ZIP 预检统计文件数量'
    Assert-Equal -Expected $true -Actual ($zipInfo.UncompressedBytes -gt 0) -Name 'ZIP 预检统计解压大小'
    Assert-ThrowsExitCode `
        -Action {
            Assert-ArchivePackageReasonable `
                -PackageInfo ([pscustomobject]@{
                    FileCount = 1
                    UncompressedBytes = 2GB
                    CompressedBytes = 1MB
                }) `
                -TemporaryBase $testRoot
        } `
        -ExitCode 4 `
        -Name '拒绝异常高压缩比'

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $unsafeZipPath = Join-Path $testRoot 'unsafe.zip'
    $unsafeArchive = [IO.Compression.ZipFile]::Open($unsafeZipPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $unsafeArchive.CreateEntry('../escape.txt') | Out-Null
    }
    finally {
        $unsafeArchive.Dispose()
    }
    Assert-ThrowsExitCode `
        -Action { Assert-ZipEntriesSafe -ArchivePath $unsafeZipPath } `
        -ExitCode 4 `
        -Name '拒绝 ZIP 路径穿越'

    $ambiguous = Join-Path $testRoot 'Ambiguous'
    New-Item -ItemType Directory -Path (Join-Path (Join-Path $ambiguous 'A') 'Mods') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path (Join-Path $ambiguous 'B') 'Mods') -Force | Out-Null
    Assert-ThrowsExitCode `
        -Action { Resolve-SourceModsRoot -RootPath $ambiguous | Out-Null } `
        -ExitCode 2 `
        -Name '拒绝多个 Mods 候选'

    $empty = Join-Path $testRoot 'Empty'
    New-Item -ItemType Directory -Path $empty | Out-Null
    Assert-ThrowsExitCode `
        -Action { Resolve-SourceModsRoot -RootPath $empty | Out-Null } `
        -ExitCode 2 `
        -Name '拒绝无法识别的空目录'

    Assert-ThrowsExitCode `
        -Action { Assert-SafeCopyRelationship -SourceRoot $directMods -TargetRoot $directMods } `
        -ExitCode 2 `
        -Name '拒绝来源和目标相同'

    Assert-ThrowsExitCode `
        -Action { Assert-SafeCopyRelationship -SourceRoot $wrapped -TargetRoot $wrappedMods } `
        -ExitCode 2 `
        -Name '拒绝来源和目标互相嵌套'

    $overwriteOnlySource = Join-Path $testRoot 'OverwriteOnlySource'
    $overwriteOnlyTarget = Join-Path $testRoot 'OverwriteOnlyTarget'
    New-Item -ItemType Directory -Path $overwriteOnlySource, $overwriteOnlyTarget -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $overwriteOnlySource 'same.bin'), [byte[]](1, 2, 3, 4))
    [IO.File]::WriteAllBytes((Join-Path $overwriteOnlyTarget 'same.bin'), [byte[]](9, 8, 7, 6))
    $overwriteOnlySummary = Get-CopySummary -SourceRoot $overwriteOnlySource -TargetRoot $overwriteOnlyTarget
    Assert-Equal -Expected 1 -Actual $overwriteOnlySummary.FileCount -Name '复制摘要统计覆盖文件数'
    Assert-Equal -Expected 4 -Actual $overwriteOnlySummary.TotalBytes -Name '复制摘要统计本次写入量'
    Assert-Equal -Expected 1 -Actual $overwriteOnlySummary.ConflictCount -Name '复制摘要统计同名目标文件'
    Assert-Equal -Expected 4 -Actual $overwriteOnlySummary.OverwriteBytes -Name '复制摘要统计覆盖写入量'
    Assert-Equal -Expected 0 -Actual $overwriteOnlySummary.RequiredGrowthBytes -Name '同大小覆盖的预计净增长为零'

    $quotedPath = '"{0}"' -f $contentRoot
    Assert-Equal `
        -Expected (Get-Item -LiteralPath $contentRoot).FullName `
        -Actual (Resolve-InstallerInputPath -InputPath $quotedPath) `
        -Name '处理拖放产生的引号路径'

    $secondDraggedPath = Join-Path $testRoot 'Second Dragged Package'
    New-Item -ItemType Directory -Path $secondDraggedPath | Out-Null
    $draggedLine = '"{0}" "{1}"' -f $contentRoot, $secondDraggedPath
    $draggedPaths = @(ConvertFrom-InstallerInputLine -InputLine $draggedLine)
    Assert-Equal -Expected 2 -Actual $draggedPaths.Count -Name '解析一次拖入的多个带空格路径'
    Assert-Equal -Expected $secondDraggedPath -Actual $draggedPaths[1] -Name '保留第二个拖入路径'

    $handoffRoot = Get-InstallerHandoffRoot
    New-Item -ItemType Directory -Path $handoffRoot -Force | Out-Null
    $handoffId = [guid]::NewGuid().ToString('N')
    $requestPath = Join-Path $handoffRoot ($handoffId + '.request.json')
    $resultPath = Join-Path $handoffRoot ($handoffId + '.result.json')
    @{
        PackagePaths = @($contentRoot, $secondDraggedPath)
        DestinationPath = $directMods
        ForceWhileRunning = $false
        NonInteractive = $true
        ResultPath = $resultPath
    } | ConvertTo-Json | Set-Content -LiteralPath $requestPath -Encoding UTF8
    $handoffData = Read-InstallerHandoff -Path $requestPath
    Assert-Equal -Expected 2 -Actual @($handoffData.PackagePaths).Count -Name 'UAC 交接保留多图包列表'
    Assert-Equal -Expected $false -Actual (Test-Path -LiteralPath $requestPath) -Name '读取后清理 UAC 请求文件'

    $script:LastBatchResults = @(
        [pscustomobject]@{
            PackagePath = $contentRoot
            ExitCode = 0
            TargetPath = $directMods
            LogPath = 'test.log'
        }
    )
    Write-InstallerHandoffResult -Path $resultPath -ExitCode 0
    $writtenResult = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    Assert-Equal -Expected 0 -Actual $writtenResult.ExitCode -Name 'UAC 子进程结果写回'
    Assert-Equal -Expected 'test.log' -Actual $writtenResult.Results[0].LogPath -Name 'UAC 结果包含日志路径'
    Remove-Item -LiteralPath $resultPath -Force

    $unownedHandoff = Join-Path $testRoot (([guid]::NewGuid().ToString('N')) + '.request.json')
    '{}' | Set-Content -LiteralPath $unownedHandoff -Encoding UTF8
    Assert-ThrowsExitCode `
        -Action { Read-InstallerHandoff -Path $unownedHandoff | Out-Null } `
        -ExitCode 5 `
        -Name '拒绝读取安装器目录之外的 UAC 交接文件'
    Assert-Equal -Expected $true -Actual (Test-Path -LiteralPath $unownedHandoff) -Name '拒绝时不删除目录外文件'

    $endToEndPackage = Join-Path $testRoot 'EndToEndPackage'
    $endToEndMods = Join-Path $endToEndPackage 'Mods'
    $endToEndImages = Join-Path $endToEndMods 'Images'
    $endToEndTarget = Join-Path $testRoot 'EndToEndTarget'
    New-Item -ItemType Directory -Path $endToEndImages -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $endToEndTarget 'Images') -Force | Out-Null
    'new-content' | Set-Content -LiteralPath (Join-Path $endToEndImages 'asset.txt') -Encoding UTF8
    'old-content' | Set-Content -LiteralPath (Join-Path (Join-Path $endToEndTarget 'Images') 'asset.txt') -Encoding UTF8
    'keep-me' | Set-Content -LiteralPath (Join-Path $endToEndTarget 'unrelated.txt') -Encoding UTF8

    function Invoke-ModCopy {
        param([string]$SourceRoot, [string]$TargetRoot)
        Get-ChildItem -LiteralPath $SourceRoot -Force |
            Copy-Item -Destination $TargetRoot -Recurse -Force
        return 1
    }

    $installResult = Invoke-OnePackageInstall `
        -InputPath $endToEndPackage `
        -ExplicitDestination $endToEndTarget `
        -NoPrompt
    Assert-Equal -Expected 0 -Actual $installResult -Name '显式目标端到端安装流程'
    Assert-Equal `
        -Expected 'new-content' `
        -Actual ((Get-Content -LiteralPath (Join-Path (Join-Path $endToEndTarget 'Images') 'asset.txt') -Raw).Trim()) `
        -Name '端到端流程覆盖同名文件'
    Assert-Equal `
        -Expected 'keep-me' `
        -Actual ((Get-Content -LiteralPath (Join-Path $endToEndTarget 'unrelated.txt') -Raw).Trim()) `
        -Name '端到端流程保留无关文件'

    $secondPackage = Join-Path $testRoot 'SecondPackage'
    $secondPackageModels = Join-Path (Join-Path $secondPackage 'Mods') 'Models'
    New-Item -ItemType Directory -Path $secondPackageModels -Force | Out-Null
    'second-content' | Set-Content -LiteralPath (Join-Path $secondPackageModels 'second.txt') -Encoding UTF8
    $batchResult = Invoke-PackageBatch `
        -InputPaths @($endToEndPackage, $secondPackage) `
        -ExplicitDestination $endToEndTarget `
        -NoPrompt
    Assert-Equal -Expected 0 -Actual $batchResult -Name '多图包批次安装流程'
    Assert-Equal `
        -Expected 'second-content' `
        -Actual ((Get-Content -LiteralPath (Join-Path (Join-Path $endToEndTarget 'Models') 'second.txt') -Raw).Trim()) `
        -Name '多图包批次写入第二个图包'
}
finally {
    $script:InstallerDataRoot = $previousInstallerDataRoot
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host ''
Write-Host ("测试结果：{0} 通过，{1} 失败" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) {
    exit 1
}
exit 0
