#!/usr/bin/env python3
"""Read-only native-browser build/VM preflight. Never downloads or installs.

Exit 0: preliminary reference-build checks pass (not a successful build).
Exit 2: a prerequisite is missing. GPU claims require separate guest tests.
"""
import argparse
from dataclasses import asdict
import json
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess

from vm_profile import resolve

ROOT = Path(__file__).resolve().parents[1]
GIB = 1024 ** 3
# OrangeOS planning reserve, not a claim about macOS upstream minimums.
BUILD_FREE_BYTES = 100 * GIB


def probe(argv):
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=10)
        return {"ok": result.returncode == 0, "exit_code": result.returncode,
                "stdout": result.stdout.strip(), "stderr": result.stderr.strip()}
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"ok": False, "error": str(error)}


def assess(facts):
    blockers = []
    if any(char.isspace() for char in facts.get("build_dir", "")):
        blockers.append("Chromium checkout/build path must not contain whitespace")
    if facts["disk_free_bytes"] < BUILD_FREE_BYTES:
        blockers.append("Need an agreed build volume with at least 100 GiB free; no checkout attempted")
    if facts["host_os"] != "Darwin":
        blockers.append("This first reference-build profile is macOS; qualify another build host separately")
    elif not facts["xcode"]["ok"] or not facts["sdk"]["ok"]:
        blockers.append("Full Xcode and macOS SDK are required for the Mac reference build")
    if facts.get("host_arch") not in (None, "arm64", "x86_64"):
        blockers.append("Reference-build host architecture is not qualified")
    if facts.get("filesystem") != "apfs":
        blockers.append("Build volume must be verified as APFS for the Mac reference build")
    if not facts["git"]["ok"]:
        blockers.append("Git is unavailable")
    if not facts["depot_tools"]:
        blockers.append("depot_tools fetch/gclient are not available; installation is a separate step")
    devices = facts["qemu_devices"].get("stdout", "")
    acceleration = "not probed: QEMU device listing failed"
    if facts["qemu_devices"]["ok"]:
        acceleration = ("accelerated device advertised; guest/host support UNQUALIFIED"
                        if any(name in devices for name in ("virtio-gpu-gl", "virtio-vga-gl", "rutabaga"))
                        else "no accelerated virtio-gpu device advertised")
    return {"reference_build_prerequisites": "blocked" if blockers else "preliminary checks passed",
            "build_blockers": blockers,
            "graphics": acceleration,
            "hardware_video_decode": "UNQUALIFIED: no implemented guest decoder backend",
            "native_browser": "NOT IMPLEMENTED: runtime/platform/engine gates remain",
            "reference_build": "NOT RUN",
            "note": "A host reference build is a toolchain check, never the OrangeOS browser"}


def collect(build_dir):
    facts = {"host_os": platform.system(), "host_arch": platform.machine(),
             "build_dir": str(build_dir.resolve()), "filesystem": None,
             "disk_free_bytes": shutil.disk_usage(build_dir).free,
             "git": probe(["git", "--version"]),
             "depot_tools": bool(shutil.which("gclient") and shutil.which("fetch")),
             "xcode": {"ok": False}, "sdk": {"ok": False}}
    if facts["host_os"] == "Darwin":
        facts["xcode"] = probe(["xcodebuild", "-version"])
        facts["sdk"] = probe(["xcrun", "--sdk", "macosx", "--show-sdk-version"])
        facts["host_ram"] = probe(["sysctl", "-n", "hw.memsize"])
        directory = build_dir.resolve()
        mount = next(p for p in (directory, *directory.parents) if p.is_mount())
        facts["build_mount"] = str(mount)
        filesystem = probe(["diskutil", "info", "-plist", str(mount)])
        facts["disk_probe"] = filesystem
        if filesystem["ok"]:
            try:
                facts["filesystem"] = plistlib.loads(filesystem["stdout"].encode()).get("FilesystemType")
            except (ValueError, plistlib.InvalidFileException):
                pass  # Unknown is a blocker, never an assumed compatible filesystem.
    for key, args in (("qemu_version", ["--version"]),
                      ("qemu_accelerators", ["-accel", "help"]),
                      ("qemu_displays", ["-display", "help"]),
                      ("qemu_devices", ["-device", "help"])):
        facts[key] = probe(["qemu-system-x86_64", *args])
    return facts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, default=ROOT,
                        help="Existing directory on the proposed build volume (read-only)")
    parser.add_argument("--output", type=Path, help="Write JSON evidence to a NEW file")
    args = parser.parse_args()
    if not args.build_dir.is_dir():
        parser.error("--build-dir must already exist; no directories are created")
    try:
        profile = resolve()
    except ValueError as error:
        parser.error(str(error))
    facts = collect(args.build_dir)
    report = {"schema_version": 1, "build_dir": str(args.build_dir.resolve()),
              "vm_profile": asdict(profile),
              "planning_free_space_bytes": BUILD_FREE_BYTES,
              "facts": facts, "assessment": assess(facts)}
    rendered = json.dumps(report, indent=2) + "\n"
    if args.output:
        # Exclusive creation prevents destroying existing evidence or user data.
        with args.output.open("x") as out:
            out.write(rendered)
    print(rendered, end="")
    return 2 if report["assessment"]["build_blockers"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
