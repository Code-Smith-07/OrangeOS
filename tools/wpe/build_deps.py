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


def unpack(entry, as_name=None):
    """A clean source tree, so a rebuild never sees stale generated files.
    `as_name` unpacks under another name (a host build of a target library)."""
    subprocess.run([sys.executable, os.path.join(TOOLS, "fetch.py"), entry["name"]], check=True)
    tarball = os.path.join(SOURCES, os.path.basename(entry["url"]))
    stage = os.path.join(WORK, "unpack")
    shutil.rmtree(stage, ignore_errors=True)
    os.makedirs(stage)
    subprocess.run(["tar", "-xf", tarball, "-C", stage], check=True)
    (top,) = os.listdir(stage)
    target = os.path.join(SRC, f"{as_name or entry['name']}-{entry['version']}")
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


def build_glib_host(src, env):
    """GLib's tools for the Mac: WebKit's build runs glib-compile-resources
    and glib-mkenums. GLib's own wrap files (pinned by hash or revision in
    the pinned tarball) supply PCRE2, libffi and proxy-libintl."""
    build = fresh_build_dir("glib-host")
    host = host_environment()
    # meson downloads the wraps with Python, which (python.org builds) has
    # no CA store of its own; use the one macOS ships.
    if os.path.exists("/etc/ssl/cert.pem"):
        host["SSL_CERT_FILE"] = "/etc/ssl/cert.pem"
    run(["meson", "setup", build, src, f"--prefix={HOST_TOOLS}", "--libdir=lib",
         "--buildtype=release", "--default-library=static", "--wrap-mode=default",
         "-Dtests=false", "-Dinstalled_tests=false", "-Dintrospection=disabled",
         "-Ddocumentation=false", "-Dman-pages=disabled", "-Dnls=disabled",
         "-Dsysprof=disabled", "-Ddtrace=disabled", "-Dsystemtap=disabled",
         "-Dxattr=false", "-Dlibelf=disabled"], ROOT, host)
    run(["meson", "compile", "-C", build, "gio/glib-compile-resources"], ROOT, host)
    os.makedirs(os.path.join(HOST_TOOLS, "bin"), exist_ok=True)
    shutil.copy2(os.path.join(build, "gio", "glib-compile-resources"), os.path.join(HOST_TOOLS, "bin"))
    # Python scripts, generated when the build is configured.
    for script in ("glib-mkenums", "glib-genmarshal"):
        shutil.copy2(os.path.join(build, "gobject", script), os.path.join(HOST_TOOLS, "bin"))


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
    # GIO's Unix headers also beside the others: some WebKit targets use
    # them without the gio-unix-2.0 include directory being passed on.
    merge_tree(os.path.join(SYSROOT, "include", "gio-unix-2.0", "gio"),
               os.path.join(SYSROOT, "include", "glib-2.0", "gio"))


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


def add_static_libs(module, extra):
    """Static libraries need their private dependencies at every link;
    name them in the pkg-config file's Libs line."""
    path = os.path.join(SYSROOT, "lib", "pkgconfig", f"{module}.pc")
    with open(path) as f:
        lines = f.read().splitlines()
    lines = [line + " " + extra if line.startswith("Libs:") and extra not in line else line for line in lines]
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def build_brotli(src, env):
    cmake(src, "brotli", env, "-DBROTLI_DISABLE_TESTS=ON", "-DBROTLI_BUILD_TOOLS=OFF")
    for module in ("libbrotlidec", "libbrotlienc"):
        add_static_libs(module, "-lbrotlicommon")


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


PATCHES = os.path.join(TOOLS, "patches")

# WPE WebKit's configuration for OrangeOS (docs/design/012 section 3): the
# headless platform only, software rendering, and no media, GPU process,
# sandbox, speech, spelling, hyphenation, WebDriver or introspection.
WPE_OPTIONS = [
    "-DPORT=WPE", "-DCMAKE_BUILD_TYPE=Release", "-DDEVELOPER_MODE=OFF",
    # Paths compiled in: the helper processes live in /usr/libexec/wpe-webkit-2.0
    # (GNUInstallDirs puts libexec under /usr when the prefix is /).
    "-DCMAKE_INSTALL_PREFIX=/", "-DCMAKE_INSTALL_LIBEXECDIR=libexec",
    # AVX-512 kernels in simdutf and Skia's skcms need clang's evex512
    # feature, and OrangeOS has no AVX state support yet; both choose their
    # kernels at run time, so the SSE ones remain.
    "-DUSE_HEADER_MAPS=OFF",
    # -g0: zig's clang emits debug information unless told not to.
    # JIT: OrangeOS keeps W^X, so code pages are read/execute and written
    # through a second, read/write mapping of the same memfd (patch 0008,
    # docs/design/012 §4.5). A 256 MiB pool (JSC's x86-64 default is 1 GiB)
    # keeps libpas's segregated JIT heap; the memfd is sparse.
    "-DCMAKE_CXX_FLAGS=-g0 -DSIMDUTF_IMPLEMENTATION_ICELAKE=0 -DSKCMS_DISABLE_SKX"
    " -DENABLE_SEPARATED_WX_HEAP=1 -DFIXED_EXECUTABLE_MEMORY_POOL_SIZE_IN_MB=256",
    "-DCMAKE_C_FLAGS=-g0 -DSKCMS_DISABLE_SKX",
    "-DENABLE_DOCUMENTATION=OFF", "-DENABLE_INTROSPECTION=OFF", "-DENABLE_JOURNALD_LOG=OFF",
    "-DENABLE_WPE_PLATFORM=ON", "-DENABLE_WPE_PLATFORM_HEADLESS=ON",
    "-DENABLE_WPE_PLATFORM_DRM=OFF", "-DENABLE_WPE_PLATFORM_WAYLAND=OFF",
    "-DENABLE_WPE_LEGACY_API=OFF", "-DENABLE_WPE_QT_API=OFF",
    "-DUSE_ATK=OFF", "-DUSE_FLITE=OFF", "-DUSE_GBM=OFF", "-DUSE_LIBDRM=OFF",
    "-DUSE_LIBBACKTRACE=OFF", "-DUSE_LIBHYPHEN=OFF", "-DUSE_VULKAN=OFF",
    "-DUSE_AVIF=OFF", "-DUSE_JPEGXL=OFF", "-DUSE_LCMS=OFF", "-DUSE_WOFF2=ON",
        # Media (W11): GStreamer linked statically (gst-orange's
    # libgstreamer-full-1.0.a: plugins, FFmpeg decoders, /dev/audio sink).
    # No GL (CPU rendering), no MPEG-TS, no WebRTC.
    "-DUSE_GSTREAMER_FULL=ON", "-DUSE_GSTREAMER_GL=OFF", "-DUSE_GSTREAMER_MPEGTS=OFF",
    # Stated, not left to defaults: options that depend on video keep the
    # value from the first configure, which had video off. MSE is how
    # YouTube streams.
    "-DENABLE_MEDIA_SOURCE=ON", "-DENABLE_VIDEO_USES_ELEMENT_FULLSCREEN=ON",
    "-DENABLE_BUBBLEWRAP_SANDBOX=OFF", "-DENABLE_VIDEO=ON", "-DENABLE_WEB_AUDIO=ON",
    "-DENABLE_ENCRYPTED_MEDIA=OFF", "-DENABLE_SPELLCHECK=OFF", "-DENABLE_WEBDRIVER=OFF",
    "-DENABLE_SPEECH_SYNTHESIS=OFF", "-DENABLE_MINIBROWSER=OFF", "-DENABLE_API_TESTS=OFF",
    "-DENABLE_LAYOUT_TESTS=OFF", "-DENABLE_REMOTE_INSPECTOR=OFF",
    # The bundled unifdef would be built for OrangeOS and then run on the
    # Mac; macOS ships unifdef.
    "-DUSE_SYSTEM_UNIFDEF=ON", "-DUNIFDEF_EXECUTABLE=/usr/bin/unifdef",
    "-DENABLE_GAMEPAD=OFF", "-DENABLE_WEBGL=OFF", "-DUSE_SYSPROF_CAPTURE=OFF",
    "-DENABLE_GPU_PROCESS=OFF", "-DENABLE_WEB_CODECS=OFF", "-DENABLE_MEDIA_STREAM=OFF",
    "-DENABLE_MEDIA_RECORDER=OFF", "-DENABLE_WEB_RTC=OFF", "-DUSE_GSTREAMER=ON",
    "-DUSE_GSTREAMER_WEBRTC=OFF",
]


def apply_patches(src, package):
    directory = os.path.join(PATCHES, package)
    if not os.path.isdir(directory):
        return
    for name in sorted(os.listdir(directory)):
        if name.endswith(".patch"):
            run(["patch", "-p1", "-i", os.path.join(directory, name)], src, os.environ)


def configure_wpe(src, env):
    build = os.path.join(OBJ, "wpe")
    os.makedirs(build, exist_ok=True)
    run(["cmake", "-S", src, "-B", build, "-G", "Ninja",
         f"-DCMAKE_TOOLCHAIN_FILE={configured('orangeos-x86_64.cmake.in')}",
         f"-DGLIB_COMPILE_RESOURCES_EXECUTABLE={os.path.join(HOST_TOOLS, 'bin', 'glib-compile-resources')}",
         *WPE_OPTIONS], ROOT, env)
    return build


def build_wpe(src, env):
    """W6: WPE WebKit from the pinned tarball with OrangeOS's patches."""
    apply_patches(src, "wpewebkit")
    build = configure_wpe(src, env)
    # Only what OrangeOS links: WebKit's objects and the two entry points
    # (collect_wpe). The Linux-ABI jsc and helper executables CMake would
    # also link are not needed.
    # CMake's final link of libWPEWebKit-2.0.so is expected to fail: it
    # omits the static libraries' own dependencies (nghttp2, psl, ffi...)
    # and the gesture handlers unreachable.c supplies, which the OrangeOS
    # program links resolve. Everything else must build.
    try:
        run(["cmake", "--build", build, "--", "-k", "0", *WPE_TARGETS], ROOT, env)
    except subprocess.CalledProcessError:
        missing = [t for t in WPE_TARGETS[1:] if not os.path.exists(os.path.join(build, t))]
        if missing:
            raise SystemExit(f"wpe: not built: {missing}")
        print("wpe: the shared library link failed as expected; collecting its objects", flush=True)
    collect_wpe(build, env)


WPE_TARGETS = [
    "lib/libWPEWebKit-2.0.so.1.11.3",
    "Source/WebKit/CMakeFiles/WebProcess.dir/WebProcess/EntryPoint/unix/WebProcessMain.cpp.o",
    "Source/WebKit/CMakeFiles/NetworkProcess.dir/NetworkProcess/EntryPoint/unix/NetworkProcessMain.cpp.o",
    # JavaScriptCore's shell, linked by build.zig as /bin/jsc (jsc-probe).
    "Source/JavaScriptCore/shell/CMakeFiles/jsc.dir/__/jsc.cpp.o",
]


def install_headers(build):
    """Copy the files cmake_install.cmake installs under include/."""
    import re
    pattern = re.compile(r'file\(INSTALL DESTINATION "\$\{CMAKE_INSTALL_PREFIX\}/(?:usr/)?include/([^"]+)" TYPE FILE FILES(.*?)\)', re.S)
    for base, _dirs, files in os.walk(build):
        if "cmake_install.cmake" not in files:
            continue
        with open(os.path.join(base, "cmake_install.cmake")) as f:
            text = f.read()
        for match in pattern.finditer(text):
            target = os.path.join(SYSROOT, "include", match.group(1))
            os.makedirs(target, exist_ok=True)
            for header in re.findall(r'"([^"]+)"', match.group(2)):
                shutil.copy2(header, target)


def collect_wpe(build, env):
    """OrangeOS links programs statically, so take WebKit apart where CMake
    would link libWPEWebKit-2.0.so: its object files become
    libWPEWebKitStatic.a, WebKit's own static libraries (PAL, Skia,
    xdgmime...) and the web and network processes' entry points are copied
    next to it, and the API headers are installed. build.zig links the UI
    program and the helper processes from these (-Dwpe-probes)."""
    lib = os.path.join(SYSROOT, "lib")
    with open(os.path.join(build, "build.ninja")) as f:
        ninja = f.read()
    start = ninja.index("build lib/libWPEWebKit-2.0.so.")
    header = ninja[start:ninja.index("\n", start)]
    objects = [token for token in header.split() if token.endswith(".o")]
    block = ninja[start:ninja.index("\n\n", start)]
    libraries = next(line for line in block.splitlines() if line.strip().startswith("LINK_LIBRARIES"))
    own = sorted({token for token in libraries.split() if token.startswith("lib/") and token.endswith(".a")})
    archive = os.path.join(lib, "libWPEWebKitStatic.a")
    if os.path.exists(archive):
        os.remove(archive)
    listing = os.path.join(WORK, "wpe-objects.txt")
    with open(listing, "w") as f:
        f.write("\n".join(os.path.join(build, o) for o in objects) + "\n")
    # One archive; the object list is long, so it is passed in chunks.
    for i in range(0, len(objects), 400):
        run([AR, "qc", archive, *[os.path.join(build, o) for o in objects[i:i + 400]]], ROOT, env)
    run([RANLIB, archive], ROOT, env)
    for name in own:
        shutil.copy2(os.path.join(build, name), os.path.join(lib, "libWPE" + os.path.basename(name)[3:]))
    for entry, target in (("WebProcess.dir/WebProcess/EntryPoint/unix/WebProcessMain.cpp.o", "wpe-web-process.o"),
                          ("NetworkProcess.dir/NetworkProcess/EntryPoint/unix/NetworkProcessMain.cpp.o", "wpe-network-process.o")):
        shutil.copy2(os.path.join(build, "Source/WebKit/CMakeFiles", entry), os.path.join(lib, target))
    shutil.copy2(os.path.join(build, "Source/JavaScriptCore/shell/CMakeFiles/jsc.dir/__/jsc.cpp.o"), os.path.join(lib, "jsc-shell.o"))
    # The API headers, as CMake's install rules list them (its install
    # would also want the shared library, which is not built).
    install_headers(build)
    print(f"collected {len(objects)} objects and {', '.join(own)}")


def build_openssl(src, env):
    # OPENSSLDIR is where OrangeOS keeps TLS configuration: the default
    # trust store is /etc/ssl/cert.pem (B9). No async (it needs ucontext,
    # which musl lacks), no engines or shared objects to load.
    build = fresh_build_dir("openssl")
    run(["perl", os.path.join(src, "Configure"), "linux-x86_64", f"--prefix={SYSROOT}",
         "--libdir=lib", "--openssldir=/etc/ssl", "no-shared", "no-dso", "no-async",
         "no-engine", "no-tests", "no-docs", "no-apps", f"CC={CC}", f"AR={AR}", f"RANLIB={RANLIB}"], build, env)
    run(["make", f"-j{os.cpu_count()}", "build_libs"], build, env)
    run(["make", "install_dev"], build, env)


def build_libpsl(src, env):
    # The public suffix list is compiled in (from the tarball's copy), so
    # nothing is read at run time.
    meson(src, "libpsl", env, "-Druntime=no", "-Dbuiltin=true", "-Dtests=false", "-Ddocs=false")


def build_nghttp2(src, env):
    cmake(src, "nghttp2", env, "-DENABLE_LIB_ONLY=ON", "-DBUILD_STATIC_LIBS=ON",
          "-DENABLE_DOC=OFF", "-DWITH_LIBXML2=OFF", "-DWITH_JEMALLOC=OFF")


def build_libsoup(src, env):
    meson(src, "libsoup", env, "-Dgssapi=disabled", "-Dntlm=disabled", "-Dbrotli=enabled",
          "-Dtls_check=false", "-Dintrospection=disabled", "-Dvapi=disabled", "-Ddocs=disabled",
          "-Ddoc_tests=false", "-Dtests=false", "-Dautobahn=disabled", "-Dsysprof=disabled",
          "-Dpkcs11_tests=disabled")


def build_glib_networking(src, env):
    # A static build also produces libgioopenssl.a with g_io_openssl_load(),
    # which programs call to register the TLS backend (no dlopen).
    # Its install ends by running gio-querymodules, an OrangeOS binary, on
    # the Mac to index shared modules, which OrangeOS does not load. The
    # files are installed by then; only that script fails.
    try:
        meson(src, "glib-networking", env, "-Dopenssl=enabled", "-Dgnutls=disabled",
              "-Dlibproxy=disabled", "-Dgnome_proxy=disabled", "-Dinstalled_tests=false")
    except subprocess.CalledProcessError:
        if not os.path.exists(os.path.join(SYSROOT, "lib", "gio", "modules", "libgioopenssl.a")):
            raise
    for base, _dirs, files in os.walk(os.path.join(SYSROOT, "lib", "gio")):
        for name in files:
            if name.endswith(".a"):
                shutil.copy2(os.path.join(base, name), os.path.join(SYSROOT, "lib", name))


def build_javascriptcore(src, env):
    """W4: JavaScriptCore alone (WebKit's JSCOnly port) from the pinned WPE
    WebKit tarball: static WTF, bmalloc and JavaScriptCore, plus the jsc
    shell's object file. build.zig links the shell against OrangeOS's musl
    (-Dwpe-probes); the jsc CMake links here is for the stock Linux ABI and
    is not used."""
    build = os.path.join(OBJ, "javascriptcore")
    os.makedirs(build, exist_ok=True)
    run(["cmake", "-S", src, "-B", build, "-G", "Ninja",
         f"-DCMAKE_TOOLCHAIN_FILE={configured('orangeos-x86_64.cmake.in')}",
         "-DCMAKE_BUILD_TYPE=Release", "-DPORT=JSCOnly", "-DENABLE_STATIC_JSC=ON",
         "-DDEVELOPER_MODE=OFF", "-DENABLE_API_TESTS=OFF", "-DUSE_LIBBACKTRACE=OFF",
         "-DENABLE_REMOTE_INSPECTOR=OFF", "-DEVENT_LOOP_TYPE=Generic",
         # The release tarball omits Tools/Scripts/hmaptool; header maps are
         # only a build-speed optimisation.
         "-DUSE_HEADER_MAPS=OFF",
         # simdutf's AVX-512 kernels need clang's evex512 feature, and
         # OrangeOS has no AVX state support yet; simdutf picks its kernel
         # at run time, so the SSE ones remain.
         "-DCMAKE_CXX_FLAGS=-DSIMDUTF_IMPLEMENTATION_ICELAKE=0",
         "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"], ROOT, env)
    run(["cmake", "--build", build, "--target", "jsc"], ROOT, env)
    lib = os.path.join(SYSROOT, "lib")
    for archive in ("libJavaScriptCore.a", "libWTF.a", "libbmalloc.a"):
        found = [os.path.join(base, archive) for base, _dirs, files in os.walk(build) if archive in files]
        if not found:
            raise SystemExit(f"javascriptcore: {archive} was not built")
        shutil.copy2(found[0], os.path.join(lib, archive))
    # The JIT tiers are a CMake object library linked straight into jsc;
    # archive them for the OrangeOS link.
    jit_objects = sorted(os.path.join(base, name) for base, _dirs, files in os.walk(build)
                         if "JavaScriptCoreJIT.dir" in base for name in files if name.endswith(".o"))
    jit_archive = os.path.join(lib, "libJavaScriptCoreJIT.a")
    if os.path.exists(jit_archive):
        os.remove(jit_archive)
    run([AR, "qc", jit_archive, *jit_objects], ROOT, env)
    run([RANLIB, jit_archive], ROOT, env)
    shell = [os.path.join(base, name) for base, _dirs, files in os.walk(build)
             for name in files if name == "jsc.cpp.o" and "jsc.dir" in base]
    if len(shell) != 1:
        raise SystemExit(f"javascriptcore: expected one jsc.cpp.o, found {shell}")
    shutil.copy2(shell[0], os.path.join(lib, "jsc-shell.o"))


# ── W11: media ──────────────────────────────────────────────────────────────


def build_nasm(src, env):
    # A host tool: FFmpeg's x86 SIMD decoders are NASM sources, and
    # decoding without them is several times slower.
    build = fresh_build_dir("nasm-host")
    host = host_environment()
    run([os.path.join(src, "configure"), f"--prefix={HOST_TOOLS}"], build, host)
    run(["make", f"-j{os.cpu_count()}"], build, host)
    run(["make", "install"], build, host)


# What YouTube and most sites serve: H.264 and VP9 video (VP8 for older
# WebM), AAC and Opus audio (Vorbis, MP3, FLAC for the rest). No encoders,
# muxers, devices or network: GStreamer does the containers and I/O.
FFMPEG_DECODERS = "h264,vp8,vp9,aac,aac_latm,opus,vorbis,mp3,mp3float,flac,pcm_s16le,pcm_f32le"
FFMPEG_PARSERS = "h264,vp8,vp9,aac,aac_latm,opus,vorbis,mpegaudio,flac"


def build_ffmpeg(src, env):
    build = fresh_build_dir("ffmpeg")
    run([os.path.join(src, "configure"), f"--prefix={SYSROOT}", "--enable-cross-compile",
         "--target-os=linux", "--arch=x86_64", f"--cc={CC}", f"--cxx={CXX}", f"--ar={AR}",
         f"--ranlib={RANLIB}", "--nm=/usr/bin/nm", "--x86asmexe=nasm", "--pkg-config=pkg-config",
         "--enable-static", "--disable-shared", "--enable-pic", "--disable-programs", "--disable-doc",
         "--disable-network", "--disable-autodetect", "--disable-debug", "--disable-everything",
         "--enable-avcodec", "--enable-avformat", "--enable-avfilter", "--enable-swresample",
         f"--enable-decoder={FFMPEG_DECODERS}", f"--enable-parser={FFMPEG_PARSERS}",
         # OrangeOS has no AVX state support yet; FFmpeg checks XGETBV
         # before AVX anyway, so the SSE kernels are what runs.
         "--disable-avx512", "--disable-avx512icl"], build, env)
    run(["make", f"-j{os.cpu_count()}"], build, env)
    run(["make", "install"], build, env)


# Each module has its own subset of these options.
GST_COMMON = ["-Dauto_features=disabled", "-Dtests=disabled", "-Ddoc=disabled"]
GST_MODULE = ["-Dexamples=disabled", "-Dnls=disabled"]


def build_gstreamer(src, env):
    # No registry: plugins are linked in and registered by
    # gst_init_static_plugins (gst-orange), and scanning would fork a helper.
    meson(src, "gstreamer", env, *GST_COMMON, *GST_MODULE, "-Dintrospection=disabled", "-Dregistry=false", "-Dtools=disabled",
          "-Dbenchmarks=disabled", "-Dcheck=disabled", "-Dlibunwind=disabled", "-Dlibdw=disabled",
          "-Dbash-completion=disabled", "-Dptp-helper=disabled", "-Dcoretracers=disabled",
          "-Dgst_debug=true",
          # gst_init() then calls gst_init_static_plugins() (gst-orange)
          # directly instead of looking it up with GModule.
          "-Dc_args=-DGST_FULL_STATIC_COMPILATION")


def build_gst_plugins_base(src, env):
    meson(src, "gst-plugins-base", env, *GST_COMMON, *GST_MODULE, "-Dintrospection=disabled",
          "-Dorc=disabled", "-Dtools=disabled",
          "-Dapp=enabled", "-Daudioconvert=enabled", "-Daudioresample=enabled", "-Dplayback=enabled",
          "-Dtypefind=enabled", "-Dvideoconvertscale=enabled", "-Dvolume=enabled",
          "-Daudiotestsrc=enabled", "-Dvideotestsrc=enabled", "-Drawparse=enabled",
          "-Dgl=disabled")


def build_gst_plugins_good(src, env):
    meson(src, "gst-plugins-good", env, *GST_COMMON, *GST_MODULE, "-Dorc=disabled",
          "-Disomp4=enabled", "-Dmatroska=enabled", "-Daudioparsers=enabled", "-Dautodetect=enabled",
          "-Did3demux=enabled", "-Dwavparse=enabled",
          # scaletempo (audiofx) for playback rates, deinterlace for playsink.
          "-Daudiofx=enabled", "-Ddeinterlace=enabled")


def build_opus(src, env):
    # For gst-plugins-bad's opusparse, which WebKit's MSE pipeline uses;
    # decoding itself is FFmpeg's.
    meson(src, "opus", env, "-Dtests=disabled", "-Ddocs=disabled", "-Dextra-programs=disabled")


def build_gst_plugins_bad(src, env):
    meson(src, "gst-plugins-bad", env, *GST_COMMON, *GST_MODULE, "-Dintrospection=disabled",
          "-Dorc=disabled", "-Dtools=disabled",
          # fakevideosink (debugutils): WebKit's player uses it.
          "-Dvideoparsers=enabled", "-Dopus=enabled", "-Ddebugutils=enabled", "-Dgl=disabled")


def build_gst_libav(src, env):
    meson(src, "gst-libav", env, *GST_COMMON)


def build_gst_orange(env):
    """OrangeOS's GStreamer glue (userland/libs/gst-orange): the static
    plugin registration and /dev/audio sink, archived together with the
    GStreamer libraries and plugins as libgstreamer-full-1.0.a, with the
    pkg-config file WebKit's USE_GSTREAMER_FULL looks for."""
    build = fresh_build_dir("gst-orange")
    cflags = subprocess.run(["pkg-config", "--cflags", "gstreamer-audio-1.0"], env=env, check=True,
                            capture_output=True, text=True).stdout.split()
    obj = os.path.join(build, "gstorange.o")
    run([CC, *CFLAGS.split(), *cflags, "-c", os.path.join(ROOT, "userland/libs/gst-orange/gstorange.c"),
         "-o", obj], build, env)
    lib = os.path.join(SYSROOT, "lib")
    archives = sorted(os.path.join(lib, "gstreamer-1.0", n) for n in os.listdir(os.path.join(lib, "gstreamer-1.0"))
                      if n.endswith(".a"))
    archives += sorted(os.path.join(lib, n) for n in os.listdir(lib) if n.startswith("libgst") and n.endswith("-1.0.a")
                       and n != "libgstreamer-full-1.0.a")
    full = os.path.join(lib, "libgstreamer-full-1.0.a")
    if os.path.exists(full):
        os.remove(full)
    script = "\n".join([f"create {full}", f"addmod {obj}", *(f"addlib {a}" for a in archives), "save", "end", ""])
    subprocess.run([AR, "-M"], input=script, text=True, env=env, check=True)
    run([RANLIB, full], ROOT, env)
    requires = ("gstreamer-1.0 gstreamer-base-1.0 gstreamer-app-1.0 gstreamer-audio-1.0 gstreamer-video-1.0 "
                "gstreamer-pbutils-1.0 gstreamer-tag-1.0 gstreamer-allocators-1.0 gstreamer-fft-1.0")
    with open(os.path.join(lib, "pkgconfig", "gstreamer-full-1.0.pc"), "w") as f:
        f.write(f"prefix={SYSROOT}\nlibdir=${{prefix}}/lib\n\nName: gstreamer-full-1.0\n"
                "Description: OrangeOS: GStreamer with its plugins linked in (gst-orange)\n"
                f"Version: 1.28.7\nRequires: {requires}\nLibs: -L${{libdir}} -lgstreamer-full-1.0\n")
    print(f"gst-orange: {len(archives)} archives in {full}")


# Built from this repository rather than a pinned tarball.
LOCAL_RECIPES = {"gst-orange": build_gst_orange}

RECIPES = {
    "nasm": build_nasm,
    "ffmpeg": build_ffmpeg,
    "opus": build_opus,
    "gstreamer": build_gstreamer,
    "gst-plugins-base": build_gst_plugins_base,
    "gst-plugins-good": build_gst_plugins_good,
    "gst-plugins-bad": build_gst_plugins_bad,
    "gst-libav": build_gst_libav,
    "bison": build_bison,
    "zlib": build_zlib,
    "libffi": build_libffi,
    "pcre2": build_pcre2,
    "glib": build_glib,
    "glib-host": build_glib_host,
    "wpe": build_wpe,
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
    "wpewebkit": build_javascriptcore,
    "openssl": build_openssl,
    "libpsl": build_libpsl,
    "nghttp2": build_nghttp2,
    "libsoup": build_libsoup,
    "glib-networking": build_glib_networking,
}
# Recipes that build a pinned source under another name.
ALIASES = {"glib-host": "glib", "wpe": "wpewebkit"}

STAGES = {
    "W1": ["zlib", "libffi", "pcre2", "glib"],
    "W3": ["bison", "libpng", "libjpeg-turbo", "libwebp", "brotli", "freetype", "expat",
           "fontconfig", "icu", "harfbuzz", "libxml2", "libxslt", "sqlite", "libgpg-error",
           "libgcrypt", "libtasn1", "libxkbcommon", "egl-registry", "libepoxy", "woff2"],
    "W4": ["wpewebkit"],
    "W5": ["openssl", "libpsl", "nghttp2", "libsoup", "glib-networking"],
    "W11": ["nasm", "ffmpeg", "opus", "gstreamer", "gst-plugins-base", "gst-plugins-good",
            "gst-plugins-bad", "gst-libav", "gst-orange"],
}


def main(argv):
    if argv[:1] == ["--stage"] and len(argv) == 2 and argv[1] in STAGES:
        names = STAGES[argv[1]]
    else:
        names = argv
    unknown = [n for n in names if n not in RECIPES and n not in LOCAL_RECIPES]
    if unknown or not names:
        raise SystemExit(__doc__ + (f"\nno recipe for: {unknown}" if unknown else ""))
    pins = manifest()
    env = environment()
    for name in names:
        if name in LOCAL_RECIPES:
            print(f"== {name} (userland)", flush=True)
            LOCAL_RECIPES[name](env)
            continue
        pin = pins[ALIASES.get(name, name)]
        print(f"== {name} {pin['version']}", flush=True)
        RECIPES[name](unpack(pin, as_name=name), env)
    print(f"installed into {SYSROOT}")


if __name__ == "__main__":
    main(sys.argv[1:])
