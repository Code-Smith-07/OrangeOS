#!/bin/sh
# Boot the existing OS in the native-browser capacity profile, not a browser.
# Additional arguments select a command to run under the same profile.
set -eu
cd "$(dirname "$0")/.."
export ORANGE_VM_PROFILE=browser
. ./scripts/vm-profile.sh
if [ "$#" -eq 0 ]; then
    exec python3 tools/host_bridge_preview.py
fi
exec "$@"
