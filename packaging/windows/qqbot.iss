; ============================================================
;  qqbot.iss —— Windows 安装器（Inno Setup 6）
;
;  它装的是"安装器"本身，不是机器人本体：
;    {app}\…            部署包（脚本、compose、文档、一行安装入口）
;    开始菜单           "安装 QQ 机器人（不用 Docker）" → 跑 host\install-host.ps1
;                       "查看安装说明" / "查看更新与卸载"
;  装的时候不会起服务、不碰数据、不需要管理员权限（PrivilegesRequired=lowest，装到用户目录）。
;  向导走完会**自动**在一个控制台窗口里继续安装（不再需要去开始菜单点第二次）；
;  那个窗口会把过程写在屏幕上并停住等你按回车，报错也会留在 %USERPROFILE%\qqbot\install-log-*.txt。
;
;  构建（CI 里做，本机没 Windows 也能写）：
;    1) 把 deploy/qqbot 的内容拷到本目录的 payload\ 下
;    2) ISCC.exe qqbot.iss /DAppVersion=0.7.3
;  产物：qqbot-deploy-<版本>-setup.exe（未签名 → 首次运行会有 SmartScreen 提示）
; ============================================================

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#define AppName "QQ 机器人"
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
; 有中文语言包就用中文（CI 会在编译前下载）；没有就退回 Inno 自带的英文对话框
#if FileExists(AddBackslash(SourcePath) + "ChineseSimplified.isl")
Name: "chinese"; MessagesFile: "ChineseSimplified.isl"
#else
Name: "chinese"; MessagesFile: "compiler:Default.isl"
#endif

[Files]
; 整个部署包（payload\ 由 CI 从 deploy/qqbot 拷过来）
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; 主入口：直接跑宿主安装器（分层判断，已有 Node/dsh 不动）；不开控制台向导是为了不依赖 WSL
Name: "{group}\重新安装或修复（不用 Docker）"; Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\host\install-host.ps1"""; \
  WorkingDir: "{app}"
Name: "{group}\先体检（什么都不改）"; Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\host\install-host.ps1"" -Check"; WorkingDir: "{app}"
Name: "{group}\更新"; Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\host\update-host.ps1"""; WorkingDir: "{app}"
Name: "{group}\卸载（保留数据）"; Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\host\uninstall-host.ps1"""; WorkingDir: "{app}"
Name: "{group}\安装说明（HOST-INSTALL.md）"; Filename: "{app}\HOST-INSTALL.md"
Name: "{group}\更新与卸载（UPDATE-UNINSTALL.md）"; Filename: "{app}\UPDATE-UNINSTALL.md"

[Run]
; ---- 主流程：向导一结束就**自动**开始安装（不是复选框，不需要再去开始菜单）----
;      安装脚本自己会：刷新 PATH（捡起刚装好的 Node/dsh）、分层安装、全程记日志、
;      结束/报错都停住等回车 —— 窗口不会一闪而过。
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\host\install-host.ps1""{code:GetQQArg}"; \
  WorkingDir: "{app}"; StatusMsg: "正在安装…"; \
  Flags: runascurrentuser nowait skipifsilent

; ---- 可选：装完再跑一次只读体检（默认不勾；排查问题用）----
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\host\install-host.ps1"" -Check"; \
  Description: "安装后做一次环境检查"; Flags: postinstall nowait skipifsilent unchecked

[UninstallDelete]
; 只删程序目录；数据在 %USERPROFILE%\qqbot 与 %USERPROFILE%\.dsh，卸载器不碰
Type: filesandordirs; Name: "{app}\build-context"

[Messages]
; 只留事实：装什么 / 装哪 / 进度 / 完成。解释性句子全部去掉（标准对话框的也覆盖掉）。
chinese.WelcomeLabel1=安装 %1
chinese.WelcomeLabel2=结束后自动开始安装。
chinese.SelectDirLabel3=安装到：
chinese.SelectDirBrowseLabel=
chinese.ReadyLabel1=可以安装了。
chinese.ReadyLabel2a=
chinese.ReadyLabel2b=
chinese.InstallingLabel=安装中…
chinese.FinishedHeadingLabel=完成
chinese.ClickFinish=
chinese.SetupAppRunningError=请先关闭正在运行的安装程序，然后点"确定"重试。

[Code]
var
  QQPage: TInputQueryWizardPage;

{ 注意：Inno 的 Pascal 是"先声明后使用"，这个函数必须在 NextButtonClick 之前 }
function IsDigitsOnly(const S: String): Boolean;
var
  i: Integer;
begin
  Result := S <> '';
  for i := 1 to Length(S) do
    if (S[i] < '0') or (S[i] > '9') then
    begin
      Result := False;
      Break;
    end;
end;

procedure InitializeWizard;
begin
  QQPage := CreateInputQueryPage(wpSelectDir, '机器人 QQ 号', '', '');
  QQPage.Add('QQ 号（可留空）', False);
end;

function GetQQArg(Param: String): String;
begin
  if Trim(QQPage.Values[0]) <> '' then
    Result := ' -QQ ' + Trim(QQPage.Values[0])
  else
    Result := '';
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  v: String;
begin
  Result := True;
  if CurPageID = QQPage.ID then
  begin
    v := Trim(QQPage.Values[0]);
    if (v <> '') and (not IsDigitsOnly(v)) then
    begin
      MsgBox('QQ 号必须是纯数字（例如 123456789），或者留空。', mbError, MB_OK);
      Result := False;
    end;
  end;
end;
