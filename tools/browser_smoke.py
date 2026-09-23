#!/usr/bin/env python3
"""Local-only Chromium host-reference smoke, NOT OrangeOS or security qualification.

Upstream --run-web-tests alters browser policy (including certificate checks).
This runner therefore accepts NO URL and only loads our checked-in file fixture.
Never use this mode for public browsing or HTTPS/sandbox acceptance tests.
"""
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

from browser_reference import (ROOT, WORK, environment, fingerprint, guard_workspace,
                               load_manifest, verify_repo)

CHECKS = ("javascript", "dom", "css-layout", "canvas", "async")
APP = Path("checkout/src/out/OrangeReference/Content Shell.app/Contents/MacOS/Content Shell")
FIXTURE = ROOT / "tools/browser/fixtures/engine-smoke.html"


def validate_output(output, returncode):
    lines = output.splitlines()
    return (returncode == 0 and
            lines.count("ORANGE_REFERENCE_ENGINE_PASS") == 1 and
            not any("ORANGE_REFERENCE_ENGINE_FAIL" in line for line in lines) and
            all(lines.count("PASS " + check) == 1 for check in CHECKS))


def require_build(work, manifest):
    state = json.loads((work / "state.json").read_text())
    record = state.get("build", {})
    if record.get("result") != "passed" or record.get("manifest_sha256") != fingerprint(manifest):
        raise ValueError("A successful reference build at the current pins is required first")
    binary = work / APP
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError("Built Content Shell executable is missing or not executable")
    verify_repo(work / "checkout/src", manifest["chromium"])
    return binary


def run_fixture(binary, fixture, evidence, env, timeout=90):
    argv = [str(binary), "--run-web-tests", fixture.resolve().as_uri()]
    timed_out = False
    with (evidence / "stdout.log").open("xb") as stdout, (evidence / "stderr.log").open("xb") as stderr:
        process = subprocess.Popen(argv, env=env, cwd=evidence, stdin=subprocess.DEVNULL,
                                   stdout=stdout, stderr=stderr, start_new_session=True)
        try:
            returncode = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            # Only the new test process group; never unrelated user browsers.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            returncode = process.wait()
        finally:
            # Clean up any child left in our group even if the parent exited.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
    output = (evidence / "stdout.log").read_text(errors="replace")
    return {"passed": not timed_out and validate_output(output, returncode),
            "returncode": returncode, "timed_out": timed_out, "command": argv,
            "scope": "macOS reference only: JS/DOM/CSS/canvas/async local fixture",
            "security_qualification": "NOT TESTED: upstream web-test mode modifies policy",
            "native_orangeos_browser": "NOT IMPLEMENTED"}


def main():
    manifest = load_manifest()
    work = guard_workspace(WORK, manifest)
    # Existing lock only: no creating a workspace just to report missing build.
    with (work / ".lock").open("r") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        binary = require_build(work, manifest)
        evidence = Path(tempfile.mkdtemp(prefix="engine-smoke-", dir=work / "logs"))
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
        raise SystemExit(f"Reference smoke stopped: {error}")
