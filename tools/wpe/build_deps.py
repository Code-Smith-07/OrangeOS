#!/usr/bin/env python3
"""Cross-build the WPE WebKit trial's libraries for OrangeOS.

    tools/wpe/build_deps.py zlib libffi pcre2 glib    build these, in order
    tools/wpe/build_deps.py --stage W1                everything W1 needs

Each package is unpacked from its pinned tarball (tools/wpe/fetch.py) into
build/wpe/src, built out of tree in build/wpe/obj, and installed as static
libraries into build/wpe/sysroot. The compilers are tools/wpe/bin/orange-*:
Zig's clang targeting x86_64-linux-musl with the code-generation flags
build.zig uses for OrangeOS C programs. Programs that use these libraries
are linked by build.zig against OrangeOS's own musl (-Dwpe-probes).

Host tools (meson, ninja, cmake, pkg-config) come from build/wpe/venv;
see tools/wpe/setup_host.sh.
"""

import json
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TOOLS = os.path.join(ROOT, "tools", "wpe")
WORK = os.path.join(ROOT, "build", "wpe")
SOURCES = os.path.join(WORK, "sources")
SRC = os.path.join(WORK, "src")
OBJ = os.path.join(WORK, "obj")
SYSROOT = os.path.join(WORK, "sysroot")
VENV_BIN = os.path.join(WORK, "venv", "bin")
BIN = os.path.join(TOOLS, "bin")

CC = os.path.join(BIN, "orange-cc")
CXX = os.path.join(BIN, "orange-c++")
AR = os.path.join(BIN, "orange-ar")
RANLIB = os.path.join(BIN, "orange-ranlib")
HOST = "x86_64-linux-musl"
CFLAGS = "-O2 -g0"


def manifest():
    with open(os.path.join(TOOLS, "sources.json")) as f:
        return {s["name"]: s for s in json.load(f)["sources"]}


def environment():
    env = dict(os.environ)
    env["PATH"] = VENV_BIN + os.pathsep + env["PATH"]
    env["PKG_CONFIG_LIBDIR"] = os.path.join(SYSROOT, "lib", "pkgconfig")
    env.pop("PKG_CONFIG_PATH", None)
    env.update(CC=CC, CXX=CXX, AR=AR, RANLIB=RANLIB, CFLAGS=CFLAGS, CXXFLAGS=CFLAGS)
    return env


def run(command, cwd, env):
    print("  $ " + " ".join(command), flush=True)
    subprocess.run(command, cwd=cwd, env=env, check=True)


def unpack(entry):
    """A clean source tree, so a rebuild never sees stale generated files."""
    subprocess.run([sys.executable, os.path.join(TOOLS, "fetch.py"), entry["name"]], check=True)
    tarball = os.path.join(SOURCES, os.path.basename(entry["url"]))
    stage = os.path.join(WORK, "unpack")
    shutil.rmtree(stage, ignore_errors=True)
    os.makedirs(stage)
    subprocess.run(["tar", "-xf", tarball, "-C", stage], check=True)
    (top,) = os.listdir(stage)
    target = os.path.join(SRC, f"{entry['name']}-{entry['version']}")
    shutil.rmtree(target, ignore_errors=True)
    os.makedirs(SRC, exist_ok=True)
    os.replace(os.path.join(stage, top), target)
    os.rmdir(stage)
    return target


def fresh_build_dir(name):
    path = os.path.join(OBJ, name)
    shutil.rmtree(path, ignore_errors=True)
    os.makedirs(path)
    return path


def cross_file():
    """Meson's description of the OrangeOS target (absolute paths)."""
    path = os.path.join(WORK, "orangeos-x86_64.ini")
    with open(os.path.join(TOOLS, "orangeos-x86_64.ini.in")) as f:
        text = f.read()
    text = text.replace("@BIN@", BIN).replace("@VENV_BIN@", VENV_BIN).replace("@SYSROOT@", SYSROOT)
    with open(path, "w") as f:
        f.write(text)
    return path


# ── Recipes ─────────────────────────────────────────────────────────────────


def autotools(src, name, env, *options):
    build = fresh_build_dir(name)
    run([os.path.join(src, "configure"), f"--host={HOST}", f"--prefix={SYSROOT}",
         "--disable-shared", "--enable-static", *options], build, env)
    run(["make", f"-j{os.cpu_count()}"], build, env)
    run(["make", "install"], build, env)


def build_zlib(src, env):
    # zlib's configure is not autoconf: it reads CC/AR from the environment
    # and has no --host; CHOST stops it choosing Apple's libtool.
    build = fresh_build_dir("zlib")
    env = dict(env, CHOST=HOST)
    run([os.path.join(src, "configure"), "--static", f"--prefix={SYSROOT}"], build, env)
    run(["make", f"-j{os.cpu_count()}", "libz.a"], build, env)
    run(["make", "install"], build, env)


def build_libffi(src, env):
    autotools(src, "libffi", env, "--disable-docs", "--disable-multi-os-directory", "--disable-exec-static-tramp")


def build_pcre2(src, env):
    autotools(src, "pcre2", env, "--enable-unicode", "--disable-pcre2grep-libz",
              "--disable-pcre2grep-libbz2", "--disable-pcre2test-libreadline")


def build_glib(src, env):
    build = fresh_build_dir("glib")
    run(["meson", "setup", build, src, "--cross-file", cross_file(), f"--prefix={SYSROOT}",
         "--libdir=lib", "--buildtype=release", "--default-library=static",
         "--wrap-mode=nodownload",
         "-Dtests=false", "-Dinstalled_tests=false", "-Dintrospection=disabled",
         "-Ddocumentation=false", "-Dman-pages=disabled", "-Dnls=disabled",
         "-Dselinux=disabled", "-Dxattr=false", "-Dlibmount=disabled",
         "-Ddtrace=disabled", "-Dsystemtap=disabled", "-Dsysprof=disabled",
         "-Dlibelf=disabled", "-Dbsymbolic_functions=false"], ROOT, env)
    run(["meson", "compile", "-C", build], ROOT, env)
    run(["meson", "install", "-C", build, "--no-rebuild", "--quiet"], ROOT, env)


RECIPES = {
    "zlib": build_zlib,
    "libffi": build_libffi,
    "pcre2": build_pcre2,
    "glib": build_glib,
}
STAGES = {"W1": ["zlib", "libffi", "pcre2", "glib"]}


def main(argv):
    if argv[:1] == ["--stage"] and len(argv) == 2 and argv[1] in STAGES:
        names = STAGES[argv[1]]
    else:
        names = argv
    unknown = [n for n in names if n not in RECIPES]
    if unknown or not names:
        raise SystemExit(__doc__ + (f"\nno recipe for: {unknown}" if unknown else ""))
    pins = manifest()
    env = environment()
    for name in names:
        print(f"== {name} {pins[name]['version']}", flush=True)
        RECIPES[name](unpack(pins[name]), env)
    print(f"installed into {SYSROOT}")


if __name__ == "__main__":
    main(sys.argv[1:])
