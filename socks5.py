#!/usr/bin/env python3
"""Interactive Linux SOCKS5 deployment and maintenance; Python standard library only."""

import argparse
import copy
import fcntl
import getpass
import grp
import hashlib
import io
import ipaddress
import json
import os
from pathlib import Path
import platform
import pwd
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid
import zipfile
from contextlib import contextmanager

if sys.version_info < (3, 9):
    sys.exit("需要 Python 3.9 或更高版本。")

from socks5_config import (
    assert_port_available, choose_port, credential, normalize_domains,
    normalize_whitelist, parse_port, probe_upstream, render_nft,
    render_xray, validate_state,
)

VERSION = "v26.3.27"
ASSETS = {
    "x86_64": ("Xray-linux-64.zip", "23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae"),
    "aarch64": ("Xray-linux-arm64-v8a.zip", "4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c"),
}
SERVICE = "socks5-router.service"
ACCOUNT = "socks5-router"
NFT_TABLE = "socks5_router"
MODES = {"domain": "按域名分流", "direct": "跳过分流（A 直连）", "global": "全局代理（通过 B）"}


def run(args, *, data=None, check=True, timeout=30):
    """Never invoke a shell or put credentials on a command line."""
    result = subprocess.run([str(x) for x in args], input=data, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if check and result.returncode:
        detail = (result.stderr or result.stdout).strip()
        raise RuntimeError(f"命令失败（{args[0]}）：{detail}")
    return result


def atomic_write(path, data, mode=0o600, gid=None):
    path = Path(path)
    content = data.encode("utf-8") if isinstance(data, str) else data
    fd, name = tempfile.mkstemp(prefix=".new-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as file:
            file.write(content)
            file.flush()
            os.fchmod(file.fileno(), mode)
            if gid is not None:
                os.fchown(file.fileno(), -1, gid)
            os.fsync(file.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def json_text(value):
    return json.dumps(value, ensure_ascii=False, indent=2) + "\n"


def read_state(path):
    try:
        return validate_state(json.loads(Path(path).read_text(encoding="utf-8")))
    except FileNotFoundError as exc:
        raise ValueError("尚未安装，请先选择部署服务器 A 或 B。") from exc


def masked(state):
    result = copy.deepcopy(state)
    result["password"] = "********"
    if result.get("upstream"):
        result["upstream"]["password"] = "********"
    return result


def check_live_firewall(state, document):
    """Compare nft's structured rules with this manager's intended filter."""
    state = validate_state(state)
    chains, rules = [], []
    for item in document.get("nftables", []):
        if "chain" in item:
            chain = item["chain"]
            chains.append({key: chain.get(key) for key in
                           ("family", "table", "name", "type", "hook", "prio", "policy")})
        elif "rule" in item:
            rule = item["rule"]
            if (rule.get("family"), rule.get("table"), rule.get("chain")) != ("inet", NFT_TABLE, "input"):
                raise RuntimeError("发现不属于预期输入链的白名单规则。")
            rules.append(rule.get("expr"))
        elif not ("table" in item or "metainfo" in item):
            raise RuntimeError("专用防火墙表中存在非预期对象。")
    expected_chain = {"family": "inet", "table": NFT_TABLE, "name": "input",
                      "type": "filter", "hook": "input", "prio": -10, "policy": "accept"}
    expected_rules = []
    listen = ipaddress.ip_address(state["listen"])
    def destination_match():
        matches = [{"match": {"op": "==", "left": {"payload": {"protocol": "tcp", "field": "dport"}},
                              "right": state["port"]}}]
        if not listen.is_unspecified:
            matches.append({"match": {"op": "==", "left": {"payload": {
                "protocol": "ip6" if listen.version == 6 else "ip", "field": "daddr"}},
                "right": str(listen)}})
        return matches
    for source in state["whitelist"]:
        network = ipaddress.ip_network(source)
        if not listen.is_unspecified and listen.version != network.version:
            continue
        right = (str(network.network_address) if network.prefixlen == network.max_prefixlen else
                 {"prefix": {"addr": str(network.network_address), "len": network.prefixlen}})
        expected_rules.append(destination_match() + [{"match": {"op": "==", "left": {"payload": {
            "protocol": "ip6" if network.version == 6 else "ip", "field": "saddr"}}, "right": right}},
            {"return": None}])
    if state["whitelist"]:
        expected_rules.append(destination_match() + [{"drop": None}])
    if chains != [expected_chain] or rules != expected_rules:
        raise RuntimeError("内核白名单与当前配置不一致，请选择启动/重启服务重新加载。")


def require_root():
    if os.geteuid() != 0:
        raise RuntimeError("此操作需要 root，请使用 sudo bash socks5.sh。")


@contextmanager
def manager_lock():
    require_root()
    fd = os.open("/run/socks5-router.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise RuntimeError("已有另一个管理进程在运行，请先退出它。") from exc
        yield


class Manager:
    def __init__(self, root=Path("/")):
        self.root = Path(root)
        self.base = self.root / "etc/socks5-router"
        self.lib = self.root / "usr/local/lib/socks5-router"
        self.state = self.base / "state.json"
        self.config = self.base / "config.json"
        self.previous = self.base / "previous.json"
        self.binary = self.lib / "xray"
        self.unit = self.root / "etc/systemd/system" / SERVICE
        self.command = self.root / "usr/local/bin/socks5-router"

    def systemctl(self, *args, **kwargs):
        return run(["systemctl", *args], **kwargs)

    def active(self):
        return self.systemctl("is-active", "--quiet", SERVICE, check=False).returncode == 0

    def load(self):
        return read_state(self.state)

    def prerequisites(self):
        require_root()
        if platform.system() != "Linux" or not Path("/run/systemd/system").is_dir():
            raise RuntimeError("部署需要以 systemd 为 PID 1 的 Linux 服务器。")
        if platform.machine() not in ASSETS:
            raise RuntimeError("自动下载仅支持 x86_64 和 aarch64。")
        if not shutil.which("nft"):
            print("正在安装 nftables 和 CA 证书……")
            if shutil.which("apt-get"):
                run(["apt-get", "update"], timeout=600)
                run(["apt-get", "install", "-y", "nftables", "ca-certificates"], timeout=600)
            elif shutil.which("dnf") or shutil.which("yum"):
                run([shutil.which("dnf") or shutil.which("yum"), "install", "-y",
                     "nftables", "ca-certificates"], timeout=600)
            else:
                raise RuntimeError("请先手动安装 nftables 和 ca-certificates。")
        # Fail early in containers without CAP_NET_ADMIN, even when the list is empty.
        run(["nft", "list", "tables"])

    def prepare_paths(self):
        try:
            user = pwd.getpwnam(ACCOUNT)
            if user.pw_uid == 0:
                raise RuntimeError("专用服务账号意外指向 root，拒绝继续。")
        except KeyError:
            run(["useradd", "--system", "--user-group", "--no-create-home",
                 "--home-dir", "/nonexistent", "--shell", "/usr/sbin/nologin", ACCOUNT])
        gid = grp.getgrnam(ACCOUNT).gr_gid
        self.base.mkdir(parents=True, exist_ok=True)
        os.chown(self.base, 0, gid)
        self.base.chmod(0o750)
        self.lib.mkdir(parents=True, exist_ok=True)
        self.lib.chmod(0o755)
        self.unit.parent.mkdir(parents=True, exist_ok=True)
        self.command.parent.mkdir(parents=True, exist_ok=True)

    def install_binary(self, archive=None):
        name, digest = ASSETS[platform.machine()]
        if self.binary.exists():
            result = run([self.binary, "version"])
            if f"Xray {VERSION[1:]} " in result.stdout:
                return
            raise RuntimeError("已安装的核心版本与脚本不符，请先备份并检查专用安装目录。")
        if archive:
            content = Path(archive).read_bytes()
        else:
            url = f"https://github.com/XTLS/Xray-core/releases/download/{VERSION}/{name}"
            print(f"正在下载 {name}（{VERSION}），并核对固定 SHA256……", flush=True)
            request = urllib.request.Request(url, headers={"User-Agent": "socks5-router"})
            with urllib.request.urlopen(request, timeout=60) as response:
                content = response.read(150 * 1024 * 1024 + 1)
        if hashlib.sha256(content).hexdigest() != digest:
            raise RuntimeError("Xray 压缩包 SHA256 不匹配，未安装。请确认版本与 CPU 架构。")
        with zipfile.ZipFile(io.BytesIO(content)) as archive_file:
            # Extract only the known executable; never extract arbitrary archive paths.
            executable = archive_file.read("xray")
        atomic_write(self.binary, executable, 0o755)
        try:
            run([self.binary, "version"])
        except BaseException:
            self.binary.unlink()
            raise

    def install_manager(self):
        source = Path(__file__).resolve().parent
        for name in ("socks5.py", "socks5_config.py"):
            atomic_write(self.lib / name, (source / name).read_bytes(), 0o644)
        atomic_write(self.command,
                     '#!/bin/sh\nexec /usr/bin/python3 /usr/local/lib/socks5-router/socks5.py "$@"\n',
                     0o755)

    def service_text(self):
        return """[Unit]
Description=Lightweight SOCKS5 router (Xray)
Wants=network-online.target
After=network-online.target nftables.service firewalld.service ufw.service
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
User=socks5-router
Group=socks5-router
ExecStartPre=+/usr/bin/python3 /usr/local/lib/socks5-router/socks5.py _firewall
ExecStart=/usr/local/lib/socks5-router/xray run -config /etc/socks5-router/config.json
Restart=on-failure
RestartSec=3
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
"""

    def firewall(self, state):
        run(["nft", "-f", "-"], data=render_nft(state))

    def firewall_snapshot(self):
        # Listing all tables must succeed; permission errors must not masquerade as absence.
        tables = run(["nft", "list", "tables"]).stdout
        if f"table inet {NFT_TABLE}" not in tables.splitlines():
            return None
        return run(["nft", "-s", "list", "table", "inet", NFT_TABLE]).stdout

    def restore_firewall(self, saved):
        prefix = f"add table inet {NFT_TABLE}\n"
        if saved is None:
            run(["nft", "-f", "-"], data=prefix + f"delete table inet {NFT_TABLE}\n")
        else:
            run(["nft", "-f", "-"], data=prefix + f"delete table inet {NFT_TABLE}\n" + saved)

    def check_xray(self, config_path):
        run([self.binary, "run", "-test", "-config", config_path])

    def wait_started(self):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if self.active():
                time.sleep(0.6)
                if self.active():
                    return
            time.sleep(0.25)
        raise RuntimeError("服务启动后未能保持运行，请通过 journalctl -u socks5-router 检查原因。")

    def apply(self, state, *, verify_upstream=True):
        state = validate_state(state)
        old = self.load() if self.state.exists() else None
        was_active = self.active()
        if not (old and was_active and old["listen"] == state["listen"] and old["port"] == state["port"]):
            assert_port_available(state["listen"], state["port"])
        if verify_upstream and state["role"] == "A" and state["mode"] != "direct":
            print("正在核对服务器 B 的 SOCKS5 账号认证……", flush=True)
            probe_upstream(state["upstream"])
        gid = grp.getgrnam(ACCOUNT).gr_gid
        with tempfile.TemporaryDirectory(prefix=".check-", dir=self.base) as staging:
            candidate = Path(staging) / "config.json"
            atomic_write(candidate, json_text(render_xray(state)))
            self.check_xray(candidate)
        run(["nft", "-c", "-f", "-"], data=render_nft(state))
        files = (self.state, self.config, self.unit, self.previous)
        snapshots = {p: (p.read_bytes(), p.stat().st_mode & 0o777, p.stat().st_gid)
                     if p.exists() else None for p in files}
        saved_firewall = self.firewall_snapshot()
        was_enabled = self.systemctl("is-enabled", "--quiet", SERVICE, check=False).returncode == 0
        # Stop before changing ports or filters: no old listener with a new port's filter.
        # If stopping fails, leave the existing files and filter untouched.
        self.systemctl("stop", SERVICE, check=old is not None)
        try:
            atomic_write(self.state, json_text(state))
            atomic_write(self.config, json_text(render_xray(state)), 0o640, gid)
            atomic_write(self.unit, self.service_text(), 0o644)
            self.firewall(state)
            self.systemctl("daemon-reload")
            self.systemctl("enable", SERVICE)
            self.systemctl("restart", SERVICE)
            self.wait_started()
            if old is not None:
                atomic_write(self.previous, json_text(old))
        except BaseException as exc:
            failures = []
            def attempt(action):
                try:
                    action()
                except Exception as error:
                    failures.append(str(error))
            # Do not remove a new filter while a new listener might still be running.
            try:
                self.systemctl("stop", SERVICE, check=self.unit.exists())
            except Exception as stop_error:
                raise RuntimeError("应用失败且无法停止服务，已保留当前过滤规则；"
                                   f"请检查 systemd：{stop_error}") from exc
            for path, saved in snapshots.items():
                if saved is None:
                    attempt(lambda p=path: p.unlink(missing_ok=True))
                else:
                    attempt(lambda p=path, s=saved: atomic_write(p, s[0], s[1], s[2]))
            attempt(lambda: self.restore_firewall(saved_firewall))
            if not was_enabled:
                attempt(lambda: self.systemctl("disable", SERVICE, check=False))
            attempt(lambda: self.systemctl("daemon-reload"))
            if was_active and not failures:
                attempt(lambda: self.systemctl("restart", SERVICE))
                attempt(self.wait_started)
            if failures:
                self.systemctl("stop", SERVICE, check=False)
                raise RuntimeError("应用失败，恢复旧配置也有错误，已停止服务：" + "; ".join(failures)) from exc
            raise RuntimeError(f"应用失败，已恢复之前的配置和运行状态：{exc}") from exc
        print("配置已生效，服务已设置为开机启动。")

    def install(self, state, archive=None):
        if self.state.exists() or self.unit.exists():
            raise ValueError("已有本脚本管理的服务，请使用修改配置菜单。")
        state = validate_state(state)
        assert_port_available(state["listen"], state["port"])
        if state["mode"] != "direct":
            print("正在验证服务器 B 的账号认证……", flush=True)
            probe_upstream(state["upstream"])
        self.prerequisites()
        self.prepare_paths()
        self.install_binary(archive)
        self.install_manager()
        self.apply(state, verify_upstream=False)

    def check(self):
        state = self.load()
        expected = render_xray(state)
        actual = json.loads(self.config.read_text(encoding="utf-8"))
        if actual != expected:
            raise ValueError("config.json 与 state.json 不一致，请从菜单重新应用配置。")
        self.check_xray(self.config)
        print("[通过] 状态文件、生成配置和 Xray 配置语法。")
        run(["nft", "-c", "-f", "-"], data=render_nft(state))
        live = run(["nft", "-j", "-n", "list", "table", "inet", NFT_TABLE]).stdout
        check_live_firewall(state, json.loads(live))
        print("[通过] 内核中的来源白名单规则与当前配置一致。")
        if not self.active():
            raise RuntimeError("配置检查通过，但服务当前未运行。")
        print("[通过] systemd 服务运行中。")
        if state["role"] == "A" and state["mode"] != "direct":
            probe_upstream(state["upstream"])
            print("[通过] B 接受当前 SOCKS5 用户名和密码（未检测 B 到目标网站的转发）。")
        else:
            print("当前为直连模式，无需检查 B。")

    def restart(self):
        state = self.load()
        if json.loads(self.config.read_text(encoding="utf-8")) != render_xray(state):
            raise ValueError("运行配置与状态文件不一致，请选择重新应用当前配置。")
        self.check_xray(self.config)
        self.systemctl("restart", SERVICE)
        self.wait_started()
        print("服务已启动，白名单已重新加载。")

    def uninstall(self):
        state = self.load()
        print(f"将删除本工具的 {state['role']} 服务、配置、账号信息备份和专用防火墙表。")
        if input("输入 DELETE 确认卸载：").strip() != "DELETE":
            print("已取消。")
            return
        self.systemctl("stop", SERVICE)
        self.systemctl("disable", SERVICE)
        self.restore_firewall(None)
        self.unit.unlink(missing_ok=True)
        self.command.unlink(missing_ok=True)
        shutil.rmtree(self.base)
        shutil.rmtree(self.lib)
        self.systemctl("daemon-reload")
        print("已卸载。专用无登录系统账号予以保留，可按需手动删除。")


def ask(prompt, default=None, secret=False):
    suffix = f" [{default}]" if default is not None and not secret else ""
    value = (getpass.getpass if secret else input)(prompt + suffix + "：")
    return value if value else default


def retry(prompt, parser, default=None, secret=False):
    while True:
        try:
            return parser(ask(prompt, default, secret))
        except (ValueError, TypeError, OSError) as exc:
            print(f"输入无效：{exc}")


def split_items(value):
    return [x for x in re.split(r"[\s,;，；]+", value or "") if x]


def ask_credentials(state):
    def username(value):
        return credential(str(uuid.uuid4()) if value == "auto" else value)
    state["username"] = retry("用户名（auto 自动生成 UUID）", username, state.get("username", "auto"))
    old = state.get("password")
    message = "密码（回车保留，输入 auto 重新生成 UUID）" if old else "密码（回车或 auto 自动生成 UUID）"
    def password(value):
        return credential(str(uuid.uuid4()) if value == "auto" or value is None else value)
    state["password"] = retry(message, password, old, secret=True)


def ask_listener(state):
    state["listen"] = retry("监听 IP（0.0.0.0 / :: 为通配，系统支持时双栈）",
                            lambda value: str(ipaddress.ip_address(value)), state.get("listen", "0.0.0.0"))
    def port(value):
        return choose_port(state["listen"]) if value == "auto" else parse_port(value)
    state["port"] = retry("监听端口（auto 自动选择可用端口）", port, str(state.get("port", "auto")))


def ask_whitelist(state):
    old = state.get("whitelist", [])
    enabled = retry("是否启用可信来源 IP 白名单？y/n", lambda s: choice(s, ("y", "n")), "y" if old else "n")
    if enabled == "n":
        state["whitelist"] = []
        return
    print("支持 IPv4、IPv6 和 CIDR，空格或逗号分隔；B 可填写 A 的实际出口 IP。")
    def entries(value):
        values = normalize_whitelist(split_items(value))
        if not values:
            raise ValueError("启用白名单时至少填写一个 IP 或网段。")
        return values
    state["whitelist"] = retry("可信来源 IP", entries, " ".join(old) or None)


def choice(value, options):
    if value not in options:
        raise ValueError("请选择 " + "/".join(options))
    return value


def ask_upstream(state):
    old = state.get("upstream") or {}
    print("请逐项填写 B 的实际连接信息；不会为上游自动生成新账号。")
    upstream = {
        "host": retry("B 地址（IP 或域名，不含协议和端口）", lambda s: s if s else choice(s, ()), old.get("host")),
        "port": retry("B 端口", parse_port, str(old["port"]) if old else None),
        "username": retry("B 用户名", credential, old.get("username")),
        "password": retry("B 密码（已有值时回车保留）", credential, old.get("password"), secret=True),
    }
    state["upstream"] = upstream


def ask_domains(state):
    print("填写域名，空格或逗号分隔，例如 example.com full:api.example.net。")
    print("普通域名匹配自身及子域；full: 仅精确匹配。不要填写 URL 或 IP。")
    def entries(value):
        result = normalize_domains(split_items(value))
        if not result:
            raise ValueError("按域名分流时至少填写一个域名。")
        return result
    state["domains"] = retry("通过 B 访问的域名", entries, " ".join(state.get("domains", [])) or None)


def ask_mode(state):
    options = {"1": "domain", "2": "direct", "3": "global"}
    print("1. 按域名分流   2. 跳过分流（全部直连）   3. 全局代理（全部通过 B）")
    default = next((key for key, value in options.items() if value == state.get("mode")), "1")
    state["mode"] = options[retry("分流模式", lambda v: choice(v, options), default)]
    if state["mode"] != "direct" and not state.get("upstream"):
        ask_upstream(state)
    if state["mode"] == "domain":
        ask_domains(state)


def new_state(role):
    state = {"schema": 1, "role": role, "mode": "direct", "domains": [], "upstream": None}
    ask_credentials(state)
    ask_listener(state)
    ask_whitelist(state)
    if role == "A":
        state.pop("mode")
        ask_mode(state)
    return validate_state(state)


def show(state, reveal=False):
    print(json_text(state if reveal else masked(state)))


def connection_info(state):
    print(f"角色：{state['role']}；监听：{state['listen']}:{state['port']}；用户名：{state['username']}")
    print("密码已保存在仅 root 可读的 state.json；菜单 4 可显式显示。")
    if state["role"] == "B":
        print("请将 B 的可达 IP/域名、上述端口和实际账号填入 A 的 SOCKS5 出站配置。")
    print("请放行云安全组与现有防火墙中的该 TCP 端口。客户端按域名分流请启用远程 DNS / socks5h。")


def edit(manager):
    state = manager.load()
    print("1. 入站账号密码\n2. 监听 IP/端口\n3. 来源 IP 白名单")
    if state["role"] == "A":
        print("4. B 的连接信息\n5. 域名列表\n6. 分流模式")
    print("0. 返回")
    value = input("选择修改项：").strip()
    actions = {"1": ask_credentials, "2": ask_listener, "3": ask_whitelist}
    if state["role"] == "A":
        actions.update({"4": ask_upstream, "5": ask_domains, "6": ask_mode})
    if value == "0":
        return
    if value not in actions:
        raise ValueError("无效选项。")
    actions[value](state)
    if value == "4":
        probe_upstream(validate_state(state)["upstream"])
    manager.apply(state)
    connection_info(state)


def menu(manager, archive=None):
    while True:
        print("\n轻量 SOCKS5 管理（TCP CONNECT）")
        print("1. 部署服务器 A\n2. 部署服务器 B\n3. 查看配置（隐藏密码）\n4. 显示连接账号密码")
        print("5. 检查配置与上游认证\n6. 修改配置\n7. 启动/重启服务\n8. 停止服务")
        print("9. 服务状态与最近日志\n10. 恢复上一次配置\n11. 重新应用当前配置\n12. 卸载\n0. 退出")
        try:
            selected = input("请选择：").strip()
            if selected == "0":
                return
            if selected in ("1", "2"):
                if manager.state.exists():
                    raise ValueError("已有配置，请从修改菜单维护，或先卸载再切换 A/B 角色。")
                state = new_state("A" if selected == "1" else "B")
                manager.install(state, archive)
                connection_info(state)
                print("本次生成的入站密码：" + state["password"])
            elif selected in ("3", "4"):
                show(manager.load(), reveal=selected == "4")
            elif selected == "5":
                manager.check()
            elif selected == "6":
                edit(manager)
            elif selected == "7":
                manager.restart()
            elif selected == "8":
                manager.load()
                manager.systemctl("stop", SERVICE)
                print("服务已停止；开机启动设置仍保留。")
            elif selected == "9":
                print(manager.systemctl("status", "--no-pager", SERVICE, check=False).stdout)
                print(run(["journalctl", "-u", SERVICE, "-n", "40", "--no-pager"], check=False).stdout)
            elif selected == "10":
                manager.apply(read_state(manager.previous))
            elif selected == "11":
                manager.apply(manager.load())
            elif selected == "12":
                manager.uninstall()
            else:
                print("无效选项。")
        except (EOFError, KeyboardInterrupt):
            print("\n已退出；正在编辑但未提交的内容未应用。")
            return
        except (ValueError, RuntimeError, OSError, subprocess.SubprocessError, zipfile.BadZipFile) as exc:
            print(f"操作失败：{exc}", file=sys.stderr)


def main(argv=None):
    parser = argparse.ArgumentParser(description="交互式 A/B SOCKS5 管理（默认打开中文菜单）")
    parser.add_argument("action", nargs="?", default="menu",
                        choices=("menu", "validate", "render", "check", "show", "_firewall"))
    parser.add_argument("--state", type=Path, help="validate/render 所用状态 JSON 文件")
    parser.add_argument("--output", type=Path, help="render 的输出文件（包含密码，权限 600）")
    parser.add_argument("--xray-archive", type=Path, help=f"安装时使用离线官方 {VERSION} ZIP，仍验证固定 SHA256")
    args = parser.parse_args(argv)
    manager = Manager()
    if args.action in ("validate", "render"):
        if args.state is None:
            parser.error("validate/render 必须指定 --state")
        state = read_state(args.state)
        if args.action == "validate":
            print("状态配置校验通过。")
        else:
            content = json_text(render_xray(state))
            if args.output:
                atomic_write(args.output, content)
                print(f"已生成 {args.output}")
            else:
                sys.stdout.write(content)
        return 0
    require_root()
    if args.action == "_firewall":
        # systemd calls this while apply() holds the interactive manager lock.
        manager.firewall(manager.load())
        return 0
    with manager_lock():
        if args.action == "check":
            manager.check()
        elif args.action == "show":
            show(manager.load())
        else:
            menu(manager, args.xray_archive)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        print(f"错误：{error}", file=sys.stderr)
        sys.exit(1)
    except (EOFError, KeyboardInterrupt):
        print("\n已取消。", file=sys.stderr)
        sys.exit(130)
