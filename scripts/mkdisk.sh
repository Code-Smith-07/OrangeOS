#!/bin/sh
# Create a 64 MiB GPT disk image for development.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build
python3 tools/mkdisk/mkdisk.py "$@"
