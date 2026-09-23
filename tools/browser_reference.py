#!/usr/bin/env python3
"""Explicit, resumable upstream reference-build steps on the external volume.

Default action is read-only status. No global PATH/config changes, automatic
Xcode installation, clean/reset, or guest-image modification. This builds a Mac
test shell, NOT the native OrangeOS browser. Sources/caches/output stay beneath
the project build/browser directory. Failed commands retain logs and checkouts.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import time

from browser_preflight import collect, assess

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "tools/browser/upstream.json"
WORK = ROOT / "build/browser"
STAGES = ("tools", "source", "sync", "hooks", "generate", "build")


def load_manifest(path=MANIFEST):
    manifest = json.loads(path.read_text())
    if manifest["schema_version"] != 1:
        raise ValueError("Unsupported manifest schema")
    for name in ("chromium", "depot_tools"):
        if not re.fullmatch(r"[0-9a-f]{40}", manifest[name]["revision"]):
            raise ValueError(f"{name} must use a full commit hash")
    return manifest


def fingerprint(manifest):
    return hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest()


def sdk_supported(actual, minimum):
    def version(value):
        if not re.fullmatch(r"\d+(\.\d+){0,2}", value):
            raise ValueError(f"Unrecognized SDK version: {value}")
        parts = tuple(int(part) for part in value.split("."))
        return parts + (0,) * (3 - len(parts))
    return version(actual) >= version(minimum)


def gclient_config(manifest):
    return "solutions = " + repr([{"name": "src", "url": manifest["chromium"]["url"],
        "managed": False, "custom_deps": {}, "custom_vars": {}}]) + "\ncache_dir = None\n"


def environment(work, original=None):
    env = dict(os.environ if original is None else original)
    # Never inherit an opt-out of the pinned Python runtime or a different tools tree.
    env.pop("VPYTHON_BYPASS", None)
    env.update({
        "PATH": env.get("PATH", os.defpath) + os.pathsep + str(work / "depot_tools"),
        "DEPOT_TOOLS_UPDATE": "0",
        "DEPOT_TOOLS_DIR": str(work / "depot_tools"),
        "DEPOT_TOOLS_METRICS": "0",
        "PYTHONUNBUFFERED": "1",
        "GIT_TERMINAL_PROMPT": "0",
        "CIPD_CACHE_DIR": str(work / "cache/cipd"),
        "VPYTHON_VIRTUALENV_ROOT": str(work / "cache/vpython"),
        "XDG_CACHE_HOME": str(work / "cache/xdg"),
        "BOTO_CONFIG": str(work / "cache/public-downloads.boto"),
        "TMPDIR": str(work / "tmp"),
    })
    return env


def source_audit(src, manifest):
    """Inspect constants, never execute DEPS or imported upstream Python."""
    sdk = (src / "build/config/mac/mac_sdk_overrides.gni").read_text()
    official = (src / "build/config/mac/mac_sdk.gni").read_text()
    clang = (src / "tools/clang/scripts/update.py").read_text()
    def value(text, name):
        match = re.search(r"^\s*" + re.escape(name) + r"\s*=\s*['\"]?([\w.\-]+)", text, re.M)
        if not match:
            raise ValueError(f"Pinned source no longer declares {name}")
        return match[1]
    actual = {"mac_sdk_minimum": value(sdk, "mac_sdk_min"),
              "mac_sdk_official": value(official, "mac_sdk_official_version"),
              "clang_package": value(clang, "CLANG_REVISION") + "-" + value(clang, "CLANG_SUB_REVISION")}
    for key, found in actual.items():
        if found != manifest["toolchain"][key]:
            raise ValueError(f"Toolchain lock mismatch: {key}: {found}")
    actual["deps_sha256"] = hashlib.sha256((src / "DEPS").read_bytes()).hexdigest()
    return actual


def ensure_text(path, text):
    """Create our configuration once; refuse to replace differing user content."""
    if path.exists():
        if path.read_text() != text:
            raise ValueError(f"Refusing to overwrite modified configuration: {path}")
    else:
        with path.open("x") as stream:
            stream.write(text)


def git_text(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()


def verify_repo(repo, spec):
    if not (repo / ".git").is_dir():
        raise ValueError(f"Not an owned Git checkout: {repo}")
    if git_text(repo, "remote", "get-url", "origin") != spec["url"]:
        raise ValueError(f"Unexpected origin in {repo}")
    if git_text(repo, "rev-parse", "HEAD") != spec["revision"]:
        raise ValueError(f"Wrong revision in {repo}; refusing to reset existing work")
    if git_text(repo, "status", "--porcelain", "--untracked-files=no"):
        raise ValueError(f"Tracked changes in {repo}; preserve/review them before continuing")


def guard_workspace(work, manifest):
    work = work.resolve()
    # A disconnected drive must never fall back to the internal startup volume.
    existing = next(p for p in (work, *work.parents) if p.exists())
    mount = next(p for p in (existing, *existing.parents) if p.is_mount())
    if mount.parent != Path("/Volumes"):
        raise ValueError("Reference workspace must be on a mounted external /Volumes volume")
    if any(c.isspace() for c in str(work)):
        raise ValueError("Chromium workspace cannot contain whitespace")
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ValueError("This reference profile is qualified for an arm64 Mac only")
    facts = collect(existing)
    # Tools are installed by our first stage; all other preflight checks apply.
    facts["depot_tools"] = True
    blockers = assess(facts)["build_blockers"]
    if blockers:
        raise ValueError("; ".join(blockers))
    if not sdk_supported(facts["sdk"]["stdout"], manifest["toolchain"]["mac_sdk_minimum"]):
        raise ValueError("Installed SDK is older than the pinned source's development minimum")
    return work


class ReferenceBuild:
    def __init__(self, work, manifest, log):
        self.work, self.manifest, self.log = work, manifest, log
        self.env = environment(work)
        self.depot = work / "depot_tools"
        self.checkout = work / "checkout"
        self.src = self.checkout / "src"
        # depot_tools documents appending itself to PATH. Refuse a stale tool
        # earlier on PATH instead of silently using another checkout's runtime.
        vpython = shutil.which("vpython3", path=self.env["PATH"])
        if vpython and Path(vpython).resolve() != (self.depot / "vpython3").resolve():
            raise ValueError("A different vpython3 precedes the pinned tools in PATH")

    def run(self, argv, cwd=None):
        argv = [str(a) for a in argv]
        print("Running:", " ".join(argv), flush=True)
        self.log.write(json.dumps({"command": argv, "cwd": str(cwd or self.work)}) + "\n")
        self.log.flush()
        subprocess.run(argv, cwd=cwd or self.work, env=self.env,
                       stdout=self.log, stderr=subprocess.STDOUT, check=True)

    def checkout_pin(self, repo, spec):
        if repo.exists():
            # An interrupted fetch leaves our .git with no HEAD. Never adopt
            # a pre-existing directory without the exact expected origin.
            if not (repo / ".git").is_dir() or git_text(repo, "remote", "get-url", "origin") != spec["url"]:
                raise ValueError(f"Refusing to adopt existing directory: {repo}")
            head = subprocess.run(["git", "-C", str(repo), "rev-parse", "--verify", "HEAD"],
                                  capture_output=True)
            if head.returncode == 0:
                verify_repo(repo, spec)
                return
            if any(p.name != ".git" for p in repo.iterdir()):
                raise ValueError(f"Unfinished checkout contains files; review {repo}")
        else:
            self.run(["git", "init", repo])
            self.run(["git", "remote", "add", "origin", spec["url"]], repo)
        self.run(["git", "-c", "http.lowSpeedLimit=1024", "-c", "http.lowSpeedTime=120",
                  "fetch", "--depth=1", "--no-tags", "origin", spec["revision"]], repo)
        self.run(["git", "checkout", "--detach", spec["revision"]], repo)
        verify_repo(repo, spec)

    def ensure_tool_runtime(self):
        # gclient uses vpython, but gn/autoninja use python-bin/python3. With
        # auto-update disabled, gclient alone does NOT bootstrap that launcher.
        # ensure_bootstrap explicitly keeps the existing depot_tools revision.
        if not (self.depot / "python3_bin_reldir.txt").is_file():
            self.run([self.depot / "ensure_bootstrap"])
        self.run([self.depot / "python-bin/python3", "--version"])
        verify_repo(self.depot, self.manifest["depot_tools"])

    def execute(self, stage):
        if stage == "tools":
            self.checkout_pin(self.depot, self.manifest["depot_tools"])
            self.ensure_tool_runtime()
            self.run([self.depot / "gclient", "--version"])
            verify_repo(self.depot, self.manifest["depot_tools"])
            return
        verify_repo(self.depot, self.manifest["depot_tools"])
        self.ensure_tool_runtime()
        if stage == "source":
            self.checkout.mkdir(exist_ok=True)
            ensure_text(self.checkout / ".gclient", gclient_config(self.manifest))
            self.checkout_pin(self.src, self.manifest["chromium"])
            audit = source_audit(self.src, self.manifest)
            ensure_text(self.work / "source-audit.json", json.dumps(audit, indent=2) + "\n")
            return
        verify_repo(self.src, self.manifest["chromium"])
        source_audit(self.src, self.manifest)
        config = self.checkout / ".gclient"
        if not config.exists() or config.read_text() != gclient_config(self.manifest):
            raise ValueError("Missing or modified .gclient; refusing to sync different dependencies")
        if stage == "sync":
            self.run([self.depot / "gclient", "sync", "--nohooks", "--no-history", "--jobs=2",
                      "--revision", "src@" + self.manifest["chromium"]["revision"]], self.checkout)
            self.run([self.depot / "gclient", "revinfo", "--actual"], self.checkout)
        elif stage == "hooks":
            self.run([self.depot / "gclient", "runhooks"], self.checkout)
            stamp = self.src / "third_party/llvm-build/Release+Asserts/cr_build_revision"
            if stamp.read_text().strip().partition(",")[0] != self.manifest["toolchain"]["clang_package"]:
                raise ValueError("Downloaded Clang stamp differs from pinned package")
            self.run([self.src / "third_party/llvm-build/Release+Asserts/bin/clang", "--version"])
            self.run([self.src / "third_party/rust-toolchain/bin/rustc", "--version"])
        elif stage == "generate":
            output = self.src / "out/OrangeReference"
            output.mkdir(parents=True, exist_ok=True)
            args = "".join(f"{k} = {json.dumps(v)}\n" for k, v in sorted(self.manifest["gn_args"].items()))
            ensure_text(output / "args.gn", args)
            self.run([self.depot / "gn", "gen", "out/OrangeReference"], self.src)
        elif stage == "build":
            self.run([self.depot / "autoninja", "-C", "out/OrangeReference", "-j", "2", "content_shell"], self.src)
        verify_repo(self.src, self.manifest["chromium"])
        verify_repo(self.depot, self.manifest["depot_tools"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", nargs="?", default="status", choices=("status", "preflight", *STAGES))
    args = parser.parse_args()
    manifest = load_manifest()
    state_path = WORK / "state.json"
    state = json.loads(state_path.read_text()) if state_path.exists() else {}
    if args.stage == "status":
        print(json.dumps({"workspace": str(WORK), "pins": manifest,
                          "recorded_steps": state, "native_browser": "NOT IMPLEMENTED"}, indent=2))
        return 0
    if args.stage == "preflight":
        return subprocess.run([sys.executable, ROOT / "tools/browser_preflight.py",
                               "--build-dir", WORK], env=environment(WORK)).returncode
    work = guard_workspace(WORK, manifest)
    work.mkdir(parents=True, exist_ok=True)
    with (work / ".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        ensure_text(work / "manifest.json", json.dumps(manifest, indent=2) + "\n")
        for directory in ("depot_tools", "checkout", "cache", "tmp", "logs"):
            if not (work / directory).resolve().is_relative_to(work):
                raise ValueError(f"Workspace path escapes the external build directory: {directory}")
        state = json.loads(state_path.read_text()) if state_path.exists() else {}
        previous = STAGES[:STAGES.index(args.stage)]
        if any(state.get(s, {}).get("result") != "passed" or
               state.get(s, {}).get("manifest_sha256") != fingerprint(manifest) for s in previous):
            raise ValueError(f"Complete prior steps first: {', '.join(previous)}")
        for directory in ("cache/cipd", "cache/vpython", "cache/xdg", "cache/gsutil", "tmp", "logs"):
            (work / directory).mkdir(parents=True, exist_ok=True)
        # gsutil doesn't honor XDG_CACHE_HOME. Its explicit, credential-free
        # configuration keeps transfer tracking off the internal disk too.
        ensure_text(work / "cache/public-downloads.boto",
                    f"[GSUtil]\nstate_dir = {work / 'cache/gsutil'}\n")
        # Invalidate dependent records before a retry, so failure cannot retain
        # a stale green build. Only this tool's state file is rewritten.
        state = {k: v for k, v in state.items() if k in previous}
        logfile = work / "logs" / f"{time.time_ns()}-{args.stage}.log"
        record = {"result": "running", "manifest_sha256": fingerprint(manifest), "log": str(logfile)}
        state[args.stage] = record
        state_path.write_text(json.dumps(state, indent=2) + "\n")
        print(f"Log: {logfile}", flush=True)
        try:
            with logfile.open("x") as log:
                ReferenceBuild(work, manifest, log).execute(args.stage)
            record["result"] = "passed"
        except BaseException:
            record["result"] = "failed/interrupted"
            raise
        finally:
            state_path.write_text(json.dumps(state, indent=2) + "\n")
        print(f"Reference step '{args.stage}' passed. Native OrangeOS browser remains unimplemented.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Reference setup stopped: {error}")
