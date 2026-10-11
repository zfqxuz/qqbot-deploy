# QQ 机器人 · Docker 一键部署

把「QQ 协议端 + DeepSeek Harness 宿主（含 QQ 桥接）+ 控制台」跑成三个容器。
**两条命令起栈，四步开始对话**（设密码 → 填白名单 → 重启宿主 → 扫码登录）。

- 不需要源码、不需要编译：镜像已预构建，公开可拉（免登录）
- 你的数据、配置、工作区都在**你自己的目录**里；镜像里没有你的任何东西
- 升级 = 改一行版本号 + `pull && up -d`：配置、会话、工作区都不动

```
napcat（QQ 协议端）──反向 WS 6700──▶ harness（DSH 宿主 + QQ 桥接插件）◀──控制台 8798
                                        └─ DSH WebUI 3081
```

---

## 30 秒开始

```bash
cp .env.example .env      # 只需要改一项：QQ_ACCOUNT=你的QQ号
bash install.sh           # 补全路径 → 拉镜像 → 起栈 → 等就绪 → 打印下一步
```

起好之后（脚本会再打印一遍）：

| 步骤 | 做什么 | 在哪 |
|---|---|---|
| 1 | 设置控制台管理员密码 | http://127.0.0.1:8798/login |
| 2 | 「机器人身份」页：私聊白名单填你自己的 QQ，群白名单填要服务的群，保存 | 控制台左侧 |
| 3 | 让配置生效 | `docker compose restart harness` |
| 4 | 扫码登录 QQ（首次要手机确认） | 控制台「状态台」 |

> 白名单留空 = **谁都不回**。这是防呆默认：先填你自己的号，再决定开放哪些群。

---

## 需要什么

| 项目 | 要求 |
|---|---|
| Docker | Docker Engine 20.10+ 或 Docker Desktop（Compose v2：`docker compose version` 有输出） |
| 内存 | 建议 ≥ 2GB 可用（NapCat 里的 QQ 客户端是大头，约 0.7~1.5GB） |
| 磁盘 | ≥ 2GB（镜像 ~1.9GB，加数据留 2~3GB） |
| 端口 | 3081（DSH）、6700（桥接）、8798（控制台）、6099（NapCat WebUI）——被占用就在 `.env` 里改 |
| 其他 | 一个能登录的 QQ 号；首次登录需要手机确认；出网能连 QQ |

---

## 首次使用（每一步在点什么）

**1) 设控制台密码**
控制台是唯一的管理入口（改白名单、看日志、扫码、改插件配置），所以第一件事是给它设个密码。
密码用 scrypt 加盐存放，会话是 HttpOnly Cookie；控制台只绑 127.0.0.1，不对外网监听。

**2) 填「机器人身份」**
- 私聊白名单：允许和机器人私聊的 QQ 号（先填你自己的）
- 群白名单：允许机器人服务的群号（不需要就留空）
- 角色：`owner` = 你的私人助理（可读写文件、跑命令）；`guest` = 群里的人（默认只读）。
  整群升级成 owner 等于**群里每个人都有主人的权限**，只给完全信任的群。
- 保存后配置写进你自己的 DSH home，**升级镜像不会覆盖它**。

**3) 重启宿主**
白名单/角色是宿主启动时读的，保存后执行：

```bash
docker compose restart harness      # 约 3~5 秒
```

**4) 扫码登录 QQ**
控制台「状态台」里点 NapCat 的 WebUI 入口扫码。登录态存在数据根里（`napcat-data/`），
以后重启不用重扫；**换机器要把这个目录一起带走**。

---

## 日常操作

| 目的 | 命令 |
|---|---|
| 看容器状态 | `docker compose ps` |
| 看宿主日志（含 QQ 桥接） | `docker compose logs -f harness` |
| 看 QQ 协议端日志 | `docker compose logs -f napcat` |
| 只看桥接错误 | `docker compose logs --tail=100 harness \| grep -E "import-error\|失败"` |
| 重启宿主（改完配置） | `docker compose restart harness` |
| 停机（数据不动） | `docker compose down` |
| 备份 / 恢复 | `bash backup.sh` / `bash restore.sh <备份目录>` |
| 升级镜像 | `.env` 改 `QQ_TAG` → `docker compose pull` → `docker compose up -d` |
| 彻底卸载 | `docker compose down` 后删掉数据根、DSH home、工作区三个目录和两个镜像 |

---

## 数据在哪、隐私

| 目录（默认） | 装什么 | 换机器/升级 |
|---|---|---|
| `~/qqbot`（数据根） | 会话记录、日志、状态、ACL 库、媒体、NapCat 登录态 | 要带走 |
| `~/.dsh`（DSH home） | profile 配置、插件、凭据（模型 API key） | 要带走 |
| `~/qqbot/workspace`（工作区） | 你在里面写的代码/文件；**首启为空** | 要带走 |

- 三个目录都是**宿主目录挂进容器**：容器重建、换镜像、升级都不会动它们
- **镜像里没有任何配置、凭据和个人数据**，每次起容器只做两件事：补缺失的配置项（不覆盖已有值）、修软链
- `.env` 里有你的 QQ 号和 uid，**不要提交到 git、不要外发**；备份包里也含 `.env`，注意保管
- 模型 API key 放在 `~/.dsh/.credentials.yaml`（容器不打印、日志里也会脱敏）

---

## Windows / macOS（Docker Desktop）

Docker Desktop 跑的是 Linux 容器，镜像同一批（amd64/arm64 都有）。网络两条路，选一条：

**1. 打开 host networking（推荐，和 Linux 行为一致）**
Docker Desktop 4.34+ → Settings → Resources → Network → 勾 *Enable host networking* → Apply & restart。
然后照 Linux 那套来，NapCat 的反向 WS `ws://127.0.0.1:6700` 不用改。

**2. 走桥接网络（不开那个开关）**

```bash
bash install.sh --desktop
```
两个差异要知道：NapCat 的反向 WS 目标要改成 `ws://harness:6700`（compose 服务名，在 NapCat WebUI 的 OneBot 配置里改一次）；
控制台的探活已自动指向服务名。Windows 侧访问就是 `localhost:8798` / `localhost:3081` / `localhost:6099`。

建议把栈跑在 WSL2 发行版里（打开 Docker Desktop 的 WSL integration），路径和本文档完全一致。
arm64（Apple Silicon / ARM Windows）不需要模拟，但 QQ 官方 Linux 客户端在 arm64 上的稳定性没验证过。

---

## 开发者模式（可选）

```bash
QQ_DEV_MOUNT=1 bash install.sh          # 或者
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d
```

它把宿主开发环境按原路径接进容器：源码仓库（只读）、`~/.config/gh`、`~/.ssh`（只读）、
`~/.gitconfig`（只读）、`/var/run/docker.sock`。于是容器里可以直接 `gh repo view`、`git push`、
`docker ps/logs/build`、改源码后 `docker compose restart harness` 生效。

代价（别忽略）：挂 docker.sock ≈ 给这个容器宿主机 root 级能力；gh/ssh 凭据对容器内所有进程
（包括模型驱动的工具调用）可见。只在你自己信任的机器上开；不需要就用默认的普通模式。

不开发、只是部署的用户**不需要**这个模式，也不需要源码仓库。
## 排查

**容器都在跑，但 QQ 不回**
1. 白名单是不是空的？（空 = 谁都不回）
2. 填完白名单重启过 harness 吗：`docker compose restart harness`
3. 扫码登录完成了吗（控制台状态台看 NapCat 是否在线）
4. `docker compose logs --tail=100 harness` 看有没有 `import-error`

**6700 没有监听 / 桥接没起来**
`docker compose logs --tail=200 harness | grep -E "import-error|桥接"`。
出现 `Cannot find package` 说明镜像里的依赖不完整（旧镜像有这个坑，升级到 `QQ_TAG=v0.7.0` 及以上即可）。

**控制台打不开（8798）**
`docker compose ps` 看 console 是否在跑；`docker compose logs console` 看报错；
端口被占就在 `.env` 改 `QQ_CONSOLE_PORT` 后 `docker compose up -d`。

**端口被占用**
改 `.env` 里的 `QQ_DSH_PORT` / `QQ_CONSOLE_PORT`；6700 是 NapCat 写死的反连目标，
要改得同时改 NapCat 的 OneBot 配置（不推荐，留给懂的人）。

**内存不足（容器被杀）**
`dmesg | grep -i oom` 有记录就是 OOM。至少要给 1.5~2GB 可用内存；或把 NapCat 挪到另一台机器。

**代理**
`UPSTREAM_PROXY` 留空 = 直连；填了就由 entrypoint 探活决定用不用，不可用会自动摘掉代理直连启动。

**从 systemd 老部署搬过来**
`bash install.sh --legacy-compat`（把老配置里的宿主绝对路径按原样再挂一遍），
老部署的开关机单元与容器二选一，别同时跑。

---

## 版本

- 当前：`QQ_TAG=v0.7.0`（桥接 0.7.0；配置项、控制台「机器人身份」页、路径可配、首启只补缺）
- 镜像：`.env` 里的 `QQ_HARNESS_IMAGE` / `QQ_CONSOLE_IMAGE`（默认指向公开的预构建仓库，可覆盖成自己的）
- 想自己构建镜像：需要两个源码仓库，`QQ_BRIDGE_REPO` / `QQ_PLUGINS_REPO` 指过去后 `./build.sh`
  （开发期热更挂载：`docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d`）
