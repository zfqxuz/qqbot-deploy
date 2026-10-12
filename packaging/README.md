# 发布版安装器（packaging/）

给"不想 git clone、只想要个安装包"的人。四种产物**内容一样**：把部署包装到固定位置，
再给三个命令/快捷方式：

```
qqbot-install     开始安装（分层：已有 Node/dsh 不重装；--check 只体检）
qqbot-update      更新
qqbot-uninstall   卸载（默认保留数据；--purge 才删）
```

安装包**只放文件**：不起服务、不写数据、不需要管理员（Windows 装到用户目录）。
这是包管理器的惯例 —— 装什么、什么时候装，由用户显式发起。

| 平台 | 产物 | 怎么构建 | 备注 |
|---|---|---|---|
| Debian/Ubuntu | `qqbot-deploy_<版本>_all.deb` | `bash packaging/linux/build-deb.sh <版本> dist` | 本机已实测（解包后 `qqbot-install --check` 可跑） |
| Fedora/RHEL | `qqbot-deploy-<版本>-1.*.noarch.rpm` | `bash packaging/linux/build-rpm.sh <版本> dist` | 需要 `rpmbuild`（`apt install rpm`） |
| Windows | `qqbot-deploy-<版本>-setup.exe` | `ISCC.exe packaging\windows\qqbot.iss /DAppVersion=<版本>`（需先把部署包拷进 `packaging\windows\payload\`） | 只写了 .iss；**没在 Windows 上实测过**，需要 Inno Setup 6 |
| macOS | `qqbot-deploy-<版本>.pkg` | `bash packaging/macos/build-pkg.sh <版本> dist` | 只能在 macOS 上跑（`pkgbuild` 自带） |

## CI 怎么跑

`.github/workflows/release.yml` **只在公开的部署包仓库里生效**（`zfqxuz/qqbot-deploy`）。
本仓库（dshbot-ops）里这份文件放在 `deploy/qqbot/.github/` 下，GitHub 不会当成工作流；
`publish-deploy-repo.sh` 同步时会把它放到公开仓库根目录，那时才是真的 CI。

触发方式：

```bash
git tag v0.7.3 && git push --tags        # 或在公开仓库 Actions 页手动 Run（填版本号）
```

四个产物挂到公开仓库的 Release 上。

## 未签名（重要）

`.exe` 与 `.pkg` 都没做代码签名/公证：Windows 会弹"未知发布者"（更多信息 → 仍要运行），
macOS 首次打开要右键打开或 `xattr -d com.apple.quarantine <文件>`。要消除提示就得买证书
（Windows 代码签名证书 / Apple Developer 账号做 notarization），这是钱与流程的事，不是代码的事。

## 与其它渠道的关系

| 渠道 | 适合谁 |
|---|---|
| 一行安装（`get-qqbot.sh` / `get-qqbot.ps1`） | 会开终端、想最快跑起来的人（能拿到最新脚本） |
| 本目录的安装包 | 想要"下载 → 双击 → 开始菜单里点一下"的人 |
| Docker 镜像 + compose | 想要容器隔离、随系统编排的人 |
| npm 插件（`@zfqxuz/dsh-qq-onebot-bridge`） | 已经有 DSH，只缺 QQ 接入的人 |
