@echo off
setlocal
chcp 65001 >nul
title 🎲 TTS 图包魔法搬运工 ✨

if not exist "%~dp0TTSModInstaller.ps1" (
    echo.
    echo   ❌ 没有找到 TTSModInstaller.ps1  ^(╥﹏╥^)
    echo.
    echo   如果你正在压缩包预览窗口中运行，请先选择“全部解压”，
    echo   然后在解压后的文件夹中双击 Install-TTS-Mods.cmd。
    echo.
    echo   按任意键退出……
    pause >nul
    exit /b 2
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0TTSModInstaller.ps1" %*
set "installer_exit_code=%ERRORLEVEL%"

echo.
if not "%installer_exit_code%"=="0" (
    echo   ⚠️ 安装器退出码：%installer_exit_code%
)
echo   🌸 按任意键关闭窗口～
pause >nul
exit /b %installer_exit_code%
