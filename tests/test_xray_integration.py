"""Opt-in real Xray tests. No systemd or firewall changes, no remote traffic.

Run with XRAY_BIN=/absolute/path/to/xray python3 -m unittest discover -s tests -v.
The destination echoes its TCP peer address: B uses 127.0.0.2 as a marker.
"""

import http.server
import ipaddress
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import threading
import time
import unittest

from socks5_config import (
    _authenticated_connection, _read_exact, choose_port, probe_upstream, render_xray,
)


class Destination(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = self.client_address[0].encode("ascii")
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def state(role, port):
    return {"schema": 1, "role": role, "listen": "127.0.0.1", "port": port,
            "username": role + "-user", "password": role + "-password",
            "whitelist": [], "mode": "direct", "domains": [], "upstream": None}


def endpoint(value):
    return {"host": value["listen"], "port": value["port"],
            "username": value["username"], "password": value["password"]}


def fetch(proxy, host, port):
    """Read a real HTTP response; a successful SOCKS CONNECT alone is insufficient."""
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        encoded = host.encode("idna")
        target = b"\x03" + bytes([len(encoded)]) + encoded
    else:
        target = (b"\x01" if address.version == 4 else b"\x04") + address.packed
    with _authenticated_connection(proxy, timeout=4) as connection:
        connection.sendall(b"\x05\x01\x00" + target + struct.pack("!H", port))
        response = _read_exact(connection, 4)
        if response[:3] != b"\x05\x00\x00":
            raise ConnectionError("SOCKS CONNECT refused")
        if response[3] == 1:
            _read_exact(connection, 4)
        elif response[3] == 4:
            _read_exact(connection, 16)
        elif response[3] == 3:
            _read_exact(connection, _read_exact(connection, 1)[0])
        else:
            raise ConnectionError("Invalid SOCKS address type")
        _read_exact(connection, 2)
        connection.sendall(b"GET / HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        received = bytearray()
        while len(received) < 65536:
            block = connection.recv(4096)
            if not block:
                break
            received.extend(block)
    headers, separator, body = bytes(received).partition(b"\r\n\r\n")
    if not separator or b" 200 " not in headers.split(b"\r\n", 1)[0]:
        raise ConnectionError("No successful HTTP response from destination")
    return body.decode("ascii")


@unittest.skipUnless(os.environ.get("XRAY_BIN"), "Set XRAY_BIN to enable real Xray A/B tests")
class XrayIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.binary = str(Path(os.environ["XRAY_BIN"]).resolve())
        subprocess.run([self.binary, "version"], check=True, stdout=subprocess.DEVNULL, timeout=5)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.destination = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Destination)
        self.destination.daemon_threads = True
        thread = threading.Thread(target=self.destination.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.destination.server_close)
        self.addCleanup(self.destination.shutdown)
        self.destination_port = self.destination.server_address[1]
        self.b = state("B", choose_port("127.0.0.1"))
        self.start_proxy(self.b, "b", mark_egress=True)
        self.a = state("A", choose_port("127.0.0.1"))
        self.a["upstream"] = endpoint(self.b)

    def start_proxy(self, value, name, mark_egress=False):
        config = render_xray(value)
        if mark_egress:
            config["outbounds"][0]["sendThrough"] = "127.0.0.2"
        path = self.directory / (name + ".json")
        path.write_text(json.dumps(config), encoding="utf-8")
        subprocess.run([self.binary, "run", "-test", "-config", str(path)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=10)
        log = (self.directory / (name + ".log")).open("wb")
        self.addCleanup(log.close)
        process = subprocess.Popen([self.binary, "run", "-config", str(path)],
                                   stdout=log, stderr=subprocess.STDOUT)
        def stop():
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)
        self.addCleanup(stop)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if process.poll() is not None:
                self.fail("Xray exited: " + (self.directory / (name + ".log")).read_text())
            try:
                probe_upstream(endpoint(value), timeout=0.3)
                return
            except (OSError, ValueError):
                time.sleep(0.05)
        self.fail("Xray did not begin accepting authenticated SOCKS5 connections")

    def test_direct_mode_uses_a_for_domains_and_ips(self):
        self.start_proxy(self.a, "a")
        for host in ("localhost", "127.0.0.1"):
            with self.subTest(host=host):
                self.assertEqual(fetch(endpoint(self.a), host, self.destination_port), "127.0.0.1")

    def test_domain_mode_uses_b_only_for_matching_domain(self):
        self.a.update(mode="domain", domains=["full:localhost"])
        self.start_proxy(self.a, "a")
        self.assertEqual(fetch(endpoint(self.a), "localhost", self.destination_port), "127.0.0.2")
        self.assertEqual(fetch(endpoint(self.a), "127.0.0.1", self.destination_port), "127.0.0.1")

    def test_global_mode_uses_b_for_domains_and_ips(self):
        self.a["mode"] = "global"
        self.start_proxy(self.a, "a")
        for host in ("localhost", "127.0.0.1"):
            with self.subTest(host=host):
                self.assertEqual(fetch(endpoint(self.a), host, self.destination_port), "127.0.0.2")

    def test_invalid_inbound_password_is_rejected(self):
        self.start_proxy(self.a, "a")
        proxy = endpoint(self.a)
        proxy["password"] = "incorrect"
        with self.assertRaises(ValueError):
            probe_upstream(proxy)

    def test_invalid_b_password_never_falls_back_to_a(self):
        self.a["mode"] = "global"
        self.a["upstream"]["password"] = "incorrect"
        self.start_proxy(self.a, "a")
        with self.assertRaises((OSError, ValueError)):
            fetch(endpoint(self.a), "127.0.0.1", self.destination_port)

    def test_xray_source_rules_block_unauthorized_forwarding(self):
        self.a["whitelist"] = ["192.0.2.1"]
        self.start_proxy(self.a, "a")
        with self.assertRaises((OSError, ValueError)):
            fetch(endpoint(self.a), "127.0.0.1", self.destination_port)


if __name__ == "__main__":
    unittest.main()
