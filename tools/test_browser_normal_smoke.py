import json
from pathlib import Path
import tempfile
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from unittest.mock import patch

from browser_normal_smoke import CHECKS, make_server, run_fixture, validate_report


class NormalSmokeTests(unittest.TestCase):
    def test_report_requires_every_true_check_and_exact_marker(self):
        valid = {"marker": "ORANGE_NORMAL_ENGINE_RESULT",
                 "checks": {name: True for name in CHECKS}}
        self.assertTrue(validate_report(valid))
        self.assertFalse(validate_report({**valid, "marker": "wrong"}))
        self.assertFalse(validate_report({**valid, "checks": {"javascript": True}}))
        self.assertFalse(validate_report({**valid, "checks": {**valid["checks"], "http": False}}))
        self.assertFalse(validate_report({**valid, "checks": {**valid["checks"], "extra": True}}))

    def test_loopback_server_only_serves_token_paths_and_bounded_report(self):
        server, reports = make_server(b"<h1>fixture</h1>", "test-token")
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = f"http://127.0.0.1:{server.server_port}"
        try:
            self.assertEqual(urlopen(base + "/test-token/fixture").read(), b"<h1>fixture</h1>")
            self.assertEqual(urlopen(base + "/test-token/ping").read(), b"pong")
            with self.assertRaises(HTTPError) as denied:
                urlopen(base + "/wrong/fixture")
            self.assertEqual(denied.exception.code, 404)
            payload = {"marker": "ORANGE_NORMAL_ENGINE_RESULT",
                       "checks": {name: True for name in CHECKS}}
            request = Request(base + "/test-token/report", data=json.dumps(payload).encode(),
                              headers={"Content-Type": "application/json"}, method="POST")
            self.assertEqual(urlopen(request).status, 200)
            self.assertEqual(reports.get_nowait(), payload)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_early_exit_fails_without_test_or_security_bypass_switches(self):
        with tempfile.TemporaryDirectory() as temp:
            evidence = Path(temp)
            fixture = evidence / "fixture.html"
            fixture.write_text("<title>fixture</title>")
            with patch("browser_normal_smoke.subprocess.Popen") as popen, \
                 patch("browser_normal_smoke.stop_process_group"):
                process = popen.return_value
                process.poll.return_value = 1
                process.returncode = 1
                report = run_fixture(Path("/test/Content Shell"), fixture, evidence, {}, timeout=1)
            self.assertFalse(report["passed"])
            self.assertEqual(report["early_exit"], 1)
            argv = popen.call_args.args[0]
            self.assertTrue(argv[-1].startswith("http://127.0.0.1:"))
            self.assertFalse(any("web-tests" in part or "no-sandbox" in part or
                                 "ignore-certificate" in part for part in argv))
            self.assertTrue(popen.call_args.kwargs["start_new_session"])


if __name__ == "__main__":
    unittest.main()
