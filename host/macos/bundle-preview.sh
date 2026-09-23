#!/bin/sh
# Local wrapper around the already installed QEMU; no downloaded executable.
# A real app identity makes the VM addressable by macOS window/accessibility UI.
set -eu
PREVIEW_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PREVIEW_APP="$PREVIEW_ROOT/../../build/OrangeOS Preview.app"
PREVIEW_QEMU="$(command -v qemu-system-x86_64)"
mkdir -p "$PREVIEW_APP/Contents/MacOS"
cp "$PREVIEW_ROOT/QemuPreview.plist" "$PREVIEW_APP/Contents/Info.plist"
cp "$PREVIEW_QEMU" "$PREVIEW_APP/Contents/MacOS/orange-qemu"
codesign --force --sign - "$PREVIEW_APP"
echo "Preview bundle: $PREVIEW_APP"
