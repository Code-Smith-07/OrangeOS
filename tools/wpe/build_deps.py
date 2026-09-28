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
# Tools built for the Mac itself (bison), kept out of the system.
HOST_TOOLS = os.path.join(WORK, "host")
# Run-time files that belong on the OrangeOS disk (/etc/fonts, /share/...),
# as opposed to headers and libraries for linking.
ROOTFS = os.path.join(WORK, "rootfs")
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
    env["PATH"] = os.pathsep.join([os.path.join(HOST_TOOLS, "bin"), VENV_BIN, env["PATH"]])
    env["PKG_CONFIG_LIBDIR"] = os.path.join(SYSROOT, "lib", "pkgconfig")
    env.pop("PKG_CONFIG_PATH", None)
    env.update(CC=CC, CXX=CXX, AR=AR, RANLIB=RANLIB, CFLAGS=CFLAGS, CXXFLAGS=CFLAGS,
               CPPFLAGS=f"-I{SYSROOT}/include", LDFLAGS=f"-L{SYSROOT}/lib")
    return env


def host_environment():
    """For tools that run on the Mac: the system compiler, no sysroot."""
    env = dict(os.environ)
    env["PATH"] = os.pathsep.join([os.path.join(HOST_TOOLS, "bin"), VENV_BIN, env["PATH"]])
    for key in ("CC", "CXX", "AR", "RANLIB", "CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS", "PKG_CONFIG_LIBDIR"):
        env.pop(key, None)
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


def configured(template):
    """A template from tools/wpe with this checkout's absolute paths."""
    path = os.path.join(WORK, template.removesuffix(".in"))
    with open(os.path.join(TOOLS, template)) as f:
        text = f.read()
    text = text.replace("@BIN@", BIN).replace("@VENV_BIN@", VENV_BIN).replace("@SYSROOT@", SYSROOT)
    with open(path, "w") as f:
        f.write(text)
    return path


def cross_file():
    """Meson's description of the OrangeOS target."""
    return configured("orangeos-x86_64.ini.in")


# ── Recipes ─────────────────────────────────────────────────────────────────


def autotools(src, name, env, *options):
    build = fresh_build_dir(name)
    run([os.path.join(src, "configure"), f"--host={HOST}", f"--prefix={SYSROOT}",
         "--disable-shared", "--enable-static", *options], build, env)
    run(["make", f"-j{os.cpu_count()}"], build, env)
    run(["make", "install"], build, env)


def merge_tree(source, target):
    for base, _dirs, files in os.walk(source):
        destination = os.path.join(target, os.path.relpath(base, source))
        os.makedirs(destination, exist_ok=True)
        for name in files:
            shutil.copy2(os.path.join(base, name), os.path.join(destination, name))


def meson(src, name, env, *options, staged=False):
    """staged: the package also installs to absolute OrangeOS paths
    (configuration, data). It is installed into a staging directory; what
    lands under the sysroot goes to the sysroot, the rest to ROOTFS."""
    build = fresh_build_dir(name)
    run(["meson", "setup", build, src, "--cross-file", cross_file(), f"--prefix={SYSROOT}",
         "--libdir=lib", "--buildtype=release", "--default-library=static",
         "--wrap-mode=nodownload", *options], ROOT, env)
    run(["meson", "compile", "-C", build], ROOT, env)
    if not staged:
        run(["meson", "install", "-C", build, "--no-rebuild", "--quiet"], ROOT, env)
        return
    stage = os.path.join(WORK, "stage", name)
    shutil.rmtree(stage, ignore_errors=True)
    run(["meson", "install", "-C", build, "--no-rebuild", "--quiet", "--destdir", stage], ROOT, env)
    staged_sysroot = stage + SYSROOT
    merge_tree(staged_sysroot, SYSROOT)
    shutil.rmtree(staged_sysroot)
    # Drop the now-empty parents of the sysroot path, and /tmp, which is
    # created at run time on OrangeOS (a tmpfs).
    for base, _dirs, _files in os.walk(stage, topdown=False):
        if not os.listdir(base) or os.path.relpath(base, stage) == "tmp":
            shutil.rmtree(base)
    if os.path.isdir(stage):
        merge_tree(stage, ROOTFS)


def cmake(src, name, env, *options):
    build = fresh_build_dir(name)
    run(["cmake", "-S", src, "-B", build, "-G", "Ninja",
         f"-DCMAKE_TOOLCHAIN_FILE={configured('orangeos-x86_64.cmake.in')}",
         f"-DCMAKE_INSTALL_PREFIX={SYSROOT}", "-DCMAKE_INSTALL_LIBDIR=lib",
         "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_SHARED_LIBS=OFF",
         "-DCMAKE_POLICY_VERSION_MINIMUM=3.5", *options], ROOT, env)
    run(["cmake", "--build", build], ROOT, env)
    run(["cmake", "--install", build], ROOT, env)


def build_bison(src, env):
    # A host tool: libxkbcommon needs bison >= 3.6 and macOS ships 2.3.
    build = fresh_build_dir("bison-host")
    host = host_environment()
    run([os.path.join(src, "configure"), f"--prefix={HOST_TOOLS}", "--disable-nls"], build, host)
    run(["make", f"-j{os.cpu_count()}"], build, host)
    run(["make", "install"], build, host)


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


def build_libpng(src, env):
    autotools(src, "libpng", env, "--disable-tools", "--disable-tests")


def build_libjpeg_turbo(src, env):
    # The SIMD code needs NASM, which is not on the host; the C paths are
    # complete, only slower. Recorded in docs/design/012.
    cmake(src, "libjpeg-turbo", env, "-DENABLE_SHARED=OFF", "-DENABLE_STATIC=ON",
          "-DWITH_SIMD=OFF", "-DWITH_TURBOJPEG=OFF", "-DWITH_TOOLS=OFF", "-DWITH_TESTS=OFF")


def build_libwebp(src, env):
    autotools(src, "libwebp", env, "--enable-libwebpdemux", "--enable-libwebpmux",
              "--disable-gif", "--disable-jpeg", "--disable-png", "--disable-tiff",
              "--disable-gl", "--disable-sdl", "--disable-wic")


def build_brotli(src, env):
    cmake(src, "brotli", env, "-DBROTLI_DISABLE_TESTS=ON", "-DBROTLI_BUILD_TOOLS=OFF")


def build_freetype(src, env):
    # Built before HarfBuzz, so without it (FreeType uses HarfBuzz only for
    # auto-hinting of complex scripts).
    meson(src, "freetype", env, "-Dharfbuzz=disabled", "-Dpng=enabled", "-Dzlib=enabled",
          "-Dbrotli=enabled", "-Dbzip2=disabled", "-Dtests=disabled")


def build_expat(src, env):
    autotools(src, "expat", env, "--without-docbook", "--without-examples",
              "--without-tests", "--without-xmlwf")


def build_fontconfig(src, env):
    meson(src, "fontconfig", env, "-Ddoc=disabled", "-Dtests=disabled", "-Dtools=disabled",
          "-Dcache-build=disabled", "-Dnls=disabled", "-Dxml-backend=expat",
          "-Dfontations=disabled", "-Ddefault-fonts-dirs=/share/fonts",
          "-Dcache-dir=/tmp/fontconfig", "-Dbaseconfig-dir=/etc/fonts",
          "-Dconfig-dir=/etc/fonts/conf.d", "-Dtemplate-dir=/share/fontconfig/conf.avail",
          "-Dxml-dir=/share/xml/fontconfig", staged=True)


def build_icu(src, env):
    # ICU builds its data with its own tools, so it is built twice: once
    # for the Mac (tools only), then for OrangeOS using those tools.
    source = os.path.join(src, "source")
    host_build = fresh_build_dir("icu-host")
    host = host_environment()
    run([os.path.join(source, "configure"), "--disable-tests", "--disable-samples",
         "--disable-extras", "--enable-static", "--disable-shared"], host_build, host)
    run(["make", f"-j{os.cpu_count()}"], host_build, host)
    autotools(source, "icu", env, f"--with-cross-build={host_build}", "--disable-tests",
              "--disable-samples", "--disable-extras", "--disable-tools",
              "--with-data-packaging=static")
    # Static ICU is C++ and needs the C++ runtime wherever it is linked,
    # including into C programs; say so in its pkg-config files.
    for module in ("icu-uc", "icu-i18n", "icu-io"):
        path = os.path.join(SYSROOT, "lib", "pkgconfig", f"{module}.pc")
        if not os.path.exists(path):
            continue
        with open(path) as f:
            lines = f.read().splitlines()
        lines = [line + " -lc++" if line.startswith("Libs:") and "-lc++" not in line else line for line in lines]
        with open(path, "w") as f:
            f.write("\n".join(lines) + "\n")


def build_harfbuzz(src, env):
    meson(src, "harfbuzz", env, "-Dglib=enabled", "-Dgobject=disabled", "-Dicu=enabled",
          "-Dfreetype=enabled", "-Dcairo=disabled", "-Dchafa=disabled", "-Dgraphite2=disabled",
          "-Dtests=disabled", "-Dintrospection=disabled", "-Ddocs=disabled",
          "-Dutilities=disabled", "-Dbenchmark=disabled", "-Dsubset=enabled")


def build_libxml2(src, env):
    meson(src, "libxml2", env, "-Dpython=disabled", "-Dhistory=disabled",
          "-Dreadline=disabled", "-Dicu=disabled", "-Dhttp=disabled", "-Ddocs=disabled",
          "-Dzlib=enabled", "-Dthreads=enabled")


def build_libxslt(src, env):
    autotools(src, "libxslt", env, "--without-python", "--without-crypto",
              "--without-debugger", "--without-profiler")


def build_sqlite(src, env):
    # autosetup, not autoconf: the same flags where it matters.
    build = fresh_build_dir("sqlite")
    run([os.path.join(src, "configure"), f"--host={HOST}", f"--prefix={SYSROOT}",
         "--disable-shared", "--enable-static", "--disable-readline",
         "--disable-editline"], build, env)
    run(["make", f"-j{os.cpu_count()}", "libsqlite3.a"], build, env)
    run(["make", "install-lib", "install-headers", "install-pc"], build, env)


def build_libgpg_error(src, env):
    # The musl lock-object layout ships pre-generated for this host triple.
    build = fresh_build_dir("libgpg-error")
    run([os.path.join(src, "configure"), "--host=x86_64-unknown-linux-musl", f"--prefix={SYSROOT}",
         "--disable-shared", "--enable-static", "--disable-doc", "--disable-tests",
         "--disable-nls", "--disable-languages"], build, env)
    run(["make", f"-j{os.cpu_count()}"], build, env)
    run(["make", "install"], build, env)


def build_libgcrypt(src, env):
    autotools(src, "libgcrypt", env, f"--with-libgpg-error-prefix={SYSROOT}",
              "--disable-doc", "--disable-tests")


def build_libtasn1(src, env):
    autotools(src, "libtasn1", env, "--disable-doc", "--disable-valgrind-tests")


def build_libxkbcommon(src, env):
    meson(src, "libxkbcommon", env, "-Denable-x11=false", "-Denable-wayland=false",
          "-Denable-docs=false", "-Denable-tools=false", "-Denable-bash-completion=false",
          "-Denable-xkbregistry=false", "-Dxkb-config-root=/share/X11/xkb")


def build_egl_registry(src, env):
    # Headers only: the EGL and KHR API headers libepoxy and WebKit compile
    # against. No EGL implementation is installed (docs/design/012 §4.1).
    for part in ("EGL", "KHR"):
        target = os.path.join(SYSROOT, "include", part)
        shutil.rmtree(target, ignore_errors=True)
        shutil.copytree(os.path.join(src, "api", part), target)


def build_libepoxy(src, env):
    # EGL entry points only, loaded lazily with dlopen. OrangeOS has no EGL,
    # so epoxy_has_egl() reports false; nothing may call EGL (docs/design/012).
    meson(src, "libepoxy", env, "-Degl=yes", "-Dglx=no", "-Dx11=false",
          "-Dtests=false", "-Ddocs=false")


def build_woff2(src, env):
    # Its find modules predate static brotli, which also needs brotlicommon.
    lib = os.path.join(SYSROOT, "lib")
    common = os.path.join(lib, "libbrotlicommon.a")
    cmake(src, "woff2", env, "-DCANONICAL_PREFIXES=ON", "-DNOISY_LOGGING=OFF",
          f"-DBROTLIENC_LIBRARIES={os.path.join(lib, 'libbrotlienc.a')};{common}",
          f"-DBROTLIDEC_LIBRARIES={os.path.join(lib, 'libbrotlidec.a')};{common}")


RECIPES = {
    "bison": build_bison,
    "zlib": build_zlib,
    "libffi": build_libffi,
    "pcre2": build_pcre2,
    "glib": build_glib,
    "libpng": build_libpng,
    "libjpeg-turbo": build_libjpeg_turbo,
    "libwebp": build_libwebp,
    "brotli": build_brotli,
    "freetype": build_freetype,
    "expat": build_expat,
    "fontconfig": build_fontconfig,
    "icu": build_icu,
    "harfbuzz": build_harfbuzz,
    "libxml2": build_libxml2,
    "libxslt": build_libxslt,
    "sqlite": build_sqlite,
    "libgpg-error": build_libgpg_error,
    "libgcrypt": build_libgcrypt,
    "libtasn1": build_libtasn1,
    "libxkbcommon": build_libxkbcommon,
    "egl-registry": build_egl_registry,
    "libepoxy": build_libepoxy,
    "woff2": build_woff2,
}
STAGES = {
    "W1": ["zlib", "libffi", "pcre2", "glib"],
    "W3": ["bison", "libpng", "libjpeg-turbo", "libwebp", "brotli", "freetype", "expat",
           "fontconfig", "icu", "harfbuzz", "libxml2", "libxslt", "sqlite", "libgpg-error",
           "libgcrypt", "libtasn1", "libxkbcommon", "egl-registry", "libepoxy", "woff2"],
}


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
