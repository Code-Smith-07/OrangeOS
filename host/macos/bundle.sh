#!/bin/sh
# Produce a local, ad-hoc-signed menu-bar companion. No installation required.
set -eu
COMPANION_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
swift build --package-path "$COMPANION_ROOT"
COMPANION_APP="$COMPANION_ROOT/../../build/OrangeOS Companion.app"
mkdir -p "$COMPANION_APP/Contents/MacOS"
cp "$COMPANION_ROOT/Info.plist" "$COMPANION_APP/Contents/Info.plist"
cp "$COMPANION_ROOT/.build/debug/orange-host" "$COMPANION_APP/Contents/MacOS/orange-host"
codesign --force --sign - "$COMPANION_APP"
echo "Companion bundle: $COMPANION_APP"
