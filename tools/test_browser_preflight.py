#!/usr/bin/env python3
import unittest
from unittest.mock import patch
import subprocess
from pathlib import Path
import plistlib
from types import SimpleNamespace

from browser_preflight import assess, collect, probe, BUILD_FREE_BYTES


class PreflightTests(unittest.TestCase):
    def facts(self, **overrides):
        base = dict(disk_free_bytes=BUILD_FREE_BYTES, host_os="Darwin",
                    filesystem="apfs", host_arch="arm64", build_dir="/Volumes/Build/chromium",
                    xcode={"ok": True}, sdk={"ok": True}, git={"ok": True},
                    depot_tools=True, qemu_devices={"ok": True, "stdout": 'name "virtio-gpu-pci"'})
        return dict(base, **overrides)

    def test_checks_are_not_native_browser_success(self):
        result = assess(self.facts())
        self.assertEqual(result["build_blockers"], [])
        self.assertEqual(result["reference_build"], "NOT RUN")
        self.assertIn("NOT IMPLEMENTED", result["native_browser"])

    def test_disk_below_threshold_blocks(self):
        self.assertTrue(assess(self.facts(disk_free_bytes=BUILD_FREE_BYTES-1))["build_blockers"])

    def test_missing_tools_block(self):
        for delta in (dict(xcode={"ok":False}), dict(sdk={"ok":False}),
                      dict(git={"ok":False}), dict(depot_tools=False), dict(host_os="Linux")):
            with self.subTest(delta=delta):
                self.assertTrue(assess(self.facts(**delta))["build_blockers"])

    def test_build_path_and_filesystem_are_qualified(self):
        for delta in (dict(build_dir="/Volumes/External Drive/browser"),
                      dict(filesystem=None), dict(filesystem="exfat"), dict(host_arch="unknown")):
            with self.subTest(delta=delta):
                self.assertTrue(assess(self.facts(**delta))["build_blockers"])

    def test_diskutil_receives_mountpoint_not_checkout_directory(self):
        calls = []
        def fake_probe(argv):
            calls.append(argv)
            return {"ok": True, "stdout": plistlib.dumps({"FilesystemType": "apfs"}).decode()}
        with patch("browser_preflight.probe", side_effect=fake_probe), \
             patch("browser_preflight.platform.system", return_value="Darwin"), \
             patch("browser_preflight.shutil.disk_usage", return_value=SimpleNamespace(free=BUILD_FREE_BYTES)), \
             patch.object(Path, "is_mount", lambda p: str(p) == "/Volumes/Build"):
            facts = collect(Path("/Volumes/Build/chromium"))
        self.assertIn(["diskutil", "info", "-plist", "/Volumes/Build"], calls)
        self.assertEqual(facts["filesystem"], "apfs")

    def test_2d_is_not_acceleration(self):
        self.assertEqual(assess(self.facts())["graphics"], "no accelerated virtio-gpu device advertised")

    def test_advertised_device_is_not_qualified(self):
        result = assess(self.facts(qemu_devices={"ok":True,"stdout":'name "virtio-gpu-gl-pci"'}))
        self.assertIn("UNQUALIFIED", result["graphics"])
        self.assertIn("UNQUALIFIED", result["hardware_video_decode"])

    def test_failed_probe_is_unknown_not_no_gpu(self):
        self.assertIn("not probed", assess(self.facts(qemu_devices={"ok":False}))["graphics"])

    def test_subprocess_timeout_and_missing_tool(self):
        for error in (FileNotFoundError("absent"), subprocess.TimeoutExpired("qemu",10)):
            with patch("browser_preflight.subprocess.run", side_effect=error):
                self.assertFalse(probe(["qemu"])["ok"])


if __name__ == "__main__":
    unittest.main()
