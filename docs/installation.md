# 安装说明

[返回 README](../README.md)

## 运行要求

- 使用 systemd 的 Linux 服务器；x86_64 / amd64 或 aarch64 / arm64。
- Bash 4+、jq 1.6+、curl、unzip、iproute / iproute2、util-linux、coreutils 和 CA 证书。
- 安装与维护需要 root；离线校验和生成 JSON 可使用普通用户。
- 系统依赖支持通过 apt、dnf、yum 安装；Xray 跟随[官方 Latest 稳定版](https://github.com/XTLS/Xray-core/releases/latest)，使用官方发布的 SHA256 校验，拒绝草稿和预发布版。

## 一键安装

在服务器的 SSH 终端执行一条命令。安装器从 GitHub 下载最新稳定版安装包和 `SHA256SUMS`，校验后打开交互菜单：

```bash
socks5_installer=$(mktemp) && curl -fsSL https://raw.githubusercontent.com/vatebur/socks5-router/main/install.sh -o "$socks5_installer" && sudo bash "$socks5_installer"; rm -f -- "$socks5_installer"
```

选择 `1. SOCKS5 部署（入站 / 出站）`，按需分别配置组件，见[配置说明](configuration.md)。安装器会拒绝缺少 Bash 模块的旧发行包。首次打开菜单即安装管理命令，暂未配置组件或核心下载失败后也可通过 `sudo socks5-router` 重新进入菜单。

## 手动安装

从 [GitHub Releases](https://github.com/vatebur/socks5-router/releases) 下载 `socks5-router.tar.gz` 和 `SHA256SUMS`，放在同一目录后执行：

```bash
sha256sum -c --ignore-missing SHA256SUMS
tar -xzf socks5-router.tar.gz
cd socks5-router
sudo bash socks5.sh
```

版本命名的安装包也可使用同一校验文件验证，解压后目录均为 `socks5-router/`。

## 依赖检查与下载

1. 一键安装器先准备 `curl`、`jq`、`tar`、SHA256 校验工具、`awk`、临时文件工具及 CA 证书。
2. 管理脚本补齐 `unzip`、`ss`、`flock`、`timeout`、coreutils、服务账号工具等运行依赖；已有可用工具直接复用。
3. 自动选择 `apt-get`、`dnf` 或 `yum`，刷新软件源后安装对应软件包。`ss` 对应 Debian/Ubuntu 的 `iproute2` 或 RPM 系统的 `iproute`；CentOS 缺少 jq 时会先准备 EPEL。
4. 安装后重新检查工具和 jq 版本，要求 jq 1.6+；软件源、下载或检查失败时停止并显示错误。

普通用户执行 `validate` / `render` 时只检查 jq。若需要自动安装，请使用 sudo。下载一键安装器本身需要服务器已有 curl；手动下载 `install.sh` 后执行 `sudo bash install.sh` 也可自动补齐 curl。

## 离线核心安装

从 [Xray 官方 Latest](https://github.com/XTLS/Xray-core/releases/latest) 下载 `Xray-linux-64.zip` 或 `Xray-linux-arm64-v8a.zip`。只提供 ZIP 时仍会联网查询 Latest 并验证 SHA256；完全离线时，还需事先保存相同版本的官方元数据：

```bash
curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest -o xray-release.json
sudo bash socks5.sh --xray-archive /path/Xray-linux-64.zip --xray-release /path/xray-release.json
```

离线安装按元数据快照选择版本和校验值；请同时保存对应的 ZIP。GitHub 元数据缺少 SHA256 时，脚本会读取官方 `.dgst` 校验文件，因此该情形仍需要联网。系统依赖需提前准备或通过软件源安装。
