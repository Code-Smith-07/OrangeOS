#!/usr/bin/env python3
"""Resource-profile regression tests; no VM or host settings are changed."""
import os
from pathlib import Path
import subprocess
import sys
import unittest
import json
import tempfile

from vm_profile import memory_mib, resolve

ROOT = Path(__file__).resolve().parents[1]


class ProfileTests(unittest.TestCase):
    def test_desktop_unchanged(self):
        p = resolve({})
        self.assertEqual((p.ram_mib, p.cpus, p.ram_budget_mib), (3072, 2, 3072))

    def test_browser(self):
        p = resolve({"ORANGE_VM_PROFILE": "browser"})
        self.assertEqual((p.ram_mib, p.cpus, p.ram_budget_mib), (4096, 2, 4096))
        self.assertEqual(p.qemu_args(), ["-m", "4096", "-smp", "2"])

    def test_overrides(self):
        p = resolve({"ORANGE_VM_PROFILE": "browser", "ORANGE_VM_RAM": "6G",
                     "ORANGE_VM_CPUS": "4", "ORANGE_RAM_BUDGET_MIB": "5120"})
        self.assertEqual((p.ram_mib, p.cpus, p.ram_budget_mib), (6144, 4, 5120))

    def test_capacity_override_does_not_relax_budget(self):
        self.assertEqual(resolve({"ORANGE_VM_RAM": "8G"}).ram_budget_mib, 3072)

    def test_explicit_low_memory(self):
        p = resolve({"ORANGE_VM_RAM": "512M", "ORANGE_RAM_BUDGET_MIB": "512"})
        self.assertEqual(p.ram_mib, 512)

    def test_units(self):
        for value, expected in [("4G",4096),("4096M",4096),("4096",4096),("3g",3072)]:
            with self.subTest(value=value):
                self.assertEqual(memory_mib(value), expected)

    def test_reject_invalid(self):
        for env in ({"ORANGE_VM_PROFILE":"browzer"}, {"ORANGE_VM_RAM":"0G"},
                    {"ORANGE_VM_RAM":"-m 4G"}, {"ORANGE_VM_RAM":"3.5G"},
                    {"ORANGE_VM_RAM":""}, {"ORANGE_VM_CPUS":"0"},
                    {"ORANGE_VM_CPUS":"33"}, {"ORANGE_VM_CPUS":"2,sockets=2"},
                    {"ORANGE_RAM_BUDGET_MIB":"0"}, {"ORANGE_VM_RAM":"1G"},
                    {"ORANGE_RAM_BUDGET_MIB":"4096"}):
            with self.subTest(env=env), self.assertRaises(ValueError):
                resolve(env)

    def test_shell_wrapper_preserves_arguments_and_profile(self):
        env = {k:v for k,v in os.environ.items() if not k.startswith("ORANGE_")}
        code = ('import os,sys; assert os.environ["ORANGE_VM_RAM"] == "4096"; '
                'assert os.environ["ORANGE_RAM_BUDGET_MIB"] == "4096"; '
                'assert sys.argv[1] == "argument with spaces"')
        subprocess.run(["sh", "scripts/run-browser-profile.sh", sys.executable,
                        "-c", code, "argument with spaces"], cwd=ROOT, env=env, check=True)

    def test_bad_profile_stops_before_command(self):
        env = dict(os.environ, ORANGE_VM_CPUS="0")
        result = subprocess.run(["sh", "scripts/run-browser-profile.sh", sys.executable,
                                 "-c", 'print("COMMAND_RAN")'], cwd=ROOT, env=env,
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("COMMAND_RAN", result.stdout)

    def test_qemu_wrapper_uses_profile_and_preserves_arguments(self):
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / "qemu-system-x86_64"
            fake.write_text('#!' + sys.executable + '\nimport json,sys; print(json.dumps(sys.argv[1:]))\n')
            fake.chmod(0o755)
            for name, ram in (("desktop", "3072"), ("browser", "4096")):
                env = {k: v for k, v in os.environ.items() if not k.startswith("ORANGE_")}
                env.update(PATH=directory + os.pathsep + env["PATH"], ORANGE_VM_PROFILE=name)
                result = subprocess.run(["sh", str(ROOT / "scripts/run-qemu.sh"), "-name", "Orange browser test"],
                                        cwd=directory, env=env, text=True, capture_output=True, check=True)
                self.assertEqual(json.loads(result.stdout),
                                 ["-m", ram, "-smp", "2", "-name", "Orange browser test"])

    def test_qemu_wrapper_rejects_bad_capacity_before_launch(self):
        env = dict(os.environ, ORANGE_VM_PROFILE="browser", ORANGE_VM_RAM="1G", ORANGE_RAM_BUDGET_MIB="4096")
        result = subprocess.run(["sh", "scripts/run-qemu.sh", "--version"], cwd=ROOT,
                                env=env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("QEMU emulator version", result.stdout)


if __name__ == "__main__":
    unittest.main()
