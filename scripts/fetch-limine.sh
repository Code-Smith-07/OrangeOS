#!/bin/sh
# Fetch the Limine bootloader binaries and protocol header.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BRANCH=v11.x-binary
DEST=third_party/limine

if [ -d "$DEST" ]; then
    echo "fetch-limine: $DEST already present"
else
    git clone https://github.com/limine-bootloader/limine.git \
        --branch="$BRANCH" --depth=1 "$DEST"
fi

if [ ! -f "$DEST/limine.h" ]; then
    curl -fsSL \
      https://raw.githubusercontent.com/limine-bootloader/limine-protocol/trunk/include/limine.h \
      -o "$DEST/limine.h"
fi

# Build the host-side 'limine' helper used for BIOS install.
if [ ! -x "$DEST/limine" ] && [ -f "$DEST/Makefile" ]; then
    make -C "$DEST" >/dev/null 2>&1 || true
fi

echo "fetch-limine: ready"
