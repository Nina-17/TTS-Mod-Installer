[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RequestPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-UpdateStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $color = 'Cyan'
    $icon = '💠'
    if ($Level -eq 'OK') {
        $color = 'Green'
        $icon = '✅'
    }
    elseif ($Level -eq 'WARN') {
        $color = 'Yellow'
        $icon = '⚠️'
    }
    elseif ($Level -eq 'ERROR') {
        $color = 'Red'
        $icon = '❌'
    }

    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Write-Host ("  {0} {1}" -f $icon, $Message) -ForegroundColor $color
    if (-not [string]::IsNullOrWhiteSpace($script:UpdateLogPath)) {
        $line | Add-Content -LiteralPath $script:UpdateLogPath -Encoding UTF8
    }
}

function Invoke-UpdateRobocopy {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $robocopy = Get-Command 'robocopy.exe' -ErrorAction Stop
    & $robocopy.Source `
        $Source `
        $Destination `
        '/E' `
        '/COPY:DAT' `
        '/DCOPY:DAT' `
        '/R:2' `
        '/W:1' `
        '/XJ' `
        '/IS' `
        '/IT' `
        '/NFL' `
        '/NDL' `
        '/NJH' `
        '/NJS' `
        '/NP' 2>&1 |
        ForEach-Object {
            if (-not [string]::IsNullOrWhiteSpace([string]$_)) {
                ([string]$_) | Add-Content -LiteralPath $script:UpdateLogPath -Encoding UTF8
            }
        }
    $exitCode = $LASTEXITCODE
    if ($exitCode -ge 8) {
        throw ("robocopy 复制失败，退出码：{0}" -f $exitCode)
    }
    return $exitCode
}

function Backup-CurrentInstaller {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallDirectory,

        [Parameter(Mandatory = $true)]
        [string]$BackupDirectory
    )

    New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
    $ownedPaths = @(
        'TTSModInstaller.ps1',
        'TTSModUpdater.ps1',
        '点我启动.cmd',
        'Install-TTS-Mods.cmd',
        'QUICK-START.txt',
        'README.md',
        'DESIGN.md',
        'THIRD-PARTY-NOTICES.txt',
        'tools'
    )

    foreach ($relativePath in $ownedPaths) {
        $sourcePath = Join-Path $InstallDirectory $relativePath
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            continue
        }
        Copy-Item `
            -LiteralPath $sourcePath `
            -Destination $BackupDirectory `
            -Recurse `
            -Force
    }
}

function Start-UpdatedInstaller {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [object[]]$Arguments
    )

    $argumentText = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $ScriptPath
    foreach ($argument in @($Arguments)) {
        $argumentText += ' "{0}"' -f ([string]$argument)
    }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentText | Out-Null
}

$script:UpdateLogPath = $null
$request = $null
$backupDirectory = $null
$installDirectory = $null
$relaunchPath = $null
$relaunchArguments = @()
$updateSucceeded = $false

try {
    if (-not (Test-Path -LiteralPath $RequestPath -PathType Leaf)) {
        throw '更新请求文件不存在。'
    }
    $request = Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json
    $installDirectory = [string]$request.InstallDirectory
    $packageDirectory = [string]$request.PackageDirectory
    $relaunchPath = [string]$request.RelaunchPath
    $relaunchArguments = @($request.RelaunchArguments)

    $installerDataRoot = [string]$request.DataRoot
    if ([string]::IsNullOrWhiteSpace($installerDataRoot)) {
        throw '更新请求没有提供便携运行数据目录。'
    }
    $expectedDataRoot = [IO.Path]::GetFullPath(
        (Join-Path $installDirectory '运行数据')
    ).TrimEnd('\', '/')
    $actualDataRoot = [IO.Path]::GetFullPath(
        $installerDataRoot
    ).TrimEnd('\', '/')
    if (-not $actualDataRoot.Equals($expectedDataRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw '更新请求中的运行数据目录不属于安装器文件夹。'
    }
    $installerDataRoot = $actualDataRoot
    $logDirectory = Join-Path $installerDataRoot 'Logs'
    $backupRoot = Join-Path $installerDataRoot 'Backups'
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:UpdateLogPath = Join-Path $logDirectory ("update-{0}.log" -f $stamp)
    $backupDirectory = Join-Path $backupRoot (
        'v{0}-{1}' -f ([string]$request.CurrentVersion), $stamp
    )

    try {
        $Host.UI.RawUI.WindowTitle = '🎲 TTS 图包魔法搬运工 — 正在更新 ✨'
    }
    catch {
        # Some hosts do not expose a writable title.
    }

    Write-Host ''
    Write-Host '  ✦ ───────────────────────────────────────── ✦' -ForegroundColor DarkMagenta
    Write-Host '       🔄  正在更新 TTS 图包魔法搬运工  ✨' -ForegroundColor Magenta
    Write-Host '  ✦ ───────────────────────────────────────── ✦' -ForegroundColor DarkMagenta
    Write-Host ''

    Write-UpdateStatus -Message '正在等待旧版安装器退出……'
    try {
        $parentProcess = Get-Process -Id ([int]$request.ParentProcessId) -ErrorAction Stop
        $parentProcess.WaitForExit()
    }
    catch {
        # The parent may already have exited.
    }
    Start-Sleep -Milliseconds 800

    if (-not (Test-Path -LiteralPath $installDirectory -PathType Container)) {
        throw '安装器目录不存在。'
    }
    if (-not (Test-Path -LiteralPath $packageDirectory -PathType Container)) {
        throw '下载后的更新包目录不存在。'
    }

    Write-UpdateStatus -Message '正在备份当前版本……'
    Backup-CurrentInstaller `
        -InstallDirectory $installDirectory `
        -BackupDirectory $backupDirectory

    Write-UpdateStatus -Message ("正在安装 v{0}……" -f ([string]$request.TargetVersion))
    Invoke-UpdateRobocopy `
        -Source $packageDirectory `
        -Destination $installDirectory | Out-Null

    $updatedScript = Join-Path $installDirectory 'TTSModInstaller.ps1'
    if (-not (Test-Path -LiteralPath $updatedScript -PathType Leaf)) {
        throw '更新后没有找到主安装器脚本。'
    }
    $updatedText = Get-Content -LiteralPath $updatedScript -Raw
    $expectedVersionPattern = 'InstallerVersion\s*=\s*[''"]{0}[''"]' -f (
        [regex]::Escape([string]$request.TargetVersion)
    )
    if ($updatedText -notmatch $expectedVersionPattern) {
        throw '更新后的安装器版本校验失败。'
    }

    $newLauncher = Join-Path $installDirectory '点我启动.cmd'
    if (-not (Test-Path -LiteralPath $newLauncher -PathType Leaf)) {
        throw '更新后没有找到“点我启动.cmd”。'
    }
    $legacyLauncher = Join-Path $installDirectory 'Install-TTS-Mods.cmd'
    if (Test-Path -LiteralPath $legacyLauncher -PathType Leaf) {
        Remove-Item -LiteralPath $legacyLauncher -Force -ErrorAction SilentlyContinue
    }

    $updateSucceeded = $true
    Write-UpdateStatus -Level OK -Message (
        "更新完成：v{0} → v{1}！(ﾉ◕ヮ◕)ﾉ*:･ﾟ✧" -f
        ([string]$request.CurrentVersion),
        ([string]$request.TargetVersion)
    )
}
catch {
    Write-UpdateStatus -Level ERROR -Message ("更新失败：{0}" -f $_.Exception.Message)
    if (
        -not [string]::IsNullOrWhiteSpace($backupDirectory) -and
        (Test-Path -LiteralPath $backupDirectory -PathType Container) -and
        -not [string]::IsNullOrWhiteSpace($installDirectory)
    ) {
        try {
            Write-UpdateStatus -Level WARN -Message '正在恢复更新前的版本……'
            Invoke-UpdateRobocopy `
                -Source $backupDirectory `
                -Destination $installDirectory | Out-Null
            Write-UpdateStatus -Level OK -Message '旧版本已经恢复。'
        }
        catch {
            Write-UpdateStatus -Level ERROR -Message ("恢复旧版本也失败了：{0}" -f $_.Exception.Message)
        }
    }
}
finally {
    if (
        -not [string]::IsNullOrWhiteSpace($relaunchPath) -and
        (Test-Path -LiteralPath $relaunchPath -PathType Leaf)
    ) {
        try {
            Write-UpdateStatus -Message '正在重新打开安装器……'
            Start-UpdatedInstaller `
                -ScriptPath $relaunchPath `
                -Arguments $relaunchArguments
        }
        catch {
            Write-UpdateStatus -Level ERROR -Message ("无法重新打开安装器：{0}" -f $_.Exception.Message)
        }
    }

    if (-not $updateSucceeded) {
        Write-Host ''
        Write-Host '  按 Enter 关闭更新窗口。' -ForegroundColor Yellow
        Read-Host | Out-Null
    }
}
