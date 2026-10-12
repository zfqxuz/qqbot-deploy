; ============================================================
;  qqbot.iss —— Windows 安装器（Inno Setup 6）
;
;  它装的是"安装器"本身，不是机器人本体：
;    {app}\…            部署包（脚本、compose、文档、一行安装入口）
;    开始菜单           "安装 QQ 机器人（不用 Docker）" → 跑 host\install-host.ps1
;                       "查看安装说明" / "查看更新与卸载"
;  装的时候不会起服务、不碰数据、不需要管理员权限（PrivilegesRequired=lowest，装到用户目录）。
;
;  构建（CI 里做，本机没 Windows 也能写）：
;    1) 把 deploy/qqbot 的内容拷到本目录的 payload\ 下
;    2) ISCC.exe qqbot.iss /DAppVersion=0.7.3
;  产物：qqbot-deploy-<版本>-setup.exe（未签名 → 首次运行会有 SmartScreen 提示）
; ============================================================

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#define AppName "QQ 机器人（DSH + OneBot 桥接）"
#define AppPublisher "zfqxuz"
#define AppURL "https://github.com/zfqxuz/qqbot-deploy"
#define PayloadDir "payload"

[Setup]
AppId={{8E1F3C42-6B7A-4E6D-9F21-QQBOTDEPLOY01}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}
DefaultDirName={autopf}\QQBot
DefaultGroupName=QQ 机器人
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputBaseFilename=qqbot-deploy-{#AppVersion}-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayName={#AppName}
; 中文向导
ShowLanguageDialog=no

[Languages]
Name: "chinese"; MessagesFile: "compiler:Default.isl"

[Files]
; 整个部署包（payload\ 由 CI 从 deploy/qqbot 拷过来）
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; 主入口：直接跑宿主安装器（分层判断，已有 Node/dsh 不动）；不开控制台向导是为了不依赖 WSL
Name: "{group}\安装 QQ 机器人（不用 Docker）"; Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\host\install-host.ps1"""; \
  WorkingDir: "{app}"; Comment: "分层安装：已有 Node/dsh 不会重装"
Name: "{group}\先体检（什么都不改）"; Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\host\install-host.ps1"" -Check"; WorkingDir: "{app}"
Name: "{group}\更新"; Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\host\update-host.ps1"""; WorkingDir: "{app}"
Name: "{group}\卸载（保留数据）"; Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\host\uninstall-host.ps1"""; WorkingDir: "{app}"
Name: "{group}\安装说明（HOST-INSTALL.md）"; Filename: "{app}\HOST-INSTALL.md"
Name: "{group}\更新与卸载（UPDATE-UNINSTALL.md）"; Filename: "{app}\UPDATE-UNINSTALL.md"

[Run]
; 装完不自动干活，只问一句要不要现在开始体检
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\host\install-host.ps1"" -Check"; \
  Description: "现在先体检这台机器（只读，什么都不改）"; Flags: postinstall nowait skipifsilent unchecked

[UninstallDelete]
; 只删程序目录；数据在 %USERPROFILE%\qqbot 与 %USERPROFILE%\.dsh，卸载器不碰
Type: filesandordirs; Name: "{app}\build-context"

[Messages]
chinese.WelcomeLabel2=即将安装 %1。%n%n它会放好安装脚本与文档，不会自动启服务、不会碰你的数据；装完在开始菜单里点"安装 QQ 机器人（不用 Docker）"再开始。
chinese.FinishedLabel=安装完成。%n%n下一步：开始菜单 → "安装 QQ 机器人（不用 Docker）"（想先看看会做什么就点"先体检"）。%n%n注意：本安装包未做代码签名，Windows 可能提示"未知发布者"。
