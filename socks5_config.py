"""Validated configuration and SOCKS5 probes for the interactive installer.

This module uses only the Python standard library and never changes the host.
SOCKS credentials are deliberately never included in validation error messages.
"""

import errno
import ipaddress
import math
import re
import socket
import struct
import unicodedata
from typing import Any, Dict, List


STATE_KEYS = {
    "schema", "role", "listen", "port", "username", "password", "whitelist",
    "mode", "domains", "upstream",
}
UPSTREAM_KEYS = {"host", "port", "username", "password"}
INBOUND_TAG = "socks-in"
NFT_TABLE = "socks5_router"
_LABEL = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\Z")


def credential(value: str) -> str:
    """Validate the 1..255 UTF-8 byte limit imposed by RFC 1929."""
    if not isinstance(value, str):
        raise ValueError("用户名和密码必须是字符串")
    if any(unicodedata.category(char) in {"Cc", "Cf", "Cs"} for char in value):
        raise ValueError("用户名和密码不能包含控制字符")
    try:
        length = len(value.encode("utf-8"))
    except UnicodeError as exc:
        raise ValueError("用户名和密码必须是有效的 UTF-8 文本") from exc
    if not 1 <= length <= 255:
        raise ValueError("用户名和密码的 UTF-8 长度必须为 1 至 255 字节")
    return value


def parse_port(value: Any) -> int:
    """Accept an integer or decimal input; reject floats, booleans and port 0."""
    if isinstance(value, bool):
        raise ValueError("端口必须是 1 至 65535 的整数")
    if isinstance(value, str):
        value = value.strip()
        if not re.fullmatch(r"[0-9]+", value):
            raise ValueError("端口必须是 1 至 65535 的整数")
        # Bound input before int() so very long input has predictable errors.
        if len(value) > 5:
            raise ValueError("端口必须是 1 至 65535 的整数")
        value = int(value)
    if not isinstance(value, int) or not 1 <= value <= 65535:
        raise ValueError("端口必须是 1 至 65535 的整数")
    return value


def _listen_address(value: str) -> str:
    if not isinstance(value, str) or "%" in value:
        raise ValueError("监听地址必须是 IPv4 或 IPv6 地址，不能包含作用域标识")
    try:
        address = ipaddress.ip_address(value.strip())
        if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
            address = address.ipv4_mapped
        return str(address)
    except ValueError as exc:
        raise ValueError("监听地址必须是 IPv4 或 IPv6 地址") from exc


def _domain_name(value: str) -> str:
    """Return an ASCII DNS name, rejecting IP literals and Xray expressions."""
    if not isinstance(value, str):
        raise ValueError("域名必须是字符串")
    value = value.strip().lower()
    if value.endswith("."):
        value = value[:-1]
    if not value or any(char in value for char in "/\\:@*?#[]%"):
        raise ValueError("请输入域名，不要输入 URL、路径、IP 或其他分流表达式")
    try:
        ipaddress.ip_address(value)
    except ValueError:
        pass
    else:
        raise ValueError("域名列表不能包含 IP 地址")
    try:
        ascii_name = value.encode("idna").decode("ascii").lower()
    except UnicodeError as exc:
        raise ValueError("域名不是有效的 IDNA 域名") from exc
    labels = ascii_name.split(".")
    if (len(ascii_name) > 253 or any(not _LABEL.fullmatch(label) for label in labels)
            or all(label.isdecimal() for label in labels)):
        raise ValueError("域名格式无效")
    return ascii_name


def normalize_domains(values: List[str]) -> List[str]:
    """Normalize domain/full match rules, retaining their first occurrence.

    A bare name, ``domain:name`` and ``*.name`` all match the name itself and
    its subdomains. ``full:name`` only matches the exact name. The returned
    strings can be passed directly to Xray's routing ``domain`` field.
    """
    if not isinstance(values, list):
        raise ValueError("域名列表必须是数组")
    result = []
    seen = set()
    for value in values:
        if not isinstance(value, str):
            raise ValueError("域名列表的每一项必须是字符串")
        value = value.strip()
        prefix = "domain"
        if value.lower().startswith("domain:"):
            value = value[7:]
        elif value.lower().startswith("full:"):
            prefix, value = "full", value[5:]
        if value.startswith("*.") and prefix == "domain":
            value = value[2:]
        normalized = prefix + ":" + _domain_name(value)
        if normalized not in seen:
            seen.add(normalized)
            result.append(normalized)
    return result


def normalize_whitelist(values: List[str]) -> List[str]:
    """Normalize IPv4/IPv6 addresses and networks, rejecting hostnames."""
    if not isinstance(values, list):
        raise ValueError("IP 白名单必须是数组")
    result = []
    seen = set()
    for value in values:
        if not isinstance(value, str) or "%" in value:
            raise ValueError("白名单只能包含 IPv4、IPv6 地址或 CIDR 网段")
        try:
            network = ipaddress.ip_network(value.strip(), strict=False)
        except ValueError as exc:
            raise ValueError("白名单只能包含 IPv4、IPv6 地址或 CIDR 网段") from exc
        normalized = (str(network.network_address) if network.prefixlen == network.max_prefixlen
                      else str(network))
        if normalized not in seen:
            seen.add(normalized)
            result.append(normalized)
    return result


def _host(value: str) -> str:
    if not isinstance(value, str) or "%" in value:
        raise ValueError("上游地址必须是域名、IPv4 或 IPv6 地址")
    value = value.strip()
    if value.startswith("[") and value.endswith("]"):
        value = value[1:-1]
    try:
        return str(ipaddress.ip_address(value))
    except ValueError:
        return _domain_name(value)


def _upstream(value: Dict[str, Any]) -> Dict[str, Any]:
    if not isinstance(value, dict) or set(value) != UPSTREAM_KEYS:
        raise ValueError("上游配置必须包含 host、port、username、password")
    return {
        "host": _host(value["host"]),
        "port": parse_port(value["port"]),
        "username": credential(value["username"]),
        "password": credential(value["password"]),
    }


def validate_state(state: Dict[str, Any]) -> Dict[str, Any]:
    """Return a normalized independent copy, or raise ValueError."""
    if not isinstance(state, dict) or set(state) != STATE_KEYS:
        raise ValueError("配置字段不完整或包含不支持的字段")
    if type(state["schema"]) is not int or state["schema"] != 1:
        raise ValueError("不支持的配置版本，schema 必须为 1")
    if state["role"] not in ("A", "B"):
        raise ValueError("服务器角色必须为 A 或 B")
    if state["mode"] not in ("domain", "direct", "global"):
        raise ValueError("分流模式必须为 domain、direct 或 global")
    result = {
        "schema": 1,
        "role": state["role"],
        "listen": _listen_address(state["listen"]),
        "port": parse_port(state["port"]),
        "username": credential(state["username"]),
        "password": credential(state["password"]),
        "whitelist": normalize_whitelist(state["whitelist"]),
        "mode": state["mode"],
        "domains": normalize_domains(state["domains"]),
        "upstream": None if state["upstream"] is None else _upstream(state["upstream"]),
    }
    if result["role"] == "B":
        if result["mode"] != "direct" or result["upstream"] is not None or result["domains"]:
            raise ValueError("服务器 B 必须使用 direct 模式，且不能配置上游或分流域名")
    if result["mode"] in ("domain", "global") and result["upstream"] is None:
        raise ValueError("按域名分流或全局代理时必须配置服务器 B 的连接信息")
    if result["mode"] == "domain" and not result["domains"]:
        raise ValueError("按域名分流时至少需要填写一个域名")
    return result


def _bind_socket(listen: str, port: int) -> socket.socket:
    listen = _listen_address(listen)
    address = ipaddress.ip_address(listen)
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
        address = address.ipv4_mapped
        listen = str(address)

    def bind(family: int, host: str) -> socket.socket:
        sock = socket.socket(family, socket.SOCK_STREAM)
        try:
            if family == socket.AF_INET6:
                sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
            sock.bind((host, port))
            sock.listen(1)
            return sock
        except BaseException:
            sock.close()
            raise

    if address.is_unspecified:
        # Go can use a dual-stack listener for either wildcard spelling. Check
        # both families together so a busy IPv6 port is never missed. Only an
        # unavailable IPv6 stack permits IPv4 fallback; a collision must fail.
        unavailable_ipv6 = {errno.EAFNOSUPPORT, errno.EPROTONOSUPPORT,
                            errno.ENOPROTOOPT, errno.EADDRNOTAVAIL, errno.ENODEV}
        try:
            return bind(socket.AF_INET6, "::")
        except OSError as exc:
            if exc.errno not in unavailable_ipv6:
                raise
        return bind(socket.AF_INET, "0.0.0.0")
    return bind(socket.AF_INET6 if address.version == 6 else socket.AF_INET, listen)


def choose_port(listen: str = "0.0.0.0") -> int:
    """Ask the kernel for a free TCP port; the caller must still handle races."""
    with _bind_socket(listen, 0) as sock:
        return int(sock.getsockname()[1])


def assert_port_available(listen: str, port: int) -> None:
    """Raise OSError if this listen address and TCP port cannot be bound."""
    with _bind_socket(listen, parse_port(port)):
        pass


def render_xray(state: Dict[str, Any]) -> Dict[str, Any]:
    """Render Xray v26.3.27 configuration using accounts/servers syntax."""
    state = validate_state(state)
    outbounds = [{"tag": "direct", "protocol": "freedom", "settings": {}}]
    upstream = state["upstream"]
    if upstream is not None:
        outbounds.append({
            "tag": "upstream", "protocol": "socks",
            "settings": {"servers": [{
                "address": upstream["host"], "port": upstream["port"],
                "users": [{"user": upstream["username"], "pass": upstream["password"]}],
            }]},
        })

    def rule(outbound: str) -> Dict[str, Any]:
        value = {"type": "field", "inboundTag": [INBOUND_TAG], "outboundTag": outbound}
        if state["whitelist"]:
            value["source"] = list(state["whitelist"])
        return value

    rules = []
    if state["mode"] == "domain":
        domain_rule = rule("upstream")
        domain_rule["domain"] = list(state["domains"])
        rules.append(domain_rule)
    rules.append(rule("upstream" if state["mode"] == "global" else "direct"))
    if state["whitelist"]:
        outbounds.append({"tag": "blocked", "protocol": "blackhole", "settings": {}})
        rules.append({"type": "field", "inboundTag": [INBOUND_TAG], "outboundTag": "blocked"})
    return {
        "log": {"loglevel": "warning"},
        "inbounds": [{
            "tag": INBOUND_TAG,
            "listen": state["listen"],
            "port": state["port"],
            "protocol": "socks",
            "settings": {"auth": "password", "udp": False, "accounts": [{
                "user": state["username"], "pass": state["password"],
            }]},
            "sniffing": {"enabled": False},
        }],
        "outbounds": outbounds,
        "routing": {"domainStrategy": "AsIs", "rules": rules},
    }


def render_nft(state: Dict[str, Any]) -> str:
    """Render one nft transaction, preserving tables owned by other software.

    Individual network rules intentionally avoid interval sets: overlapping
    networks remain valid and never fail with overlapping-element errors.
    ``return`` lets other firewall chains apply their existing policies.
    """
    state = validate_state(state)
    lines = [
        "add table inet " + NFT_TABLE,
        # Recreate the entire managed table in one transaction. A flush only
        # empties rules and can leave altered chains, policies or objects behind.
        "delete table inet " + NFT_TABLE,
        "table inet " + NFT_TABLE + " {",
        "    chain input {",
        "        type filter hook input priority -10; policy accept;",
    ]
    listen = ipaddress.ip_address(state["listen"])
    destination = ""
    if not listen.is_unspecified:
        destination = " %s daddr %s" % ("ip6" if listen.version == 6 else "ip", listen)
    for source in state["whitelist"]:
        family = "ip6" if ":" in source else "ip"
        source_version = 6 if family == "ip6" else 4
        if not listen.is_unspecified and source_version != listen.version:
            continue
        lines.append("        tcp dport %d%s %s saddr %s return" % (state["port"], destination, family, source))
    if state["whitelist"]:
        lines.append("        tcp dport %d%s drop" % (state["port"], destination))
    lines.extend(["    }", "}", ""])
    return "\n".join(lines)


def _read_exact(sock: socket.socket, count: int) -> bytes:
    result = bytearray()
    while len(result) < count:
        chunk = sock.recv(count - len(result))
        if not chunk:
            raise ConnectionError("SOCKS5 上游提前关闭连接")
        result.extend(chunk)
    return bytes(result)


def _authenticated_connection(upstream: Dict[str, Any], timeout: float) -> socket.socket:
    upstream = _upstream(upstream)
    if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or not math.isfinite(timeout) or timeout <= 0:
        raise ValueError("探测超时必须是大于 0 的秒数")
    sock = socket.create_connection((upstream["host"], upstream["port"]), timeout=timeout)
    try:
        # Offer password auth exclusively: a no-auth reply is an error.
        sock.sendall(b"\x05\x01\x02")
        if _read_exact(sock, 2) != b"\x05\x02":
            raise ValueError("上游未接受 SOCKS5 用户名密码认证")
        username = upstream["username"].encode("utf-8")
        password = upstream["password"].encode("utf-8")
        sock.sendall(b"\x01" + bytes([len(username)]) + username + bytes([len(password)]) + password)
        reply = _read_exact(sock, 2)
        if reply[0] != 1 or reply[1] != 0:
            raise ValueError("上游 SOCKS5 用户名密码认证失败")
        return sock
    except BaseException:
        sock.close()
        raise


def probe_upstream(upstream: Dict[str, Any], timeout: float = 5) -> None:
    """Verify RFC 1928/1929 authentication without connecting to a third party."""
    with _authenticated_connection(upstream, timeout):
        pass


def probe_connect(upstream: Dict[str, Any], host: str, port: int, timeout: float = 5) -> None:
    """Check that the SOCKS server accepts a TCP CONNECT request.

    This is a protocol-level check, not proof of destination reachability.
    Xray may report CONNECT success before its outbound connection succeeds.
    """
    host = _host(host)
    port = parse_port(port)
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        encoded = host.encode("ascii")
        destination = b"\x03" + bytes([len(encoded)]) + encoded
    else:
        destination = (b"\x01" if address.version == 4 else b"\x04") + address.packed
    with _authenticated_connection(upstream, timeout) as sock:
        sock.sendall(b"\x05\x01\x00" + destination + struct.pack("!H", port))
        response = _read_exact(sock, 4)
        if response[:3] != b"\x05\x00\x00":
            raise ValueError("上游拒绝 SOCKS5 CONNECT，或返回了无效响应")
        if response[3] == 1:
            _read_exact(sock, 4)
        elif response[3] == 4:
            _read_exact(sock, 16)
        elif response[3] == 3:
            length = _read_exact(sock, 1)[0]
            if not length:
                raise ValueError("上游返回了空的 SOCKS5 绑定域名")
            _read_exact(sock, length)
        else:
            raise ValueError("上游返回了无效的 SOCKS5 地址类型")
        _read_exact(sock, 2)
