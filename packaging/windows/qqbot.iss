; ============================================================
;  qqbot.iss —— Windows 安装器（Inno Setup 6）
;
;  设计目标：**双击就是安装，没有第二步**。
;    向导（目录 + QQ 号，都能直接用默认）→ 拷贝部署包 → 向导里**等**宿主安装脚本跑完
;    （装 Node / dsh、接插件、注册开机自启；过程日志实时写文件）→ 完成页显示结果 →
;    自动用浏览器打开控制台 http://127.0.0.1:8798/
;
;  为什么不是"开始菜单里再点一下"：那等于把一次安装拆成两步，用户会以为装完了却没装。
;  失败不吞掉：完成页写清退出码 + 完整日志路径，开始菜单里另留"重新安装或修复"。
;  静默安装（/VERYSILENT，CI 冒烟测试用）跳过安装脚本，只做"放文件 + 建快捷方式"。
;
;  不需要管理员：PrivilegesRequired=lowest，装到 %LOCALAPPDATA%\Programs\QQBot；
;  数据在 %USERPROFILE%\qqbot 与 %USERPROFILE%\.dsh —— 卸载器不碰数据。
;
;  构建（CI 里做，本机没 Windows 也能写）：
;    1) 把 deploy/qqbot 的内容拷到本目录的 payload\ 下
;    2) ISCC.exe qqbot.iss /DAppVersion=0.7.5
;  产物：qqbot-deploy-<版本>-setup.exe（未签名 → 首次运行会有 SmartScreen 提示）
; ============================================================

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#define AppName "QQ 机器人"
#define AppPublisher "zfqxuz"
#define AppURL "https://github.com/zfqxuz/qqbot-deploy"
#define PayloadDir "payload"
#define ConsoleURL "http://127.0.0.1:8798/"

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
; 装完之后用得着的入口（安装本身已经在向导里做完了，不需要再点一次）
Name: "{group}\打开控制台（网页）"; Filename: "{#ConsoleURL}"
Name: "{group}\更新"; Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\host\update-host.ps1"""; WorkingDir: "{app}"
Name: "{group}\重新安装或修复"; Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\host\install-host.ps1"""; WorkingDir: "{app}"
Name: "{group}\卸载（保留数据）"; Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\host\uninstall-host.ps1"""; WorkingDir: "{app}"
Name: "{group}\安装说明（HOST-INSTALL.md）"; Filename: "{app}\HOST-INSTALL.md"
Name: "{group}\更新与卸载（UPDATE-UNINSTALL.md）"; Filename: "{app}\UPDATE-UNINSTALL.md"

[UninstallDelete]
; 只删程序目录；数据在 %USERPROFILE%\qqbot 与 %USERPROFILE%\.dsh，卸载器不碰
Type: filesandordirs; Name: "{app}\build-context"

[Messages]
; 只留事实：装什么 / 装哪 / 进度 / 完成。解释性句子全部去掉（标准对话框的也覆盖掉）。
chinese.WelcomeLabel1=安装 %1
chinese.WelcomeLabel2=结束后会自动安装并打开控制台。
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
  InstallLog: String;
  LogHome: String;
  InstallRc: Integer;
  InstallTried: Boolean;
  ConsoleOpened: Boolean;

{ Inno 的 Pascal 是"先声明后使用" }
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

{ 单引号包一层：脚本路径/日志路径都可能带空格 }
function Q(const S: String): String;
begin
  Result := '''' + S + '''';
end;

function PowerShellExe: String;
begin
  Result := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  if not FileExists(Result) then
    Result := 'powershell.exe';
end;

{ 日志最后几行：失败时直接显示在完成页，不用用户去翻文件 }
function LogTail: String;
var
  Lines: TArrayOfString;
  i, From: Integer;
begin
  Result := '';
  if (InstallLog = '') or (not FileExists(InstallLog)) then
    Exit;
  if not LoadStringsFromFile(InstallLog, Lines) then
    Exit;
  From := Length(Lines) - 12;
  if From < 0 then
    From := 0;
  for i := From to Length(Lines) - 1 do
    Result := Result + Lines[i] + #13#10;
end;

{ 真正的安装：跑宿主安装脚本，等在它上面，输出重定向进日志 }
procedure RunHostInstall;
var
  Params, QQ: String;
  Rc: Integer;
begin
  { Inno 没有 userprofile 这个常量（2026-10-12 真机报 Unknown constant "userprofile"）：
    取环境变量要用百分号写法，例如 %USERPROFILE%；另外注意 %USERPROFILE%\qqbot 在全新机器上
    还不存在，不先建目录的话重定向会失败、安装脚本压根起不来。 }
  LogHome := ExpandConstant('{%USERPROFILE}');
  if LogHome = '' then LogHome := ExpandConstant('{%TEMP}');
  LogHome := LogHome + '\qqbot';
  ForceDirectories(LogHome);
  InstallLog := LogHome + '\install-gui-' +
    GetDateTimeString('yyyymmdd-hhnnss', '-', ':') + '.txt';
  QQ := Trim(QQPage.Values[0]);
  Params := '-NoProfile -ExecutionPolicy Bypass -Command "& ' +
    Q(ExpandConstant('{app}\host\install-host.ps1')) + ' -NoPause';
  if QQ <> '' then
    Params := Params + ' -QQ ' + QQ;
  Params := Params + ' *> ' + Q(InstallLog) + '"';

  WizardForm.StatusLabel.Caption := '正在安装（Node / dsh / 插件 / 开机自启，可能要几分钟）…';
  WizardForm.ProgressGauge.Style := npbstMarquee;
  if not Exec(PowerShellExe, Params, ExpandConstant('{app}'), SW_HIDE,
              ewWaitUntilTerminated, Rc) then
    Rc := -1;
  WizardForm.ProgressGauge.Style := npbstNormal;
  InstallRc := Rc;
  InstallTried := True;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  { 静默安装（CI 冒烟测试）不跑这一步：不做重活、不开浏览器 }
  if (CurStep = ssPostInstall) and (not WizardSilent) and (not InstallTried) then
    RunHostInstall;
end;

procedure InitializeWizard;
begin
  QQPage := CreateInputQueryPage(wpSelectDir, '机器人 QQ 号', '',
    '留空也行：装完在控制台里再填。');
  QQPage.Add('QQ 号（可留空）', False);
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

procedure CurPageChanged(CurPageID: Integer);
var
  ErrCode: Integer;
begin
  if (CurPageID <> wpFinished) or (not InstallTried) then
    Exit;
  if InstallRc = 0 then
  begin
    WizardForm.FinishedLabel.Caption :=
      '安装完成。控制台已经用浏览器打开了（' + '{#ConsoleURL}' + '），' +
      '在里面扫码登录 QQ 就能用。' + #13#10 + #13#10 +
      '过程日志：' + InstallLog;
    if not ConsoleOpened then
    begin
      ShellExec('open', '{#ConsoleURL}', '', '', SW_SHOWNORMAL, ewNoWait, ErrCode);
      ConsoleOpened := True;
    end;
  end
  else
  begin
    WizardForm.FinishedLabel.Caption :=
      '安装脚本报错了（退出码 ' + IntToStr(InstallRc) + '）。' + #13#10 +
      '完整日志：' + InstallLog + #13#10 + #13#10 +
      '日志最后几行：' + #13#10 + LogTail;
  end;
end;
