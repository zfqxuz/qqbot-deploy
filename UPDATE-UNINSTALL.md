# 安装 · 更新 · 卸载（用户手册）

三种部署方式各有一条完整的生命周期，**数据都与程序分离**，所以更新不动数据、卸载默认也留数据。

| 你用的是 | 装 | 更新 | 卸 |
|---|---|---|---|
| **容器版**（Docker） | `bash install.sh` / 双击 `install.cmd`·`install.command` | `bash update.sh`（`--check` 只看有没有新版） | `bash uninstall.sh`（默认留数据） |
| **宿主版**（不用 Docker） | 一行安装，或 `bash host/install-host.sh` / Windows `install.cmd host` | `bash host/update-host.sh` / Windows `host\update-host.ps1` | `bash host/uninstall-host.sh` / Windows `host\uninstall-host.ps1` |
| **只要插件**（已装好 DSH） | `dsh plugin --profile web install @zfqxuz/dsh-qq-onebot-bridge` | `dsh plugin --profile web update @zfqxuz/dsh-qq-onebot-bridge` | `dsh plugin --profile web remove @zfqxuz/dsh-qq-onebot-bridge` |

数据在哪（更新/卸载都按这个边界走）：

```
<数据根>   默认 ~/qqbot    控制台配置、ACL 库、日志、收发的文件     ← 卸载默认保留
<DSH home> 默认 ~/.dsh     profile、插件挂载声明、会话历史、凭据   ← 卸载默认保留
<工作区>   默认 /home/<你>/dshbot（或你设的目录）                  ← 不碰
QQ 登录态  NapCat 自己的目录（.env 里的 QQ_NAPCAT_DATA）           ← 不碰
```

---

## 一、容器版

```bash
bash update.sh --check        # 查上游有没有新 tag（只读）
bash update.sh                # 按 .env 现有 tag 重拉镜像 + 原地重建（数据不动）
bash update.sh --tag v0.7.3   # 换到指定 tag（.env 先备份）
```

- 更新过程：`compose pull` → `compose up -d` → 等控制台就绪 → 打印新的 DSH 地址。
- QQ 会掉线几秒（NapCat 5 秒内自动重连）；DSH 的 token 每次重启都会变。
- 回滚：把 `.env` 里的 `QQ_TAG` 改回旧值，再 `bash update.sh`。

```bash
bash uninstall.sh             # 停容器、删容器与网络；数据/镜像/登录态都留着
bash uninstall.sh --rmi       # 连两个镜像一起删（省几个 G）
bash uninstall.sh --purge -y  # 连数据根一起删（会话/控制台配置/登录态都没了）
bash uninstall.sh --dry-run   # 只打印要执行的命令
```

不碰：部署包目录本身、`~/.dsh`、NapCat 容器与登录态（脚本会打印怎么卸它们）。

## 二、宿主版（Linux / macOS / Windows）

```bash
bash host/update-host.sh --check     # 版本对照：本地源码版本 vs npm 最新
bash host/update-host.sh             # 更新部署包 + 源码 + 插件，重新播种，重启服务
bash host/update-host.sh --tag v0.7.3    # 部署包切到某个 tag
bash host/update-host.sh --no-restart    # 只更新文件，服务你自己重启
```

Windows：

```powershell
powershell -ExecutionPolicy Bypass -File host\update-host.ps1 -Check
powershell -ExecutionPolicy Bypass -File host\update-host.ps1
```

一行安装的用户（部署包在 `~/qqbot/src/qqbot-deploy`）更新部署包本身：

```bash
curl -fsSL https://raw.githubusercontent.com/zfqxuz/qqbot-deploy/main/host/get-qqbot.sh | QQBOT_REFRESH=1 bash -s -- <原来那些参数>
```

卸载：

```bash
bash host/uninstall-host.sh --dry-run      # 先看它要删什么
bash host/uninstall-host.sh                # 真卸：停服务、删软链、移除配置声明、删源码；数据留着
bash host/uninstall-host.sh --keep-sources # 源码也留着
bash host/uninstall-host.sh --purge -y     # 连数据根一起删
bash host/uninstall-host.sh --no-services  # 不动 systemd/launchd（手工起服务时用）
bash host/uninstall-host.sh --data-root <目录> --dsh-home <目录>   # 显式指定（脚本不信任环境变量）
```

它会：停用并删除 systemd/launchd 单元或计划任务 → 删掉 DSH home 里**指向本部署源码**的软链
（其它软链不碰）→ 从 profile 配置里移除桥接挂载块（**改前备份**成 `*.bak-uninstall-<时间>`）→
删环境文件与启动器 → 删源码。**数据根默认保留**，`--purge` 才删（还要过"像不像数据根"的护栏）。

不碰：Node、dsh（npm 全局）、NapCat、DSH home 本身。

## 三、只要插件（已有 DSH）

```bash
dsh plugin --profile web outdated                              # 有没有新版
dsh plugin --profile web update @zfqxuz/dsh-qq-onebot-bridge   # 更新
dsh plugin --profile web remove @zfqxuz/dsh-qq-onebot-bridge   # 卸载（插件是独立 bundle，随时可移除）
```

从源码目录装的（`dsh plugin --profile web install <源码目录>`）：更新就是
`git -C <源码目录> pull && dsh plugin --profile web update`；卸载用上面的 `remove`，
再删掉当初建的软链即可。

## 四、备份（强烈建议）

```bash
bash backup.sh                 # 打包数据根 + DSH home（不含 sessions）+ .env → ./backups/
bash restore.sh backups/qqbot-backup-<时间戳>   # 恢复
```

- 备份包含 `.env` 与凭据 → `backups/` 已在 `.gitignore` 里，**别提交**。
- 想定时备份：`crontab -e` 加一行 `0 4 * * * cd <部署包> && bash backup.sh`（保留策略自己定）。

## 五、维护者：发一版要动哪三处

1. **插件（npm）**：改版本 → CHANGELOG 一节 → `npm publish`（闸门 `prepublishOnly` 会跑测试与隐私扫描）。
2. **镜像**：`.env` 改 `QQ_TAG` → `bash build.sh --multiarch`（推 amd64+arm64 清单）。
3. **部署包**：`bash ~/dshbot/dist/publish-deploy-repo.sh`（把 `deploy/qqbot` 同步到公开仓库
   `zfqxuz/qqbot-deploy` 并推送）。**改过 `host/` 下任何文件都必须做这一步**，否则用户的一行安装拉到旧包。

顺序建议：先发部署包（脚本先能用），再发镜像与 npm（用户 `update.sh` 才拉得到新镜像）。
细节见插件仓库的 `PUBLISHING.md`。
