#!/usr/bin/env python3
import json
import argparse
import fcntl
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from browser_reference import (ReferenceBuild, build_jobs, ensure_text, environment, fingerprint,
                               gclient_config, guard_workspace, load_manifest,
                               live_status, main, sdk_supported, source_audit, verify_repo)


class ReferenceTests(unittest.TestCase):
    def test_build_jobs_validated(self):
        self.assertEqual(build_jobs("3"), 3)
        for value in ("0", "-1", "9", "1.5", "auto", True):
            with self.subTest(value=value), self.assertRaises(argparse.ArgumentTypeError):
                build_jobs(value)

    def test_requested_build_parallelism_reaches_autoninja(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            manifest = load_manifest()
            (root / "checkout").mkdir()
            (root / "checkout/.gclient").write_text(gclient_config(manifest))
            with (root / "log").open("w") as log:
                build = ReferenceBuild(root, manifest, log, jobs=3)
                with patch("browser_reference.verify_repo"), patch("browser_reference.source_audit"), \
                     patch.object(build, "ensure_tool_runtime"), patch.object(build, "run") as run:
                    build.execute("build")
                self.assertEqual(run.call_args.args[0],
                                 [build.depot / "autoninja", "-C", "out/OrangeReference", "-j", "3", "content_shell"])

    def test_checked_in_manifest_is_pinned(self):
        manifest = load_manifest()
        self.assertEqual(len(manifest["chromium"]["revision"]), 40)
        self.assertEqual(manifest["gn_args"]["target_cpu"], "arm64")
        self.assertFalse(manifest["gn_args"]["use_remoteexec"])

    def test_branch_instead_of_hash_is_rejected(self):
        manifest = load_manifest()
        manifest["chromium"]["revision"] = "main"
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "manifest.json"
            path.write_text(json.dumps(manifest))
            with self.assertRaises(ValueError):
                load_manifest(path)

    def test_fingerprint_includes_toolchain_and_args(self):
        manifest = load_manifest()
        before = fingerprint(manifest)
        manifest["gn_args"]["symbol_level"] = 1
        self.assertNotEqual(before, fingerprint(manifest))

    def test_cache_paths_are_external_without_changing_home(self):
        original = {"PATH": "/usr/bin", "HOME": "/Users/test", "CODEX_HOME": "/keep", "VPYTHON_BYPASS": "old"}
        work = Path("/Volumes/External/project/build/browser")
        env = environment(work, original)
        self.assertEqual(env["HOME"], original["HOME"])
        self.assertEqual(env["CODEX_HOME"], original["CODEX_HOME"])
        self.assertEqual(env["DEPOT_TOOLS_UPDATE"], "0")
        self.assertNotIn("VPYTHON_BYPASS", env)
        self.assertEqual(original["PATH"], "/usr/bin")
        for key in ("CIPD_CACHE_DIR", "VPYTHON_VIRTUALENV_ROOT", "XDG_CACHE_HOME", "BOTO_CONFIG", "TMPDIR"):
            self.assertTrue(Path(env[key]).is_relative_to(work))

    def test_config_is_idempotent_but_does_not_overwrite(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / ".gclient"
            ensure_text(path, "original")
            ensure_text(path, "original")
            with self.assertRaises(ValueError):
                ensure_text(path, "different")
            self.assertEqual(path.read_text(), "original")

    def test_gclient_uses_no_shared_cache_and_unmanaged_root(self):
        config = gclient_config(load_manifest())
        self.assertIn("cache_dir = None", config)
        self.assertIn("'managed': False", config)

    def test_sdk_comparison_is_numeric_and_validated(self):
        self.assertTrue(sdk_supported("26.2", "15"))
        self.assertFalse(sdk_supported("26.2", "26.5"))
        self.assertTrue(sdk_supported("26.10", "26.5"))
        self.assertTrue(sdk_supported("15.0", "15"))
        with self.assertRaises(ValueError):
            sdk_supported("unknown", "15")

    def test_internal_or_disconnected_volume_refused(self):
        with patch.object(Path, "is_mount", lambda p: p == Path("/")):
            with self.assertRaisesRegex(ValueError, "external"):
                guard_workspace(Path("/tmp/reference"), load_manifest())

    def test_source_toolchain_mismatch_is_not_silently_accepted(self):
        manifest = load_manifest()
        contents = {
            "mac_sdk_overrides.gni": '  mac_sdk_min = "15"',
            "mac_sdk.gni": '  mac_sdk_official_version = "26.5"',
            "update.py": "CLANG_REVISION = 'llvmorg-24-init-3796-g20e97c4b'\nCLANG_SUB_REVISION = 27",
        }
        with patch.object(Path, "read_text", lambda p: contents[p.name]), \
             patch.object(Path, "read_bytes", return_value=b"DEPS fixture"):
            audit = source_audit(Path("/src"), manifest)
            self.assertEqual(len(audit["deps_sha256"]), 64)
            contents["mac_sdk_overrides.gni"] = 'mac_sdk_min = "27"'
            with self.assertRaisesRegex(ValueError, "mismatch"):
                source_audit(Path("/src"), manifest)

    def test_checkout_never_adopts_existing_nonrepo(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with (root / "log").open("w") as log:
                build = ReferenceBuild(root, load_manifest(), log)
                with self.assertRaisesRegex(ValueError, "adopt"):
                    build.checkout_pin(root, load_manifest()["chromium"])

    def test_wrong_origin_head_or_modified_checkout_refused(self):
        spec = load_manifest()["chromium"]
        cases = (("wrong",), (spec["url"], "b" * 40),
                 (spec["url"], spec["revision"], " M DEPS"))
        with patch.object(Path, "is_dir", return_value=True):
            for replies in cases:
                with self.subTest(replies=replies), patch("browser_reference.git_text", side_effect=replies):
                    with self.assertRaises(ValueError):
                        verify_repo(Path("/repo"), spec)

    def test_commands_are_argv_and_fail_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with (root / "log").open("w") as log:
                build = ReferenceBuild(root, load_manifest(), log)
                with patch("browser_reference.subprocess.run", side_effect=subprocess.CalledProcessError(1, "git")) as run:
                    with self.assertRaises(subprocess.CalledProcessError):
                        build.run(["git", "status"])
                    self.assertEqual(run.call_args.args[0], ["git", "status"])
                    self.assertTrue(run.call_args.kwargs["check"])
                    self.assertNotIn("shell", run.call_args.kwargs)

    def test_stage_order_and_failure_invalidate_downstream_records(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            with patch("browser_reference.WORK", root), \
                 patch("browser_reference.guard_workspace", return_value=root), \
                 patch.object(ReferenceBuild, "execute") as execute:
                with patch("sys.argv", ["reference", "source"]):
                    with self.assertRaisesRegex(ValueError, "prior steps"):
                        main()
                execute.assert_not_called()
                for stage in ("tools", "source", "sync"):
                    with patch("sys.argv", ["reference", stage]):
                        self.assertEqual(main(), 0)
                execute.side_effect = subprocess.CalledProcessError(1, "fetch")
                with patch("sys.argv", ["reference", "source"]):
                    with self.assertRaises(subprocess.CalledProcessError):
                        main()
                state = json.loads((root / "state.json").read_text())
                self.assertEqual(state["tools"]["result"], "passed")
                self.assertEqual(state["source"]["result"], "failed/interrupted")
                self.assertNotIn("sync", state)

    def test_status_does_not_create_workspace(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "absent"
            with patch("browser_reference.WORK", root), \
                 patch("sys.argv", ["reference", "status"]), patch("builtins.print"):
                self.assertEqual(main(), 0)
                self.assertFalse(root.exists())

    def test_real_git_checkout_is_pinned_idempotent_and_preserves_edits(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            origin = root / "origin"
            origin.mkdir()
            def git(*args):
                return subprocess.check_output(["git", "-C", str(origin), *args],
                                               text=True, stderr=subprocess.DEVNULL).strip()
            git("init")
            (origin / "fixture").write_text("original\n")
            git("add", "fixture")
            git("-c", "user.name=Reference test", "-c", "user.email=test@example.invalid",
                "-c", "commit.gpgsign=false", "commit", "-m", "fixture")
            spec = {"url": str(origin), "revision": git("rev-parse", "HEAD")}
            checkout = root / "copy"
            with (root / "log").open("w") as log:
                build = ReferenceBuild(root, load_manifest(), log)
                build.checkout_pin(checkout, spec)
                verify_repo(checkout, spec)
                with patch.object(build, "run") as run:
                    build.checkout_pin(checkout, spec)
                    run.assert_not_called()
                (checkout / "fixture").write_text("user edit\n")
                with self.assertRaisesRegex(ValueError, "Tracked changes"):
                    build.checkout_pin(checkout, spec)
                self.assertEqual((checkout / "fixture").read_text(), "user edit\n")

    def test_pinned_python_launcher_bootstrapped_without_updating_tools(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with (root / "log").open("w") as log:
                build = ReferenceBuild(root, load_manifest(), log)
                with patch.object(build, "run") as run, patch("browser_reference.verify_repo"):
                    build.ensure_tool_runtime()
                    self.assertEqual(run.call_args_list[0].args[0], [build.depot / "ensure_bootstrap"])
                    self.assertEqual(run.call_args_list[1].args[0], [build.depot / "python-bin/python3", "--version"])
                    self.assertFalse(any("update_depot_tools" in str(c) for c in run.call_args_list))

    def test_live_status_flags_stale_running_record_and_keeps_success_separate(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "logs").mkdir()
            log = root / "logs/build.log"
            log.write_text("[18/100] 6.0s F CXX obj/example.o\n")
            state = {"build": {"result": "running", "log": str(log)}}
            report = live_status(root, state)
            self.assertIn("no active runner", report["warning"])
            self.assertEqual(report["recorded_result"], "running")
            self.assertIn("[18/100]", report["latest_progress"])
            self.assertFalse((root / ".lock").exists())

    def test_live_status_refuses_external_logs(self):
        with tempfile.TemporaryDirectory() as temp:
            report = live_status(Path(temp), {"build": {"result": "passed", "log": "/etc/hosts"}})
            self.assertIn("outside", report["warning"])
            self.assertNotIn("log_tail", report)

    def test_live_status_detects_lock_and_only_reads_log_tail(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "logs").mkdir()
            log = root / "logs/build.log"
            log.write_text("[1/999] old progress\n" + "x" * 20000 + "\n[90/999] current progress\n")
            with (root / ".lock").open("a") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                report = live_status(root, {"build": {"result": "running", "log": str(log)}})
            self.assertTrue(report["runner_lock_held"])
            self.assertNotIn("warning", report)
            self.assertEqual(report["latest_progress"], "[90/999] current progress")
            self.assertNotIn("old progress", str(report))


if __name__ == "__main__":
    unittest.main()
