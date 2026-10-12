# 开发与配置文件

[返回 README](../README.md) · [架构说明](architecture.md)

## 项目目录

```text
socks5-router/
├── socks5.sh                 # 管理入口、全局配置和命令分发
├── install.sh                # 独立下载入口、共用依赖及终端输出函数
├── lib/
│   ├── config.sh             # 输入校验、状态归一化、渲染及上游认证
│   ├── runtime.sh            # 运行前提、目录准备和管理程序安装
│   ├── core.sh               # Xray 下载、校验和升级
│   ├── service.sh            # systemd、配置应用与回滚、诊断
│   ├── lifecycle.sh          # 首次部署、管理程序升级和完整卸载
│   └── menu.sh               # 交互表单、组件配置和菜单
├── templates/                # Xray JSON 模板和 jq 渲染规则
├── scripts/                  # 开发及发布工具
│   └── build_release.sh
├── docs/                     # 安装、配置、架构及维护文档
├── dist/                     # 打包生成的发行产物，Git 忽略
└── README.md
```

根目录保留两个执行入口。`socks5.sh` 加载 `lib/` 模块后分发命令，模块由入口统一加载；`install.sh` 可以单独下载执行。管理程序安装和升级回滚共用入口中的 `MANAGER_FILES` 文件清单。

## 文件与 JSON 模板

| 路径 | 用途 |
| --- | --- |
| `/etc/socks5-router/state.json` | 实际配置与凭据，权限 `0600` |
| `/etc/socks5-router/config.json` | Xray 运行配置，权限 `0640` |
| `/usr/local/lib/socks5-router/socks5.sh` | Bash 管理入口 |
| `/usr/local/lib/socks5-router/install.sh` | 共用依赖检查与安装函数、GitHub 下载入口 |
| `/usr/local/lib/socks5-router/lib/config.sh` | Bash 校验、端口与认证函数 |
| `/usr/local/lib/socks5-router/lib/` | 运行环境、核心、服务、生命周期与菜单模块 |
| `/usr/local/lib/socks5-router/templates/` | JSON 文本模板与 jq 渲染规则 |
| `/usr/local/bin/socks5-router` | 管理入口 |
| `/etc/systemd/system/socks5-router.service` | systemd 服务 |

用户输入均作为 jq 字符串或 JSON 值处理，密码中的引号、反斜线和 `$` 不会成为脚本代码。通过菜单维护配置，避免状态文件与运行 JSON 不一致。

旧状态中的 `role` 字段保留为兼容标记，不需要在菜单中选择服务器角色；配置按入站启用状态、出站连接信息和分流模式管理。当前状态格式为 schema 2，加载 schema 1 时会归一化。

可使用已有状态文件进行校验和渲染：

```bash
bash socks5.sh validate --state /etc/socks5-router/state.json
bash socks5.sh render --state /etc/socks5-router/state.json --output /tmp/xray.json
```

这些命令不安装服务或连接出站。输出文件权限为 `0600`；省略 `--output` 会向终端显示完整 JSON 及凭据。

## 开发检查与发布打包

```bash
for file in socks5.sh install.sh lib/*.sh scripts/*.sh; do bash -n "$file" || exit 1; done
bash scripts/build_release.sh
(cd dist && sha256sum -c SHA256SUMS)
```

可使用已下载的 Xray 核心检查生成的运行配置：

```bash
bash socks5.sh render --state /etc/socks5-router/state.json --output /tmp/socks5-xray.json
/absolute/path/to/xray run -test -config /tmp/socks5-xray.json
```

发行产物写入 `dist/`；安装包解压后仍为 `socks5-router/`，包含入口脚本、全部 `lib/` 模块、模板、发布脚本、README 和 `docs/` 详细文档。`dist/` 与本地 `tests/` 不进入发行包。

功能参考：[mack-a/v2ray-agent](https://github.com/mack-a/v2ray-agent)。核心配置参考 Xray 官方 [SOCKS 入站](https://xtls.github.io/config/inbounds/socks.html)、[SOCKS 出站](https://xtls.github.io/config/outbounds/socks.html)、[路由](https://xtls.github.io/config/routing.html)。
