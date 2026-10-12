@echo off
REM Windows 双击入口：交给 WSL 里的 bash 跑安装向导
REM   · 需要 Docker Desktop 的 WSL integration（默认开）
REM   · 也支持带参数：install.cmd --custom
setlocal
where wsl.exe >nul 2>&1
if errorlevel 1 (
  echo.
  echo  没找到 WSL。两种办法：
  echo   1^) 在 WSL 发行版里执行： bash install.sh --desktop
  echo   2^) 用 Git Bash 打开这个目录后： bash install.sh --desktop
  echo.
  pause
  exit /b 1
)
echo 正在通过 WSL 运行安装向导（自动带 --desktop）...
wsl.exe --cd "%~dp0" bash install.sh --desktop %*
echo.
pause
