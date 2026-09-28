#!/bin/sh
# Host build tools for the WPE WebKit trial, in a project-local virtualenv
# (build/wpe/venv, git-ignored), so nothing is installed system-wide.
# macOS already provides perl, ruby, gperf, make and curl.
set -eu
cd "$(dirname "$0")/../.."
python3 -m venv build/wpe/venv
build/wpe/venv/bin/pip install --quiet --upgrade pip
build/wpe/venv/bin/pip install --quiet \
    meson==1.12.1 ninja==1.13.2 cmake==4.4.3 pkgconf==3.0.7.post0 packaging==26.3
build/wpe/venv/bin/pip freeze
