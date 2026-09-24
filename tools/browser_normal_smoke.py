#!/usr/bin/env python3
"""Normal-mode Mac Content Shell fixture; NOT native OrangeOS qualification.

Only an unpredictable loopback URL is served. No web-test, no-sandbox,
certificate-bypass, remote-debugging, or public-website switches are used.
"""

import fcntl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import queue
import secrets
import signal
import subprocess
import tempfile
import threading
import time

from browser_reference import ROOT, WORK, environment, fingerprint, guard_workspace, load_manifest
from browser_smoke import require_build


CHECKS = frozenset(("javascript", "dom", "css-layout", "canvas", "async", "http"))
FIXTURE = ROOT / "tools/browser/fixtures/normal-engine-smoke.html"


def validate_report(payload):
    return (isinstance(payload, dict) and
            payload.get("marker") == "ORANGE_NORMAL_ENGINE_RESULT" and
            isinstance(payload.get("checks"), dict) and
            set(payload["checks"]) == CHECKS and
            all(payload["checks"][name] is True for name in CHECKS))


def make_server(fixture_bytes, token):
    reports = queue.Queue(maxsize=1)
    prefix = "/" + token + "/"

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def send_bytes(self, code, data, content_type="text/plain; charset=utf-8"):
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.path == prefix + "fixture":
                self.send_bytes(200, fixture_bytes, "text/html; charset=utf-8")
            elif self.path == prefix + "ping":
                self.send_bytes(200, b"pong")
            else:
                self.send_bytes(404, b"not found")

        def do_POST(self):
            if self.path != prefix + "report" or self.headers.get_content_type() != "application/json":
                self.send_bytes(404, b"not found")
                return
            try:
                size = int(self.headers.get("Content-Length", ""))
            except ValueError:
                size = 0
            if not 0 < size <= 4096:
                self.send_bytes(413, b"invalid report size")
                return
            try:
                payload = json.loads(self.rfile.read(size))
            except (UnicodeDecodeError, json.JSONDecodeError):
                self.send_bytes(400, b"invalid report")
                return
            try:
                reports.put_nowait(payload)
            except queue.Full:
                self.send_bytes(409, b"duplicate report")
                return
            self.send_bytes(200, b"received")

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    return server, reports


def stop_process_group(process):
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=5)
        except (ProcessLookupError, subprocess.TimeoutExpired):
            pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def run_fixture(binary, fixture, evidence, env, timeout=60):
    token = secrets.token_urlsafe(18)
    profile = evidence / "profile"
    profile.mkdir()
    server, reports = make_server(fixture.read_bytes(), token)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{server.server_port}/{token}/fixture"
    argv = [str(binary), f"--user-data-dir={profile}", url]
    payload = None
    early_exit = None
    process = None
    started = time.monotonic()
    try:
        with (evidence / "stdout.log").open("xb") as stdout, (evidence / "stderr.log").open("xb") as stderr:
            process = subprocess.Popen(argv, env=env, cwd=evidence, stdin=subprocess.DEVNULL,
                                       stdout=stdout, stderr=stderr, start_new_session=True)
            deadline = started + timeout
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                try:
                    payload = reports.get(timeout=min(0.5, remaining))
                    early_exit = process.poll()
                    break
                except queue.Empty:
                    if process.poll() is not None:
                        early_exit = process.returncode
                        break
    finally:
        if process is not None:
            stop_process_group(process)
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
    return {"passed": validate_report(payload) and early_exit in (None, 0),
            "received_report": payload is not None,
            "checks": payload.get("checks") if isinstance(payload, dict) else None,
            "early_exit": early_exit, "timed_out": payload is None and early_exit is None,
            "elapsed_seconds": round(time.monotonic() - started, 2),
            "command": argv, "scope": "normal-mode Mac Content Shell, loopback HTTP fixture only",
            "security_qualification": "NOT TESTED: no HTTPS, certificate or sandbox negative tests",
            "native_orangeos_browser": "NOT IMPLEMENTED"}


def main():
    manifest = load_manifest()
    work = guard_workspace(WORK, manifest)
    with (work / ".lock").open("r") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        binary = require_build(work, manifest)
        evidence = Path(tempfile.mkdtemp(prefix="normal-engine-smoke-", dir=work / "logs"))
        report = run_fixture(binary, FIXTURE, evidence, environment(work))
        report.update({"manifest_sha256": fingerprint(manifest), "timestamp": time.time(),
                       "evidence": str(evidence)})
        with (evidence / "result.json").open("x") as out:
            json.dump(report, out, indent=2)
        print(json.dumps(report, indent=2))
        return 0 if report["passed"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError) as error:
        raise SystemExit(f"Normal-mode reference smoke stopped: {error}")
