@echo off
REM Windows 双击入口：通过 WSL 打开浏览器版安装向导
REM   · 需要 Docker Desktop 的 WSL integration（默认开）
REM   · 想用命令行向导：在 WSL / Git Bash 里跑 bash install.sh --custom
setlocal
where wsl.exe >nul 2>&1
if errorlevel 1 (
  echo.
  echo  没找到 WSL。两种办法：
  echo   1^) 在 WSL 发行版里执行： bash install.sh --desktop --wizard
  echo   2^) 用 Git Bash 打开这个目录后： bash install.sh --desktop
  echo.
  pause
  exit /b 1
)
echo 正在通过 WSL 启动浏览器版安装向导...
wsl.exe --cd "%~dp0" bash install.sh --desktop --wizard %*
echo.
pause
