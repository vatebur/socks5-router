"""Transactional manager tests; system services and firewall calls stay mocked."""

import copy
import hashlib
import io
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile

import socks5
from socks5_config import render_xray, validate_state


def state(**changes):
    value = {
        "schema": 1, "role": "A", "listen": "127.0.0.1", "port": 31080,
        "username": "alice", "password": "old-password", "whitelist": ["192.0.2.1"],
        "mode": "direct", "domains": [], "upstream": None,
    }
    value.update(changes)
    return validate_state(value)


class TransactionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.manager = socks5.Manager(Path(self.temporary.name))
        for directory in (self.manager.base, self.manager.lib, self.manager.unit.parent):
            directory.mkdir(parents=True, exist_ok=True)
        self.events = []
        self.running = True
        self.enabled = True
        self.fail_start = False
        self.firewall = "original nft snapshot"
        self.original = state()
        socks5.atomic_write(self.manager.state, socks5.json_text(self.original))
        socks5.atomic_write(self.manager.config, socks5.json_text(render_xray(self.original)), 0o640)
        socks5.atomic_write(self.manager.unit, "original unit\n", 0o644)
        socks5.atomic_write(self.manager.previous, "original previous\n")
        self.saved = {path: (path.read_bytes(), path.stat().st_mode & 0o777)
                      for path in (self.manager.state, self.manager.config,
                                   self.manager.unit, self.manager.previous)}

        def systemctl(*args, **kwargs):
            self.events.append(args[0])
            result = subprocess.CompletedProcess(args, 0, "", "")
            if args[0] == "is-active":
                result.returncode = 0 if self.running else 3
            elif args[0] == "is-enabled":
                result.returncode = 0 if self.enabled else 1
            elif args[0] == "stop":
                self.running = False
            elif args[0] == "restart":
                if self.fail_start:
                    self.fail_start = False
                    raise RuntimeError("simulated service startup failure")
                self.running = True
            elif args[0] in ("enable", "disable"):
                self.enabled = args[0] == "enable"
            return result

        def apply_firewall(value):
            self.events.append("apply firewall")
            self.firewall = copy.deepcopy(value)

        def restore_firewall(value):
            self.events.append("restore firewall")
            self.firewall = value

        for target, replacement in (
            ("systemctl", systemctl), ("wait_started", lambda: None),
            ("check_xray", lambda path: None),
            ("firewall_snapshot", lambda: copy.deepcopy(self.firewall)),
            ("firewall", apply_firewall), ("restore_firewall", restore_firewall),
        ):
            patcher = patch.object(self.manager, target, replacement)
            patcher.start()
            self.addCleanup(patcher.stop)
        for target, replacement in (
            ("socks5.grp.getgrnam", lambda name: SimpleNamespace(gr_gid=os.getgid())),
            ("socks5.assert_port_available", lambda *args: None),
            ("socks5.run", lambda *args, **kwargs: subprocess.CompletedProcess(args, 0, "", "")),
        ):
            patcher = patch(target, replacement)
            patcher.start()
            self.addCleanup(patcher.stop)

    def assert_files_restored(self):
        for path, (content, permissions) in self.saved.items():
            self.assertEqual(path.read_bytes(), content, str(path))
            self.assertEqual(path.stat().st_mode & 0o777, permissions, str(path))

    def test_success_saves_previous_and_stops_before_filter_update(self):
        new = state(password="new-password", whitelist=["198.51.100.2"])
        self.manager.apply(new)
        self.assertEqual(self.manager.load(), new)
        self.assertEqual(socks5.read_state(self.manager.previous), self.original)
        self.assertEqual(self.firewall, new)
        self.assertTrue(self.running)
        self.assertTrue(self.enabled)
        self.assertLess(self.events.index("stop"), self.events.index("apply firewall"))
        self.assertLess(self.events.index("apply firewall"), self.events.index("restart"))
        self.assertEqual(self.manager.state.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.manager.config.stat().st_mode & 0o777, 0o640)

    def test_failed_restart_restores_files_firewall_and_running_state(self):
        self.fail_start = True
        with self.assertRaisesRegex(RuntimeError, "已恢复"):
            self.manager.apply(state(password="new-password", port=31081))
        self.assert_files_restored()
        self.assertEqual(self.firewall, "original nft snapshot")
        self.assertTrue(self.running)
        self.assertTrue(self.enabled)

    def test_failed_first_install_removes_new_files_and_disables_service(self):
        for path in self.saved:
            path.unlink()
        self.running = self.enabled = False
        self.firewall = None
        self.fail_start = True
        with self.assertRaisesRegex(RuntimeError, "已恢复"):
            self.manager.apply(state())
        self.assertTrue(all(not path.exists() for path in self.saved))
        self.assertIsNone(self.firewall)
        self.assertFalse(self.running)
        self.assertFalse(self.enabled)

    def test_bad_upstream_auth_does_not_stop_or_modify_existing_service(self):
        upstream = {"host": "proxy.example", "port": 1080, "username": "bob", "password": "bad"}
        with patch("socks5.probe_upstream", side_effect=ValueError("认证失败")):
            with self.assertRaisesRegex(ValueError, "认证失败"):
                self.manager.apply(state(mode="global", upstream=upstream))
        self.assert_files_restored()
        self.assertNotIn("stop", self.events)
        self.assertEqual(self.firewall, "original nft snapshot")

    def test_failed_xray_validation_does_not_change_running_service(self):
        with patch.object(self.manager, "check_xray", side_effect=RuntimeError("bad config")):
            with self.assertRaisesRegex(RuntimeError, "bad config"):
                self.manager.apply(state(password="new-password"))
        self.assert_files_restored()
        self.assertNotIn("stop", self.events)
        self.assertTrue(self.running)

    def test_incomplete_firewall_rollback_keeps_service_stopped(self):
        self.fail_start = True
        with patch.object(self.manager, "restore_firewall", side_effect=RuntimeError("restore denied")):
            with self.assertRaisesRegex(RuntimeError, "恢复旧配置也有错误"):
                self.manager.apply(state(password="new-password", port=31081))
        self.assert_files_restored()
        self.assertFalse(self.running, "Failed rollback must not restart a service with mixed state")

    def test_initial_stop_failure_preserves_files_and_firewall(self):
        original_systemctl = self.manager.systemctl
        def refusing_stop(*args, **kwargs):
            if args[0] == "stop":
                raise RuntimeError("cannot stop running service")
            return original_systemctl(*args, **kwargs)
        with patch.object(self.manager, "systemctl", side_effect=refusing_stop):
            with self.assertRaises(RuntimeError):
                self.manager.apply(state(password="new-password", port=31081))
        self.assert_files_restored()
        self.assertEqual(self.firewall, "original nft snapshot")
        self.assertNotIn("restore firewall", self.events)
        self.assertTrue(self.running)

    def test_cannot_stop_during_rollback_preserves_active_configuration_filter_pair(self):
        original_systemctl = self.manager.systemctl
        stop_count = 0
        def refusing_second_stop(*args, **kwargs):
            nonlocal stop_count
            if args[0] == "stop":
                stop_count += 1
                if stop_count > 1:
                    raise RuntimeError("cannot stop candidate service")
            return original_systemctl(*args, **kwargs)
        new = state(password="new-password", port=31081)
        with patch.object(self.manager, "systemctl", side_effect=refusing_second_stop), \
                patch.object(self.manager, "wait_started", side_effect=RuntimeError("startup incomplete")):
            with self.assertRaises(RuntimeError):
                self.manager.apply(new)
        self.assertTrue(self.running)
        self.assertEqual(self.manager.load(), new)
        self.assertEqual(self.firewall, new)
        self.assertNotIn("restore firewall", self.events)

    def test_incomplete_file_rollback_keeps_service_stopped(self):
        self.fail_start = True
        original_write = socks5.atomic_write
        def refusing_config_restore(path, data, *args, **kwargs):
            if path == self.manager.config and data == self.saved[self.manager.config][0]:
                raise OSError("cannot restore config")
            return original_write(path, data, *args, **kwargs)
        with patch("socks5.atomic_write", side_effect=refusing_config_restore):
            with self.assertRaises(RuntimeError):
                self.manager.apply(state(password="new-password", port=31081))
        self.assertFalse(self.running)

    def test_check_reports_stopped_service_after_configuration_passes(self):
        self.running = False
        result = subprocess.CompletedProcess([], 0, '{"nftables": []}', "")
        with patch("socks5.run", return_value=result), patch("socks5.check_live_firewall"):
            with self.assertRaisesRegex(RuntimeError, "未运行"):
                self.manager.check()


class LiveFirewallTests(unittest.TestCase):
    def fixture(self):
        # nft -j -n list table shape: anonymous expressions plus handles are normal.
        objects = [
            {"metainfo": {"version": "1.0.6", "release_name": "Lester Gooch"}},
            {"table": {"family": "inet", "name": "socks5_router", "handle": 7}},
            {"chain": {"family": "inet", "table": "socks5_router", "name": "input",
                       "handle": 1, "type": "filter", "hook": "input", "prio": -10,
                       "policy": "accept"}},
        ]
        port = {"match": {"op": "==", "left": {"payload": {"protocol": "tcp", "field": "dport"}},
                          "right": 31080}}
        source = {"match": {"op": "==", "left": {"payload": {"protocol": "ip", "field": "saddr"}},
                            "right": "192.0.2.1"}}
        for index, expressions in enumerate([[port, source, {"return": None}], [port, {"drop": None}]]):
            objects.append({"rule": {"family": "inet", "table": "socks5_router", "chain": "input",
                                     "handle": 2 + index, "expr": expressions}})
        return {"nftables": objects}

    def test_expected_live_rules_pass_despite_nft_handle_metadata(self):
        socks5.check_live_firewall(state(listen="0.0.0.0"), self.fixture())

    def test_removed_drop_rule_is_detected(self):
        document = self.fixture()
        document["nftables"].pop()
        with self.assertRaises(RuntimeError):
            socks5.check_live_firewall(state(listen="0.0.0.0"), document)

    def test_different_port_source_or_chain_policy_is_detected(self):
        for position, key, value in [(2, "policy", "drop"), (2, "prio", 0)]:
            document = self.fixture()
            document["nftables"][position]["chain"][key] = value
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                socks5.check_live_firewall(state(listen="0.0.0.0"), document)
        for position, value in [(0, 9999), (1, "198.51.100.2")]:
            document = self.fixture()
            document["nftables"][3]["rule"]["expr"][position]["match"]["right"] = value
            with self.subTest(value=value), self.assertRaises(RuntimeError):
                socks5.check_live_firewall(state(listen="0.0.0.0"), document)

    def test_ipv4_ipv6_cidr_rules_pass(self):
        document = self.fixture()
        allow_v4 = document["nftables"][3]["rule"]
        allow_v4["expr"][1]["match"]["right"] = {"prefix": {"addr": "192.0.2.0", "len": 24}}
        allow_v6 = copy.deepcopy(allow_v4)
        allow_v6["handle"] = 9
        allow_v6["expr"][1]["match"]["left"]["payload"]["protocol"] = "ip6"
        allow_v6["expr"][1]["match"]["right"] = {"prefix": {"addr": "2001:db8::", "len": 64}}
        document["nftables"].insert(4, {"rule": allow_v6})
        socks5.check_live_firewall(state(listen="::", whitelist=["192.0.2.0/24", "2001:db8::/64"]), document)

    def test_extra_chain_is_detected(self):
        document = self.fixture()
        extra = copy.deepcopy(document["nftables"][2])
        extra["chain"]["name"] = "unexpected"
        document["nftables"].append(extra)
        with self.assertRaises(RuntimeError):
            socks5.check_live_firewall(state(listen="0.0.0.0"), document)

    def test_concrete_ipv4_listener_requires_destination_and_ignores_ipv6_source(self):
        document = self.fixture()
        destination = {"match": {"op": "==", "left": {"payload": {"protocol": "ip", "field": "daddr"}},
                                 "right": "127.0.0.1"}}
        for item in document["nftables"]:
            if "rule" in item:
                item["rule"]["expr"].insert(1, copy.deepcopy(destination))
        current = state(listen="127.0.0.1", whitelist=["192.0.2.1", "2001:db8::1"])
        socks5.check_live_firewall(current, document)
        document["nftables"][3]["rule"]["expr"].pop(1)
        with self.assertRaises(RuntimeError):
            socks5.check_live_firewall(current, document)

    def test_concrete_ipv6_listener_requires_ipv6_destination(self):
        document = self.fixture()
        destination = {"match": {"op": "==", "left": {"payload": {"protocol": "ip6", "field": "daddr"}},
                                 "right": "2001:db8::2"}}
        source = document["nftables"][3]["rule"]["expr"][1]["match"]
        source["left"]["payload"]["protocol"] = "ip6"
        source["right"] = "2001:db8::1"
        for item in document["nftables"]:
            if "rule" in item:
                item["rule"]["expr"].insert(1, copy.deepcopy(destination))
        current = state(listen="2001:db8::2", whitelist=["192.0.2.1", "2001:db8::1"])
        socks5.check_live_firewall(current, document)


class DownloadTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.manager = socks5.Manager(self.root)
        self.manager.lib.mkdir(parents=True)
        patcher = patch("socks5.platform.machine", return_value="x86_64")
        patcher.start()
        self.addCleanup(patcher.stop)

    def make_archive(self):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as archive:
            archive.writestr("xray", b"test executable")
            archive.writestr("../../unexpected", b"must never be extracted")
        self.archive = self.root / "core.zip"
        content = buffer.getvalue()
        self.archive.write_bytes(content)
        return hashlib.sha256(content).hexdigest()

    def test_checksum_failure_never_installs_or_executes_binary(self):
        self.make_archive()
        with patch("socks5.run") as command:
            with self.assertRaisesRegex(RuntimeError, "SHA256"):
                self.manager.install_binary(self.archive)
        self.assertFalse(self.manager.binary.exists())
        command.assert_not_called()

    def test_verified_archive_extracts_only_named_executable(self):
        digest = self.make_archive()
        with patch.dict(socks5.ASSETS, {"x86_64": ("test.zip", digest)}), patch("socks5.run"):
            self.manager.install_binary(self.archive)
        self.assertEqual(self.manager.binary.read_bytes(), b"test executable")
        self.assertEqual(self.manager.binary.stat().st_mode & 0o777, 0o755)
        self.assertEqual(list(self.manager.lib.iterdir()), [self.manager.binary])
        self.assertFalse((self.manager.lib.parent.parent / "unexpected").exists())

    def test_unusable_verified_binary_is_removed(self):
        digest = self.make_archive()
        with patch.dict(socks5.ASSETS, {"x86_64": ("test.zip", digest)}), \
                patch("socks5.run", side_effect=OSError("cannot execute")):
            with self.assertRaisesRegex(OSError, "cannot execute"):
                self.manager.install_binary(self.archive)
        self.assertFalse(self.manager.binary.exists())


if __name__ == "__main__":
    unittest.main()
