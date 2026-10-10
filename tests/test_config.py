"""Configuration boundaries and SOCKS5 handshake regression tests."""

import copy
import errno
import ipaddress
import queue
import socket
import struct
import threading
import unittest
from contextlib import contextmanager
from unittest.mock import Mock, patch

from socks5_config import (
    assert_port_available, choose_port, credential, normalize_domains,
    normalize_whitelist, parse_port, probe_connect, probe_upstream, render_nft,
    render_xray, validate_state,
)


def state(**overrides):
    result = {
        "schema": 1, "role": "A", "listen": "0.0.0.0", "port": 1080,
        "username": "alice", "password": "correct-horse", "whitelist": [],
        "mode": "domain", "domains": ["example.com"],
        "upstream": {"host": "proxy.example.com", "port": 1081, "username": "bob", "password": "secret"},
    }
    result.update(overrides)
    return result


class ValidationTests(unittest.TestCase):
    def test_domain_meanings_idna_and_deduplication(self):
        self.assertEqual(normalize_domains([
            "EXAMPLE.com.", "domain:example.com", "*.example.com",
            "full:example.com", "例子.测试", "domain:*.Child.example.com",
        ]), ["domain:example.com", "full:example.com", "domain:xn--fsqu00a.xn--0zwm56d", "domain:child.example.com"])

    def test_reject_non_domain_routing_input(self):
        for value in ["", "https://example.com", "example.com/a", "127.0.0.1", "::1",
                      "regexp:.*", "geosite:cn", "ext:file:list", "full:*.example.com",
                      "example.com:443", "-bad.com", "bad_.com", "a..b", "example.com..", "1.2.3", "a" * 64 + ".com"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                normalize_domains([value])
        for values in [None, "example.com", [None], [5]]:
            with self.subTest(values=values), self.assertRaises(ValueError):
                normalize_domains(values)

    def test_whitelist_canonicalization_and_duplicates(self):
        self.assertEqual(normalize_whitelist([
            "192.0.2.7/24", "192.0.2.0/24", "2001:0db8::1", "2001:db8::1/128",
            "192.0.2.8/32", "192.0.2.8", "2001:db8:1::9/64",
        ]), ["192.0.2.0/24", "2001:db8::1", "192.0.2.8", "2001:db8:1::/64"])
        for value in ["example.com", "0.0.0.0/33", "fe80::1%eth0", "", "1.2.3.4; accept", None]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                normalize_whitelist([value])

    def test_credentials_count_bytes_and_preserve_punctuation(self):
        for value in ['p $`"\\ !', "é" * 127, "a" * 255]:
            self.assertEqual(credential(value), value)
        for value in ["", "é" * 128, "a" * 256, "a\nb", "a\x00b", "a\x7fb", "a\u0085b", "a\u200eb", None]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                credential(value)

    def test_port_range_and_types(self):
        self.assertEqual(parse_port(" 65535 "), 65535)
        self.assertEqual(parse_port(1), 1)
        for value in [0, 65536, True, 10.0, "1.0", "-1", "1; echo", None, "9" * 5000]:
            with self.subTest(value=str(value)[:40]), self.assertRaises(ValueError):
                parse_port(value)

    def test_validation_is_independent_and_normalizes(self):
        original = state(upstream={"host": "[2001:0db8::1]", "port": "1080", "username": "u", "password": "p"})
        before = copy.deepcopy(original)
        normalized = validate_state(original)
        self.assertEqual(normalized["upstream"]["host"], "2001:db8::1")
        normalized["domains"].append("domain:other.example")
        normalized["upstream"]["password"] = "changed"
        self.assertEqual(original, before)

    def test_state_rejects_inconsistent_modes_and_roles(self):
        invalid = [state(mode="global", upstream=None), state(domains=[]), state(role="B"),
                   state(role="B", mode="global"), state(role="C"), state(mode="unknown"),
                   state(schema=True), state(schema=2), state(listen="localhost"),
                   state(upstream={"host": "b.example"})]
        missing = state()
        del missing["password"]
        invalid.extend([missing, dict(state(), extra=True)])
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_state(value)
        validate_state(state(role="B", mode="direct", upstream=None, domains=[]))
        validate_state(state(mode="direct", upstream=None, domains=[]))
        validate_state(state(mode="global", domains=[]))

    def test_port_selection_and_collision(self):
        try:
            port = choose_port("127.0.0.1")
        except PermissionError:
            self.skipTest("Sandbox forbids TCP sockets; run on a host to verify port binding")
        self.assertGreater(port, 0)
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", port))
            listener.listen(1)
            with self.assertRaises(OSError):
                assert_port_available("127.0.0.1", port)
        assert_port_available("127.0.0.1", port)

    def test_wildcard_port_checks_include_ipv6_conflicts(self):
        for listen in ["0.0.0.0", "::"]:
            candidate = Mock()
            candidate.bind.side_effect = OSError(errno.EADDRINUSE, "IPv6 port occupied")
            with self.subTest(listen=listen), patch("socks5_config.socket.socket", return_value=candidate) as create:
                with self.assertRaises(OSError) as raised:
                    assert_port_available(listen, 1080)
                self.assertEqual(raised.exception.errno, errno.EADDRINUSE)
                create.assert_called_once_with(socket.AF_INET6, socket.SOCK_STREAM)
                candidate.bind.assert_called_once_with(("::", 1080))
                candidate.close.assert_called_once()

    def test_wildcard_falls_back_only_when_ipv6_unavailable(self):
        candidate = Mock()
        candidate.__enter__ = Mock(return_value=candidate)
        candidate.__exit__ = Mock()
        with patch("socks5_config.socket.socket", side_effect=[OSError(errno.EAFNOSUPPORT, "No IPv6"), candidate]) as create:
            assert_port_available("0.0.0.0", 1080)
        self.assertEqual(create.call_args_list[1].args, (socket.AF_INET, socket.SOCK_STREAM))
        candidate.bind.assert_called_once_with(("0.0.0.0", 1080))
        with patch("socks5_config.socket.socket", side_effect=PermissionError(errno.EPERM, "Sandbox")) as create:
            with self.assertRaises(PermissionError):
                assert_port_available("::", 1080)
            self.assertEqual(create.call_count, 1)


def selected_outbound(config, source, domain=None):
    """Small routing oracle for the fields this installer emits."""
    source_ip = ipaddress.ip_address(source)
    for rule in config["routing"]["rules"]:
        if "source" in rule and not any(source_ip in ipaddress.ip_network(net) for net in rule["source"]):
            continue
        if "domain" in rule:
            if domain is None:
                continue
            matched = False
            for value in rule["domain"]:
                kind, name = value.split(":", 1)
                if domain == name or (kind == "domain" and domain.endswith("." + name)):
                    matched = True
            if not matched:
                continue
        return rule["outboundTag"]
    return config["outbounds"][0]["tag"]


class RenderTests(unittest.TestCase):
    def test_domain_routes_exact_subdomains_and_ip_fallback(self):
        config = render_xray(state(domains=["example.com", "full:only.test"]))
        for domain in ["example.com", "www.example.com", "only.test"]:
            self.assertEqual(selected_outbound(config, "192.0.2.1", domain), "upstream")
        for domain in [None, "other.test", "notexample.com", "x.only.test"]:
            self.assertEqual(selected_outbound(config, "192.0.2.1", domain), "direct")
        self.assertEqual(config["routing"]["domainStrategy"], "AsIs")
        self.assertEqual(config["inbounds"][0]["sniffing"], {"enabled": False})

    def test_direct_global_and_b_default_routes(self):
        for mode, expected in [("direct", "direct"), ("global", "upstream")]:
            config = render_xray(state(mode=mode, domains=[]))
            for domain in [None, "other.test", "example.com"]:
                self.assertEqual(selected_outbound(config, "192.0.2.1", domain), expected)
            self.assertEqual(config["outbounds"][0]["tag"], "direct")
        config = render_xray(state(role="B", mode="direct", domains=[], upstream=None))
        self.assertEqual([outbound["tag"] for outbound in config["outbounds"]], ["direct"])

    def test_allowlist_guards_all_modes_and_ipv6(self):
        for mode in ["domain", "global", "direct"]:
            config = render_xray(state(mode=mode, whitelist=["192.0.2.0/24", "2001:db8::/64"]))
            for domain in [None, "example.com", "other.test"]:
                for source in ["198.51.100.1", "2001:db8:1::1"]:
                    self.assertEqual(selected_outbound(config, source, domain), "blocked")
                expected = "upstream" if mode == "global" or (mode == "domain" and domain == "example.com") else "direct"
                for source in ["192.0.2.1", "2001:db8::1"]:
                    self.assertEqual(selected_outbound(config, source, domain), expected)
            self.assertEqual(config["outbounds"][-1]["protocol"], "blackhole")

    def test_socks_credentials_and_udp_disabled(self):
        config = render_xray(state())
        inbound = config["inbounds"][0]["settings"]
        self.assertEqual(inbound, {"auth": "password", "udp": False, "accounts": [{"user": "alice", "pass": "correct-horse"}]})
        self.assertEqual(config["outbounds"][1]["settings"]["servers"], [{
            "address": "proxy.example.com", "port": 1081, "users": [{"user": "bob", "pass": "secret"}],
        }])

    def test_nft_overlapping_networks_work_without_interval_set(self):
        nft = render_nft(state(whitelist=["192.0.2.0/24", "192.0.2.5", "2001:db8::/64"]))
        self.assertIn("add table inet socks5_router\ndelete table inet socks5_router", nft)
        self.assertIn("tcp dport 1080 ip saddr 192.0.2.0/24 return", nft)
        self.assertIn("tcp dport 1080 ip saddr 192.0.2.5 return", nft)
        self.assertIn("tcp dport 1080 ip6 saddr 2001:db8::/64 return", nft)
        self.assertIn("tcp dport 1080 drop", nft)
        self.assertNotIn("flush ruleset", nft)
        self.assertNotIn("udp", nft)
        self.assertNotIn("drop", render_nft(state(whitelist=[])))

    def test_nft_specific_bind_restricts_only_that_destination(self):
        for listen, family, allowed, other in [
            ("192.0.2.10", "ip", "198.51.100.0/24", "2001:db8::/64"),
            ("2001:db8::10", "ip6", "2001:db8:1::/64", "198.51.100.0/24"),
        ]:
            with self.subTest(listen=listen):
                nft = render_nft(state(listen=listen, whitelist=[allowed, other]))
                self.assertIn("tcp dport 1080 %s daddr %s %s saddr %s return" % (family, listen, family, allowed), nft)
                self.assertIn("tcp dport 1080 %s daddr %s drop" % (family, listen), nft)
                self.assertNotIn(other, nft)
                self.assertNotIn("tcp dport 1080 drop", nft)
                denied = render_nft(state(listen=listen, whitelist=[other]))
                self.assertNotIn("return", denied)
                self.assertIn("daddr %s drop" % listen, denied)
        nft = render_nft(state(listen="::ffff:192.0.2.10", whitelist=["198.51.100.0/24"]))
        self.assertIn("ip daddr 192.0.2.10", nft)


def receive(sock, count):
    data = b""
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise AssertionError("Test client closed early")
        data += chunk
    return data


class MemorySocket:
    """A duplex byte transport for sandboxes that forbid socket send calls."""

    def __init__(self, incoming, outgoing):
        self.incoming = incoming
        self.outgoing = outgoing
        self.buffer = b""
        self.closed = False
        self.eof = False
        self.timeout = 3

    def settimeout(self, timeout):
        self.timeout = timeout

    def sendall(self, data):
        if self.closed:
            raise OSError("Transport is closed")
        # One-byte fragments also exercise the production exact-read loop.
        for byte in data:
            self.outgoing.put(bytes([byte]))

    def recv(self, count):
        if self.eof:
            return b""
        if not self.buffer:
            try:
                data = self.incoming.get(timeout=self.timeout)
            except queue.Empty as exc:
                raise TimeoutError("Test transport timed out") from exc
            if data is None:
                self.eof = True
                return b""
            self.buffer = data
        data, self.buffer = self.buffer[:count], self.buffer[count:]
        return data

    def close(self):
        if not self.closed:
            self.closed = True
            self.outgoing.put(None)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


@contextmanager
def fake_socks(handler):
    """Run both protocol peers over an injected, fragmented byte transport."""
    failures = []
    left, right = queue.Queue(), queue.Queue()
    client, server = MemorySocket(left, right), MemorySocket(right, left)

    def serve():
        try:
            with server:
                server.settimeout(3)
                handler(server)
        except BaseException as exc:
            failures.append(exc)

    worker = threading.Thread(target=serve, daemon=True)
    worker.start()
    upstream = {"host": "127.0.0.1", "port": 1081, "username": "测试", "password": "p $`\""}
    client.settimeout(3)
    try:
        with patch("socks5_config.socket.create_connection", return_value=client) as connect:
            yield upstream
            connect.assert_called_once_with(("127.0.0.1", 1081), timeout=5)
    finally:
        client.close()
        worker.join(4)
        if worker.is_alive():
            raise AssertionError("Fake SOCKS server did not finish")
        if failures:
            raise failures[0]


class ProbeTests(unittest.TestCase):
    def authenticate(self, connection, accepted=True):
        self.assertEqual(receive(connection, 3), b"\x05\x01\x02")
        connection.sendall(b"\x05")
        connection.sendall(b"\x02")
        version, length = receive(connection, 2)
        self.assertEqual(version, 1)
        self.assertEqual(receive(connection, length), "测试".encode())
        length = receive(connection, 1)[0]
        self.assertEqual(receive(connection, length), b"p $`\"")
        connection.sendall(b"\x01\x00" if accepted else b"\x01\x01")

    def test_probe_authenticates_and_never_sends_connect(self):
        def handler(connection):
            self.authenticate(connection)
            self.assertEqual(connection.recv(1), b"")
        with fake_socks(handler) as upstream:
            self.assertIsNone(probe_upstream(upstream))

    def test_wrong_password_rejected(self):
        with fake_socks(lambda connection: self.authenticate(connection, False)) as upstream:
            with self.assertRaisesRegex(ValueError, "认证失败"):
                probe_upstream(upstream)

    def test_noauth_and_unrecognized_protocol_rejected(self):
        for reply in [b"\x05\x00", b"\x05\xff", b"\x04\x02"]:
            def handler(connection):
                receive(connection, 3)
                connection.sendall(reply)
            with self.subTest(reply=reply), fake_socks(handler) as upstream:
                with self.assertRaises(ValueError):
                    probe_upstream(upstream)

    def test_truncated_response_is_network_error(self):
        def handler(connection):
            receive(connection, 3)
            connection.sendall(b"\x05")
        with fake_socks(handler) as upstream:
            with self.assertRaises(OSError):
                probe_upstream(upstream)

    def test_connect_encodes_destination_and_consumes_reply(self):
        destinations = [("192.0.2.7", b"\x01" + socket.inet_aton("192.0.2.7")),
                        ("2001:db8::7", b"\x04" + ipaddress.ip_address("2001:db8::7").packed)]
        # Derive the domain byte count explicitly to catch encoding mistakes.
        encoded = "例子.测试".encode("idna")
        destinations.append(("例子.测试", b"\x03" + bytes([len(encoded)]) + encoded))
        for host, destination in destinations:
            def handler(connection):
                self.authenticate(connection)
                expected = b"\x05\x01\x00" + destination + struct.pack("!H", 443)
                self.assertEqual(receive(connection, len(expected)), expected)
                connection.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
            with self.subTest(host=host), fake_socks(handler) as upstream:
                self.assertIsNone(probe_connect(upstream, host, 443))

    def test_connect_failure_rejected(self):
        def handler(connection):
            self.authenticate(connection)
            receive(connection, 10)
            connection.sendall(b"\x05\x05\x00\x01")
        with fake_socks(handler) as upstream:
            with self.assertRaises(ValueError):
                probe_connect(upstream, "192.0.2.7", 443)


if __name__ == "__main__":
    unittest.main()
