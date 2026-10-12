# QQ 机器人 · Docker 部署

把「QQ 协议端 + DeepSeek Harness 宿主（含 QQ 桥接）+ 控制台」跑成容器。
装的时候只回答问题，装完按网页向导点几下，就能在 QQ 里和它说话。

- 不需要源码、不需要编译：镜像已预构建，公开可拉（免登录）
- 你的数据、配置、工作区都在**你自己的目录**里，镜像里没有你的任何东西
- 升级 = 改一行版本号 + `pull && up -d`：配置、会话、工作区都不动

```
napcat（QQ 协议端）──反向 WS 6700──▶ harness（DSH 宿主 + QQ 桥接）◀──控制台 8798
                                        └─ DSH WebUI 3081
```

---

## 30 秒开始

```bash
bash install.sh            # 一键：先体检机器，只问一句"机器人用哪个 QQ 号"
```

装完它会打印一个网页向导地址（`http://127.0.0.1:8798/setup`），密码、白名单、扫码在网页上点完。

- Windows：**双击 `install.cmd`** · macOS：**双击 `install.command`**
  → 会在浏览器里打开"安装向导"页面：左边是这台机器的体检表，右边点选你要什么，点「开始安装」看日志
- Linux：想每一步自己选就用 `bash install.sh --custom`（命令行向导），要页面版就 `bash install.sh --wizard`
- 只想看看这台机器现在什么情况：`bash install.sh --check`（什么都不改）

**装完要更新 / 想卸载？** 看 [UPDATE-UNINSTALL.md](UPDATE-UNINSTALL.md)（三种部署方式各自的更新与卸载命令、数据边界、备份）。

**没有 Docker？** 一行装（Linux/macOS）：

```bash
curl -fsSL https://raw.githubusercontent.com/zfqxuz/qqbot-deploy/main/host/get-qqbot.sh | bash -s -- --qq <机器人QQ号>
```

Windows 见 [HOST-INSTALL.md](HOST-INSTALL.md)（PowerShell 一行，或 `install.cmd host` 双击）。

（不需要手动 `cp .env.example .env`，脚本会自己生成并填好。）

---

## 不想装 Docker？（Linux / Windows / macOS 都支持）

机器人不是必须用 Docker —— 容器只是我们选的打包方式。不用 Docker 的安装是同一套东西换成本机进程：
`npm` 装 dsh、桥接与插件软链进 DSH home、NapCat 用官方安装方式、自启用
systemd --user（Linux）/ 计划任务（Windows）/ launchd（macOS）。

```bash
bash host/install-host.sh --check        # 只体检，什么都不改
bash host/install-host.sh --qq 你的QQ号    # Linux / macOS 一键
```

```powershell
powershell -ExecutionPolicy Bypass -File host\install-host.ps1 -Check
powershell -ExecutionPolicy Bypass -File host\install-host.ps1 -QQ 你的QQ号   # Windows
```

**分步顺序、每步的验证命令、失败处理、回退办法**都在 [HOST-INSTALL.md](HOST-INSTALL.md)，
照着做、或者交给 agent 执行都行。三点先说清：

- 源码仓库都是公开的，`git clone` 不需要账号
- NapCat 官方安装器是交互式的（选安装方式 + 扫码登录），这一步必须人工，三个系统都一样
- Windows / macOS 是"半自动"：装 Node、拉源码、接线、自启都自动；NapCat 要你自己点
- 宿主模式升级 = `npm i -g @deepseek-ai/dsh` + `git pull` + 重启服务，没有容器那种"改一行 tag"

---

## 需要什么

| 项目 | 要求 |
|---|---|
| Docker | Docker Engine 20.10+ 或 Docker Desktop（Compose v2：`docker compose version` 有输出） |
| 内存 | 建议 ≥ 2GB 可用（NapCat 里的 QQ 客户端是大头，约 0.7~1.5GB） |
| 磁盘 | ≥ 2GB（镜像约 1.9GB，加数据留 2~3GB） |
| 端口 | 3081 DSH / 8798 控制台 / 6700 桥接 / 6099 NapCat WebUI —— **被占用会自动换一个空闲的** |
| 端口谁记住 | 不用你记：控制台自己发现宿主端口（环境变量 → 运行中的 harness 容器 → 控制台配置 → 运行中的进程 → 启动器登记的地址 → 日志）。桥接和 DSH 是解耦的，插件只认 6700 |
| 其他 | 一个能登录的 QQ 号（建议小号，见下）；首次登录需要手机确认 |

**关于"用哪个 QQ 号"**：机器人登录用的是独立的小号。桌面 QQ 和 NapCat 在 QQ 眼里都是"电脑端"，
同一个号同时在线会互相踢下线；安装脚本检测到你桌面登录过的号时会提醒，但不会替你决定。

---

## 一键安装：它到底做了什么

`bash install.sh` 先体检（只读），打印一张表：

```
  系统      Linux/WSL2 · x86_64 · Docker 29.1.3 · Compose 2.40.3
  资源      内存 15.5GB（可用 13.4GB）· 目标盘可用 926G
  端口      DSH 3081→3082（被占用）· 控制台 8798→8799（被占用）· 桥接 6700 · NapCat 6099
  协议端在用的号  2267595782
  桌面 QQ 登录过   2493922172（只作提示）
  已有协议端  napcat 容器在跑（healthy）→ 可以直接复用，不装新镜像
  旧部署      dsh-web.service qq-acl-console.service（和容器二选一）
  选装        git 2.43 · gh 已登录 · 代理 127.0.0.1:10808（探活可用）
```

然后：

1. 只问一句：**机器人用哪个 QQ 号**（检测到了就直接用，并注明这个号是从哪来的）
2. 自动填 `.env`、建目录并**实测可写**、探测 docker 组、拉镜像、起栈、等就绪
3. 打印自检表 + 网页向导地址

选 `reuse`（复用已有协议端）或 `none`（先不接 QQ）时不用填号，也不会拉 NapCat 镜像。

---

## 自定义安装：6 步向导

`bash install.sh --custom`，每步回车 = 用检测到的默认值：

| 步骤 | 选择 | 默认 |
|---|---|---|
| 1 | QQ 怎么接：**自带协议端容器** / **复用本机已有的** / **先不接 QQ** | 已有协议端就默认复用 |
| 2 | 宿主端口,控制台端口 | 自动挑空闲的 |
| 3 | 数据根（会话/配置/登录态） | `~/qqbot` |
| 4 | 工作区（助手写代码的地方，必须可写） | `<数据根>/workspace` |
| 5 | 开发者模式（源码可写 + 容器里能用 docker） | 关（会提示代价） |
| 6 | 上游代理 / 时区 | 探测到的代理 |

---

## 装完：网页向导（4 件事）

打开 `http://127.0.0.1:8798/setup`，一屏一件事，每件都能**先跳过**：

1. **设控制台管理员密码**（控制台只绑 127.0.0.1，密码用 scrypt 加盐存）
2. **填白名单**：私聊填你自己的 QQ（默认已帮你填好检测到的号）；群白名单不需要就留空。
   留空 = **谁都不回**，这是防呆默认
3. **系统配置**（选装）：GitHub token（要 `gh` / `git push` 才需要，只写不读、页面只显示掩码）、
   git 用户名/邮箱、工作区（页面会实测可写）
4. **扫码登录 QQ**（自己带协议端时；首次要手机确认）

> 白名单、token 这类东西**不在安装阶段填**：命令行参数会进 shell 历史和进程列表，
> 控制台里填是"只写不读 + 掩码显示"。所以安装脚本只做不需要保密的决定。

---

## 之后改配置在哪

| 想改什么 | 去哪 |
|---|---|
| 插件的开关与参数、装/卸插件 | 控制台「插件」页 |
| GitHub token、git 身份、工作区 | 控制台「系统配置」页 |
| 私聊/群白名单、角色、botQq | 控制台「机器人身份」页 |
| 扫码登录、看端口/容器/代理状态 | 控制台「状态台」 |
| 重启宿主、看日志、看看门狗记录 | 控制台「服务」页 |
| 端口、路径、代理、时区 | `install.sh --custom`（改完 `--repair`） |

插件是随镜像发布的功能件（跟 `QQ_TAG` 走），所以**安装阶段不勾选插件**：
装完在「插件」页里看说明、看参数，那时候判断才有信息。

---

## 日常命令

| 目的 | 命令 |
|---|---|
| 看容器状态 | `docker compose ps` |
| 看宿主日志（含 QQ 桥接） | `docker compose logs -f harness` |
| 看协议端日志 | `docker compose logs -f napcat` |
| 重启宿主（改完必须重启的配置） | `docker compose restart harness` |
| 改完 `.env` / 换挂载后原地重装 | `bash install.sh --repair` |
| 停机（数据不动） | `docker compose down` |
| 备份 / 恢复 | `bash backup.sh` / `bash restore.sh <备份目录>` |
| 升级镜像 | `.env` 改 `QQ_TAG` → `docker compose pull` → `docker compose up -d` |
| 体检 / 重新向导 | `bash install.sh --check` / `bash install.sh --custom` |
| 彻底卸载 | `docker compose down` 后删数据根、DSH home、工作区三个目录和镜像 |

---

## 数据在哪、隐私

| 目录（默认） | 装什么 | 换机器/升级 |
|---|---|---|
| `~/qqbot`（数据根） | 会话记录、日志、状态、ACL 库、媒体、NapCat 登录态 | 要带走 |
| `~/.dsh`（DSH home） | profile 配置、插件、凭据（模型 API key） | 要带走 |
| `~/qqbot/workspace`（工作区） | 你在里面写的代码/文件；首启为空 | 要带走 |
| `~/qqbot/.gitconfig`、`~/qqbot/.config/gh/` | 控制台渲染出来的 git 身份与 gh 凭据（0600） | 要带走 |

- 三个目录都是**宿主目录挂进容器**：容器重建、换镜像、升级都不会动它们
- 镜像里没有任何配置、凭据和个人数据；每次起容器只做两件事：补缺失的配置项（不覆盖已有值）、修软链
- `.env` 里有你的 QQ 号和 uid，**不要提交到 git、不要外发**；备份包里也含 `.env`
- 模型 API key 放在 `~/.dsh/.credentials.yaml`（容器不打印、日志脱敏）

---

## Windows / macOS（Docker Desktop）

镜像是同一批（amd64 / arm64 都有），入口就是"双击"：

- **Windows**：双击 `install.cmd`（通过 WSL 跑，需要 Docker Desktop 的 WSL integration）
- **macOS**：双击 `install.command`（首次可能要右键 → 打开）

双击之后会在浏览器里打开**安装向导**（`http://127.0.0.1:8790` 附近，页面里会显示地址）：

| 页面上的部分 | 内容 |
|---|---|
| 机器体检 | 系统 / 资源 / 端口占用（连占用者是谁）/ 检测到的 QQ 号 / 已有协议端 / 旧部署 / git·gh·代理 |
| ① QQ 怎么接 | 自带协议端容器（默认）· 复用本机已有的 · 先不接 |
| ② 端口 | 预填自动挑好的空闲端口，可改 |
| ③ 数据放哪 | 数据根 / 工作区 |
| ④ 其他 | 代理、时区、开发者模式（带代价说明） |
| ⑤ 确认 | 显示将要执行的命令 → 「开始安装」→ 实时日志 → 装完给「打开网页向导」的按钮 |

向导只是个页面，真正干活的是 `install.sh`（页面把选择拼成 `install.sh --yes ...` 再跑），
所以**页面版和命令行版行为完全一致**，出问题也能直接看日志重跑。

没有 python3 的机器（少数精简发行版）会自动退回命令行向导：`bash install.sh --custom`。
远程服务器上想用页面版也可以：`bash install.sh --wizard --bind 0.0.0.0`（注意：那等于把这个页面暴露到局域网）。

网络两条路，选一条：

**1. 打开 host networking（推荐，和 Linux 行为一致）**
Docker Desktop 4.34+ → Settings → Resources → Network → 勾 *Enable host networking* → Apply & restart。
然后 NapCat 的反向 WS `ws://127.0.0.1:6700` 不用改。

**2. 走桥接网络（不开那个开关）**：`bash install.sh --desktop`
两个差异：NapCat 的反向 WS 要改成 `ws://harness:6700`（在 NapCat WebUI 的 OneBot 配置里改一次）；
控制台的探活已自动指向服务名。Windows 侧访问 `localhost:8798` / `localhost:3081` / `localhost:6099`。

建议把栈跑在 WSL2 发行版里（打开 Docker Desktop 的 WSL integration），路径和本文档一致。
arm64（Apple Silicon / ARM Windows）不需要模拟，但 QQ 官方 Linux 客户端在 arm64 上的稳定性没验证过。

---

## 高手：参数与自动化

```bash
bash install.sh --check                       # 只体检
bash install.sh --json                        # 体检结果 JSON（给向导/自动化）
bash install.sh --wizard                      # 浏览器版选择向导（本机 8790 起页面）
bash install.sh --dry-run                     # 体检 + 生成 .env，不起栈
bash install.sh --yes --mode napcat --qq 123456 --ports 3081,8798
bash install.sh --mode reuse                  # 复用本机已有协议端（不拉 NapCat 镜像）
bash install.sh --mode none                   # 只起 DSH + 控制台
bash install.sh --no-proxy --tz Asia/Shanghai --dev
bash install.sh --data-root /srv/qq --workspace /srv/qq/ws
bash install.sh --repair                      # 按当前运行组合原地重建
bash install.sh --legacy-compat               # 从 systemd 老部署迁移
```

没有终端（CI、管道、双击）时自动按 `--yes` 跑：一句话都不问。
完整参数表见 `bash install.sh --help`。

---

## 排查

**容器都在跑，但 QQ 不回**
1. 白名单是不是空的（空 = 谁都不回）：控制台「机器人身份」页
2. 填完白名单重启过 harness 吗：`docker compose restart harness`
3. 扫码登录完成了吗：控制台「状态台」看 NapCat 是否在线
4. `docker compose logs --tail=100 harness` 看有没有 `import-error`

**6700 没有监听 / 桥接没起来**
`docker compose logs --tail=200 harness | grep -E "import-error|桥接"`。
出现 `Cannot find package` 说明镜像依赖不完整（升级到 `QQ_TAG=v0.7.0` 及以上）。

**控制台打不开（8798）**
`docker compose ps` 看 console 是否在跑；端口被占就 `bash install.sh --custom` 改端口后 `--repair`。

**端口被占用**
一键安装会自动换空闲端口并打印出来（`DSH 3081→3082`）。6700 是 NapCat 写死的反连目标，
要改得同时改 NapCat 的 OneBot 配置（不推荐）。

**内存不足（容器被杀）**
`dmesg | grep -i oom` 有记录就是 OOM。至少给 1.5~2GB 可用内存。

**代理**
`UPSTREAM_PROXY` 留空 = 直连；填了就由 entrypoint 探活决定用不用，不可用会自动摘掉代理直连启动。
控制台「状态台」显示的是**宿主进程实际用的**（不是配置文件里的旧值）。

**从 systemd 老部署搬过来**
`bash install.sh --legacy-compat`（老配置里的宿主绝对路径按原样再挂一遍），
老部署的开关机单元与容器二选一，别同时跑。

---

## 版本

- 当前：`QQ_TAG=v0.7.3`
  - 会话写权不再互相踢：宿主与容器共用一份 DSH home 时，冲突消息**收下、排队、拿到锁后按序补跑**；
    托管权心跳选主（host > desktop > container），宿主 dsh 在跑时容器自动待机，宿主退出后接管
  - 安装体验：一键 / 向导两档，先体检再决定，端口与 QQ 号自动识别，网页向导做完收尾配置
  - 镜像内补 `pnpm`：容器里可以直接用官方的 `dsh plugin --profile web ...` 装卸插件
- 上一版：`v0.7.2`（宿主端口彻底自描述）
- 更早：`v0.7.1`（系统配置归控制台）、`v0.7.0`（容器内自带 gh + docker 客户端；「机器人身份」页；首启只补缺不覆盖）
- 镜像：`.env` 里的 `QQ_HARNESS_IMAGE` / `QQ_CONSOLE_IMAGE`（默认指向公开的预构建仓库，可覆盖）
- 想自己构建镜像：需要两个源码仓库，`QQ_BRIDGE_REPO` / `QQ_PLUGINS_REPO` 指过去后 `./build.sh`
