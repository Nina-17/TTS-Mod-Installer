[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$PackagePath,

    [string]$DestinationPath,

    [ValidateSet('Auto', 'Documents', 'GameData')]
    [string]$LocationMode = 'Auto',

    [switch]$Elevated,
    [switch]$ForceWhileRunning,
    [switch]$NonInteractive,
    [switch]$SkipUpdateCheck,
    [string]$HandoffPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:InstallerVersion = '0.5.2'
$script:Bundled7ZipVersion = '26.02'
$script:Bundled7ZipHashes = @{
    'x86\7z.exe' = '285e5220d6d4240b6a4bdb6357d427e457313376e3464d3cb973637a384ed02a'
    'x86\7z.dll' = 'c6989259a78960805b8b646843d2ef3a8a19e5533359e8a252aad2f3cc78c844'
    'x64\7z.exe' = '83967f1b02b43c4efeda302795722c809e0e81b8307de73558d10484d5676a7d'
    'x64\7z.dll' = '69fd4df057985c40e510e2fac182881c7f85e90aa13ec703f763a8fdb2ce61f8'
    'arm64\7z.exe' = '46009c25732880c9d49032ec20da46dfdc669fb60257f50308a0026b4fac3aef'
    'arm64\7z.dll' = '7346eaea5f333b1d65b6b4eedf6797c416bbc91c75e46159df38aa28e153f7c5'
}
$script:LogPath = $null
$script:RoboCopyLogPath = $null
$script:IsWindowsPlatform = ($env:OS -eq 'Windows_NT')
$script:InstallerScriptPath = $PSCommandPath
$script:MaintenanceCompleted = $false
$script:LastInstallResult = $null
$script:LastBatchResults = @()
$script:InstallerDataRoot = Join-Path $PSScriptRoot '运行数据'
$script:UpdateApiUrl = 'https://api.github.com/repos/Nina-17/TTS-Mod-Installer/releases/latest'
$script:UpdateProxyPrefix = 'https://gh-proxy.com/'
$script:UpdateDownloadChannel = 'GitHub'
$script:UpdateExitCode = 42

function Throw-InstallerError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )

    $exception = New-Object System.InvalidOperationException -ArgumentList $Message
    $exception.Data['ExitCode'] = $ExitCode
    throw $exception
}

function Get-InstallerDataRoot {
    return $script:InstallerDataRoot
}

function Get-InstallerExtractionRoot {
    return (Join-Path (Join-Path (Get-InstallerDataRoot) 'Temp') 'Extract')
}

function Get-InstallerHandoffRoot {
    return (Join-Path (Join-Path (Get-InstallerDataRoot) 'Temp') 'Handoff')
}

function Get-InstallerUpdateRoot {
    return (Join-Path (Join-Path (Get-InstallerDataRoot) 'Temp') 'Update')
}

function Test-PathIsUnderRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $prefix = $fullRoot + [IO.Path]::DirectorySeparatorChar
    return $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Remove-StaleInstallerData {
    if ($script:MaintenanceCompleted) {
        return
    }
    $script:MaintenanceCompleted = $true

    $cutoffs = @(
        @{
            Path = Join-Path (Get-InstallerDataRoot) 'Logs'
            Before = (Get-Date).AddDays(-30)
            Directories = $false
        },
        @{
            Path = Get-InstallerExtractionRoot
            Before = (Get-Date).AddDays(-1)
            Directories = $true
        },
        @{
            Path = Get-InstallerHandoffRoot
            Before = (Get-Date).AddDays(-1)
            Directories = $false
        },
        @{
            Path = Get-InstallerUpdateRoot
            Before = (Get-Date).AddDays(-1)
            Directories = $true
        },
        @{
            Path = Join-Path (Get-InstallerDataRoot) 'Backups'
            Before = (Get-Date).AddDays(-30)
            Directories = $true
        }
    )

    foreach ($rule in $cutoffs) {
        if (-not (Test-Path -LiteralPath $rule.Path -PathType Container)) {
            continue
        }

        try {
            if ($rule.Directories) {
                Get-ChildItem -LiteralPath $rule.Path -Directory -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -lt $rule.Before } |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }
            else {
                Get-ChildItem -LiteralPath $rule.Path -File -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -lt $rule.Before } |
                    Remove-Item -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            # Maintenance is best effort and must never block an installation.
        }
    }
}

function Initialize-InstallerLog {
    Remove-StaleInstallerData
    $logDirectory = Join-Path (Get-InstallerDataRoot) 'Logs'
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $script:LogPath = Join-Path $logDirectory ("install-{0}.log" -f $stamp)
    $script:RoboCopyLogPath = Join-Path $logDirectory ("robocopy-{0}.log" -f $stamp)

    $header = @(
        'TTS Mod Installer'
        ("Version: {0}" -f $script:InstallerVersion)
        ("Started: {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))
        ("PowerShell: {0}" -f $PSVersionTable.PSVersion)
        ("OS: {0}" -f [Environment]::OSVersion.VersionString)
        ''
    )
    $header | Set-Content -LiteralPath $script:LogPath -Encoding UTF8
    return $script:LogPath
}

function Write-InstallerStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $appearance = Get-InstallerStatusAppearance -Level $Level
    $timestamp = Get-Date -Format 'HH:mm:ss'
    $line = '[{0}] [{1}] {2}' -f $timestamp, $Level, $Message

    Write-Host ("  {0}  " -f $timestamp) -ForegroundColor DarkGray -NoNewline
    Write-Host ("{0} " -f $appearance.Icon) -ForegroundColor $appearance.Color -NoNewline
    Write-Host $Message -ForegroundColor $appearance.Color

    if (-not [string]::IsNullOrWhiteSpace($script:LogPath)) {
        $line | Add-Content -LiteralPath $script:LogPath -Encoding UTF8
    }
}

function Get-InstallerStatusAppearance {
    param(
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')]
        [string]$Level
    )

    switch ($Level) {
        'OK' {
            return [pscustomobject]@{ Icon = '✅'; Color = 'Green' }
        }
        'WARN' {
            return [pscustomobject]@{ Icon = '⚠️'; Color = 'Yellow' }
        }
        'ERROR' {
            return [pscustomobject]@{ Icon = '❌'; Color = 'Red' }
        }
        default {
            return [pscustomobject]@{ Icon = '💠'; Color = 'Cyan' }
        }
    }
}

function Write-InstallerBanner {
    try {
        $Host.UI.RawUI.WindowTitle = "🎲 TTS 图包魔法搬运工 v$($script:InstallerVersion) ✨"
    }
    catch {
        # Some non-interactive hosts do not expose a writable window title.
    }

    Write-Host ''
    Write-Host '  ✦ ───────────────────────────────────────── ✦' -ForegroundColor DarkMagenta
    Write-Host '       🎲  TTS 本地图包魔法搬运工  ✨' -ForegroundColor Magenta
    Write-Host ("       v{0}    (ﾉ◕ヮ◕)ﾉ*:･ﾟ✧" -f $script:InstallerVersion) -ForegroundColor Cyan
    Write-Host '  ✦ ───────────────────────────────────────── ✦' -ForegroundColor DarkMagenta
    Write-Host ''
}

function Write-InstallerSection {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Icon,

        [Parameter(Mandatory = $true)]
        [string]$Title,

        [string]$Subtitle
    )

    Write-Host ''
    Write-Host ("  {0}  {1}" -f $Icon, $Title) -ForegroundColor Magenta
    if (-not [string]::IsNullOrWhiteSpace($Subtitle)) {
        Write-Host ("      {0}" -f $Subtitle) -ForegroundColor DarkCyan
    }
    Write-Host '  ───────────────────────────────────────────' -ForegroundColor DarkMagenta
}

function ConvertTo-DisplaySize {
    param([Int64]$Bytes)

    if ($Bytes -ge 1TB) {
        return ('{0:N2} TB' -f ($Bytes / 1TB))
    }
    if ($Bytes -ge 1GB) {
        return ('{0:N2} GB' -f ($Bytes / 1GB))
    }
    if ($Bytes -ge 1MB) {
        return ('{0:N2} MB' -f ($Bytes / 1MB))
    }
    if ($Bytes -ge 1KB) {
        return ('{0:N2} KB' -f ($Bytes / 1KB))
    }
    return ('{0} B' -f $Bytes)
}

function ConvertTo-InstallerVersion {
    param([string]$VersionText)

    if ([string]::IsNullOrWhiteSpace($VersionText)) {
        return $null
    }

    $normalized = $VersionText.Trim()
    if ($normalized.StartsWith('v', [StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(1)
    }
    if ($normalized -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
        return $null
    }

    try {
        return [version]$normalized
    }
    catch {
        return $null
    }
}

function Get-InstallerReleaseAsset {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Release,

        [Parameter(Mandatory = $true)]
        [string]$AssetName
    )

    foreach ($asset in @($Release.assets)) {
        if (([string]$asset.name) -ieq $AssetName) {
            return $asset
        }
    }
    return $null
}

function Get-InstallerChecksumHash {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ChecksumPath
    )

    foreach ($line in (Get-Content -LiteralPath $ChecksumPath)) {
        if ([string]$line -match '^\s*([a-fA-F0-9]{64})(?:\s+.*)?$') {
            return $matches[1].ToLowerInvariant()
        }
    }
    return $null
}

function ConvertTo-InstallerProxyUrl {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return $null
    }
    if ($Url.StartsWith($script:UpdateProxyPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $Url
    }

    $parsedUrl = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$parsedUrl)) {
        return $null
    }
    if ($parsedUrl.Scheme -ine 'https') {
        return $null
    }
    return ($script:UpdateProxyPrefix + $Url)
}

function Get-InstallerUpdateHeaders {
    return @{
        Accept = 'application/vnd.github+json'
        'User-Agent' = 'TTS-Mod-Installer'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
}

function Get-LatestInstallerRelease {
    $headers = Get-InstallerUpdateHeaders

    if ([Net.ServicePointManager]::SecurityProtocol -band [Net.SecurityProtocolType]::Tls12) {
        # TLS 1.2 is already enabled.
    }
    else {
        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }

    $script:UpdateDownloadChannel = 'GitHub'
    try {
        return (Invoke-RestMethod `
            -Uri $script:UpdateApiUrl `
            -Headers $headers `
            -Method Get `
            -TimeoutSec 10 `
            -ErrorAction Stop)
    }
    catch {
        $directError = $_.Exception.Message
        $proxyUrl = ConvertTo-InstallerProxyUrl -Url $script:UpdateApiUrl
        if ([string]::IsNullOrWhiteSpace($proxyUrl)) {
            throw
        }

        Write-InstallerStatus -Level WARN -Message 'GitHub 直连失败，正在切换 gh-proxy.com 通道……'
        try {
            $release = Invoke-RestMethod `
                -Uri $proxyUrl `
                -Headers $headers `
                -Method Get `
                -TimeoutSec 15 `
                -ErrorAction Stop
            $script:UpdateDownloadChannel = 'GhProxy'
            Write-InstallerStatus -Level OK -Message 'gh-proxy.com 通道连接成功。'
            return $release
        }
        catch {
            throw (
                "GitHub 直连失败：{0}；gh-proxy.com 也失败：{1}" -f
                $directError,
                $_.Exception.Message
            )
        }
    }
}

function Save-InstallerUpdateAsset {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$OutFile,

        [int]$TimeoutSec = 60
    )

    $proxyUrl = ConvertTo-InstallerProxyUrl -Url $Url
    if ([string]::IsNullOrWhiteSpace($proxyUrl)) {
        throw ("无法生成 gh-proxy.com 下载地址：{0}" -f $Url)
    }

    if ($script:UpdateDownloadChannel -eq 'GhProxy') {
        $attempts = @(
            [pscustomobject]@{ Name = 'gh-proxy.com'; Url = $proxyUrl }
        )
    }
    else {
        $attempts = @(
            [pscustomobject]@{ Name = 'GitHub'; Url = $Url },
            [pscustomobject]@{ Name = 'gh-proxy.com'; Url = $proxyUrl }
        )
    }

    $errors = @()
    foreach ($attempt in $attempts) {
        if (Test-Path -LiteralPath $OutFile) {
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
        }
        try {
            Invoke-WebRequest `
                -Uri ([string]$attempt.Url) `
                -OutFile $OutFile `
                -UseBasicParsing `
                -Headers @{ 'User-Agent' = 'TTS-Mod-Installer' } `
                -TimeoutSec $TimeoutSec `
                -ErrorAction Stop | Out-Null
            if ($attempt.Name -eq 'gh-proxy.com') {
                $script:UpdateDownloadChannel = 'GhProxy'
            }
            return
        }
        catch {
            $errors += ("{0}：{1}" -f $attempt.Name, $_.Exception.Message)
            if ($attempt.Name -eq 'GitHub') {
                Write-InstallerStatus -Level WARN -Message 'GitHub 下载失败，正在切换 gh-proxy.com 通道……'
            }
        }
    }

    throw ("更新资产下载失败（{0}）" -f ($errors -join '；'))
}

function Start-InstallerUpdate {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Release,

        [Parameter(Mandatory = $true)]
        [version]$TargetVersion,

        [string[]]$RelaunchArguments
    )

    $tagName = [string]$Release.tag_name
    $zipName = 'TTSModInstaller-{0}.zip' -f $tagName
    $checksumName = $zipName + '.sha256'
    $zipAsset = Get-InstallerReleaseAsset -Release $Release -AssetName $zipName
    $checksumAsset = Get-InstallerReleaseAsset -Release $Release -AssetName $checksumName
    if ($null -eq $zipAsset) {
        Write-InstallerStatus -Level WARN -Message ("Release 中没有找到更新包：{0}" -f $zipName)
        return $false
    }

    $updateBase = Get-InstallerUpdateRoot
    $updateRoot = Join-Path $updateBase ([guid]::NewGuid().ToString('N'))
    $zipPath = Join-Path $updateRoot $zipName
    $checksumPath = Join-Path $updateRoot $checksumName
    $packageDirectory = Join-Path $updateRoot 'Package'
    $requestPath = Join-Path $updateRoot 'update-request.json'
    $temporaryUpdater = Join-Path $updateRoot 'TTSModUpdater.ps1'
    $oldProgressPreference = $ProgressPreference

    try {
        New-Item -ItemType Directory -Path $updateRoot -Force | Out-Null
        $ProgressPreference = 'SilentlyContinue'
        Write-InstallerStatus -Message ("⬇️ 正在下载 {0}……" -f $zipName)
        Save-InstallerUpdateAsset `
            -Url ([string]$zipAsset.browser_download_url) `
            -OutFile $zipPath `
            -TimeoutSec 60

        $expectedHash = $null
        if ($zipAsset.PSObject.Properties['digest']) {
            $digest = [string]$zipAsset.digest
            if ($digest -match '^sha256:([a-fA-F0-9]{64})$') {
                $expectedHash = $matches[1].ToLowerInvariant()
            }
        }

        if ($null -ne $checksumAsset) {
            Save-InstallerUpdateAsset `
                -Url ([string]$checksumAsset.browser_download_url) `
                -OutFile $checksumPath `
                -TimeoutSec 30
            $checksumHash = Get-InstallerChecksumHash -ChecksumPath $checksumPath
            if ([string]::IsNullOrWhiteSpace($checksumHash)) {
                throw '更新包的 SHA-256 清单无法解析。'
            }
            if (-not [string]::IsNullOrWhiteSpace($expectedHash) -and $checksumHash -ne $expectedHash) {
                throw 'GitHub 资产摘要与 SHA-256 清单不一致。'
            }
            $expectedHash = $checksumHash
        }

        if ([string]::IsNullOrWhiteSpace($expectedHash)) {
            throw 'Release 没有提供可用的 SHA-256 校验值。'
        }

        $actualHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash) {
            throw '下载的更新包 SHA-256 校验失败。'
        }
        Write-InstallerStatus -Level OK -Message '更新包 SHA-256 校验通过。'

        New-Item -ItemType Directory -Path $packageDirectory | Out-Null
        Expand-Archive -LiteralPath $zipPath -DestinationPath $packageDirectory -Force

        foreach ($requiredFile in @('TTSModInstaller.ps1', '点我启动.cmd', 'TTSModUpdater.ps1')) {
            if (-not (Test-Path -LiteralPath (Join-Path $packageDirectory $requiredFile) -PathType Leaf)) {
                throw ("更新包缺少必要文件：{0}" -f $requiredFile)
            }
        }

        $newScriptText = Get-Content -LiteralPath (Join-Path $packageDirectory 'TTSModInstaller.ps1') -Raw
        $versionMatch = [regex]::Match(
            $newScriptText,
            'InstallerVersion\s*=\s*[''"]([^''"]+)[''"]'
        )
        if (-not $versionMatch.Success) {
            throw '无法读取更新包内的安装器版本。'
        }
        $packageVersion = ConvertTo-InstallerVersion -VersionText $versionMatch.Groups[1].Value
        if ($null -eq $packageVersion -or $packageVersion -ne $TargetVersion) {
            throw '更新包内版本与 GitHub Release 标签不一致。'
        }

        Copy-Item `
            -LiteralPath (Join-Path $packageDirectory 'TTSModUpdater.ps1') `
            -Destination $temporaryUpdater `
            -Force

        $updatedRelaunchArguments = @($RelaunchArguments)
        $updatedRelaunchArguments += '-SkipUpdateCheck'
        $request = [ordered]@{
            ParentProcessId = $PID
            InstallDirectory = $PSScriptRoot
            PackageDirectory = $packageDirectory
            RelaunchPath = (Join-Path $PSScriptRoot 'TTSModInstaller.ps1')
            RelaunchArguments = $updatedRelaunchArguments
            CurrentVersion = $script:InstallerVersion
            TargetVersion = $TargetVersion.ToString()
            DataRoot = (Get-InstallerDataRoot)
            UpdateRoot = $updateRoot
        }
        $request | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -Encoding UTF8

        $updaterArguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -RequestPath "{1}"' -f `
            $temporaryUpdater,
            $requestPath
        $startParameters = @{
            FilePath = 'powershell.exe'
            ArgumentList = $updaterArguments
            PassThru = $true
        }
        if (-not (Test-DestinationWriteAccess -Path $PSScriptRoot)) {
            Write-InstallerStatus -Level WARN -Message '安装器目录需要管理员权限，即将请求 Windows UAC。'
            $startParameters['Verb'] = 'RunAs'
        }

        Start-Process @startParameters | Out-Null
        Write-InstallerStatus -Level OK -Message '更新助手已启动，安装器即将重新打开～ ✨'
        return $true
    }
    catch {
        Write-InstallerStatus -Level WARN -Message ("自动更新没有完成：{0}" -f $_.Exception.Message)
        if (Test-Path -LiteralPath $updateRoot) {
            Remove-Item -LiteralPath $updateRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        return $false
    }
    finally {
        $ProgressPreference = $oldProgressPreference
    }
}

function Invoke-InstallerUpdateCheck {
    param([string[]]$RelaunchArguments)

    Write-InstallerStatus -Message '🌐 正在检查 GitHub 更新……'
    try {
        $release = Get-LatestInstallerRelease
        $currentVersion = ConvertTo-InstallerVersion -VersionText $script:InstallerVersion
        $latestVersion = ConvertTo-InstallerVersion -VersionText ([string]$release.tag_name)
        if ($null -eq $currentVersion -or $null -eq $latestVersion) {
            Write-InstallerStatus -Level WARN -Message '版本号无法解析，已跳过本次更新检查。'
            return $false
        }
        if ($latestVersion -le $currentVersion) {
            Write-InstallerStatus -Level OK -Message ("已经是最新版：v{0}" -f $script:InstallerVersion)
            return $false
        }

        Write-InstallerSection `
            -Icon '🆕' `
            -Title ("发现新版本 v{0}！" -f $latestVersion) `
            -Subtitle ("当前版本 v{0}，可以一键更新啦 (ﾉ◕ヮ◕)ﾉ*:･ﾟ✧" -f $currentVersion)
        Write-Host '      [U] 立即下载并更新' -ForegroundColor Green
        Write-Host '      [S] 本次跳过，继续安装图包' -ForegroundColor Yellow
        $choice = (Read-Host '  请选择').Trim()
        if ($choice -ine 'U') {
            Write-InstallerStatus -Message '本次先不更新，继续使用当前版本。'
            return $false
        }

        return (Start-InstallerUpdate `
            -Release $release `
            -TargetVersion $latestVersion `
            -RelaunchArguments $RelaunchArguments)
    }
    catch {
        Write-InstallerStatus -Level WARN -Message ("暂时无法检查更新，将继续运行：{0}" -f $_.Exception.Message)
        return $false
    }
}

function Resolve-InstallerInputPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath
    )

    $candidate = $InputPath.Trim()
    if ($candidate.StartsWith('& ')) {
        $candidate = $candidate.Substring(2).Trim()
    }

    if ($candidate.Length -ge 2) {
        $first = $candidate.Substring(0, 1)
        $last = $candidate.Substring($candidate.Length - 1, 1)
        if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
            $candidate = $candidate.Substring(1, $candidate.Length - 2)
        }
    }

    $candidate = [Environment]::ExpandEnvironmentVariables($candidate)
    if ($candidate -match '^[a-zA-Z]+://') {
        Throw-InstallerError -Message '请输入本地文件夹或压缩包路径，不能使用网络 URL。' -ExitCode 2
    }

    if (-not (Test-Path -LiteralPath $candidate)) {
        Throw-InstallerError -Message ("路径不存在：{0}" -f $candidate) -ExitCode 2
    }

    return (Get-Item -LiteralPath $candidate -Force).FullName
}

function Get-DocumentsModsPath {
    $documents = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
    if ([string]::IsNullOrWhiteSpace($documents)) {
        Throw-InstallerError -Message 'Windows 未返回当前用户的“文档”目录。' -ExitCode 3
    }

    return (Join-Path (Join-Path (Join-Path $documents 'My Games') 'Tabletop Simulator') 'Mods')
}

function Test-TTSInstallRoot {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    return (
        (Test-Path -LiteralPath (Join-Path $Path 'Tabletop Simulator.exe') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Path 'Tabletop Simulator_Data') -PathType Container)
    )
}

function Get-TTSRunningProcesses {
    if (-not $script:IsWindowsPlatform) {
        return @()
    }

    return @(Get-Process -Name 'Tabletop Simulator' -ErrorAction SilentlyContinue)
}

function Get-SteamLibrariesFromVdf {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $results = New-Object System.Collections.Generic.List[string]
    $patterns = @(
        '(?im)^\s*"path"\s+"([^"]+)"',
        '(?im)^\s*"\d+"\s+"((?:[A-Za-z]:\\\\|\\\\\\\\)[^"]+)"'
    )

    foreach ($pattern in $patterns) {
        foreach ($match in [regex]::Matches($Content, $pattern)) {
            $path = $match.Groups[1].Value -replace '\\\\', '\'
            if (-not [string]::IsNullOrWhiteSpace($path)) {
                $results.Add($path)
            }
        }
    }

    return $results.ToArray()
}

function Get-SteamRootCandidates {
    $candidates = New-Object System.Collections.Generic.List[string]

    $registryEntries = @(
        @{ Path = 'HKCU:\Software\Valve\Steam'; Name = 'SteamPath' },
        @{ Path = 'HKCU:\Software\Valve\Steam'; Name = 'SteamExe' },
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam'; Name = 'InstallPath' },
        @{ Path = 'HKLM:\SOFTWARE\Valve\Steam'; Name = 'InstallPath' }
    )

    foreach ($entry in $registryEntries) {
        try {
            $value = (Get-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -ErrorAction Stop).($entry.Name)
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                if ([IO.Path]::GetExtension($value) -ieq '.exe') {
                    $value = Split-Path -Parent $value
                }
                $candidates.Add($value)
            }
        }
        catch {
            # Registry variants are optional.
        }
    }

    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Steam'))
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $candidates.Add((Join-Path $env:ProgramFiles 'Steam'))
    }

    return $candidates.ToArray()
}

function Get-TTSInstallPath {
    $candidates = New-Object System.Collections.Generic.List[string]

    foreach ($process in (Get-TTSRunningProcesses)) {
        try {
            if (-not [string]::IsNullOrWhiteSpace($process.Path)) {
                $candidates.Add((Split-Path -Parent $process.Path))
            }
        }
        catch {
            # Process path can be unavailable without elevation.
        }
    }

    $uninstallKeys = @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 286160',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 286160',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 286160'
    )
    foreach ($key in $uninstallKeys) {
        try {
            $location = (Get-ItemProperty -LiteralPath $key -Name 'InstallLocation' -ErrorAction Stop).InstallLocation
            if (-not [string]::IsNullOrWhiteSpace($location)) {
                $candidates.Add($location)
            }
        }
        catch {
            # Not every Steam installation creates every uninstall key.
        }
    }

    foreach ($steamRoot in (Get-SteamRootCandidates)) {
        if ([string]::IsNullOrWhiteSpace($steamRoot)) {
            continue
        }

        $libraries = New-Object System.Collections.Generic.List[string]
        $libraries.Add($steamRoot)
        $vdfPath = Join-Path (Join-Path $steamRoot 'steamapps') 'libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdfPath -PathType Leaf) {
            try {
                $vdfContent = Get-Content -LiteralPath $vdfPath -Raw
                foreach ($library in (Get-SteamLibrariesFromVdf -Content $vdfContent)) {
                    $libraries.Add($library)
                }
            }
            catch {
                # Continue with the main Steam root.
            }
        }

        foreach ($library in $libraries) {
            $steamApps = Join-Path $library 'steamapps'
            $manifest = Join-Path $steamApps 'appmanifest_286160.acf'
            if (Test-Path -LiteralPath $manifest -PathType Leaf) {
                try {
                    $manifestContent = Get-Content -LiteralPath $manifest -Raw
                    $manifestMatch = [regex]::Match($manifestContent, '(?im)^\s*"installdir"\s+"([^"]+)"')
                    if ($manifestMatch.Success) {
                        $candidates.Add((Join-Path (Join-Path $steamApps 'common') $manifestMatch.Groups[1].Value))
                    }
                }
                catch {
                    # Fall back to the standard install directory name.
                }
            }

            $candidates.Add((Join-Path (Join-Path $steamApps 'common') 'Tabletop Simulator'))
        }
    }

    $seen = @{}
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        $key = $candidate.TrimEnd('\', '/').ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            continue
        }
        $seen[$key] = $true

        if (Test-TTSInstallRoot -Path $candidate) {
            return (Get-Item -LiteralPath $candidate).FullName
        }
    }

    return $null
}

function Get-ConfigModeFromRawValue {
    param($RawValue)

    if ($null -eq $RawValue) {
        return $null
    }

    $textCandidates = New-Object System.Collections.Generic.List[string]
    if ($RawValue -is [byte[]]) {
        foreach ($encoding in @([Text.Encoding]::UTF8, [Text.Encoding]::Unicode, [Text.Encoding]::ASCII)) {
            try {
                $textCandidates.Add($encoding.GetString($RawValue))
            }
            catch {
                # Try the other encodings.
            }
        }
    }
    else {
        $textCandidates.Add([string]$RawValue)
    }

    $initialCandidates = $textCandidates.ToArray()
    foreach ($candidate in $initialCandidates) {
        $compact = ($candidate -replace "`0", '').Trim()
        if ($compact -match '^[A-Za-z0-9+/]+={0,2}$' -and $compact.Length -ge 8 -and ($compact.Length % 4) -eq 0) {
            try {
                $decodedBytes = [Convert]::FromBase64String($compact)
                $textCandidates.Add([Text.Encoding]::UTF8.GetString($decodedBytes))
                $textCandidates.Add([Text.Encoding]::Unicode.GetString($decodedBytes))
            }
            catch {
                # It only looked like base64.
            }
        }
    }

    foreach ($candidate in $textCandidates) {
        $clean = ($candidate -replace "`0", '').Trim()
        $start = $clean.IndexOf('{')
        $end = $clean.LastIndexOf('}')
        if ($start -lt 0 -or $end -le $start) {
            continue
        }

        try {
            $jsonText = $clean.Substring($start, $end - $start + 1)
            $config = $jsonText | ConvertFrom-Json
            if ($null -ne $config.ConfigMods -and $null -ne $config.ConfigMods.Location) {
                $location = [int]$config.ConfigMods.Location
                if ($location -eq 0) {
                    return 'Documents'
                }
                if ($location -eq 1) {
                    return 'GameData'
                }
            }
        }
        catch {
            # Continue trying other encodings/candidates.
        }
    }

    return $null
}

function Resolve-TTSConfigModeCandidates {
    param([object[]]$ParsedSettings)

    $settings = @($ParsedSettings)
    if ($settings.Count -eq 0) {
        return $null
    }

    $uniqueModes = @($settings | Select-Object -ExpandProperty Mode -Unique)
    if ($uniqueModes.Count -eq 1) {
        $valueNames = @($settings | Select-Object -ExpandProperty ValueName)
        return [pscustomobject]@{
            Mode = $uniqueModes[0]
            Reason = ("TTS 配置 {0}" -f ($valueNames -join ', '))
            Ambiguous = $false
            Candidates = @($settings)
        }
    }

    return [pscustomobject]@{
        Mode = $null
        Reason = '多个 TTS 配置对 Mods 位置给出了冲突结果'
        Ambiguous = $true
        Candidates = @($settings)
    }
}

function Get-TTSModLocationSetting {
    if (-not $script:IsWindowsPlatform) {
        return $null
    }

    $registryPath = 'HKCU:\Software\Berserk Games\Tabletop Simulator'
    $parsedSettings = New-Object System.Collections.Generic.List[object]
    try {
        $key = Get-Item -LiteralPath $registryPath -ErrorAction Stop
        foreach ($valueName in $key.GetValueNames()) {
            if ($valueName -notlike 'ConfigGame_h*') {
                continue
            }

            $rawValue = $key.GetValue($valueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $mode = Get-ConfigModeFromRawValue -RawValue $rawValue
            if ($null -ne $mode) {
                $parsedSettings.Add([pscustomobject]@{
                    Mode = $mode
                    ValueName = $valueName
                })
            }
        }
    }
    catch {
        return $null
    }

    return (Resolve-TTSConfigModeCandidates -ParsedSettings ($parsedSettings.ToArray()))
}

function Resolve-TTSModsDestination {
    param(
        [string]$ExplicitDestination,
        [ValidateSet('Auto', 'Documents', 'GameData')]
        [string]$RequestedMode = 'Auto',
        [switch]$NoPrompt
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitDestination)) {
        $expanded = [Environment]::ExpandEnvironmentVariables($ExplicitDestination)
        if (Test-Path -LiteralPath $expanded -PathType Leaf) {
            Throw-InstallerError -Message ("目标路径是文件而不是目录：{0}" -f $expanded) -ExitCode 3
        }
        return [pscustomobject]@{
            Path = [IO.Path]::GetFullPath($expanded)
            Mode = 'Explicit'
            Reason = '提权前或命令行已明确指定'
            InstallRoot = $null
            DocumentsPath = $null
            GameDataPath = $null
        }
    }

    $documentsPath = Get-DocumentsModsPath
    $installRoot = Get-TTSInstallPath
    $gameDataPath = $null
    if (-not [string]::IsNullOrWhiteSpace($installRoot)) {
        $gameDataPath = Join-Path (Join-Path $installRoot 'Tabletop Simulator_Data') 'Mods'
    }

    if ($RequestedMode -eq 'Documents') {
        return [pscustomobject]@{
            Path = $documentsPath
            Mode = 'Documents'
            Reason = '命令行指定'
            InstallRoot = $installRoot
            DocumentsPath = $documentsPath
            GameDataPath = $gameDataPath
        }
    }

    if ($RequestedMode -eq 'GameData') {
        if ([string]::IsNullOrWhiteSpace($gameDataPath)) {
            Throw-InstallerError -Message '已指定 Game Data 模式，但未找到有效的 TTS 安装目录。' -ExitCode 3
        }
        return [pscustomobject]@{
            Path = $gameDataPath
            Mode = 'GameData'
            Reason = '命令行指定'
            InstallRoot = $installRoot
            DocumentsPath = $documentsPath
            GameDataPath = $gameDataPath
        }
    }

    $setting = Get-TTSModLocationSetting
    $forcePrompt = ($null -ne $setting -and $setting.Ambiguous)
    if ($null -ne $setting -and -not $forcePrompt) {
        if ($setting.Mode -eq 'Documents') {
            return [pscustomobject]@{
                Path = $documentsPath
                Mode = 'Documents'
                Reason = $setting.Reason
                InstallRoot = $installRoot
                DocumentsPath = $documentsPath
                GameDataPath = $gameDataPath
            }
        }

        if ([string]::IsNullOrWhiteSpace($gameDataPath)) {
            Throw-InstallerError -Message 'TTS 配置为 Game Data，但脚本未找到有效的 TTS 安装目录。' -ExitCode 3
        }
        return [pscustomobject]@{
            Path = $gameDataPath
            Mode = 'GameData'
            Reason = $setting.Reason
            InstallRoot = $installRoot
            DocumentsPath = $documentsPath
            GameDataPath = $gameDataPath
        }
    }

    $documentsExists = Test-Path -LiteralPath $documentsPath -PathType Container
    $gameDataExists = (
        -not [string]::IsNullOrWhiteSpace($gameDataPath) -and
        (Test-Path -LiteralPath $gameDataPath -PathType Container)
    )

    if (-not $forcePrompt -and $documentsExists -and -not $gameDataExists) {
        return [pscustomobject]@{
            Path = $documentsPath
            Mode = 'Documents'
            Reason = '配置无法读取，仅 Documents Mods 目录存在'
            InstallRoot = $installRoot
            DocumentsPath = $documentsPath
            GameDataPath = $gameDataPath
        }
    }

    if (-not $forcePrompt -and $gameDataExists -and -not $documentsExists) {
        return [pscustomobject]@{
            Path = $gameDataPath
            Mode = 'GameData'
            Reason = '配置无法读取，仅 Game Data Mods 目录存在'
            InstallRoot = $installRoot
            DocumentsPath = $documentsPath
            GameDataPath = $gameDataPath
        }
    }

    if ($NoPrompt) {
        if ($forcePrompt) {
            Throw-InstallerError -Message '检测到多个相互冲突的 TTS Mods 位置配置；非交互模式下不能询问用户。' -ExitCode 3
        }
        Throw-InstallerError -Message '无法自动判断 TTS 当前使用的 Mods 位置；非交互模式下不能询问用户。' -ExitCode 3
    }

    Write-InstallerSection -Icon '🧭' -Title '请选择 Mods 小窝' -Subtitle '检测到的位置不够明确，需要你来拍板啦 (｡･ω･｡)'
    if ($forcePrompt) {
        Write-Host '  ⚠️  多个 TTS 配置给出了不同结果：' -ForegroundColor Yellow
        foreach ($candidate in $setting.Candidates) {
            Write-Host ("      • {0}  →  {1}" -f $candidate.ValueName, $candidate.Mode) -ForegroundColor Yellow
        }
    }
    else {
        Write-Host '  ⚠️  无法从 TTS 配置唯一确定 Mods 位置。' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host ("  [1] 📄 Documents  {0}" -f $documentsPath) -ForegroundColor Cyan
    if (-not [string]::IsNullOrWhiteSpace($gameDataPath)) {
        Write-Host ("  [2] 🎮 Game Data  {0}" -f $gameDataPath) -ForegroundColor Green
    }
    else {
        Write-Host '  [2] 🎮 Game Data  未找到 TTS 安装目录，当前不可选' -ForegroundColor DarkGray
    }

    while ($true) {
        $choice = (Read-Host '  👉 请选择 1 或 2（默认 1）').Trim()
        if ([string]::IsNullOrWhiteSpace($choice) -or $choice -eq '1') {
            return [pscustomobject]@{
                Path = $documentsPath
                Mode = 'Documents'
                Reason = '用户选择'
                InstallRoot = $installRoot
                DocumentsPath = $documentsPath
                GameDataPath = $gameDataPath
            }
        }
        if ($choice -eq '2' -and -not [string]::IsNullOrWhiteSpace($gameDataPath)) {
            return [pscustomobject]@{
                Path = $gameDataPath
                Mode = 'GameData'
                Reason = '用户选择'
                InstallRoot = $installRoot
                DocumentsPath = $documentsPath
                GameDataPath = $gameDataPath
            }
        }
        Write-Host '  (・_・;)  输入无效，请输入 1 或 2。' -ForegroundColor Yellow
    }
}

function Wait-ForSafeGameState {
    param(
        [switch]$AllowRunning,
        [switch]$NoPrompt
    )

    if (@(Get-TTSRunningProcesses).Count -eq 0) {
        return $false
    }

    if ($AllowRunning) {
        Write-InstallerStatus -Level WARN -Message '检测到 TTS 正在运行；已按参数要求继续。'
        return $true
    }

    if ($NoPrompt) {
        Throw-InstallerError -Message 'TTS 正在运行。请先退出游戏，或显式使用 -ForceWhileRunning。' -ExitCode 1
    }

    Write-InstallerStatus -Level WARN -Message '检测到 TTS 正在运行。游戏可能同时写入 Mods 缓存 (｡•́︿•̀｡)'
    while (@(Get-TTSRunningProcesses).Count -gt 0) {
        $choice = (Read-Host '  🎮 退出游戏后按 Enter 重试；C 强制继续；Q 取消').Trim()
        if ($choice -ieq 'Q') {
            Throw-InstallerError -Message '用户取消安装。' -ExitCode 1
        }
        if ($choice -ieq 'C') {
            Write-InstallerStatus -Level WARN -Message '用户选择在 TTS 运行时继续。'
            return $true
        }
    }

    Write-InstallerStatus -Level OK -Message '已确认 TTS 退出，可以安心搬运啦 ( •̀ ω •́ )✧'
    return $false
}

function Test-DestinationWriteAccess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $probePath = $null
    try {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        $probePath = Join-Path $Path ('.tts-mod-installer-write-test-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
        $stream = [IO.File]::Open(
            $probePath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        $stream.Dispose()
        Remove-Item -LiteralPath $probePath -Force
        return $true
    }
    catch {
        if ($null -ne $probePath -and (Test-Path -LiteralPath $probePath)) {
            try {
                Remove-Item -LiteralPath $probePath -Force
            }
            catch {
                # Best effort cleanup.
            }
        }
        return $false
    }
}

function Invoke-ElevatedInstaller {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$SourcePaths,

        [Parameter(Mandatory = $true)]
        [string]$TargetPath,

        [switch]$ContinueWhileRunning,
        [switch]$NoPrompt
    )

    $handoffDirectory = Get-InstallerHandoffRoot
    New-Item -ItemType Directory -Path $handoffDirectory -Force | Out-Null
    $handoffId = [guid]::NewGuid().ToString('N')
    $handoffFile = Join-Path $handoffDirectory ($handoffId + '.request.json')
    $resultFile = Join-Path $handoffDirectory ($handoffId + '.result.json')

    $handoff = [ordered]@{
        PackagePaths = @($SourcePaths)
        DestinationPath = $TargetPath
        ForceWhileRunning = [bool]$ContinueWhileRunning
        NonInteractive = [bool]$NoPrompt
        ResultPath = $resultFile
    }
    $handoff | ConvertTo-Json | Set-Content -LiteralPath $handoffFile -Encoding UTF8

    $scriptPath = $script:InstallerScriptPath
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        $scriptPath = Join-Path $PSScriptRoot 'TTSModInstaller.ps1'
    }

    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -HandoffPath "{1}" -Elevated' -f $scriptPath, $handoffFile
    Write-InstallerStatus -Level WARN -Message '目标目录需要管理员权限，即将请求 Windows UAC 🛡️'

    try {
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -Wait -PassThru
        $childResult = $null
        if (Test-Path -LiteralPath $resultFile -PathType Leaf) {
            try {
                $childResult = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
            }
            catch {
                Write-InstallerStatus -Level WARN -Message '管理员进程已结束，但结果详情无法读取。'
            }
        }

        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            Details = $childResult
        }
    }
    catch {
        Throw-InstallerError -Message ("管理员权限请求失败或被取消：{0}" -f $_.Exception.Message) -ExitCode 5
    }
    finally {
        if (Test-Path -LiteralPath $handoffFile) {
            try {
                Remove-Item -LiteralPath $handoffFile -Force
            }
            catch {
                # Elevated child normally removes it.
            }
        }
        if (Test-Path -LiteralPath $resultFile) {
            Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-InstallerNativeArchitecture {
    param(
        [string]$ProcessorArchitecture = $env:PROCESSOR_ARCHITECTURE,
        [string]$ProcessorArchitectureW6432 = ${env:PROCESSOR_ARCHITEW6432}
    )

    $architecture = $ProcessorArchitecture
    if (-not [string]::IsNullOrWhiteSpace($ProcessorArchitectureW6432)) {
        $architecture = $ProcessorArchitectureW6432
    }
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        return 'x86'
    }

    switch ($architecture.ToUpperInvariant()) {
        'AMD64' { return 'x64' }
        'ARM64' { return 'arm64' }
        'X86' { return 'x86' }
        default { return 'x86' }
    }
}

function Find-Bundled7ZipExecutable {
    param(
        [string]$BundledRoot = (Join-Path (Join-Path $PSScriptRoot 'tools') '7zip'),
        [string]$Architecture = (Get-InstallerNativeArchitecture),
        [switch]$SkipHashValidation
    )

    $architectureCandidates = @($Architecture)
    if ($Architecture -ne 'x86') {
        $architectureCandidates += 'x86'
    }

    foreach ($candidateArchitecture in $architectureCandidates) {
        $candidateDirectory = Join-Path $BundledRoot $candidateArchitecture
        $candidateExe = Join-Path $candidateDirectory '7z.exe'
        $candidateDll = Join-Path $candidateDirectory '7z.dll'
        if (
            -not (Test-Path -LiteralPath $candidateExe -PathType Leaf) -or
            -not (Test-Path -LiteralPath $candidateDll -PathType Leaf)
        ) {
            continue
        }

        if (-not $SkipHashValidation) {
            foreach ($fileName in @('7z.exe', '7z.dll')) {
                $relativeKey = $candidateArchitecture + '\' + $fileName
                $expectedHash = $script:Bundled7ZipHashes[$relativeKey]
                $actualHash = (Get-FileHash -LiteralPath (Join-Path $candidateDirectory $fileName) -Algorithm SHA256).Hash.ToLowerInvariant()
                if ([string]::IsNullOrWhiteSpace($expectedHash) -or $actualHash -ne $expectedHash) {
                    Throw-InstallerError `
                        -Message ("内置 7-Zip {0} 校验失败，请重新下载完整安装器。" -f $relativeKey) `
                        -ExitCode 4
                }
            }
        }

        return $candidateExe
    }

    return $null
}

function Find-7ZipExecutable {
    $bundledExecutable = Find-Bundled7ZipExecutable
    if (-not [string]::IsNullOrWhiteSpace($bundledExecutable)) {
        return $bundledExecutable
    }

    foreach ($commandName in @('7z.exe', '7z')) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) {
            return $command.Source
        }
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $candidates.Add((Join-Path (Join-Path $env:ProgramFiles '7-Zip') '7z.exe'))
    }
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $candidates.Add((Join-Path (Join-Path ${env:ProgramFiles(x86)} '7-Zip') '7z.exe'))
    }

    foreach ($registryPath in @('HKLM:\SOFTWARE\7-Zip', 'HKLM:\SOFTWARE\WOW6432Node\7-Zip')) {
        try {
            $sevenZipRoot = (Get-ItemProperty -LiteralPath $registryPath -Name 'Path' -ErrorAction Stop).Path
            if (-not [string]::IsNullOrWhiteSpace($sevenZipRoot)) {
                $candidates.Add((Join-Path $sevenZipRoot '7z.exe'))
            }
        }
        catch {
            # Registry entry is optional.
        }
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    return $null
}

function Assert-ArchiveEntryPathSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EntryPath,

        [string]$ArchiveLabel = '压缩包'
    )

    $normalized = $EntryPath.Replace('\', '/')
    $segments = @($normalized.Split('/') | Where-Object { $_ -ne '' })
    if (
        $normalized.StartsWith('/') -or
        $normalized -match '^[A-Za-z]:' -or
        ($segments -contains '..')
    ) {
        Throw-InstallerError -Message ("{0}中包含不安全路径：{1}" -f $ArchiveLabel, $EntryPath) -ExitCode 4
    }
}

function Get-ZipPackageInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    [Int64]$uncompressedBytes = 0
    [Int64]$compressedBytes = 0
    [int]$fileCount = 0
    try {
        foreach ($entry in $archive.Entries) {
            Assert-ArchiveEntryPathSafe -EntryPath $entry.FullName -ArchiveLabel 'ZIP '
            if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) {
                continue
            }

            $fileCount++
            if ($entry.Length -gt ([Int64]::MaxValue - $uncompressedBytes)) {
                Throw-InstallerError -Message 'ZIP 声明的解压大小超出支持范围。' -ExitCode 4
            }
            $uncompressedBytes += [Int64]$entry.Length
            $compressedBytes += [Int64]$entry.CompressedLength
        }
    }
    finally {
        $archive.Dispose()
    }

    return [pscustomobject]@{
        Format = 'ZIP'
        Tool = 'Expand-Archive'
        FileCount = $fileCount
        UncompressedBytes = $uncompressedBytes
        CompressedBytes = $compressedBytes
        HadWarnings = $false
    }
}

function ConvertFrom-SevenZipListOutput {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$ListOutput,

        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,

        [Parameter(Mandatory = $true)]
        [int]$ExitCode,

        [string]$SevenZipPath
    )

    if ($ExitCode -gt 1) {
        Throw-InstallerError -Message ("7-Zip 无法读取压缩包，退出码：{0}" -f $ExitCode) -ExitCode 4
    }

    [string]$currentPath = $null
    [Int64]$currentSize = 0
    [Int64]$currentPackedSize = 0
    [bool]$currentIsFolder = $false
    [Int64]$uncompressedBytes = 0
    [Int64]$compressedBytes = 0
    [int]$fileCount = 0

    foreach ($lineObject in @($ListOutput) + @('')) {
        $line = [string]$lineObject
        if ($line -match '^Path = (.*)$') {
            if (-not [string]::IsNullOrWhiteSpace($currentPath) -and -not $currentIsFolder) {
                Assert-ArchiveEntryPathSafe -EntryPath $currentPath -ArchiveLabel '压缩包'
                $fileCount++
                $uncompressedBytes += $currentSize
                $compressedBytes += $currentPackedSize
            }
            $currentPath = $matches[1]
            $currentSize = 0
            $currentPackedSize = 0
            $currentIsFolder = $false
            continue
        }
        if ($line -match '^Size = ([0-9]+)$') {
            $currentSize = [Int64]$matches[1]
            continue
        }
        if ($line -match '^Packed Size = ([0-9]+)$') {
            $currentPackedSize = [Int64]$matches[1]
            continue
        }
        if ($line -eq 'Folder = +') {
            $currentIsFolder = $true
            continue
        }
        if ($line -match '^Attributes = D(?:\s|$)') {
            $currentIsFolder = $true
            continue
        }
        if ([string]::IsNullOrWhiteSpace($line) -and -not [string]::IsNullOrWhiteSpace($currentPath)) {
            if (-not $currentIsFolder) {
                Assert-ArchiveEntryPathSafe -EntryPath $currentPath -ArchiveLabel '压缩包'
                $fileCount++
                $uncompressedBytes += $currentSize
                $compressedBytes += $currentPackedSize
            }
            $currentPath = $null
            $currentSize = 0
            $currentPackedSize = 0
            $currentIsFolder = $false
        }
    }

    if ($compressedBytes -le 0) {
        $compressedBytes = [Int64](Get-Item -LiteralPath $ArchivePath -Force).Length
    }

    return [pscustomobject]@{
        Format = ([IO.Path]::GetExtension($ArchivePath).TrimStart('.').ToUpperInvariant())
        Tool = $SevenZipPath
        FileCount = $fileCount
        UncompressedBytes = $uncompressedBytes
        CompressedBytes = $compressedBytes
        HadWarnings = ($ExitCode -eq 1)
    }
}

function Get-SevenZipPackageInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,

        [Parameter(Mandatory = $true)]
        [string]$SevenZipPath
    )

    $listOutput = @(& $SevenZipPath 'l' '-slt' '-ba' '--' $ArchivePath 2>&1)
    $listExitCode = $LASTEXITCODE
    return ConvertFrom-SevenZipListOutput `
        -ListOutput $listOutput `
        -ArchivePath $ArchivePath `
        -ExitCode $listExitCode `
        -SevenZipPath $SevenZipPath
}

function Assert-ArchivePackageReasonable {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$PackageInfo,

        [Parameter(Mandatory = $true)]
        [string]$TemporaryBase
    )

    if ($PackageInfo.FileCount -gt 250000) {
        Throw-InstallerError -Message ("压缩包包含 {0} 个文件，超过 250000 个文件的安全上限。" -f $PackageInfo.FileCount) -ExitCode 4
    }
    if ($PackageInfo.UncompressedBytes -gt 250GB) {
        Throw-InstallerError -Message ("压缩包声明的解压大小为 {0}，超过 250 GB 的安全上限。" -f (ConvertTo-DisplaySize $PackageInfo.UncompressedBytes)) -ExitCode 4
    }

    if ($PackageInfo.CompressedBytes -gt 0 -and $PackageInfo.UncompressedBytes -gt 1GB) {
        $ratio = [double]$PackageInfo.UncompressedBytes / [double]$PackageInfo.CompressedBytes
        if ($ratio -gt 1000) {
            Throw-InstallerError -Message ("压缩包压缩比异常（约 {0:N0}:1），已停止以避免异常解压。" -f $ratio) -ExitCode 4
        }
    }

    try {
        $tempRoot = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($TemporaryBase))
        if (-not [string]::IsNullOrWhiteSpace($tempRoot)) {
            $tempDrive = New-Object System.IO.DriveInfo -ArgumentList $tempRoot
            $required = [Int64]$PackageInfo.UncompressedBytes + 256MB
            if ($tempDrive.AvailableFreeSpace -lt $required) {
                Throw-InstallerError -Message ("临时磁盘空间不足；解压预计需要 {0}，并预留 256 MB。" -f (ConvertTo-DisplaySize $PackageInfo.UncompressedBytes)) -ExitCode 4
            }
        }
    }
    catch {
        if ($null -ne $_.Exception.Data['ExitCode']) {
            throw
        }
        # UNC and unusual temporary paths may not expose free space.
    }
}

function Assert-ZipEntriesSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath
    )

    Get-ZipPackageInfo -ArchivePath $ArchivePath | Out-Null
}

function Expand-ModPackage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath
    )

    $item = Get-Item -LiteralPath $InputPath -Force
    if ($item.PSIsContainer) {
        return [pscustomobject]@{
            Root = $item.FullName
            TemporaryRoot = $null
            Tool = 'Folder'
            HadWarnings = $false
        }
    }

    $extension = $item.Extension.ToLowerInvariant()
    if ($extension -notin @('.zip', '.ttsmod', '.7z', '.rar')) {
        Throw-InstallerError -Message ("不支持的文件类型：{0}。支持文件夹、ZIP、TTSMOD、7Z 和 RAR。" -f $extension) -ExitCode 2
    }

    $tempBase = Get-InstallerExtractionRoot
    New-Item -ItemType Directory -Path $tempBase -Force | Out-Null
    $tempRoot = $null
    $hadArchiveWarnings = $false

    try {
        if ($extension -in @('.zip', '.ttsmod')) {
            $packageInfo = Get-ZipPackageInfo -ArchivePath $item.FullName
            if ($extension -eq '.zip') {
                $tool = 'Expand-Archive'
            }
            else {
                $tool = 'System.IO.Compression.ZipFile'
            }
        }
        else {
            $sevenZip = Find-7ZipExecutable
            if ([string]::IsNullOrWhiteSpace($sevenZip)) {
                Throw-InstallerError -Message '未找到内置或系统 7-Zip 组件。请重新下载完整发布包，或将图包转换为 ZIP。' -ExitCode 4
            }
            $packageInfo = Get-SevenZipPackageInfo -ArchivePath $item.FullName -SevenZipPath $sevenZip
            $tool = $sevenZip
        }

        if ($packageInfo.PSObject.Properties['HadWarnings']) {
            $hadArchiveWarnings = [bool]$packageInfo.HadWarnings
        }
        if ($hadArchiveWarnings) {
            Write-InstallerStatus -Level WARN -Message '7-Zip 读取压缩包时返回警告；将继续检查并安装可正常读取的内容。'
        }

        if ($packageInfo.FileCount -eq 0) {
            Throw-InstallerError -Message '压缩包中没有文件。' -ExitCode 4
        }
        Assert-ArchivePackageReasonable -PackageInfo $packageInfo -TemporaryBase $tempBase
        Write-InstallerStatus -Message ("📚 压缩包预检：{0} 个文件，解压后约 {1}。" -f `
            $packageInfo.FileCount,
            (ConvertTo-DisplaySize $packageInfo.UncompressedBytes))

        $tempRoot = Join-Path $tempBase ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempRoot | Out-Null

        if ($extension -eq '.zip') {
            Write-InstallerStatus -Message '📦 正在解压 .ZIP 图包……'
            Expand-Archive -LiteralPath $item.FullName -DestinationPath $tempRoot -Force
        }
        elseif ($extension -eq '.ttsmod') {
            Write-InstallerStatus -Message '📦 正在解压 .TTSMOD 图包……'
            [IO.Compression.ZipFile]::ExtractToDirectory($item.FullName, $tempRoot)
        }
        else {
            Write-InstallerStatus -Message ("📦 正在使用 7-Zip 解压 {0}……" -f $extension.ToUpperInvariant())
            & $sevenZip 'x' '-y' '-bso0' '-bsp0' ("-o{0}" -f $tempRoot) '--' $item.FullName 2>&1 |
                ForEach-Object { Write-Host ("      {0}" -f $_) -ForegroundColor DarkGray }
            $sevenZipExitCode = $LASTEXITCODE
            if ($sevenZipExitCode -gt 1) {
                Throw-InstallerError -Message ("7-Zip 解压失败，退出码：{0}" -f $sevenZipExitCode) -ExitCode 4
            }
            if ($sevenZipExitCode -eq 1) {
                $hadArchiveWarnings = $true
                Write-InstallerStatus -Level WARN -Message '7-Zip 解压完成，但返回了警告；将继续检查解压后的 Mods 内容。'
            }
        }

        return [pscustomobject]@{
            Root = $tempRoot
            TemporaryRoot = $tempRoot
            Tool = $tool
            HadWarnings = $hadArchiveWarnings
        }
    }
    catch {
        if (-not [string]::IsNullOrWhiteSpace($tempRoot) -and (Test-Path -LiteralPath $tempRoot)) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne $_.Exception.Data['ExitCode']) {
            throw
        }
        Throw-InstallerError -Message ("压缩包处理失败：{0}" -f $_.Exception.Message) -ExitCode 4
    }
}

function Test-IsReparsePoint {
    param(
        [Parameter(Mandatory = $true)]
        [IO.FileSystemInfo]$Item
    )

    return (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Resolve-SourceModsRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath
    )

    $rootItem = Get-Item -LiteralPath $RootPath -Force
    if (-not $rootItem.PSIsContainer) {
        Throw-InstallerError -Message '图包分析根路径不是文件夹。' -ExitCode 2
    }
    if (Test-IsReparsePoint -Item $rootItem) {
        Throw-InstallerError -Message '图包根目录是符号链接或目录联接，出于安全原因拒绝处理。' -ExitCode 2
    }

    if ($rootItem.Name -ieq 'Mods') {
        return $rootItem.FullName
    }

    $directDirectories = @(Get-ChildItem -LiteralPath $rootItem.FullName -Directory -Force)
    $directMods = @($directDirectories | Where-Object { $_.Name -ieq 'Mods' })
    if ($directMods.Count -eq 1) {
        return $directMods[0].FullName
    }

    $nestedMods = @()
    foreach ($directory in $directDirectories) {
        foreach ($child in @(Get-ChildItem -LiteralPath $directory.FullName -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($child.Name -ieq 'Mods') {
                $nestedMods += $child
            }
        }
    }

    if ($nestedMods.Count -eq 1) {
        return $nestedMods[0].FullName
    }
    if ($nestedMods.Count -gt 1) {
        $candidateText = (@($nestedMods | ForEach-Object { $_.FullName }) -join [Environment]::NewLine)
        Throw-InstallerError -Message ("图包中发现多个 Mods 候选，无法安全选择：{0}{1}" -f [Environment]::NewLine, $candidateText) -ExitCode 2
    }

    $knownDirectories = @(
        'Images',
        'Models',
        'Workshop',
        'Assetbundles',
        'Audio',
        'Textures',
        'PDF',
        'Images Raw',
        'Models Raw'
    )
    $markerCount = @($directDirectories | Where-Object { $knownDirectories -contains $_.Name }).Count
    if ($markerCount -gt 0) {
        return $rootItem.FullName
    }

    Throw-InstallerError -Message '没有找到可识别的 Mods 结构。请选择 Mods 文件夹，或包含 Mods 文件夹的图包。' -ExitCode 2
}

function Get-CopySummary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceRoot,

        [Parameter(Mandatory = $true)]
        [string]$TargetRoot
    )

    $sourcePrefixLength = $SourceRoot.TrimEnd('\', '/').Length
    [Int64]$totalBytes = 0
    [Int64]$requiredGrowthBytes = 0
    [int]$fileCount = 0
    [int]$conflictCount = 0

    Write-InstallerStatus -Message '正在扫描图包文件并计算覆盖范围…… 🔍 ( •̀ ω •́ )✧'
    Get-ChildItem -LiteralPath $SourceRoot -Recurse -Force | ForEach-Object {
        $entry = $_
        if (Test-IsReparsePoint -Item $entry) {
            Throw-InstallerError -Message ("图包包含符号链接或目录联接，出于安全原因拒绝处理：{0}" -f $entry.FullName) -ExitCode 2
        }
        if ($entry.PSIsContainer) {
            return
        }

        $fileCount++
        if (($fileCount % 1000) -eq 0) {
            Write-InstallerStatus -Message ("已扫描 {0} 个文件……" -f $fileCount)
        }
        $totalBytes += [Int64]$entry.Length
        $relativePath = $entry.FullName.Substring($sourcePrefixLength).TrimStart('\', '/')
        $targetFile = Join-Path $TargetRoot $relativePath
        if (Test-Path -LiteralPath $targetFile -PathType Leaf) {
            $conflictCount++
            try {
                $existingLength = [Int64](Get-Item -LiteralPath $targetFile -Force).Length
                if ($entry.Length -gt $existingLength) {
                    $requiredGrowthBytes += ([Int64]$entry.Length - $existingLength)
                }
            }
            catch {
                $requiredGrowthBytes += [Int64]$entry.Length
            }
        }
        else {
            $requiredGrowthBytes += [Int64]$entry.Length
        }
    }

    if ($fileCount -eq 0) {
        Throw-InstallerError -Message '识别出的 Mods 目录中没有任何文件。' -ExitCode 2
    }

    [Nullable[Int64]]$freeBytes = $null
    try {
        $driveRoot = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($TargetRoot))
        if (-not [string]::IsNullOrWhiteSpace($driveRoot)) {
            $driveInfo = New-Object System.IO.DriveInfo -ArgumentList $driveRoot
            $freeBytes = [Int64]$driveInfo.AvailableFreeSpace
        }
    }
    catch {
        # UNC and unusual filesystems may not expose free space.
    }

    return [pscustomobject]@{
        FileCount = $fileCount
        TotalBytes = $totalBytes
        ConflictCount = $conflictCount
        RequiredGrowthBytes = $requiredGrowthBytes
        FreeBytes = $freeBytes
    }
}

function Assert-SafeCopyRelationship {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceRoot,

        [Parameter(Mandatory = $true)]
        [string]$TargetRoot
    )

    $source = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\', '/')
    $target = [IO.Path]::GetFullPath($TargetRoot).TrimEnd('\', '/')
    if ($source.Equals($target, [StringComparison]::OrdinalIgnoreCase)) {
        Throw-InstallerError -Message '图包来源和安装目标是同一个目录，已停止以避免无意义覆盖。' -ExitCode 2
    }

    $separator = [IO.Path]::DirectorySeparatorChar
    if (
        $source.StartsWith($target + $separator, [StringComparison]::OrdinalIgnoreCase) -or
        $target.StartsWith($source + $separator, [StringComparison]::OrdinalIgnoreCase)
    ) {
        Throw-InstallerError -Message '图包来源和安装目标互相嵌套，已停止以避免递归复制。' -ExitCode 2
    }
}

function Test-RobocopyExitCode {
    param([int]$ExitCode)
    return ($ExitCode -ge 0 -and $ExitCode -lt 8)
}

function Invoke-ModCopy {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceRoot,

        [Parameter(Mandatory = $true)]
        [string]$TargetRoot
    )

    $robocopy = Get-Command 'robocopy.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $robocopy) {
        Throw-InstallerError -Message '系统中未找到 robocopy.exe。' -ExitCode 8
    }

    $arguments = @(
        $SourceRoot,
        $TargetRoot,
        '/E',
        '/COPY:DAT',
        '/DCOPY:DAT',
        '/R:2',
        '/W:1',
        '/XJ',
        '/IS',
        '/IT',
        '/NP',
        '/TEE',
        ("/UNILOG:{0}" -f $script:RoboCopyLogPath)
    )

    Write-InstallerStatus -Message '开始施展合并覆盖魔法 ✨ 目标中其他已有文件会保留。'
    & $robocopy.Source @arguments 2>&1 |
        ForEach-Object { Write-Host ("      {0}" -f $_) -ForegroundColor DarkGray }
    $exitCode = $LASTEXITCODE

    ("Robocopy log: {0}" -f $script:RoboCopyLogPath) | Add-Content -LiteralPath $script:LogPath -Encoding UTF8
    ("Robocopy exit code: {0}" -f $exitCode) | Add-Content -LiteralPath $script:LogPath -Encoding UTF8

    if (-not (Test-RobocopyExitCode -ExitCode $exitCode)) {
        Throw-InstallerError -Message ("文件复制失败，robocopy 退出码为 {0}。详细信息：{1}" -f $exitCode, $script:RoboCopyLogPath) -ExitCode 8
    }

    return $exitCode
}

function Remove-OwnedTemporaryRoot {
    param([string]$TemporaryRoot)

    if ([string]::IsNullOrWhiteSpace($TemporaryRoot) -or -not (Test-Path -LiteralPath $TemporaryRoot)) {
        return
    }

    $expectedBase = (Get-InstallerExtractionRoot).TrimEnd('\', '/')
    $fullTemporaryRoot = [IO.Path]::GetFullPath($TemporaryRoot).TrimEnd('\', '/')
    $expectedPrefix = $expectedBase + [IO.Path]::DirectorySeparatorChar
    if (-not $fullTemporaryRoot.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        Write-InstallerStatus -Level WARN -Message ("拒绝清理不属于安装器的临时路径：{0}" -f $fullTemporaryRoot)
        return
    }

    try {
        Remove-Item -LiteralPath $fullTemporaryRoot -Recurse -Force
        Write-InstallerStatus -Message '临时解压目录收拾干净啦 🧹 (｡･ω･｡)ﾉ'
    }
    catch {
        Write-InstallerStatus -Level WARN -Message ("临时目录清理失败，可稍后手动删除：{0}" -f $fullTemporaryRoot)
    }
}

function Get-InstallCompletionStatus {
    param([bool]$HadArchiveWarnings)

    if ($HadArchiveWarnings) {
        return [pscustomobject]@{
            Level = 'WARN'
            Message = '安装完成，不过压缩包处理时有一点小警告 (・_・;) 如遇素材缺失，请重新获取或解压图包。'
            ResultMessage = '安装完成，但压缩包处理有警告'
        }
    }

    return [pscustomobject]@{
        Level = 'OK'
        Message = '图包搬运完成！(ﾉ◕ヮ◕)ﾉ*:･ﾟ✧'
        ResultMessage = '安装成功'
    }
}

function Read-InstallerHandoff {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $handoffRoot = Get-InstallerHandoffRoot
    $leafName = [IO.Path]::GetFileName($Path)
    if (
        -not (Test-PathIsUnderRoot -Path $Path -Root $handoffRoot) -or
        $leafName -notmatch '^[a-fA-F0-9]{32}\.request\.json$'
    ) {
        Throw-InstallerError -Message '提权交接文件路径不属于安装器。' -ExitCode 5
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Throw-InstallerError -Message '提权交接文件不存在。' -ExitCode 5
    }

    try {
        $data = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        return $data
    }
    finally {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

function Write-InstallerHandoffResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )

    $handoffRoot = Get-InstallerHandoffRoot
    $leafName = [IO.Path]::GetFileName($Path)
    if (
        -not (Test-PathIsUnderRoot -Path $Path -Root $handoffRoot) -or
        $leafName -notmatch '^[a-fA-F0-9]{32}\.result\.json$'
    ) {
        return
    }

    $result = [ordered]@{
        ExitCode = $ExitCode
        Results = @($script:LastBatchResults)
        Finished = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')
    }
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-OnePackageInstall {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath,

        [string]$ExplicitDestination,

        [ValidateSet('Auto', 'Documents', 'GameData')]
        [string]$RequestedMode = 'Auto',

        [psobject]$ResolvedDestination,
        [switch]$SafetyChecksCompleted,
        [switch]$AlreadyElevated,
        [switch]$AllowRunning,
        [switch]$NoPrompt
    )

    $temporaryRoot = $null
    $destination = $null
    $resolvedInput = $InputPath
    $copyStarted = $false
    $script:LastInstallResult = $null
    Initialize-InstallerLog | Out-Null

    try {
        Write-InstallerSection -Icon '📦' -Title '准备搬运图包' -Subtitle '正在检查这份图包该住在哪里……'
        $resolvedInput = Resolve-InstallerInputPath -InputPath $InputPath
        Write-InstallerStatus -Message ("收到图包：{0}" -f $resolvedInput)

        if ($null -ne $ResolvedDestination) {
            $destination = $ResolvedDestination
        }
        else {
            $destination = Resolve-TTSModsDestination `
                -ExplicitDestination $ExplicitDestination `
                -RequestedMode $RequestedMode `
                -NoPrompt:$NoPrompt
        }

        if (-not [string]::IsNullOrWhiteSpace($destination.InstallRoot)) {
            Write-InstallerStatus -Message ("🎮 TTS 安装目录：{0}" -f $destination.InstallRoot)
        }
        Write-InstallerStatus -Message ("🧭 Mods 模式：{0}（{1}）" -f $destination.Mode, $destination.Reason)
        Write-InstallerStatus -Message ("🏡 安装目标：{0}" -f $destination.Path)

        if (-not $SafetyChecksCompleted) {
            $continuedWhileRunning = Wait-ForSafeGameState -AllowRunning:$AllowRunning -NoPrompt:$NoPrompt
            if ($continuedWhileRunning) {
                $AllowRunning = $true
            }
        }

        if (-not $SafetyChecksCompleted -and -not (Test-DestinationWriteAccess -Path $destination.Path)) {
            if ($AlreadyElevated) {
                Throw-InstallerError -Message ("即使以管理员身份运行也无法写入目标目录：{0}" -f $destination.Path) -ExitCode 5
            }

            $elevatedOutcome = Invoke-ElevatedInstaller `
                -SourcePaths @($resolvedInput) `
                -TargetPath $destination.Path `
                -ContinueWhileRunning:$AllowRunning `
                -NoPrompt:$NoPrompt
            if ($elevatedOutcome.ExitCode -eq 0) {
                Write-InstallerStatus -Level OK -Message '管理员进程已完成安装。'
            }
            else {
                Write-InstallerStatus -Level ERROR -Message ("管理员进程安装失败，退出码：{0}" -f $elevatedOutcome.ExitCode)
            }
            if ($null -ne $elevatedOutcome.Details) {
                foreach ($childItem in @($elevatedOutcome.Details.Results)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$childItem.TargetPath)) {
                        Write-InstallerStatus -Message ("管理员进程目标：{0}" -f $childItem.TargetPath)
                    }
                    if (-not [string]::IsNullOrWhiteSpace([string]$childItem.LogPath)) {
                        Write-InstallerStatus -Message ("管理员进程日志：{0}" -f $childItem.LogPath)
                    }
                }
            }
            return [int]$elevatedOutcome.ExitCode
        }

        $expanded = Expand-ModPackage -InputPath $resolvedInput
        $temporaryRoot = $expanded.TemporaryRoot
        Write-InstallerStatus -Message ("拆包方式：{0}" -f $expanded.Tool)

        $sourceRoot = Resolve-SourceModsRoot -RootPath $expanded.Root
        Write-InstallerStatus -Message ("🧩 识别出的 Mods 根：{0}" -f $sourceRoot)

        Assert-SafeCopyRelationship -SourceRoot $sourceRoot -TargetRoot $destination.Path
        $summary = Get-CopySummary -SourceRoot $sourceRoot -TargetRoot $destination.Path
        Write-InstallerStatus -Message ("📊 文件：{0}，总大小：{1}，同名目标文件：{2}" -f `
            $summary.FileCount,
            (ConvertTo-DisplaySize -Bytes $summary.TotalBytes),
            $summary.ConflictCount)

        if ($null -ne $summary.FreeBytes) {
            Write-InstallerStatus -Message ("目标磁盘可用空间：{0}；预计净增长：{1}" -f `
                (ConvertTo-DisplaySize -Bytes $summary.FreeBytes),
                (ConvertTo-DisplaySize -Bytes $summary.RequiredGrowthBytes))

            $reserve = 64MB
            if ($summary.FreeBytes -lt ($summary.RequiredGrowthBytes + $reserve)) {
                Throw-InstallerError -Message '目标磁盘可用空间不足（已预留 64 MB 安全余量）。' -ExitCode 8
            }
        }
        else {
            Write-InstallerStatus -Level WARN -Message '无法读取目标磁盘可用空间，将继续复制。'
        }

        $copyStarted = $true
        $robocopyExitCode = Invoke-ModCopy -SourceRoot $sourceRoot -TargetRoot $destination.Path
        $completionStatus = Get-InstallCompletionStatus -HadArchiveWarnings ([bool]$expanded.HadWarnings)
        Write-InstallerStatus `
            -Level $completionStatus.Level `
            -Message ("{0}（robocopy 退出码 {1}）。" -f $completionStatus.Message, $robocopyExitCode)
        Write-InstallerStatus -Level OK -Message ("已经放进：{0}" -f $destination.Path)
        Write-InstallerStatus -Message ("小本本日志：{0}" -f $script:LogPath)
        $script:LastInstallResult = [pscustomobject]@{
            PackagePath = $resolvedInput
            ExitCode = 0
            TargetPath = $destination.Path
            LogPath = $script:LogPath
            RoboCopyLogPath = $script:RoboCopyLogPath
            HadWarnings = [bool]$expanded.HadWarnings
            Message = $completionStatus.ResultMessage
        }
        return 0
    }
    catch {
        $exitCode = 99
        if ($null -ne $_.Exception.Data['ExitCode']) {
            $exitCode = [int]$_.Exception.Data['ExitCode']
        }
        Write-InstallerStatus -Level ERROR -Message $_.Exception.Message
        if ($copyStarted) {
            Write-InstallerStatus -Level WARN -Message '复制已经开始，失败前可能已有部分文件写入目标；修好问题后重新安装即可。'
        }
        Write-InstallerStatus -Level ERROR -Message ("安装没有完成 (╥﹏╥) 日志：{0}" -f $script:LogPath)
        $targetPath = $null
        if ($null -ne $destination) {
            $targetPath = $destination.Path
        }
        $script:LastInstallResult = [pscustomobject]@{
            PackagePath = $resolvedInput
            ExitCode = $exitCode
            TargetPath = $targetPath
            LogPath = $script:LogPath
            RoboCopyLogPath = $script:RoboCopyLogPath
            HadWarnings = $false
            Message = $_.Exception.Message
        }
        return $exitCode
    }
    finally {
        Remove-OwnedTemporaryRoot -TemporaryRoot $temporaryRoot
    }
}

function ConvertFrom-InstallerInputLine {
    param([string]$InputLine)

    if ([string]::IsNullOrWhiteSpace($InputLine)) {
        return @()
    }

    $trimmed = $InputLine.Trim()
    $singleCandidate = $trimmed
    if ($singleCandidate.Length -ge 2 -and $singleCandidate.StartsWith('"') -and $singleCandidate.EndsWith('"')) {
        $singleCandidate = $singleCandidate.Substring(1, $singleCandidate.Length - 2)
    }
    if (Test-Path -LiteralPath $singleCandidate) {
        return @($singleCandidate)
    }

    $results = New-Object System.Collections.Generic.List[string]
    foreach ($match in [regex]::Matches($trimmed, '("[^"]*"|''[^'']*''|\S+)')) {
        $value = $match.Value
        if ($value.Length -ge 2) {
            if (
                ($value.StartsWith('"') -and $value.EndsWith('"')) -or
                ($value.StartsWith("'") -and $value.EndsWith("'"))
            ) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $results.Add($value)
        }
    }
    return $results.ToArray()
}

function Select-ModPackageFiles {
    if (-not $script:IsWindowsPlatform) {
        return @()
    }

    $dialog = $null
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = '选择一个或多个 TTS 图包'
        $dialog.Filter = '支持的图包 (*.zip;*.ttsmod;*.7z;*.rar)|*.zip;*.ttsmod;*.7z;*.rar|ZIP/TTSMOD 图包 (*.zip;*.ttsmod)|*.zip;*.ttsmod|所有文件 (*.*)|*.*'
        $dialog.Multiselect = $true
        $dialog.CheckFileExists = $true
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return @($dialog.FileNames)
        }
    }
    catch {
        Write-Host ("  ⚠️ 无法打开文件选择窗口：{0} (・_・;)" -f $_.Exception.Message) -ForegroundColor Yellow
    }
    finally {
        if ($null -ne $dialog) {
            $dialog.Dispose()
        }
    }
    return @()
}

function Invoke-PackageBatch {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$InputPaths,

        [string]$ExplicitDestination,

        [ValidateSet('Auto', 'Documents', 'GameData')]
        [string]$RequestedMode = 'Auto',

        [switch]$AlreadyElevated,
        [switch]$AllowRunning,
        [switch]$NoPrompt
    )

    $paths = @($InputPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($paths.Count -eq 0) {
        return 2
    }

    $script:LastBatchResults = @()
    try {
        $destination = Resolve-TTSModsDestination `
            -ExplicitDestination $ExplicitDestination `
            -RequestedMode $RequestedMode `
            -NoPrompt:$NoPrompt

        $continuedWhileRunning = Wait-ForSafeGameState -AllowRunning:$AllowRunning -NoPrompt:$NoPrompt
        if ($continuedWhileRunning) {
            $AllowRunning = $true
        }

        if (-not (Test-DestinationWriteAccess -Path $destination.Path)) {
            if ($AlreadyElevated) {
                Throw-InstallerError -Message ("即使以管理员身份运行也无法写入目标目录：{0}" -f $destination.Path) -ExitCode 5
            }

            Initialize-InstallerLog | Out-Null
            $elevatedOutcome = Invoke-ElevatedInstaller `
                -SourcePaths $paths `
                -TargetPath $destination.Path `
                -ContinueWhileRunning:$AllowRunning `
                -NoPrompt:$NoPrompt

            if ($null -ne $elevatedOutcome.Details) {
                $script:LastBatchResults = @($elevatedOutcome.Details.Results)
                foreach ($childItem in $script:LastBatchResults) {
                    $level = 'INFO'
                    if ([int]$childItem.ExitCode -eq 0) {
                        $level = 'OK'
                        if (
                            $childItem.PSObject.Properties['HadWarnings'] -and
                            [bool]$childItem.HadWarnings
                        ) {
                            $level = 'WARN'
                        }
                    }
                    else {
                        $level = 'ERROR'
                    }
                    $childMessage = "管理员进程：{0}（退出码 {1}）" -f `
                        $childItem.PackagePath,
                        $childItem.ExitCode
                    if (-not [string]::IsNullOrWhiteSpace([string]$childItem.Message)) {
                        $childMessage += "：{0}" -f $childItem.Message
                    }
                    Write-InstallerStatus -Level $level -Message $childMessage
                    if (-not [string]::IsNullOrWhiteSpace([string]$childItem.LogPath)) {
                        Write-InstallerStatus -Message ("日志：{0}" -f $childItem.LogPath)
                    }
                }
            }
            elseif ($elevatedOutcome.ExitCode -eq 0) {
                Write-InstallerStatus -Level OK -Message '管理员进程已完成安装。'
            }
            else {
                Write-InstallerStatus -Level ERROR -Message ("管理员进程安装失败，退出码：{0}" -f $elevatedOutcome.ExitCode)
            }
            return [int]$elevatedOutcome.ExitCode
        }
    }
    catch {
        $exitCode = 99
        if ($null -ne $_.Exception.Data['ExitCode']) {
            $exitCode = [int]$_.Exception.Data['ExitCode']
        }
        Write-InstallerStatus -Level ERROR -Message ("{0} (╥﹏╥)" -f $_.Exception.Message)
        return $exitCode
    }

    $firstFailure = 0
    $index = 0
    foreach ($path in $paths) {
        $index++
        if ($paths.Count -gt 1) {
            Write-InstallerSection `
                -Icon '🎁' `
                -Title ("图包 {0}/{1}" -f $index, $paths.Count) `
                -Subtitle '一个一个来，很快就搬完啦～'
        }

        $result = Invoke-OnePackageInstall `
            -InputPath $path `
            -ResolvedDestination $destination `
            -RequestedMode $RequestedMode `
            -SafetyChecksCompleted `
            -AlreadyElevated:$AlreadyElevated `
            -AllowRunning:$AllowRunning `
            -NoPrompt:$NoPrompt

        if ($null -ne $script:LastInstallResult) {
            $script:LastBatchResults += $script:LastInstallResult
        }
        if ($result -ne 0 -and $firstFailure -eq 0) {
            $firstFailure = $result
        }
    }

    if ($paths.Count -gt 1) {
        $successCount = @($script:LastBatchResults | Where-Object { $_.ExitCode -eq 0 }).Count
        if ($firstFailure -eq 0) {
            Write-InstallerSection `
                -Icon '🎉' `
                -Title ("整批搬运完成：{0}/{1} 个图包安装成功！" -f $successCount, $paths.Count) `
                -Subtitle '全员安全抵达 Mods 小窝啦～ ヽ(✿ﾟ▽ﾟ)ノ'
        }
        else {
            Write-InstallerSection `
                -Icon '🌧️' `
                -Title ("批次结束：{0}/{1} 个图包安装成功" -f $successCount, $paths.Count) `
                -Subtitle '有图包没搬完，看看红色提示和日志吧 (｡•́︿•̀｡)'
        }
    }
    return $firstFailure
}

function Invoke-InstallerEntryPoint {
    if (-not $script:IsWindowsPlatform) {
        Write-Host '❌ 此安装器只能在 Windows 上实际运行 (╥﹏╥)' -ForegroundColor Red
        return 10
    }

    Write-InstallerBanner
    if (-not (Test-DestinationWriteAccess -Path (Get-InstallerDataRoot))) {
        Write-InstallerStatus -Level ERROR -Message (
            '安装器所在文件夹不可写。请把整个解压文件夹移动到有写入权限的位置后重试。'
        )
        return 5
    }

    $effectivePackagePaths = @($PackagePath)
    $effectiveDestinationPath = $DestinationPath
    $effectiveForceWhileRunning = [bool]$ForceWhileRunning
    $effectiveNonInteractive = [bool]$NonInteractive
    $resultHandoffPath = $null

    if (-not [string]::IsNullOrWhiteSpace($HandoffPath)) {
        try {
            $handoff = Read-InstallerHandoff -Path $HandoffPath
            $effectivePackagePaths = @($handoff.PackagePaths | ForEach-Object { [string]$_ })
            $effectiveDestinationPath = [string]$handoff.DestinationPath
            $effectiveForceWhileRunning = [bool]$handoff.ForceWhileRunning
            $effectiveNonInteractive = [bool]$handoff.NonInteractive
            $resultHandoffPath = [string]$handoff.ResultPath
        }
        catch {
            Write-Host ("  ❌ {0} (╥﹏╥)" -f $_.Exception.Message) -ForegroundColor Red
            return 5
        }
    }

    $effectivePackagePaths = @($effectivePackagePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $shouldCheckForUpdates = (
        -not $SkipUpdateCheck -and
        -not $Elevated -and
        [string]::IsNullOrWhiteSpace($HandoffPath) -and
        -not $effectiveNonInteractive
    )
    if ($shouldCheckForUpdates) {
        $updateRelaunchArguments = @()
        foreach ($effectivePackagePath in $effectivePackagePaths) {
            $updateRelaunchArguments += [string]$effectivePackagePath
        }
        if ($LocationMode -ne 'Auto') {
            $updateRelaunchArguments += '-LocationMode'
            $updateRelaunchArguments += $LocationMode
        }
        if (-not [string]::IsNullOrWhiteSpace($effectiveDestinationPath)) {
            $updateRelaunchArguments += '-DestinationPath'
            $updateRelaunchArguments += $effectiveDestinationPath
        }
        if ($effectiveForceWhileRunning) {
            $updateRelaunchArguments += '-ForceWhileRunning'
        }

        $updateStarted = Invoke-InstallerUpdateCheck -RelaunchArguments $updateRelaunchArguments
        if ($updateStarted) {
            return $script:UpdateExitCode
        }
    }

    if ($effectivePackagePaths.Count -gt 0) {
        $batchResult = Invoke-PackageBatch `
            -InputPaths $effectivePackagePaths `
            -ExplicitDestination $effectiveDestinationPath `
            -RequestedMode $LocationMode `
            -AlreadyElevated:$Elevated `
            -AllowRunning:$effectiveForceWhileRunning `
            -NoPrompt:$effectiveNonInteractive
        if (-not [string]::IsNullOrWhiteSpace($resultHandoffPath)) {
            Write-InstallerHandoffResult -Path $resultHandoffPath -ExitCode $batchResult
        }
        return $batchResult
    }

    if ($effectiveNonInteractive) {
        Write-Host '  ❌ 非交互模式必须通过参数提供图包路径 (・_・;)' -ForegroundColor Red
        return 2
    }

    Write-InstallerSection -Icon '💌' -Title '把图包交给我吧！' -Subtitle '拖进窗口后按 Enter，就会自动寻找 TTS Mods 小窝～'
    Write-Host '      📂 支持：文件夹 / ZIP / TTSMOD / 7Z / RAR' -ForegroundColor Cyan
    Write-Host '      🔎 输入 F：打开文件选择窗口' -ForegroundColor Green
    Write-Host '      👋 输入 Q：先不安装，退出程序' -ForegroundColor Yellow

    while ($true) {
        Write-Host ''
        $inputValue = (Read-Host '  (づ｡◕‿‿◕｡)づ 图包路径').Trim()
        if ($inputValue -ieq 'Q') {
            Write-Host '  👋 下次见～ 图包小窝会等你的！(｡･ω･｡)ﾉ' -ForegroundColor Magenta
            return 0
        }
        if ($inputValue -ieq 'F') {
            $selectedPaths = @(Select-ModPackageFiles)
        }
        else {
            $selectedPaths = @(ConvertFrom-InstallerInputLine -InputLine $inputValue)
        }
        if ($selectedPaths.Count -eq 0) {
            continue
        }

        $result = Invoke-PackageBatch `
            -InputPaths $selectedPaths `
            -RequestedMode $LocationMode `
            -AlreadyElevated:$Elevated

        Write-Host ''
        if ($result -eq 0) {
            $next = (Read-Host '  ✨ 按 Enter 安装下一批；输入 Q 满载而归').Trim()
        }
        else {
            $next = (Read-Host '  🔧 按 Enter 重新选择；输入 Q 暂时退出').Trim()
        }
        if ($next -ieq 'Q') {
            Write-Host '  👋 辛苦啦，下次再来搬图包～ (｡･ω･｡)ﾉ' -ForegroundColor Magenta
            return $result
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $finalExitCode = Invoke-InstallerEntryPoint
    exit $finalExitCode
}
