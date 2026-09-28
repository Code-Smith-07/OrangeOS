# OrangeOS browser: WPE WebKit trial

Status (2026-09-28): **WPE WebKit is OrangeOS's browser engine.** It passed
its W7 gate by rendering a page inside OrangeOS (§6,
[screenshot](../screenshots/wpe-first-render.png)), and the owner dropped the
Chromium plan the same day (doc 011 is archived as runtime history).
Created: 2026-09-28. Owner decision: try WPE WebKit first, because it looks
faster to bring up than Chromium. If the trial succeeds, the Chromium plan is
retired. If it fails, Chromium work resumes where it stopped.

No browser engine is installed yet. This document is a plan and a trial
ledger, not a claim that anything works.

## 1. Why we are pausing Chromium

The Chromium plan ([011](011-native-chromium-browser.md)) finished its runtime
part (A1–A7): musl, libc++, threads, pipes, Unix sockets, epoll, `posix_spawn`,
shared memory, file mappings, V8-style memory, `getrandom` and signals. The
next hard step was C14, cross-building Chromium. That step is very large:
- It needs roughly 100 GB of disk and many hours of compiling.
- Google does not support building Chromium for Linux on a macOS host.
- The Ozone backend comes after that.

Doc 008 and doc 011 both already named WPE WebKit as the fallback engine. The
owner chose (2026-09-28) to try it now, before C14, for these reasons:
- **It is built for this.** WPE is WebKit's official port for embedded and
  unusual platforms. It does not depend on any UI toolkit (GTK, Qt, Cocoa).
  Drawing and input go through a small backend interface that the platform
  implements.
- **CPU rendering is supported.** WPE paints with Skia and can render on the
  CPU, so a GPU is not needed at first.
- **The build is smaller.** WPE uses CMake with ordinary Linux libraries, not
  Chromium's GN/depot_tools stack.
- **The web engine is modern.** WebKit (Safari's engine) with JavaScriptCore
  handles modern sites, unlike NetSurf or Dillo.

## 2. What stays the same

- **Nothing built so far is discarded.** A1–A7 are engine-neutral; WebKit
  needs the same things (threads, sockets, shared memory, JIT memory,
  signals). The Chromium pins and workspace on the external drive stay as
  they are.
- **The platform decision in [011 §2.1](011-native-chromium-browser.md) still
  holds.** The engine is built as a Linux target against OrangeOS's musl, and
  the userland layer translates calls. The kernel ABI does not change, and no
  Linux kernel code is used.
- **The honesty rules still apply.** Unsupported calls fail with real errors,
  never faked success. Linux-only subsystems are switched off explicitly.
- **Peel and Zest stay.** The browser runs inside OrangeOS in a Peel window.
  There is no host WebView and no streaming from the Mac.

## 3. What WPE needs (verified against upstream)

These are the required packages found by upstream `Source/cmake/OptionsWPE.cmake`
on WebKit `main` (checked 2026-09-28). Versions are minimums.

| Area | Libraries |
|---|---|
| Core | GLib ≥ 2.70 (GIO, GModule, threads), libxml2 ≥ 2.9.13, SQLite3, zlib |
| Text | ICU ≥ 70.1, HarfBuzz ≥ 2.7.4 (with ICU), FreeType ≥ 2.9 |
| Images | libjpeg, libpng ≥ 1.5, libwebp (demux) |
| Network | libsoup ≥ 3.0 (which also needs libpsl and nghttp2, plus glib-networking for TLS) |
| Crypto | libgcrypt ≥ 1.7 (Web Crypto), libtasn1 |
| Input | libxkbcommon ≥ 0.4 |
| Graphics | libepoxy ≥ 1.5.4 |

Options to switch **off** for the first build: `ENABLE_BUBBLEWRAP_SANDBOX`,
`ENABLE_WPE_PLATFORM_DRM`, `ENABLE_WPE_PLATFORM_WAYLAND`, `USE_GBM`,
`USE_LIBDRM`, `USE_ATK`, `USE_FLITE`, `USE_LIBBACKTRACE`, `USE_LIBHYPHEN`,
`ENABLE_JOURNALD_LOG`, `ENABLE_DOCUMENTATION`, `ENABLE_INTROSPECTION`, and
video/audio (GStreamer). Keep `ENABLE_WPE_PLATFORM_HEADLESS` on for the first
run. Each option switched off is recorded in the ledger (§6) with the reason.

## 4. Known risks (not yet verified)

1. **EGL through libepoxy — answered at W3, proven at W7 (2026-09-28).**
   The engine runs with no EGL at all, using patches 0001 (no display in
   the web process) and 0007 (hardware acceleration and compositing off
   when the display has no rendering device; WPE has no policy API for it).
   The analysis from the 2.54.0 source: Mesa is not needed for first light; one small recorded patch
   is. Details:
   - **A supported CPU path exists.** With the GLib API's
     `WEBKIT_HARDWARE_ACCELERATION_POLICY_NEVER`, hardware acceleration and
     accelerated compositing are off. `AcceleratedSurface::usesGL()` is then
     false for non-composited rendering, and pages are painted by Skia into
     a raster surface over a shared-memory `ShareableBitmap`
     (`RenderTargetSHMImage`).
   - **Transport.** Without GBM (`USE_GBM` off), the UI process offers
     `RendererBufferTransportMode::SharedMemory` only
     (`WebProcessPoolGLib.cpp`).
   - **CPU painting.** `WEBKIT_SKIA_ENABLE_CPU_RENDERING=1` makes image
     buffers and tiles raster-only (`ProcessCapabilities`).
   - **The one blocker.** On WPE, `WebProcess::platformInitializeWebProcess`
     calls `initializePlatformDisplayIfNeeded()` unconditionally. With no EGL
     that ends in "Could not create EGL display … Aborting" and `CRASH()`.
     GTK only initializes the display when hardware acceleration is enabled
     (`DrawingAreaCoordinatedGraphicsGLib.cpp`).
   - **Plan.** A patch of about 10 lines making WPE do the same: skip the
     display when the transport mode has no `Hardware`. WebGL is switched
     off, since it needs `PlatformDisplay::sharedDisplay()`, which
     `RELEASE_ASSERT`s.
   - **libepoxy behaves.** It is linked, but only looks for EGL through
     `dlopen`, which static musl refuses. `epoxy_has_egl()` then reports
     false without aborting; this is checked in the guest (§7).
   - **Still open.** About 40 WebCore/WebKit files call `sharedDisplay()`;
     any that run in this mode will show up at W7 and be patched or
     switched off there. If they cannot be avoided, a software EGL (Mesa)
     returns as the fallback.
2. **Shared libraries and `dlopen`.** OrangeOS programs are statically linked
   today. WebKit normally builds `libWPEWebKit.so`, and GIO loads TLS
   (glib-networking) as a module.
   - Options: link everything statically and register the GIO TLS module
     statically, or add dynamic linking to OrangeOS (`PT_INTERP` in the ELF
     loader plus musl's own dynamic loader). The file mappings from A4 make
     dynamic linking realistic.
   - Decided in W1.
3. **Cross-building from macOS.** The first choice is Zig's clang
   (`zig cc`/`zig c++` targeting `x86_64-linux-musl`, the toolchain OrangeOS
   already uses) with CMake/Meson cross files.
   - The fallback is a musl cross toolchain (such as Buildroot) in a Linux
     container. Objects built against stock musl 1.2.5 headers link against
     OrangeOS's musl, because the headers and ABI are the same; only the
     syscall layer differs.
   - Disk use is measured and recorded; WPE is expected to be far smaller
     than Chromium, but that is not yet measured.
4. **Multiple processes.** WebKit runs a UI process, a WebProcess and a
   NetworkProcess, joined by Unix socket pairs with descriptor passing.
   OrangeOS has these pieces (A2/A3), but WebKit has not been run on them.
5. **JavaScriptCore JIT — decided (owner, 2026-09-28): keep W^X and give JSC
   a dual-mapped JIT (the first option below); see §7 for its status.** On Linux x86-64,
   JSC maps its JIT memory writable and executable at once. It has no
   separated W/X heap there (`ENABLE_SEPARATED_WX_HEAP` is 0, and its
   dual-mapping path is Darwin-only). OrangeOS refuses such mappings by
   design (W^X). So W4 runs JSC's interpreter (LLInt) with `--useJIT=false`:
   correct, and much slower on heavy scripts. The owner has to choose one of:
   - keep W^X and patch JSC to write code through a second, writable
     mapping of the same memory (a memfd mapped twice: the way Chromium's V8
     and Firefox work on Linux);
   - allow read-write-execute memory for programs that ask for it, as
     macOS does with `MAP_JIT`;
   - stay on the interpreter.

   The first keeps the security property and is the recommendation.

## 5. Milestones

Platform services from the Chromium plan are still needed and are reused
as-is: **B8** sockets through musl, **B9** TLS roots, **B10** fonts and
**B11** a persistent profile.

| # | Milestone | Done when |
|---|---|---|
| W0 | Pin a WPE WebKit stable release and every dependency version; measure source size | Pins recorded in §7 — **done 2026-09-28** |
| W1 | Toolchain: cross files for `zig cc` → OrangeOS musl sysroot; decide static vs dynamic (§4.2) | A small GLib test program runs in OrangeOS — **done 2026-09-28** (§7) |
| W2 | B8: BSD sockets, non-blocking I/O, readiness, DNS through musl (shared with 011) | Socket probe passes in QEMU on 2 and 4 vCPUs — **done 2026-09-28** (§7) |
| W3 | Base libraries: zlib, libpng, libjpeg, libwebp, FreeType, HarfBuzz, ICU, libxml2, SQLite, GLib, libepoxy, libgcrypt, libtasn1, libxkbcommon; answer the EGL question (§4.1) | Each has a small test that runs in OrangeOS — **done 2026-09-28** (§7) |
| W4 | JavaScriptCore alone (the `jsc` shell) | JavaScript runs in OrangeOS, JIT on or recorded off — **done 2026-09-28, JIT recorded off** (§7) |
| W5 | Network stack: libsoup 3, libpsl, nghttp2, OpenSSL/GnuTLS + glib-networking; B9 TLS roots | An HTTPS GET works from inside OrangeOS — **done 2026-09-28** (§7) |
| W6 | WPE WebKit build (options in §3); B10 fonts | The engine links for OrangeOS — **done 2026-09-28** (§7) |
| W7 | First run, headless: load a local page and write the rendered frame to a PNG | The screenshot matches the page — **done 2026-09-28** (§6, §7) |
| W8 | OrangeOS WPE platform backend: draw into a Peel window through shared memory, keyboard and mouse | A page shows in a Peel window and responds to input |
| W9 | Minimal browser shell (address bar, back/forward, tabs later), B11 profile, installed on the disk image | Orange Browser opens from the desktop and loads real sites |

## 6. Decision gate: keep WPE or go back to Chromium

The trial is judged at **W7** (headless first run), or earlier if a blocker
appears.

**Keep WPE and retire Chromium** when all of these hold:
- JSC runs.
- A real page renders on the CPU.
- HTTPS works.
- No blocker needs a fork of WebKit that we would have to keep maintaining.

At that point doc 011 is marked archived and its runtime ledger stays as
history.

**Result at W7 (2026-09-28): passed.**
- JSC runs (interpreter; the JIT waits on §4.5).
- A real page renders on the CPU: `docs/screenshots/wpe-first-render.png` is the frame WebKit drew in the guest, with text, a rounded card, a gradient, and content changed by the page's own script.
- HTTPS works through the same stack WebKit uses (libsoup, glib-networking, OpenSSL, Mozilla roots).
- No fork of WebKit is needed. Seven recorded patches (`tools/wpe/patches/wpewebkit`), each a few lines:
  - two are OrangeOS policy: 0001 no EGL display without hardware rendering, and 0007 CPU rendering when the display has no rendering device;
  - five fix upstream build gaps that other builds would hit too: cross-compiling on a macOS host, video off, libdrm off, and two linkage omissions a shared library hides.

  Four IPC handlers WPE generates but never compiles are satisfied by an aborting shim outside WebKit (`userland/bin/wpe-render/unreachable.c`).

**Decision (owner, 2026-09-28):** keep WPE; the Chromium plan is dropped and its workspace removed.

Not proven yet: loading an HTTPS page through WebKit itself (W5 proved the stack below it), a page in a real window (W8), and performance beyond this test page.

**Go back to Chromium** when a blocker would cost more than the Chromium path.
Examples:
- EGL cannot be avoided without porting Mesa.
- JSC cannot run on OrangeOS.
- The dependency stack cannot be cross-built in reasonable time.

In that case the blocker is recorded here and work resumes at 011 §11.0. B8–B11
are shared, so that work carries over.

## 7. Trial ledger

| Date | Entry |
|---|---|
| 2026-09-28 | Trial opened. Chromium paused after A1–A7 (last commit `513c374`). No WPE code, pins or builds yet. |
| 2026-09-28 | **W0 done.** WPE WebKit **2.54.0** (released 2026-09-16) and 27 libraries pinned in `tools/wpe/sources.json` with SHA-256. `tools/wpe/fetch.py` downloads with the system curl and verifies each file. For WebKit, GLib, fontconfig, libxml2, libxslt, libepoxy, OpenSSL, libsoup and glib-networking it also cross-checks upstream's published checksum; all matched. Choices: GLib 2.88.3 (latest fix release of the mature series, not the fresh 2.90.0); libsoup 3.6.6 (3.7 is the development series); OpenSSL 3.5.8 LTS (not 4.0) for glib-networking; ICU 78.3. Deferred with their first-build switches: lcms2, libavif, libjxl, GStreamer, libwpe. All sources come to 200 MB. |
| 2026-09-28 | **W1 done: GLib runs inside OrangeOS.** How it works:<br>- **Toolchain.** `tools/wpe/bin/orange-cc`/`orange-c++` wrap Zig's clang for `x86_64-linux-musl` with build.zig's code-generation flags (baseline x86-64, no stack protector, no red zone, no sanitizers, non-PIC). `tools/wpe/orangeos-x86_64.ini.in` is the meson cross file. `tools/wpe/build_deps.py` builds pinned sources out of tree into `build/wpe/sysroot` as static libraries (zlib's configure needed `CHOST` so it stops choosing Apple's libtool).<br>- **Linking.** zlib 1.3.2, libffi 3.8.0, PCRE2 10.48 and GLib 2.88.3 (GLib, GObject, GIO, GModule) built without source changes. build.zig links programs against them and OrangeOS's own musl, opt-in with `-Dwpe-probes`, so normal builds are unchanged. §4.2 is settled as static for now; dynamic linking waits until something needs it.<br>- **glib-probe covers:** strings, Unicode case mapping, PCRE2 regex, GVariant, SHA-256, base64 and the real-time clock; 4 threads × 20,000 mutex increments, an async queue and a thread pool; a main loop with a repeating timeout, an idle source, a pipe fd source and a cross-thread `g_main_context_invoke` wakeup; a GObject type with a property, notify and a 2-argument signal marshalled through libffi; GIO `g_file_set_contents`, load, `query_info` (statx), `/tmp` listing, a line reader, delete, and a gzip round trip through GIO converters; `g_spawn_sync` capturing a child's stdout (GLib's posix_spawn path).<br>- **One layer fix:** musl turns `faccessat` with flags into `faccessat2`, which is now translated. OrangeOS has no symbolic links and real ids equal effective ids, so `AT_SYMLINK_NOFOLLOW`/`AT_EACCESS` cannot change the answer; other flags get EINVAL.<br>- **Limit:** GLib's fork path does not exist, so `g_spawn` needs `G_SPAWN_LEAVE_DESCRIPTORS_OPEN` (and no working directory or child setup) to use posix_spawn. `GSubprocess` defaults are not usable yet.<br>- **Verified:** runtime suite with the probe on 2 and 4 vCPUs, the plain runtime suite (probe absent), and the desktop and Files suites.<br>- **Sizes:** sysroot 85 MB; glib-probe 3.8 MB. |
| 2026-09-28 | **W3 done: WebKit's base libraries run inside OrangeOS, and the EGL question is answered (§4.1).**<br>- **Libraries.** Cross-built with the W1 toolchain, all as static libraries and without source changes: libpng 1.6.58, libjpeg-turbo 3.2.0, libwebp 1.6.0, brotli 1.2.0, FreeType 2.14.3, expat 2.8.5, fontconfig 2.18.3, ICU 78.3, HarfBuzz 14.5.0, libxml2 2.15.4, libxslt 1.1.45, SQLite 3.53.4, libgpg-error 1.61, libgcrypt 1.12.4, libtasn1 4.21.0, libxkbcommon 1.13.2, libepoxy 1.5.10 (with Khronos EGL/KHR headers pinned at EGL-Registry `db3425b8`, headers only) and woff2 1.0.2.<br>- **Build notes.**<br>  - ICU builds twice: a Mac build supplies the data tools for the OrangeOS build. Static ICU's pkg-config files now name the C++ runtime (`-lc++`).<br>  - GNU bison 3.8.2 is built as a project-local host tool, because libxkbcommon needs ≥ 3.6 and macOS has 2.3.<br>  - The compiler wrappers drop `-c` when `-E` is given, because meson preprocesses that way and zig would otherwise compile.<br>  - Packages that install configuration (fontconfig) install through a staging directory: libraries go into the sysroot and run-time files into `build/wpe/rootfs`. Symlinks become copies, since CitrusFS has none.<br>  - woff2's old CMake gets static brotli's `brotlicommon` explicitly.<br>- **Recorded shortcut.** libjpeg-turbo is built without its SIMD code because NASM is not on the host; it is correct but slower. Revisit for performance.<br>- **Probe.** wpe-libs-probe (45 MB, mostly ICU data) checks, in the guest: PNG, JPEG and WebP (with demux) round trips; FreeType rendering of Inter; HarfBuzz shaping with ICU script detection (Latin left-to-right, Arabic right-to-left); fontconfig matching fonts in `/share/fonts` through the staged `/etc/fonts`; a WOFF2 round trip of JetBrains Mono; ICU Turkish casing, word breaks, German collation and number format; libxml2 XPath and libxslt; SQLite writing 1,000 rows to a `/tmp` file and reading them back after reopening; libgcrypt SHA-256 and AES-256-GCM (a bad tag rejected); libtasn1 DER; a brotli round trip; an xkbcommon keymap with Shift; and `epoxy_has_egl()` reporting no EGL.<br>- **OS work found by the probe.**<br>  - **Record locks.** SQLite needs POSIX record locks. The kernel now has advisory locks (`kernel/fs/lock.zig`, `fd_control` 8–13): POSIX locks owned by the process (released by any close of the file or on exit) and OFD locks owned by the description; range splitting; `F_GETLK` reporting the holder; `F_SETLKW` waits that are interruptible; EDEADLK for cycles between processes. file-probe now checks all of this against a second process.<br>  - **chmod.** fontconfig creates its cache with `mkdir` then `chmod`. OrangeOS keeps no permission bits (one user, modes fixed per kind), so chmod to the mode a file already reports succeeds, any other mode gets EPERM, and read-only filesystems get EROFS.<br>- **Disk image.** `ORANGE_WPE_PROBES=1 scripts/mkdisk.sh` adds 160 MiB and stages the probes, `/etc/fonts`, the two OFL fonts in `/share/fonts` and every library's licence; ordinary images are unchanged.<br>- **Verified:** WPE runtime suite on 2 and 4 vCPUs; plain runtime suite on 2 and 4; desktop; Files; 23 kernel filesystem tests.<br>- **Sizes:** sysroot 215 MB; the whole trial `build/wpe` tree is about 2.3 GB with sources and build objects (the Mac-side ICU build and object trees can be deleted after a build). |
| 2026-09-28 | **W2 (B8) done: BSD sockets through musl.** Shared with the Chromium plan; its ledger row points here.<br>- **Kernel.** Internet sockets are file descriptions (`kernel/net/socket.zig`), with native calls 157–163 in BSD's shape using Linux's `sockaddr_in`, levels and option names. `sendmsg`/`recvmsg` carry addresses. Also: read/write, `shutdown`, poll/epoll readiness (IN/OUT/ERR/HUP/RDHUP), FIONREAD, SO_ERROR for non-blocking connects, and send/receive timeouts.<br>- **TCP rewritten (`kernel/net/tcp.zig`).**<br>  - Connections are allocated from the heap, not 4 fixed slots.<br>  - 64 KiB receive and send rings, with the advertised window taken from free space; as many segments in flight as the peer's window allows.<br>  - The MSS option; retransmission from the oldest unacknowledged byte with back-off; zero-window probes.<br>  - All closing states, including a detached close finishing in the background; a reset for segments that match no connection; checksums verified on receipt; random initial sequence numbers; keepalive.<br>  - Still missing: out-of-order reassembly, congestion control, window scaling.<br>- **Network thread.** A kernel thread now drains the NIC and runs the timers: every 1 ms while connections or UDP sockets are open, every 20 ms otherwise. Waiting calls sleep on channels instead of polling. The e1000 is still not interrupt-driven.<br>- **ARP.** Packets to a next hop that is not yet resolved are held and sent when the ARP reply arrives, so a first SYN is not lost.<br>- **The original native TCP calls** (97–100) are now a thin layer over the new engine; their tests pass unchanged.<br>- **musl layer.** `socket`/`connect`/`bind`/`listen`/`accept`/`getsockname`/`getpeername`/`getsockopt`/`setsockopt`, addresses through `sendto`/`recvfrom`/`sendmsg`/`recvmsg`, MSG_PEEK/TRUNC/NOSIGNAL, FIONREAD. `/etc/hosts` and `/etc/resolv.conf` (QEMU's resolver, 10.0.2.3) are on every image.<br>- **Honest refusals:** IPv6 and named local sockets get EAFNOSUPPORT, `listen` gets EOPNOTSUPP, 127/8 gets ENETUNREACH (no loopback interface), and a blocking SO_LINGER gets EOPNOTSUPP.<br>- **inet-probe** (in the normal runtime suite) checks against host fixtures: `/etc/hosts`; a DNS exchange through musl's resolver; blocking and non-blocking connects with epoll; a 2 MiB transfer (about 460 KiB/s under QEMU TCG); half-close; refused connections both ways; UDP sendto/recvfrom, connect and MSG_TRUNC; options and refusals.<br>- **Verified:** plain and WPE runtime suites on 2 and 4 vCPUs, desktop (its Files preview now opens `/etc/hosts`, which sorts first), Files, 23 filesystem tests. |
| 2026-09-28 | **W4 done: JavaScriptCore runs in OrangeOS, on its interpreter.**<br>- **Build.** WebKit's JSCOnly port from the pinned 2.54.0 tarball, with the W3 toolchain: static WTF, bmalloc, JavaScriptCore and its JIT tiers (archived as `libJavaScriptCoreJIT.a`). The `jsc` shell is linked by build.zig against OrangeOS's musl and libc++ (67 MB, mostly ICU data).<br>- **Build fixes.** The compiler wrappers allow PIC when asked (WebKit builds PIE). Header maps are off (the release tarball omits `hmaptool`). simdutf's AVX-512 kernels are compiled out (clang 19 needs `evex512`, and OrangeOS has no AVX state support yet; simdutf chooses its kernel at run time).<br>- **OS fix found by it.** JSC freezes its configuration page with `mprotect(PROT_READ)` and aborts if that fails. mprotect now works on the loaded program image: exec records its range, and W^X still holds.<br>- **Porting aid.** `ORANGE_SYSCALL_TRACE=1` makes the musl layer log each Linux call and its result to stderr; it found the mprotect failure. `-Dwpe-first` runs the WPE probes at the start of the runtime tests.<br>- **jsc-probe** runs `jsc --useJIT=false` on a script with 17 checks: classes with private fields, generators, destructuring, BigInt, JSON, Map/Set, typed arrays, RegExp, string methods, `Intl` (NumberFormat de-DE, Collator, Turkish case mapping, Segmenter, DateTimeFormat) through ICU, recursion, sorting 50,000 numbers, and async/await through the shell's microtask queue. The workload takes about 280 ms under QEMU TCG.<br>- **JIT off:** see §4.5; this is a decision for the owner.<br>- **Verified** with W2 above. |
| 2026-09-28 | **W5 done: HTTPS through libsoup, glib-networking and OpenSSL; B9 TLS roots.**<br>- **Libraries.** OpenSSL 3.5.8 (static, OPENSSLDIR `/etc/ssl`, no async because musl has no ucontext, no engines or DSOs), libpsl (public suffix list compiled in), nghttp2 (library only), libsoup 3.6.6 and glib-networking 2.80.1. The OpenSSL backend is linked statically and registered with `g_io_openssl_load()`, since there is no `dlopen`.<br>- **Build changes.** All OrangeOS libraries are now built position-independent: glib-networking and WebKit link static libraries into shared objects while building, and PIC links into OrangeOS's static programs. Static brotli's pkg-config files name `brotlicommon`. glib-networking's install ends by running an OrangeOS binary on the Mac, so that one step is tolerated.<br>- **B9.** Mozilla's CA bundle as curl.se extracts it (2026-09-25, 121 roots; its published SHA-256 matched) is `/etc/ssl/cert.pem` on every image.<br>- **https-probe** checks:<br>  - the OpenSSL backend registers;<br>  - a libsoup GET with keep-alive to an HTTPS fixture on the host (a throwaway test CA from `tools/wpe/test_certs.sh`) succeeds when that CA is trusted;<br>  - the same request is refused with G_TLS_ERROR_BAD_CERTIFICATE against the Mozilla roots, so verification is real;<br>  - the Mozilla roots load. |
| 2026-09-28 | **W6 done: WPE WebKit 2.54.0 builds for OrangeOS.**<br>- **Configuration.** WPE port, WPE Platform with only the headless backend; video, audio, media stream, WebRTC, GStreamer, WebGL, GPU process, GBM/libdrm, sandbox, gamepad, speech, spelling, hyphenation, AVIF/JPEG XL/LCMS, WebDriver, remote inspector, introspection and docs off. XSLT and WOFF2 on.<br>- **Host tools.** `glib-compile-resources` and `glib-mkenums` are built for the Mac (`glib-host`; GLib's own pinned wraps supply PCRE2, libffi and proxy-libintl); unifdef is macOS's.<br>- **Build notes.** Header maps are off. The AVX-512 kernels in simdutf and Skia's skcms are compiled out (clang 19 `evex512`; no AVX state support). GIO's Unix headers are also installed beside the others.<br>- **Patches** 0002–0006 fix upstream build gaps (see §6).<br>- **Collect step.** `collect_wpe` archives the 1,584 objects CMake links into `libWPEWebKit-2.0.so` into `libWPEWebKitStatic.a`, copies WebKit's own static libraries and the helper entry points, and installs the API headers from CMake's install rules. build.zig links `wpe-render`, `WPEWebProcess` and `WPENetworkProcess` statically, about 150 MB each, stripped.<br>- **Recorded to fix:** the objects carry debug information (4 GB archive) because an explicit `CMAKE_CXX_FLAGS` overrode `-g0`; the options now say `-g0` for the next full build. The trial's build tree is 18 GB. |
| 2026-09-28 | **W7 done: the first headless render.** `wpe-render` is the UI process.<br>- **Setup.** A web view on WPE Platform's headless display, WebGL off, an ephemeral network session, and caches under `/tmp`.<br>- **Processes.** WebKit starts `WPENetworkProcess` and `WPEWebProcess` from `/usr/libexec/wpe-webkit-2.0` through GSubprocess → posix_spawn, and the three talk over SEQPACKET socket pairs with descriptor passing.<br>- **The page** `file:///share/wpe-tests/hello.html` loads, its script runs, and a JavaScript evaluation returns the state it set. The snapshot (1024×768) is checked: orange background 77%, white card 18%, 6,844 text pixels, the gradient bar. It is saved as a PNG in the guest and sent to the host over the serial console in base64.<br>- **Found on the way:** file:// loads need content types, which GIO takes from the shared-mime-info database. A `globs2` index for the web's common types is on the WPE image (`userland/share/mime/globs2`); the full database is a follow-up. The web process warns that the injected bundle cannot be loaded (no `dlopen`), which this embedder does not use.<br>- **Also:** inet-probe's EAGAIN check no longer depends on timing (it failed once on 4 vCPUs when all data arrived before the first read). The desktop test's Files step now opens `/etc/ssl` and previews `cert.pem`.<br>- **Verified:** the WPE runtime suite with the render on 2 and 4 vCPUs, the plain runtime suite on 2 and 4, desktop, Files, 23 filesystem tests. |

## References

- [WPE | WebKit](https://webkit.org/wpe/)
- [WPE architecture](https://wpewebkit.org/about/architecture.html)
- [WPE WebKit 2.48 highlights (Skia CPU/GPU rendering)](https://wpewebkit.org/blog/2025-04-11-wpewebkit-2.48.html)
- [The WPE Platform API](https://blogs.igalia.com/llepage/the-wpe-platform-api/)
- [Creating a new WPE backend](https://blogs.igalia.com/llepage/the-process-of-creating-a-new-wpe-backend/)
- [Upstream OptionsWPE.cmake](https://github.com/WebKit/WebKit/blob/main/Source/cmake/OptionsWPE.cmake)
