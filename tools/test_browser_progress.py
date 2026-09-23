#!/usr/bin/env python3
import fcntl
import json
from pathlib import Path
import tempfile
import unittest

from browser_progress import last_action, render, snapshot


class ProgressTests(unittest.TestCase):
    def test_last_action_reads_tail_and_ignores_footer(self):
        with tempfile.TemporaryDirectory() as temp:
            log = Path(temp) / "build.log"
            log.write_text("[1/20] old\n" + "x" * 70000 +
                           "\n[7/18] 2.0s F CXX obj/latest.o\nBuild Failure: interrupted\n")
            self.assertEqual(last_action(log), (7, 18, "2.0s F CXX obj/latest.o"))

    def test_incremental_percentage_and_ascii_rendering(self):
        with tempfile.TemporaryDirectory() as temp:
            work = Path(temp)
            logs = work / "logs"
            logs.mkdir()
            (logs / "1-build.log").write_text("[40/100] previous\n")
            active = logs / "2-build.log"
            active.write_text("[10/60] current\n")
            (work / "state.json").write_text(json.dumps({
                "build": {"result": "running", "log": str(active), "local_jobs": 5}}))
            with (work / ".lock").open("a") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                report = snapshot(work)
            self.assertEqual(report["result"], "running")
            self.assertEqual(report["percent"], 50.0)
            self.assertEqual(report["remaining"], 50)
            self.assertEqual(report["attempts"], 2)
            display = render(report)
            self.assertIn("50.0% complete", display)
            self.assertIn("50.0%", display)
            self.assertIn("Workers: 5", display)
            self.assertIn("Ctrl-C", display)

    def test_stale_runner_is_not_reported_as_active(self):
        with tempfile.TemporaryDirectory() as temp:
            work = Path(temp)
            logs = work / "logs"
            logs.mkdir()
            log = logs / "1-build.log"
            log.write_text("[4/10] action\n")
            (work / "state.json").write_text(json.dumps({"build": {
                "result": "running", "log": str(log)}}))
            report = snapshot(work)
            self.assertEqual(report["result"], "stale/interrupted")
            self.assertFalse(report["running"])
            self.assertAlmostEqual(report["percent"], 40)

    def test_passed_record_shows_complete_and_external_log_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            work = Path(temp)
            logs = work / "logs"
            logs.mkdir()
            log = logs / "1-build.log"
            log.write_text("[10/10] final\n")
            state = work / "state.json"
            state.write_text(json.dumps({"build": {"result": "passed", "log": str(log)}}))
            self.assertEqual(snapshot(work)["percent"], 100)
            state.write_text(json.dumps({"build": {"result": "running", "log": "/etc/hosts"}}))
            self.assertEqual(snapshot(work)["result"], "invalid log path")

    def test_missing_workspace_does_not_create_files(self):
        with tempfile.TemporaryDirectory() as temp:
            work = Path(temp) / "absent"
            self.assertEqual(snapshot(work)["result"], "not started")
            self.assertFalse(work.exists())


if __name__ == "__main__":
    unittest.main()
