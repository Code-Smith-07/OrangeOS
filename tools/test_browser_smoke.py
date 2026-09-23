import json
from pathlib import Path
import tempfile
import subprocess
import unittest
from unittest.mock import patch

from browser_reference import load_manifest
from browser_smoke import CHECKS, require_build, run_fixture, validate_output


class EngineSmokeTests(unittest.TestCase):
    def output(self):
        return "\n".join([*("PASS " + check for check in CHECKS), "ORANGE_REFERENCE_ENGINE_PASS"])

    def test_all_checks_and_successful_exit_required(self):
        self.assertTrue(validate_output(self.output(), 0))
        self.assertFalse(validate_output(self.output(), 1))
        self.assertFalse(validate_output(self.output(), -9))
        for check in CHECKS:
            self.assertFalse(validate_output(self.output().replace("PASS " + check, "MISSING"), 0))

    def test_marker_cannot_mask_failure_or_duplicates(self):
        self.assertFalse(validate_output("ORANGE_REFERENCE_ENGINE_PASS", 0))
        self.assertFalse(validate_output(self.output() + "\nORANGE_REFERENCE_ENGINE_FAIL canvas", 0))
        self.assertFalse(validate_output(self.output() + "\nPASS canvas", 0))
        self.assertFalse(validate_output(self.output() + "\nORANGE_REFERENCE_ENGINE_PASS", 0))

    def test_incomplete_build_refused_before_launch(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for result in ("running", "failed/interrupted", "passed"):
                (root / "state.json").write_text(json.dumps({"build": {"result": result}}))
                with patch("browser_smoke.verify_repo") as verify:
                    with self.assertRaisesRegex(ValueError, "successful reference build"):
                        require_build(root, load_manifest())
                    verify.assert_not_called()

    def test_fixture_launch_uses_local_file_and_timeout_fails_even_with_pass_text(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fixture = root / "fixture.html"
            fixture.write_text("local test fixture")
            with patch("browser_smoke.subprocess.Popen") as popen, patch("browser_smoke.os.killpg") as kill:
                process = popen.return_value
                process.pid = 123456
                process.wait.side_effect = [subprocess.TimeoutExpired("fixture", 90), -9, -9]
                def launch(*args, **kwargs):
                    kwargs["stdout"].write(self.output().encode())
                    kwargs["stdout"].flush()
                    return process
                popen.side_effect = launch
                report = run_fixture(Path("/test/Content Shell"), fixture, root, {})
                self.assertFalse(report["passed"])
                self.assertTrue(report["timed_out"])
                argv = popen.call_args.args[0]
                self.assertEqual(argv[1:], ["--run-web-tests", fixture.resolve().as_uri()])
                self.assertTrue(popen.call_args.kwargs["start_new_session"])
                self.assertEqual(kill.call_args.args[0], process.pid)
