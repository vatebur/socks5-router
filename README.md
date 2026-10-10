# socks5-router

轻量 SOCKS5 部署与分流管理工具，基于 Xray，提供中文交互菜单。入站与出站可分别配置，按需组合直连、域名分流或全局代理。

## 功能

- **灵活部署**：入站、出站分别安装、修改和卸载，支持独立代理或组合转发。
- **入站管理**：用户名密码认证、自动生成账号与空闲端口、来源 IP / CIDR 白名单。
- **出站分流**：支持入站流量全部直连、按域名分流或全部通过 SOCKS5 出站。
- **日常维护**：查看配置、连接检查、服务管理、日志和完整卸载；错误使用红色提示。
- **可靠更新**：跟随 Xray 官方 Latest 稳定版，校验 SHA256；配置或核心更新失败时支持回滚。

支持 systemd Linux、x86_64 / arm64；代理流量使用 SOCKS5 TCP CONNECT。

## 安装

在服务器终端执行，安装器校验最新稳定版安装包后打开菜单：

```bash
socks5_installer=$(mktemp) && curl -fsSL https://raw.githubusercontent.com/vatebur/socks5-router/main/install.sh -o "$socks5_installer" && sudo bash "$socks5_installer"; rm -f -- "$socks5_installer"
```

选择 `1. SOCKS5 部署（入站 / 出站）`，按需安装入站、出站。依赖会自动补齐；手动安装和离线安装见[安装说明](docs/installation.md)。

## 使用

再次打开管理菜单：

```bash
sudo socks5-router
```

- **入站**：设置本机接收连接的账号、端口和来源白名单；客户端填写入站连接信息。
- **出站**：设置 SOCKS5 出站连接信息，选择按域名分流或全局代理；全部直连无需配置出站。
- **维护**：通过菜单查看、修改配置，检查连接与日志，管理服务、升级或卸载。

请放行入站 TCP 端口；域名分流需在客户端开启远程 DNS / `socks5h`。仅配置出站时不监听客户端端口，也不接管本机应用流量；添加入站后才能接收代理请求。

更新管理脚本与 Xray：

```bash
sudo socks5-router upgrade
```

首次从旧版本升级请按[升级说明](docs/maintenance.md#升级)操作。

详细文档：[架构与部署组合](docs/architecture.md) · [入站、出站与分流](docs/configuration.md) · [维护与升级](docs/maintenance.md) · [开发与配置文件](docs/development.md)。更新记录见 [Releases](https://github.com/vatebur/socks5-router/releases)。

参考项目：[mack-a/v2ray-agent](https://github.com/mack-a/v2ray-agent)。
