@echo off
REM ============================================================
REM  QQ 机器人 · Windows 双击入口
REM
REM  自己判断该走哪条路，不需要你手工敲命令：
REM    · 有可用 Docker（docker.exe 在且守护进程能连上）→ 经 WSL 起"容器版"网页向导
REM    · 没有 Docker                                    → 直接在 PowerShell 里跑"不用 Docker 的安装"
REM  想强制某一条：  install.cmd host    /    install.cmd docker
REM  只体检不改动：  install.cmd host -Check
REM ============================================================
setlocal EnableDelayedExpansion
cd /d "%~dp0"

set "MODE=%~1"
if /i "%MODE%"=="host" goto HOST
if /i "%MODE%"=="docker" goto DOCKER
if /i "%MODE%"=="-h" goto USAGE
if /i "%MODE%"=="--help" goto USAGE
if /i "%MODE%"=="/?" goto USAGE

REM ---- 自动判断：有没有"真的能用"的 Docker ----
set "HAVE_DOCKER=0"
where docker.exe >nul 2>&1 && (
  docker info >nul 2>&1 && set "HAVE_DOCKER=1"
)
if "%HAVE_DOCKER%"=="1" goto DOCKER
goto HOST

:USAGE
echo.
echo  用法：install.cmd [host^|docker] [传给安装脚本的其它参数]
echo    install.cmd            自动判断（有 Docker 走容器版，没有就走本机安装）
echo    install.cmd host       强制"不用 Docker 的安装"（原生 PowerShell，不需要 WSL）
echo    install.cmd host -Check      只体检，什么都不改
echo    install.cmd docker     强制"容器版"（需要 WSL）
echo.
pause
exit /b 0

:DOCKER
echo.
echo [1/2] 检测到可用的 Docker，走"容器版"（经 WSL 起网页向导）
where wsl.exe >nul 2>&1
if errorlevel 1 (
  echo.
  echo  没找到 WSL。两种办法：
  echo   1^) 装好 WSL 后重跑本文件（Docker Desktop 默认带 WSL 后端）
  echo   2^) 不想用 Docker：双击 install.cmd host，或在本目录开 PowerShell 跑
  echo        powershell -ExecutionPolicy Bypass -File host\install-host.ps1
  echo.
  pause
  exit /b 1
)
wsl.exe --cd "%~dp0" bash install.sh --desktop --wizard %2 %3 %4 %5 %6 %7 %8 %9
set "RC=%ERRORLEVEL%"
echo.
pause
exit /b %RC%

:HOST
echo.
echo [1/2] 没有可用的 Docker（或你指定了 host），走"不用 Docker 的安装"
echo       分层来装：已有 Node 就不装 Node、已有 dsh 就不装 dsh，缺什么补什么。
echo       只想先看看会做什么：install.cmd host -Check   ^(只体检，不改动^)
echo.
REM 注意：批处理里 %1 是在"块解析"时就展开的，所以这里用 goto 分流而不是 if(...) + shift
if "%~1"=="" goto HOST_PLAIN
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0host\install-host.ps1" %2 %3 %4 %5 %6 %7 %8 %9
goto HOST_DONE

:HOST_PLAIN
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0host\install-host.ps1"

:HOST_DONE
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" echo  安装脚本退出码 %RC%：把上面的报错发给维护者，或照 HOST-INSTALL.md 手工做。
pause
exit /b %RC%
