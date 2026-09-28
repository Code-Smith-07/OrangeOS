# OrangeOS browser: WPE WebKit trial

Status (2026-09-28): **active trial; the Chromium port is paused, not cancelled.**
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

1. **EGL through libepoxy.** Epoxy is a required dependency. We do not yet
   know whether a CPU-only (Skia CPU) WPE build runs with no EGL at all.
   - Options if it does not: find the code path that tolerates a missing EGL
     display, carry a small recorded patch, or port a software EGL (Mesa).
     Mesa is a large job.
   - W3 answers this before anything else is invested.
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
5. **JavaScriptCore JIT.** It needs W^X executable memory, and on Linux it
   suspends threads with signals. Both exist (A5, A7). If the JIT fails, JSC
   can run without it (`ENABLE_JIT=OFF`, C loop) while it is fixed; that
   fallback is slower and is recorded.

## 5. Milestones

Platform services from the Chromium plan are still needed and are reused
as-is: **B8** sockets through musl, **B9** TLS roots, **B10** fonts and
**B11** a persistent profile.

| # | Milestone | Done when |
|---|---|---|
| W0 | Pin a WPE WebKit stable release and every dependency version; measure source size | Pins recorded in §6 |
| W1 | Toolchain: cross files for `zig cc` → OrangeOS musl sysroot; decide static vs dynamic (§4.2) | A small GLib test program runs in OrangeOS |
| W2 | B8: BSD sockets, non-blocking I/O, readiness, DNS through musl (shared with 011) | Socket probe passes in QEMU on 2 and 4 vCPUs |
| W3 | Base libraries: zlib, libpng, libjpeg, libwebp, FreeType, HarfBuzz, ICU, libxml2, SQLite, GLib, libepoxy, libgcrypt, libtasn1, libxkbcommon; answer the EGL question (§4.1) | Each has a small test that runs in OrangeOS |
| W4 | JavaScriptCore alone (the `jsc` shell) | JavaScript runs in OrangeOS, JIT on or recorded off |
| W5 | Network stack: libsoup 3, libpsl, nghttp2, OpenSSL/GnuTLS + glib-networking; B9 TLS roots | An HTTPS GET works from inside OrangeOS |
| W6 | WPE WebKit build (options in §3); B10 fonts | The engine links for OrangeOS |
| W7 | First run, headless: load a local page and write the rendered frame to a PNG | The screenshot matches the page |
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

## References

- [WPE | WebKit](https://webkit.org/wpe/)
- [WPE architecture](https://wpewebkit.org/about/architecture.html)
- [WPE WebKit 2.48 highlights (Skia CPU/GPU rendering)](https://wpewebkit.org/blog/2025-04-11-wpewebkit-2.48.html)
- [The WPE Platform API](https://blogs.igalia.com/llepage/the-wpe-platform-api/)
- [Creating a new WPE backend](https://blogs.igalia.com/llepage/the-process-of-creating-a-new-wpe-backend/)
- [Upstream OptionsWPE.cmake](https://github.com/WebKit/WebKit/blob/main/Source/cmake/OptionsWPE.cmake)
