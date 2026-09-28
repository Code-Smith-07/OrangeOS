#!/usr/bin/env python3
"""Download and verify the pinned WPE WebKit trial sources.

    tools/wpe/fetch.py glib pcre2      fetch (or re-verify) named sources
    tools/wpe/fetch.py --stage W1      fetch everything a milestone needs
    tools/wpe/fetch.py --pin           fetch all, record sha256 in sources.json

Tarballs go to build/wpe/sources/ (git-ignored). A fetched file must match
its recorded sha256, and where upstream publishes a checksum, that too;
a mismatch deletes the file and fails. --pin only fills entries without a
recorded hash, so a pin never silently changes.
"""

import hashlib
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MANIFEST = os.path.join(ROOT, "tools", "wpe", "sources.json")
DEST = os.path.join(ROOT, "build", "wpe", "sources")


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def curl(url, out=None):
    """The system curl verifies TLS against the macOS keychain; python.org
    builds of Python ship without a CA store."""
    command = ["curl", "-fsSL", "--retry", "3", "--max-time", "900", url]
    if out:
        subprocess.run(command + ["-o", out], check=True)
        return None
    return subprocess.run(command, check=True, capture_output=True).stdout


def published_sha256(entry):
    if "published_sha256" in entry:
        return entry["published_sha256"]
    url = entry.get("published")
    if not url:
        return None
    text = curl(url).decode("utf-8", "replace")
    name = os.path.basename(entry["url"])
    for line in text.splitlines():
        match = re.search(r"\b([0-9a-f]{64})\b", line)
        if match and (name in line or len(text.split()) <= 2):
            return match.group(1)
    raise SystemExit(f"{entry['name']}: no checksum for {name} in {url}")


def fetch(entry):
    os.makedirs(DEST, exist_ok=True)
    path = os.path.join(DEST, os.path.basename(entry["url"]))
    if not os.path.exists(path):
        print(f"fetch  {entry['name']} {entry['version']}", flush=True)
        partial = path + ".part"
        curl(entry["url"], partial)
        os.replace(partial, path)
    actual = sha256_of(path)
    expected = [v for v in (entry.get("sha256"), published_sha256(entry)) if v]
    for value in expected:
        if value != actual:
            os.remove(path)
            raise SystemExit(f"{entry['name']}: sha256 {actual} != expected {value}; file removed")
    size = os.path.getsize(path) / (1 << 20)
    checks = "pinned+published" if len(expected) == 2 else ("verified" if expected else "unpinned")
    print(f"ok     {entry['name']:<16} {entry['version']:<10} {size:7.1f} MiB  {checks}")
    return actual


def main(argv):
    with open(MANIFEST) as f:
        manifest = json.load(f)
    sources = manifest["sources"]
    by_name = {s["name"]: s for s in sources}

    if argv[:1] == ["--pin"]:
        for entry in sources:
            digest = fetch(entry)
            entry.setdefault("sha256", digest)
        with open(MANIFEST, "w") as f:
            json.dump(manifest, f, indent=2)
            f.write("\n")
        return
    if argv[:1] == ["--stage"] and len(argv) == 2:
        chosen = [s for s in sources if s["stage"] == argv[1]]
    else:
        unknown = [n for n in argv if n not in by_name]
        if unknown or not argv:
            raise SystemExit(__doc__ + f"\nunknown: {unknown}" if unknown else __doc__)
        chosen = [by_name[n] for n in argv]
    for entry in chosen:
        if "sha256" not in entry:
            raise SystemExit(f"{entry['name']} has no pinned sha256; run --pin first")
        fetch(entry)


if __name__ == "__main__":
    main(sys.argv[1:])
