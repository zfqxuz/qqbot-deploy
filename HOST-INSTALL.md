# 不用 Docker 的安装（Linux / macOS / Windows）

这份文档是给"机器上没有 Docker，或者不想为了机器人装 Docker"的人用的。
**顺序照做即可**；每一步都写了「执行 → 验证 → 失败怎么办」。给 agent 执行也适用，
规则见第 1 节（不要跳步、不要自己提权）。

## 最省事：下载安装包（Windows）

去 Release 下 `qqbot-deploy-<版本>-setup.exe`，双击 → 填机器人 QQ 号（可留空）→ 装完自动打开控制台
http://127.0.0.1:8798/ 。它做的就是本文第 2 节那一整套（装 Node/dsh、拉源码、接插件、注册开机自启
并**立刻启动**、等 3081/8798 就绪），不需要你敲任何命令；失败会在安装向导的完成页给出退出码和日志路径。

本文余下的步骤是"自己一步步来"的版本 —— 想看清楚每一步、或者安装包跑不通时，照下面做。

## 一行安装（推荐先试这个）

Linux / macOS（把 `<机器人QQ号>` 换成你的）：

```bash
curl -fsSL https://raw.githubusercontent.com/zfqxuz/qqbot-deploy/main/host/get-qqbot.sh | bash -s -- --qq <机器人QQ号>
```

Windows（PowerShell）：

```powershell
irm https://raw.githubusercontent.com/zfqxuz/qqbot-deploy/main/host/get-qqbot.ps1 -OutFile "$env:TEMP\get-qqbot.ps1"
powershell -ExecutionPolicy Bypass -File "$env:TEMP\get-qqbot.ps1" -QQ <机器人QQ号>
```

它会：把部署包拉到 `~/qqbot/src/qqbot-deploy`（Windows：`%USERPROFILE%\qqbot\src\qqbot-deploy`）→ 交给包里的
`host/install-host.sh`（Windows：`host\install-host.ps1`）。那个安装器**按你机器已有的东西分层**：
有 Node 不装 Node、有 dsh 不装 dsh，缺什么补什么（见下一节的表）。

- 只想看看会做什么：把 `--qq <号>` 换成 `--check`（只体检）或 `--dry-run`（打印每一步）
- 已经在部署包里：`bash host/get-qqbot.sh --check`（不会重复下载）
- 下面第 2 节起是**手工分步版**，脚本不能用时照它做

> 有 Docker 的话别用本文，用 README 里的容器版（一条命令 + 网页向导，最省事）。

---

## 0. 先看这张表：哪条路适合你

| | 容器版（README） | 宿主版（本文） |
|---|---|---|
| 需要 | Docker / Docker Desktop | Node ≥ 22.13（缺了脚本会装；插件用内置 `node:sqlite`，20.x 装不起来） |
| Linux 自动化 | 全自动 | 全自动（除 NapCat 安装器要交互、linger 要一次 sudo） |
| Windows 自动化 | 全自动（WSL） | 半自动：装 Node/dsh/自启可自动；NapCat 官方安装器要人工点 |
| macOS 自动化 | 全自动 | 半自动：同上，NapCat 用官方 Mac 安装器 |
| 升级 | 改一行 tag + pull | npm 升级 + git pull + 重启服务 |
| 回滚 | compose down + 起老服务 | 停服务 + 删软链/环境文件 |

宿主版的组成和容器版**完全一样**，只是把容器换成本机进程：

```
NapCat（官方安装）──反连 WS 6700──▶ dsh web（宿主进程，桥接插件在里面）◀──控制台 8798
```

---

## 1. 给执行者（人或 agent）的规矩

1. **按顺序做，不要跳步**：每一步都有验证命令，验证不过就停下来修，不要"先继续看看"。
2. **需要 sudo / 管理员的地方停下来，把命令原样交给用户**执行。不要自行提权、不要改 sudoers。
3. 每一步的失败处理都写在当步的「失败怎么办」里；没有写在里面的，就把原始报错贴出来问。
4. 全部做完必须跑第 8 节的验收清单（4 条），缺一条都不算成功。
5. 不要动用户已有的配置：脚本对已有文件一律"只补缺、不覆盖"（`qq-seed.mjs` 的规矩）。

---

## 1.5 分层：机器上已经有什么，脚本就少做什么

宿主安装器**不会动你已经装好的东西**。按机器现状分四种情况：

| 机器现状 | 脚本做什么 |
|---|---|
| Node ≥20 + dsh | 两个都不装，直接接线：源码 → 软链 → 播种 → 自启 |
| Node ≥20，没有 dsh | 只装 dsh（`npm i -g @deepseek-ai/dsh`），装完验证 `dsh --version` 与插件兼容范围（0.1.x / 0.2.x） |
| 没有 Node（或 <20） | 先装 Node（Linux：解压到 `~/.local`，**不需要 sudo**；macOS：Homebrew；Windows：winget 用户作用域），再装 dsh |
| 已有 dsh 但版本不合适 | 只警告、**不擅自升级**；要换版本显式指定：`--dsh-version 0.2.0-rc.2`（Windows：`-DshVersion`） |

另外两种常见情况：

- **只想用现成的 dsh**：`--skip-dsh`（Windows：`-SkipDsh`）——脚本完全不碰 dsh，没有就直接报错退出。
- **想主动升级 dsh**：`--upgrade-dsh`（Windows：`-UpgradeDsh`）——默认**不升级**，因为升级有可能弄坏正在跑的部署。

先看清楚会做什么，再动手：`bash host/install-host.sh --check`（只读体检）/ `--dry-run`（打印每一步）。

## 1.8 更新与卸载（宿主版）

```bash
bash host/update-host.sh --check     # 版本对照（本地源码 vs npm 最新），只读
bash host/update-host.sh             # 更新部署包+源码+插件，重新播种，重启服务
bash host/uninstall-host.sh --dry-run  # 先看卸载会删什么
bash host/uninstall-host.sh            # 真卸（数据根默认保留；--purge 才删）
```

Windows：`host\update-host.ps1` / `host\uninstall-host.ps1`（同样的 `-Check` / `-DryRun` / `-Purge`）。
完整说明（含容器版、插件版、备份、数据边界）见 [UPDATE-UNINSTALL.md](UPDATE-UNINSTALL.md)。

## 2. 七步总览（三平台一样）

| 步 | 做什么 | 自动？ |
|---|---|---|
| 1 | 体检：系统、Node、端口、已有协议端、DSH home | 自动 |
| 2 | 装 Node ≥ 22.13（已有且够新就跳过） | Linux 自动（下 tarball 到 ~/.local，不需要 sudo）；macOS 用 brew；Windows 用 winget |
| 3 | `npm install -g @deepseek-ai/dsh`（**已有就不装**） | 自动 |
| 4 | 拉桥接 + 插件源码 | 自动（Windows 没 git 时用 zip 包） |
| 5 | 接线：插件软链进 `$DSH_HOME/plugins`、桥接软链进 profile 的 `node_modules`，跑首启播种 | 自动 |
| 6 | 装协议端 NapCat（**官方安装器是交互式的**） | **人工**（本文给命令与验证） |
| 7 | 自启（systemd --user / launchd / 计划任务）+ 打开 `/setup` 做收尾 | 自动 + 人工三步 |

---

## 3. Linux

### 一键

```bash
cd qqbot-deploy          # 部署包解压出来的目录
bash host/install-host.sh --qq <机器人QQ号>          # 只体检不改动：加 --check
bash host/install-host.sh --dry-run                  # 打印将要执行的每一步
```

脚本会：装 Node（缺失时，下到 `~/.local`，**不需要 sudo**）→ `npm i -g dsh` →
`git clone` 桥接与插件 → 建软链 → 播种 → 写 `~/.config/dsh-bot/dsh.env` →
写 `~/.config/systemd/user/{dsh-web,qq-acl-console}.service` 并 `enable --now`。

### 手工版（脚本不能用时照这个来）

```bash
# 1) 体检
node -v || echo 缺 node
ss -ltn | grep -E ':(6099|6700) ' || echo 没有协议端
# 2) Node ≥20（无 sudo 的装法）
mkdir -p ~/.local/lib ~/.local/bin && cd ~/.local/lib
curl -fLO https://nodejs.org/dist/v22.14.0/node-v22.14.0-linux-x64.tar.xz
tar -xf node-v22.14.0-linux-x64.tar.xz && rm -f node-v22.14.0-linux-x64.tar.xz
ln -sfn ~/.local/lib/node-v22.14.0-linux-x64/bin/node ~/.local/bin/node
ln -sfn ~/.local/lib/node-v22.14.0-linux-x64/bin/npm  ~/.local/bin/npm
export PATH="$HOME/.local/bin:$PATH"
# 3) dsh
npm install -g --no-fund --no-audit @deepseek-ai/dsh && dsh --version
# 4) 源码
mkdir -p ~/qqbot/src && cd ~/qqbot/src
git clone --depth 1 https://github.com/zfqxuz/dsh-qq-onebot-bridge.git
git clone --depth 1 https://github.com/zfqxuz/dsh-plugins.git
# 5) 接线（只动软链）
mkdir -p ~/.dsh/plugins ~/.dsh/profiles/web/node_modules
for d in ~/qqbot/src/dsh-plugins/*/; do ln -sfn "${d%/}" ~/.dsh/plugins/"$(basename "$d")"; done
ln -sfn ~/qqbot/src/dsh-qq-onebot-bridge ~/.dsh/profiles/web/node_modules/dsh-qq-onebot-bridge
node ~/qqbot/src/dsh-qq-onebot-bridge/control/bin/qq-seed.mjs
# 6) 手动起一次看有没有报错
dsh web --no-open --port 3081       # 另开一个终端看 3081 能不能打开
# 推荐：用随包的启动器起（它会登记真实地址，控制台据此自己发现端口，端口/令牌变了也不用配）
#   mkdir -p ~/qqbot/bin && cp qqbot-deploy/dsh-web-run.mjs ~/qqbot/bin/
#   node ~/qqbot/bin/dsh-web-run.mjs --port 3081 --data-root ~/qqbot -- dsh web --no-open --port 3081
```

### 验证（每步之后跑）

```bash
node -v                     # ≥ v20
dsh --version               # 有输出
ls -l ~/.dsh/plugins/        # 每个插件一条软链
systemctl --user is-active dsh-web.service qq-acl-console.service   # active active
ss -ltn | grep -E ':(3081|6700|8798) '                              # 三条都在
```

### 失败怎么办

| 现象 | 处理 |
|---|---|
| 下 Node 超时 | 换版本：`NODE_TARBALL_VER=v20.19.0 bash host/install-host.sh` 或换国内镜像 |
| `npm install -g` 很慢 | `npm config set registry https://registry.npmmirror.com` 后重跑 |
| `dsh: command not found` | npm 全局 bin 不在 PATH：`npm config get prefix`，把它的 `bin` 加进 PATH |
| 拉源码报 `could not read Username for github.com` | 两个源码仓库都是公开的，正常不会遇到。真遇到了：检查网络/代理，或用随包的源码 `--src-archive src.tar.gz`、指本地源码 `--src-dir <目录>` |
| `systemctl --user` 不可用 | 无 systemd 的环境（容器/WSL1）跳过自启，手动起：`node ~/qqbot/bin/dsh-web-run.mjs --port 3081 --data-root ~/qqbot -- dsh web --no-open --port 3081` |
| 注销后服务停了 | `sudo loginctl enable-linger $(id -un)`（**这一步要用户自己执行**） |

---

## 4. Windows

```powershell
# 解压部署包后，在 PowerShell 里
cd qqbot-deploy
powershell -ExecutionPolicy Bypass -File host\install-host.ps1 -Check                 # 只体检
powershell -ExecutionPolicy Bypass -File host\install-host.ps1 -QQ <机器人QQ号>
```

脚本做：`winget` 装 Node LTS（无 winget 就提示你去 nodejs.org 装）→ `npm i -g dsh` →
拉源码（没 git 就用 codeload 的 zip）→ 用 **junction**（Windows 上不需要管理员的软链）接线 →
播种 → 写用户环境变量 → 建计划任务 `qqbot-dsh-web`（登录时自启）。

### NapCat（Windows，必须人工）

1. 打开官方文档的 Windows 一节：https://napneko.github.io/guide/boot/Shell
2. 下载 **NapCat.Shell.Windows.OneKey.zip**，解压后运行 `NapCatInstaller.exe`（官方说明：无需预先安装 QQ）
3. 安装完成后启动一次，**扫码登录**
4. 在 NapCat 的 OneBot11 配置里，把反向 WebSocket 目标填成 `ws://127.0.0.1:6700`（这是本机桥接）
5. 确认 6099（WebUI）能打开

### 验证

```powershell
node -v                                             # ≥ v20
dsh --version
Get-ChildItem "$env:USERPROFILE\.dsh\plugins"       # junction 列表
Get-NetTCPConnection -LocalPort 6700 -State Listen  # 桥接在听
(Invoke-WebRequest "http://127.0.0.1:8798/login").StatusCode   # 200
schtasks /Query /TN qqbot-dsh-web                   # 自启任务在
```

### 失败怎么办

| 现象 | 处理 |
|---|---|
| `winget` 找不到 | 去 https://nodejs.org 装 LTS，安装时勾 *Add to PATH*，重开 PowerShell 重跑 |
| 装完 `node -v` 还是旧的 | 重开一个 PowerShell（PATH 变了） |
| 没有 git | 脚本自动改用 zip 下载；也可自己装 Git for Windows |
| `New-Item -ItemType Junction` 报错 | 目标分区必须是 NTFS；FAT/exFAT 的移动盘不行 |
| 计划任务没跑 | `schtasks /Run /TN qqbot-dsh-web` 手动跑一次看窗口里的报错 |
| 防火墙弹窗 | 允许即可（只监听 127.0.0.1 的端口，不需要对外放行） |

---

## 5. macOS

```bash
cd qqbot-deploy
bash host/install-host.sh --check                    # 只体检
bash host/install-host.sh --qq <机器人QQ号>
```

脚本做：没有 node 就用 Homebrew 装（没 brew 会提示你先装）→ `npm i -g dsh` → 拉源码 →
软链接线 → 播种 → 写 `~/Library/LaunchAgents/com.qqbot.dsh-web.plist` 并 `launchctl load`。

### NapCat（macOS）

官方安装器：https://github.com/NapNeko/NapCat-Mac-Installer/releases/latest
装完同样把 OneBot11 反向 WS 指到 `ws://127.0.0.1:6700`。

### 验证

```bash
node -v && dsh --version
ls -l ~/.dsh/plugins/
lsof -nP -iTCP:6700 -sTCP:LISTEN
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8798/login     # 200
launchctl list | grep qqbot
```

### 失败怎么办

| 现象 | 处理 |
|---|---|
| 没有 brew | 装 Homebrew（官网一行命令）或自己装 Node ≥20 后重跑 |
| `launchctl load` 报错 | 先 `launchctl unload` 旧 plist；看 `~/Library/LaunchAgents` 是否写进去了 |
| Apple Silicon 上 NapCat 不稳 | 官方 Mac 安装器可用，但 QQ 客户端在 arm64 上跑机器人的稳定性没验证；不行就换 Docker 或 Linux 机器 |

---

## 6. 收尾：网页向导（三平台都一样）

宿主起来后，浏览器打开：

```
http://127.0.0.1:8798/setup
```

四步：设管理员密码 → 填白名单（私聊填你自己的 QQ；群不要就留空）→
系统配置（GitHub token / git 身份 / 工作区，可跳过）→ 扫码登录 QQ。
填完白名单要重启宿主：
- Linux：`systemctl --user restart dsh-web.service`
- macOS：`launchctl kickstart -k gui/$(id -u)/com.qqbot.dsh-web`
- Windows：`schtasks /End /TN qqbot-dsh-web & schtasks /Run /TN qqbot-dsh-web`

---

## 7. 端到端验收清单（必须四条全过）

1. `6700` 在监听（桥接）；NapCat 的 OneBot11 指向它就是"机器人上线"
2. `http://127.0.0.1:8798/login` 返回 200，`/setup` 能打开
3. `/setup` 四步走完：密码有了、白名单里能看到你的 QQ、扫码完成
4. 用白名单里的号私聊机器人说一句话，**10 秒内**有回复。群里要 @ 它

前三条不过 → 看第 3/4/5 节的"失败怎么办"；第 4 条不过 → 按这个顺序查：
白名单是否为空 → 白名单改完有没有重启宿主 → NapCat 是否真在线（控制台状态台）→
宿主日志里有没有 `import-error`（`journalctl --user -u dsh-web -n 100`）。

---

## 8. 回退与卸载

```bash
# Linux
systemctl --user disable --now dsh-web.service qq-acl-console.service
rm -f ~/.config/systemd/user/{dsh-web,qq-acl-console}.service ~/.config/dsh-bot/dsh.env
rm -f ~/.dsh/plugins/* ~/.dsh/profiles/web/node_modules/dsh-qq-onebot-bridge
npm uninstall -g @deepseek-ai/dsh
```
```powershell
# Windows
schtasks /Delete /TN qqbot-dsh-web /F
Remove-Item "$env:USERPROFILE\.dsh\plugins" -Recurse -Force
Remove-Item "$env:USERPROFILE\.dsh\profiles\web\node_modules\dsh-qq-onebot-bridge" -Recurse -Force
npm uninstall -g @deepseek-ai/dsh
```
数据不会自己消失：会话/配置在数据根（默认 `~/qqbot`）与 `~/.dsh`，要清就手动删。

---

## 9. 已知限制（写在前面，免得到时候怪文档）

- 源码仓库（dsh-qq-onebot-bridge / dsh-plugins）都是**公开**的，`git clone` 不需要账号；后面若要私有化，改用 `--src-archive` 随包源码。
- **NapCat 的官方安装器是交互式的**（选安装方式、扫码登录），这三条路都做不到无人值守 ——
  这是唯一必须人工的一步，绕不过去。
- Windows 的 `install-host.ps1` 是在 Linux 上写的，**没有 Windows 机器实测过**；
  每一步都配了验证命令，卡住按第 4 节的表处理，或者把报错贴出来。
- 宿主模式没有容器版那种"改一行 tag 就升级"的体验：
  升级 = `npm i -g @deepseek-ai/dsh` + `git -C ~/qqbot/src/... pull` + 重启服务。
- Linux 的免登录自启要一次 `sudo loginctl enable-linger <用户>`，这一步必须用户自己来。
- macOS 上 QQ 客户端（NapCat）的稳定性不如 Linux；跑机器人建议 Linux 或 Docker。
